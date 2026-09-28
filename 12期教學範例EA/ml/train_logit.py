#!/usr/bin/env python3
"""
離線訓練 BQ_ML 邏輯斯迴歸模型（選用；EA 內建線上學習，不跑這支也能用）

流程
  1. 回測時設定 InpMLMode=只學習、InpMLExportCSV=true
     → 產生 %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\BeeQuantML\\<EA>_<商品>_<週期>_<magic>_tester.csv
  2. python train_logit.py <csv> [<csv> ...] --out <模型檔>
     會做「前 70% 訓練 / 後 30% 驗證」的時間序切分，印出過濾前後的勝率與期望值
  3. 把 --out 產生的 .model 放回 Common\\Files\\BeeQuantML\\（檔名要與 EA 一致）
     EA 設 InpMLLoadModel=true 就會載入，之後仍會持續線上學習

只需要 numpy：pip install numpy
"""
import argparse
import csv
import math
import sys

import numpy as np

NF = 12
FEATURES = ["dir", "rsi14", "close_vs_ema20", "ema20_vs_ema50", "ema20_slope", "atr_regime",
            "spread_atr", "hour_sin", "hour_cos", "last_body", "range_pos20", "adx14"]


def load(paths):
    rows = []
    for p in paths:
        with open(p, newline="", encoding="latin-1") as f:
            for r in csv.DictReader(f):
                try:
                    x = [float(r[k]) for k in FEATURES]
                    y = int(float(r["label"]))
                    be = float(r.get("be", 0.5) or 0.5)
                except (KeyError, ValueError):
                    continue
                rows.append((r["time"], x, y, be))
    rows.sort(key=lambda t: t[0])
    if not rows:
        sys.exit("沒有讀到資料，請確認 CSV 是 BQ_ML 匯出的格式")
    X = np.array([r[1] for r in rows], dtype=float)
    y = np.array([r[2] for r in rows], dtype=float)
    be = np.array([r[3] for r in rows], dtype=float)
    return X, y, be


def fit(X, y, l2=0.001, lr=0.1, epochs=400):
    mean = X.mean(axis=0)
    sd = X.std(axis=0, ddof=1)
    sd[sd < 1e-9] = 1.0
    Z = np.clip((X - mean) / sd, -5, 5)
    w = np.zeros(NF)
    b = 0.0
    n = len(y)
    for _ in range(epochs):
        p = 1.0 / (1.0 + np.exp(-np.clip(Z @ w + b, -30, 30)))
        g = p - y
        w -= lr * (Z.T @ g / n + l2 * w)
        b -= lr * g.mean()
    return w, b, mean, sd


def predict(X, w, b, mean, sd):
    Z = np.clip((X - mean) / sd, -5, 5)
    return 1.0 / (1.0 + np.exp(-np.clip(Z @ w + b, -30, 30)))


def auc(y, p):
    order = np.argsort(p)
    ranks = np.empty(len(p))
    ranks[order] = np.arange(1, len(p) + 1)
    pos = y == 1
    npos, nneg = pos.sum(), (~pos).sum()
    if npos == 0 or nneg == 0:
        return float("nan")
    return (ranks[pos].sum() - npos * (npos + 1) / 2) / (npos * nneg)


def expectancy(y, be):
    """以 R 為單位的平均損益：勝 = (1-be)/be R，敗 = -1R"""
    rr = (1 - be) / np.maximum(be, 1e-6)
    return float(np.mean(np.where(y == 1, rr, -1.0))) if len(y) else float("nan")


def save_model(path, w, b, mean, sd, n):
    m2 = (sd ** 2) * (n - 1)
    with open(path, "w", encoding="ascii", newline="\r\n") as f:
        f.write("BQML1\n")
        f.write(f"{NF}\n")
        f.write(f"{n}\n")
        f.write(f"{n}\n")
        f.write(",".join(f"{v:.10f}" for v in list(w) + [b]) + "\n")
        f.write(",".join(f"{v:.10f}" for v in mean) + "\n")
        f.write(",".join(f"{v:.10f}" for v in m2) + "\n")


def main():
    ap = argparse.ArgumentParser(description="訓練 BQ_ML 模型")
    ap.add_argument("csv", nargs="+", help="BQ_ML 匯出的 CSV")
    ap.add_argument("--out", help="輸出模型檔 (.model)")
    ap.add_argument("--edge", type=float, default=0.03, help="放行門檻：高於兩平勝率多少 (同 EA 的 InpMLThreshold)")
    ap.add_argument("--split", type=float, default=0.7, help="訓練資料比例 (依時間切分)")
    a = ap.parse_args()

    X, y, be = load(a.csv)
    n = len(y)
    k = int(n * a.split)
    print(f"樣本 {n} 筆，訓練 {k} / 驗證 {n - k}，整體勝率 {y.mean():.1%}")
    if k < 50 or n - k < 20:
        print("樣本太少，結果僅供參考 (建議至少數百筆)")

    w, b, mean, sd = fit(X[:k], y[:k])
    if n - k > 0:
        p = predict(X[k:], w, b, mean, sd)
        yt, bt = y[k:], be[k:]
        keep = p >= bt + a.edge
        print(f"驗證 AUC {auc(yt, p):.3f}")
        print(f"不過濾：{len(yt)} 筆 勝率 {yt.mean():.1%} 期望值 {expectancy(yt, bt):+.3f}R")
        if keep.any():
            print(f"過濾後：{keep.sum()} 筆 勝率 {yt[keep].mean():.1%} 期望值 {expectancy(yt[keep], bt[keep]):+.3f}R")
        else:
            print("過濾後：沒有任何單通過門檻，請降低 --edge")

    print("\n權重 (標準化後)：")
    for name, v in sorted(zip(FEATURES, w), key=lambda t: -abs(t[1])):
        print(f"  {name:16s} {v:+.4f}")

    if a.out:
        w, b, mean, sd = fit(X, y)        # 用全部資料重新訓練後輸出
        save_model(a.out, w, b, mean, sd, n)
        print(f"\n模型已輸出：{a.out}")


if __name__ == "__main__":
    main()
