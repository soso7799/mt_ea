"""
波段避險分組：近 251 個交易日 D1 報酬率的相關係數。
  同向組：組內每一對相關係數 ≥ 0.70（貪婪法由相關最高的一對開始擴充）
  反向避險：某商品與某同向組每個成員相關係數都 ≤ -0.70
  獨立商品：其餘
可信度：組內最低相關 ≥0.90 高、≥0.75 中、其餘低。
"""
import itertools

import numpy as np
import pandas as pd

TH = 0.70
DAYS = 251


def corr_matrix(d1s):
    rets = {}
    for s, df in d1s.items():
        if df is not None and len(df) > 30:
            x = df.set_index(df["time"].dt.normalize())["close"]
            rets[s] = x.pct_change()
    r = pd.DataFrame(rets).dropna(how="all").tail(DAYS)
    return r.corr(min_periods=100), len(r)


def build_groups(d1s):
    C, n = corr_matrix(d1s)
    syms = list(C.columns)
    left = set(syms)
    groups = []
    pairs = sorted(((C.loc[a, b], a, b) for a, b in itertools.combinations(syms, 2)
                    if not np.isnan(C.loc[a, b])), reverse=True)
    for v, a, b in pairs:
        if v < TH:
            break
        if a in left and b in left:
            g = [a, b]
            for s in sorted(left - set(g), key=lambda s: -C.loc[a, s]):
                if all(C.loc[s, x] >= TH for x in g):
                    g.append(s)
            groups.append(sorted(g))
            left -= set(g)
    out = []
    for i, g in enumerate(groups, 1):
        vals = [C.loc[a, b] for a, b in itertools.combinations(g, 2)]
        out.append(dict(name=f"同向組{i}", members=g, avg=np.mean(vals), min=np.min(vals), kind="same"))
    for s in sorted(left):
        for grp in out[:]:
            if grp["kind"] != "same":
                continue
            vals = [C.loc[s, x] for x in grp["members"]]
            if all(v <= -TH for v in vals):
                out.append(dict(name=f"反向避險 {s} ↔ {grp['name']}", members=[s], against=grp["members"],
                                avg=np.mean(vals), min=np.max(vals), kind="hedge"))
    hedged = {m for g in out if g["kind"] == "hedge" for m in g["members"]}
    indep = sorted(left - hedged)
    return out, indep, n


def reliability(g, n):
    m = abs(g["min"])
    lv = "高" if m >= 0.90 else ("中" if m >= 0.75 else "低")
    return f"{lv}（{n} 天樣本）"
