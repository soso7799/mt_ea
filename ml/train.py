"""
ML 第 2 階段：用 MLRecorder 產生的 CSV 訓練「信號過濾」模型並匯出 ONNX。

用法（Windows 命令提示字元）：
    python train.py --data H:\\ml\\features --out "G:\\我的雲端硬碟\\releases\\models" --report H:\\ml\\reports

流程：
  1. 讀取資料夾內所有 features_*.csv，只保留有結果的列（label 0/1；逾時預設排除）
  2. 依時間排序做 walk-forward 驗證（永遠用過去訓練、用之後測試，中間留間隔避免結果重疊）
  3. 比較「全部信號」與「模型過濾後」在不同門檻下的筆數、勝率、每筆期望值(R)
  4. 用全部資料訓練最終模型，匯出 model.onnx + model.json（特徵清單、建議門檻、驗證結果）

輸出的 model.onnx：輸入 float[1, N]，輸出 label(int64) 與 probabilities(float[1,2])，
與 MLFilter.mqh 的讀法一致。
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys

import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

THRESHOLDS = [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]


def load(data_dir, keep_timeout, all_rows):
    files = sorted(glob.glob(os.path.join(data_dir, "features_*.csv")))
    if not files:
        sys.exit(f"[錯誤] {data_dir} 找不到 features_*.csv")
    frames = []
    for f in files:
        df = pd.read_csv(f)
        df["source"] = os.path.basename(f)
        frames.append(df)
    df = pd.concat(frames, ignore_index=True)

    feats = [c for c in df.columns if c.startswith("f_")]
    for f in files:
        cols = [c for c in pd.read_csv(f, nrows=0).columns if c.startswith("f_")]
        if cols != feats:
            sys.exit(f"[錯誤] {os.path.basename(f)} 的特徵欄位與其他檔案不同，請只放同一版 EA 產生的資料")

    n_total = len(df)
    df = df[df["label"] >= 0]                      # -1 = 回測結束時仍未有結果
    if keep_timeout:
        df.loc[df["label"] == 2, "label"] = 0      # 逾時視為失敗
    else:
        df = df[df["label"] != 2]
    if not all_rows:
        # 實盤只會對「沒有持倉、波動正常」的商品下單，訓練資料也只用這些情況
        df = df[(df["has_pos"] == 0) & (df["vol_ok"] == 1)]

    df["signal_time"] = pd.to_datetime(df["signal_time"], format="%Y.%m.%d %H:%M:%S")
    df = df.drop_duplicates(subset=["signal_time", "symbol", "dir"])
    df = df.sort_values("signal_time").reset_index(drop=True)

    # 每筆的報酬（R 倍數）：TP = tp距離/sl距離，SL = -1
    r_win = (df["tp"] - df["entry"]).abs() / (df["entry"] - df["sl"]).abs()
    df["r"] = np.where(df["label"] == 1, r_win, -1.0)
    return df, feats, files, n_total


def make_model(kind):
    if kind == "logreg":
        return make_pipeline(StandardScaler(), LogisticRegression(C=0.5, max_iter=2000))
    # 用 GradientBoostingClassifier 而非 HistGradientBoosting：skl2onnx 對後者的轉換
    # 在新版 scikit-learn 會失敗
    return GradientBoostingClassifier(
        max_depth=3, learning_rate=0.05, n_estimators=200, min_samples_leaf=50,
        subsample=0.8, random_state=0)


def stats(r):
    n = len(r)
    if n == 0:
        return {"n": 0, "win": None, "exp_r": None, "total_r": 0.0}
    return {"n": int(n), "win": float((r > 0).mean()), "exp_r": float(r.mean()), "total_r": float(r.sum())}


def walk_forward(df, feats, kind, folds, gap_hours):
    """擴展視窗：第 k 段用前面所有資料訓練，測試第 k+1 段。回傳所有測試列的機率。"""
    n = len(df)
    edges = np.linspace(0, n, folds + 2, dtype=int)   # 第一段只當訓練
    prob = np.full(n, np.nan)
    aucs = []
    X, y, t = df[feats].to_numpy(np.float32), df["label"].to_numpy(), df["signal_time"]
    for k in range(1, folds + 1):
        test = np.arange(edges[k], edges[k + 1])
        cutoff = t.iloc[edges[k]] - pd.Timedelta(hours=gap_hours)
        train = np.where(t < cutoff)[0]
        if len(train) < 200 or len(np.unique(y[train])) < 2 or len(test) == 0:
            continue
        m = make_model(kind).fit(X[train], y[train])
        p = m.predict_proba(X[test])[:, 1]
        prob[test] = p
        if len(np.unique(y[test])) == 2:
            aucs.append(roc_auc_score(y[test], p))
    return prob, aucs


def export_onnx(model, n_feats, path):
    from skl2onnx import to_onnx
    from skl2onnx.common.data_types import FloatTensorType

    onx = to_onnx(model, initial_types=[("input", FloatTensorType([None, n_feats]))],
                  options={id(model): {"zipmap": False}}, target_opset=15)
    with open(path, "wb") as f:
        f.write(onx.SerializeToString())


def check_onnx(path, model, X):
    import onnxruntime as ort
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    outs = sess.get_outputs()
    assert len(outs) == 2, "ONNX 應有 2 個輸出 (label, probabilities)"
    got = sess.run(None, {"input": X[:200]})[1][:, 1]
    want = model.predict_proba(X[:200])[:, 1]
    return float(np.max(np.abs(got - want)))


def main():
    ap = argparse.ArgumentParser(description="訓練 MultiCurrency_EA 的 ML 信號過濾模型")
    ap.add_argument("--data", required=True, help="features_*.csv 所在資料夾（例如 H:\\ml\\features）")
    ap.add_argument("--out", required=True, help="模型輸出資料夾（例如 ...\\releases\\models）")
    ap.add_argument("--report", default=None, help="報告輸出資料夾（預設同 --out）")
    ap.add_argument("--model", choices=["gbm", "logreg"], default="gbm",
                    help="gbm=梯度提升樹（預設），logreg=邏輯迴歸（較保守）")
    ap.add_argument("--folds", type=int, default=5, help="walk-forward 測試段數")
    ap.add_argument("--gap-hours", type=float, default=72,
                    help="訓練與測試之間的間隔小時，應 >= EA 的 Inp_MLMaxHoldHours")
    ap.add_argument("--keep-timeout", action="store_true", help="逾時的信號當作失敗保留（預設排除）")
    ap.add_argument("--all-rows", action="store_true", help="包含已有持倉 / 波動異常時的信號")
    ap.add_argument("--holdout-months", type=float, default=0,
                    help="最近幾個月不拿來訓練，留給 MT5 測試器做最後驗證（例如 3）")
    args = ap.parse_args()

    df, feats, files, n_total = load(args.data, args.keep_timeout, args.all_rows)
    holdout_from = None
    if args.holdout_months > 0:
        holdout_from = df["signal_time"].max() - pd.Timedelta(days=round(args.holdout_months * 30.44))
        n_before = len(df)
        df = df[df["signal_time"] < holdout_from].reset_index(drop=True)
        print(f"保留 {holdout_from:%Y-%m-%d} 之後的 {n_before - len(df)} 筆不訓練（留給 MT5 測試器驗證）")
    print(f"讀入 {len(files)} 個檔案，共 {n_total} 筆，可用 {len(df)} 筆，特徵 {len(feats)} 個")
    if len(df) < 1000:
        print("⚠️ 可用資料少於 1000 筆，結果可信度很低，建議拉長回測期間")
    print(f"期間 {df['signal_time'].min()} ~ {df['signal_time'].max()}，TP 比例 {df['label'].mean():.1%}")

    prob, aucs = walk_forward(df, feats, args.model, args.folds, args.gap_hours)
    tested = ~np.isnan(prob)
    if tested.sum() == 0:
        sys.exit("[錯誤] 資料太少，無法做 walk-forward 驗證")
    r = df["r"].to_numpy()
    base = stats(r[tested])
    rows = []
    for th in THRESHOLDS:
        keep = tested & (prob >= th)
        s = stats(r[keep])
        s["threshold"] = th
        s["kept"] = s["n"] / base["n"] if base["n"] else 0
        rows.append(s)

    # 建議門檻：保留至少 30% 信號的前提下，期望值最高者；且必須優於不過濾
    cands = [x for x in rows if x["kept"] >= 0.3 and x["exp_r"] is not None]
    best = max(cands, key=lambda x: x["exp_r"]) if cands else None
    improves = best is not None and best["exp_r"] > base["exp_r"] + 0.02

    # 最終模型：用全部資料訓練
    X = df[feats].to_numpy(np.float32)
    final = make_model(args.model).fit(X, df["label"].to_numpy())

    os.makedirs(args.out, exist_ok=True)
    report_dir = args.report or args.out
    os.makedirs(report_dir, exist_ok=True)
    onnx_path = os.path.join(args.out, "model.onnx")
    export_onnx(final, len(feats), onnx_path)
    diff = check_onnx(onnx_path, final, X)

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    meta = {
        "created": stamp,
        "model": args.model,
        "features": feats,
        "n_features": len(feats),
        "rows": int(len(df)),
        "period": [str(df["signal_time"].min()), str(df["signal_time"].max())],
        "walk_forward_auc": aucs,
        "baseline": base,
        "thresholds": rows,
        "suggested_threshold": best["threshold"] if improves else None,
        "improves_on_baseline": bool(improves),
        "onnx_max_abs_diff": diff,
        "source_files": [os.path.basename(f) for f in files],
        "holdout_from": str(holdout_from) if holdout_from is not None else None,
    }
    with open(os.path.join(args.out, "model.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    def fmt(s):
        if s["n"] == 0:
            return f"{0:>6}      -        -"
        return f"{s['n']:>6}  {s['win']:>6.1%}  {s['exp_r']:>+7.3f}"

    lines = [
        f"ML 信號過濾模型報告  {stamp}",
        f"模型: {args.model}   資料: {len(df)} 筆   期間: {meta['period'][0]} ~ {meta['period'][1]}",
        f"Walk-forward AUC（0.5=沒有預測力）: " + ", ".join(f"{a:.3f}" for a in aucs)
        + (f"   平均 {np.mean(aucs):.3f}" if aucs else ""),
        "",
        "樣本外（walk-forward 測試段）結果：",
        f"{'門檻':>8}  {'筆數':>6}  {'勝率':>6}  {'期望值R':>7}  保留比例",
        f"{'不過濾':>8}  {fmt(base)}   100%",
    ]
    for s in rows:
        lines.append(f"{s['threshold']:>8.2f}  {fmt(s)}  {s['kept']:>5.0%}")
    lines.append("")
    if improves:
        lines.append(f"✅ 建議 Inp_MLThreshold = {best['threshold']:.2f}"
                     f"（期望值 {base['exp_r']:+.3f}R → {best['exp_r']:+.3f}R，保留 {best['kept']:.0%} 信號）")
        if holdout_from is not None:
            lines.append(f"   下一步：在 MT5 策略測試器回測 {holdout_from:%Y.%m.%d} 到今天，"
                         "比較 Inp_UseML=false 與 true。")
        else:
            lines.append("   下一步：用 --holdout-months 3 重新訓練，保留最近 3 個月在 MT5 測試器驗證。")
    else:
        lines.append("❌ 模型沒有明顯優於不過濾（期望值改善 < 0.02R 或保留信號太少），不建議啟用 Inp_UseML。")
    lines.append(f"ONNX 與 sklearn 輸出最大差異: {diff:.2e}")
    report = "\n".join(lines)
    print("\n" + report)
    with open(os.path.join(report_dir, f"report_{stamp}.txt"), "w", encoding="utf-8") as f:
        f.write(report + "\n")
    print(f"\n模型: {onnx_path}")


if __name__ == "__main__":
    main()
