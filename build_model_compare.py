#!/usr/bin/env python3
"""新客样本上的新戳额模型与线上模型效果对比，输出自包含 HTML。

样本：wagego_02 中的新客首笔成交样本（application_rank = 1，戳额时间落在窗口内）。
新戳额模型分数按 last_limit_flow_id = 打分文件的 flow_id 关联；线上模型分数取自主表。

用法：
    python build_model_compare.py
    python build_model_compare.py --score-csv xxx.csv --output 对比.html
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from html import escape
from math import erf, sqrt
from pathlib import Path

import numpy as np
import pandas as pd

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_LABEL = PROJECT_DIR / "原始数据" / "table_tmp_eliam_wagego_dwd_loan_apply_label.csv"
DEFAULT_SCORE = PROJECT_DIR / "aus_new_wagego_credit_20261028_v1_0_txn_lgb_score.csv"
DEFAULT_OUTPUT = PROJECT_DIR / "模型效果对比.html"

OLD_SCORE = "aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626"
NEW_SCORE = "aus_new_wagego_credit_20261028_v1_0_txn_lgb_score"

OLD_NAME = "线上模型"
NEW_NAME = "新戳额模型"
OLD_DESC = "发标 3rd 模型"
NEW_DESC = "交易流水 LGB 模型"

WINDOWS = (15, 7)  # 主口径在前
CUTOFF_REJECTS = (10, 20, 30, 40, 50)
THROUGH_TARGETS = (4, 5, 6, 7, 8, 9)  # 通过坏率预算（%）
THROUGH_REF = 8  # 结论引用的坏率预算
WEEK_MIN_BAD = 10  # 单周算 AUC 的最少坏样本 / 好样本

Z95 = 1.959963984540054


# --------------------------------------------------------------------------- 统计


def midrank(values) -> np.ndarray:
    return pd.Series(np.asarray(values, dtype=float)).rank(method="average").to_numpy()


def auc_ks(score, label):
    """AUC（midrank 法，正确处理并列）与 KS。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n1 = int(label.sum())
    n0 = int(len(label) - n1)
    if n1 == 0 or n0 == 0:
        return None, None

    ranks = midrank(score)
    auc = float((ranks[label == 1].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))

    order = np.argsort(score, kind="mergesort")
    sorted_score = score[order]
    sorted_label = label[order]
    unique, first = np.unique(sorted_score, return_index=True)
    last = np.searchsorted(sorted_score, unique, side="right") - 1
    cum_bad = np.cumsum(sorted_label)[last]
    cdf_bad = cum_bad / n1
    cdf_good = (last + 1 - cum_bad) / n0
    ks = float(np.max(np.abs(cdf_bad - cdf_good)))
    return auc, ks


def delong(score, label):
    """单模型 DeLong：返回 AUC 与标准误。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    pos, neg = label == 1, label == 0
    n1, n0 = int(pos.sum()), int(neg.sum())
    ranks_all = midrank(score)
    ranks_pos = midrank(score[pos])
    ranks_neg = midrank(score[neg])
    auc = float((ranks_all[pos].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))
    v10 = (ranks_all[pos] - ranks_pos) / n0
    v01 = 1 - (ranks_all[neg] - ranks_neg) / n1
    var = v10.var(ddof=1) / n1 + v01.var(ddof=1) / n0
    return auc, sqrt(var), v10, v01


def delong_paired(score_a, score_b, label):
    """配对 DeLong 检验：两个模型在同一批样本上的 AUC 差异。"""
    label = np.asarray(label, dtype=int)
    pos, neg = label == 1, label == 0
    n1, n0 = int(pos.sum()), int(neg.sum())
    out = {}
    for name, score in (("a", score_a), ("b", score_b)):
        auc, se, v10, v01 = delong(score, label)
        out[name] = {"auc": auc, "se": se, "v10": v10, "v01": v01}
    var_a = out["a"]["se"] ** 2
    var_b = out["b"]["se"] ** 2
    cov = float(
        np.cov(out["a"]["v10"], out["b"]["v10"], ddof=1)[0, 1] / n1
        + np.cov(out["a"]["v01"], out["b"]["v01"], ddof=1)[0, 1] / n0
    )
    diff = out["b"]["auc"] - out["a"]["auc"]
    var_diff = var_a + var_b - 2 * cov
    se_diff = sqrt(max(var_diff, 0.0))
    z = diff / se_diff if se_diff else float("nan")
    p = 2 * (1 - 0.5 * (1 + erf(abs(z) / sqrt(2)))) if se_diff else float("nan")
    out["diff"] = {
        "diff": diff,
        "se": se_diff,
        "ci_low": diff - Z95 * se_diff,
        "ci_high": diff + Z95 * se_diff,
        "z": z,
        "p": p,
    }
    return out


def deciles(score, label, amount=None, loss=None):
    """按分数升序切 10 档（第 1 档最低风险）；可选带放款规模与坏账损失本金。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n = len(score)
    order = np.argsort(score, kind="mergesort")
    rank = np.empty(n, dtype=int)
    rank[order] = np.arange(1, n + 1)
    q = np.ceil(rank * 10 / n).astype(int)
    rows = []
    for k in range(1, 11):
        mask = q == k
        item = {
            "q": k,
            "n": int(mask.sum()),
            "bad": int(label[mask].sum()),
            "rate": float(label[mask].mean() * 100) if mask.sum() else None,
        }
        if amount is not None:
            amt = float(amount[mask].sum())
            loss_amt = float(loss[mask].sum()) if loss is not None else 0.0
            item["amt"] = amt
            item["loss_amt"] = loss_amt
            item["amt_rate"] = round(loss_amt / amt * 100, 2) if amt else None
        rows.append(item)
    return rows


def capture_curve(score, label, max_reject=60):
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n = len(score)
    order = np.argsort(-score, kind="mergesort")
    bad_cum = np.cumsum(label[order])
    total_bad = int(label.sum())
    points = []
    for rej in range(0, max_reject + 1):
        k = int(round(n * rej / 100))
        captured = int(bad_cum[k - 1]) if k > 0 else 0
        points.append([rej, round(captured / total_bad * 100, 2) if total_bad else 0.0])
    return points


def cutoff_stats(score, label, reject_pct, amount=None, loss=None):
    """按分数拒绝最差 reject_pct% 后的通过坏率与坏账捕获率。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n = len(score)
    k = int(round(n * reject_pct / 100))
    order = np.argsort(-score, kind="mergesort")
    rejected = np.zeros(n, dtype=bool)
    rejected[order[:k]] = True
    kept = ~rejected
    total_bad = int(label.sum())
    kept_bad = int(label[kept].sum())
    stats = {
        "reject_pct": reject_pct,
        "reject_n": k,
        "kept_n": int(kept.sum()),
        "kept_bad": kept_bad,
        "kept_rate": round(float(kept_bad / kept.sum() * 100), 3) if kept.sum() else None,
        "capture": round((total_bad - kept_bad) / total_bad * 100, 2) if total_bad else None,
        "rejected_bad": total_bad - kept_bad,
    }
    if amount is not None and loss is not None:
        total_loss = float(loss.sum())
        kept_loss = float(loss[kept].sum())
        stats["kept_amt"] = float(amount[kept].sum())
        stats["kept_loss"] = kept_loss
        stats["capture_amt"] = (
            round((total_loss - kept_loss) / total_loss * 100, 2) if total_loss else None
        )
    return stats


def approval_envelope(score, label):
    """通过率包络：返回 (bad_rate 升序, 该坏率下可达的最大通过笔数)。

    对每个"保留 k 笔"的切点算通过坏率，再按坏率排序取累计最大通过数，
    得到"坏率不超过 x 时最多能通过多少人"的单调曲线。
    """
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n = len(score)
    order = np.argsort(-score, kind="mergesort")
    cum_bad = np.concatenate([[0], np.cumsum(label[order])])
    total_bad = int(label.sum())
    kept = np.arange(1, n + 1)
    rate = (total_bad - cum_bad[n - kept]) / kept * 100
    idx = np.argsort(rate, kind="mergesort")
    rate_sorted, kept_sorted = rate[idx], kept[idx]
    keep_max = np.maximum.accumulate(kept_sorted)
    better = np.concatenate([[True], np.diff(keep_max) > 0])
    return rate_sorted[better], keep_max[better]


HEAT_EDGES = (1, 3, 7, 15)  # 坏率分级边界：<1 / 1–3 / 3–7 / 7–15 / ≥15


def heat_level(rate):
    """把坏率映射到 1–5 的热力档。"""
    if rate is None:
        return 0
    for level, edge in enumerate(HEAT_EDGES, start=1):
        if rate < edge:
            return level
    return 5


def kept_stats(score, label, amount, kept):
    """通过分数最低的 kept 笔（即放行最安全的部分）后的通过结构。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    amount = np.asarray(amount, dtype=float)
    n = len(score)
    kept = int(min(max(kept, 0), n))
    order = np.argsort(-score, kind="mergesort")  # 降序：头部是高分（高风险）
    mask = np.zeros(n, dtype=bool)
    mask[order[n - kept:]] = True  # 保留尾部 = 分数最低
    bad = int(label[mask].sum())
    return {
        "kept": kept,
        "approval": round(kept / n * 100, 1) if n else None,
        "bad": bad,
        "good": kept - bad,
        "rate": round(bad / kept * 100, 2) if kept else None,
        "amt": float(amount[mask].sum()),
        "good_amt": float(amount[mask & (label == 0)].sum()),
        "bad_amt": float(amount[mask & (label == 1)].sum()),
    }


def roc_points(score, label, steps=200):
    """ROC 点：按阈值从高到低，返回 [[FPR%, TPR%], ...]。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n1, n0 = int(label.sum()), int(len(label) - label.sum())
    order = np.argsort(score, kind="mergesort")  # 升序，便于按阈值分组
    sorted_score = score[order]
    sorted_label = label[order]
    unique = np.unique(sorted_score)
    first = np.searchsorted(sorted_score, unique, side="left")
    pos_ge = np.cumsum(sorted_label[::-1])[::-1][first]
    neg_ge = np.cumsum((1 - sorted_label)[::-1])[::-1][first]
    # 阈值升序 => 取 >= 阈值为正例，FPR/TPR 由大到小；反转后从原点出发
    fpr = np.concatenate([[0.0], (neg_ge / n0)[::-1], [1.0]])
    tpr = np.concatenate([[0.0], (pos_ge / n1)[::-1], [1.0]])
    idx = np.unique(np.linspace(0, len(fpr) - 1, min(steps, len(fpr))).astype(int))
    return [[round(float(fpr[i] * 100), 2), round(float(tpr[i] * 100), 2)] for i in idx]


# --------------------------------------------------------------------------- 数据


def load_sample(label_csv: Path, score_csv: Path, start: str, end: str) -> pd.DataFrame:
    label = pd.read_csv(label_csv, encoding="utf-8-sig", low_memory=False)
    label["last_limit_time"] = pd.to_datetime(label["last_limit_time"], errors="coerce")
    rank = pd.to_numeric(label["application_rank"], errors="coerce")
    sample = label[
        (rank == 1)
        & (label["last_limit_time"] >= pd.Timestamp(start))
        & (label["last_limit_time"] < pd.Timestamp(end))
    ].copy()
    if sample.empty:
        raise ValueError(f"样本为空：{start} ~ {end}")

    score = pd.read_csv(score_csv, encoding="utf-8-sig")
    score = score[["flow_id", NEW_SCORE]].copy()
    score["flow_id"] = score["flow_id"].astype(str).str.strip()
    score = score.drop_duplicates("flow_id")

    sample["last_limit_flow_id"] = sample["last_limit_flow_id"].astype(str).str.strip()
    merged = sample.merge(
        score, left_on="last_limit_flow_id", right_on="flow_id", how="inner"
    )
    merged = merged.rename(columns={NEW_SCORE: "new_score"})
    merged["old_score"] = pd.to_numeric(merged[OLD_SCORE], errors="coerce")
    # 线上模型的 -1 是"未打分"哨兵值，按缺失处理，不参与排序
    merged.loc[merged["old_score"] < 0, "old_score"] = np.nan
    merged["new_score"] = pd.to_numeric(merged["new_score"], errors="coerce")

    merged["days_to_disburse"] = (
        pd.to_datetime(merged["disburse_time"]) - merged["last_limit_time"]
    ).dt.total_seconds() / 86400

    unscored = sample[~sample["last_limit_flow_id"].isin(set(score["flow_id"]))]
    merged.attrs["unscored"] = int(len(unscored))
    merged.attrs["unscored_immature"] = bool(
        len(unscored) > 0
        and (unscored[[c for c in ("y_fpd7_obs", "y_fpd15_obs") if c in unscored]] == 0)
        .all()
        .all()
    )
    return merged


def build_data(sample: pd.DataFrame, reject_pct: int) -> dict:
    obs_at = pd.to_datetime(sample["obs_dt"]).max()
    data = {
        "meta": {
            "n_sample": int(len(sample)),
            "obs_dt": obs_at.strftime("%Y-%m-%d"),
            "weeks": sorted(sample["disburse_week"].dropna().unique().tolist()),
            "new_missing": int(sample["new_score"].isna().sum()),
            "old_missing": int(sample["old_score"].isna().sum()),
            "median_days": float(sample["days_to_disburse"].median()),
            "p75_days": float(sample["days_to_disburse"].quantile(0.75)),
            "reject_pct": reject_pct,
            "n_unscored": int(sample.attrs.get("unscored", 0)),
            "unscored_immature": bool(sample.attrs.get("unscored_immature", False)),
        },
        "windows": {},
        "throughRef": THROUGH_REF,
        "weeks": sorted(sample["disburse_week"].dropna().unique().tolist()),
        "week_counts": {
            str(k): int(v) for k, v in sample["disburse_week"].value_counts().items()
        },
    }
    weeks = data["weeks"]

    for w in WINDOWS:
        obs_col, ovd_col = f"y_fpd{w}_obs", f"y_fpd{w}_ovd"
        base = sample[sample[obs_col] == 1]
        entry = {
            "label": f"FPD{w}",
            "n_obs": int(len(base)),
            "n_bad": int(base[ovd_col].sum()),
            "maturity": round(len(base) / len(sample) * 100, 1),
            "models": {},
        }
        loss_col = f"estimate_principal_remaining_fpd{w}"
        for key, col in (("old", "old_score"), ("new", "new_score")):
            d = base.dropna(subset=[col])
            y = d[ovd_col].astype(int).to_numpy()
            s = d[col].to_numpy(float)
            amt = pd.to_numeric(d["real_amount"], errors="coerce").fillna(0).to_numpy(float)
            loss = pd.to_numeric(d[loss_col], errors="coerce").fillna(0).to_numpy(float)
            auc, ks = auc_ks(s, y)
            _, se, _, _ = delong(s, y)
            dec = deciles(s, y, amt, loss)
            overall_rate = float(y.mean() * 100)
            for item in dec:
                item["lift"] = round(item["rate"] / overall_rate, 2) if overall_rate else None
            entry["models"][key] = {
                "n": int(len(d)),
                "bad": int(y.sum()),
                "rate": round(overall_rate, 2),
                "amt": float(amt.sum()),
                "loss_amt": float(loss.sum()),
                "amt_rate": round(float(loss.sum() / amt.sum() * 100), 2) if amt.sum() else None,
                "auc": round(auc, 4),
                "se": round(se, 4),
                "auc_lo": round(auc - Z95 * se, 4),
                "auc_hi": round(auc + Z95 * se, 4),
                "gini": round(2 * auc - 1, 4),
                "ks": round(ks, 4),
                "top_rate": dec[-1]["rate"],
                "top_lift": dec[-1]["lift"],
                "deciles": dec,
                "roc": roc_points(s, y),
                "capture": capture_curve(s, y),
                "cutoffs": [
                    cutoff_stats(s, y, r, amt, loss)
                    for r in sorted(set(CUTOFF_REJECTS) | {reject_pct})
                ],
            }

        # 配对检验：两模型都有分的样本
        pair = base.dropna(subset=["old_score", "new_score"])
        y_pair = pair[ovd_col].astype(int).to_numpy()
        test = delong_paired(
            pair["old_score"].to_numpy(float), pair["new_score"].to_numpy(float), y_pair
        )
        delta = test["diff"]
        entry["delta"] = {
            "n": int(len(pair)),
            "diff": round(delta["diff"], 4),
            "ci_low": round(delta["ci_low"], 4),
            "ci_high": round(delta["ci_high"], 4),
            "p": delta["p"],
            "z": round(delta["z"], 2),
        }

        # 决策互换矩阵
        pair_reset = pair.reset_index(drop=True)
        n_pair = len(pair_reset)
        k = int(round(n_pair * reject_pct / 100))
        rej = {}
        for key in ("old", "new"):
            order = np.argsort(-pair_reset[f"{key}_score"].to_numpy(float), kind="mergesort")
            mask = np.zeros(n_pair, dtype=bool)
            mask[order[:k]] = True
            rej[key] = mask
        label_arr = y_pair
        cells = []
        for new_rej, old_rej, cell_key in (
            (False, False, "both_pass"),
            (False, True, "old_only"),
            (True, False, "new_only"),
            (True, True, "both_reject"),
        ):
            mask = (rej["new"] == new_rej) & (rej["old"] == old_rej)
            cnt = int(mask.sum())
            bad = int(label_arr[mask].sum())
            cells.append(
                {
                    "key": cell_key,
                    "new_reject": new_rej,
                    "old_reject": old_rej,
                    "n": cnt,
                    "share": round(cnt / n_pair * 100, 1) if n_pair else None,
                    "bad": bad,
                    "rate": round(bad / cnt * 100, 2) if cnt else None,
                }
            )
        entry["swap"] = {
            "reject_pct": reject_pct,
            "reject_n": k,
            "n": n_pair,
            "cells": cells,
            "overall_rate": round(float(label_arr.mean() * 100), 2),
        }

        # 五分位交叉矩阵：行 = 新戳额模型档，列 = 线上模型档
        pair_all = base.dropna(subset=["old_score", "new_score"])
        label_all = pair_all[ovd_col].astype(int).to_numpy()
        n_pair_all = len(pair_all)

        def quintile(values):
            rank = pd.Series(np.asarray(values, dtype=float)).rank(method="first")
            return np.ceil(rank * 5 / n_pair_all).astype(int).to_numpy()

        q_new = quintile(pair_all["new_score"].to_numpy(float))
        q_old = quintile(pair_all["old_score"].to_numpy(float))
        cross_rows = []
        for i in range(1, 6):
            cells = []
            for j in range(1, 6):
                mask = (q_new == i) & (q_old == j)
                cnt = int(mask.sum())
                bad = int(label_all[mask].sum())
                cells.append(
                    {
                        "n": cnt,
                        "bad": bad,
                        "rate": round(bad / cnt * 100, 2) if cnt else None,
                        "level": heat_level(bad / cnt * 100) if cnt else 0,
                    }
                )
            cross_rows.append({"q": i, "cells": cells})

        rates = [[c["rate"] for c in row["cells"]] for row in cross_rows]
        row_spreads = [
            max(v for v in r if v is not None) - min(v for v in r if v is not None)
            for r in rates
        ]
        col_spreads = [
            max(rates[i][j] for i in range(5)) - min(rates[i][j] for i in range(5))
            for j in range(5)
        ]
        diag = sum(cross_rows[i]["cells"][i]["n"] for i in range(5))
        entry["cross"] = {
            "rows": cross_rows,
            "n": n_pair_all,
            "min_cell": min(c["n"] for row in cross_rows for c in row["cells"]),
            "diag_share": round(diag / n_pair_all * 100, 1),
            "row_spread_max": round(max(row_spreads), 2),
            "col_spread_min": round(min(col_spreads), 2),
        }

        # 通过收益：同一通过坏率预算下，两个模型各自能做到多大通过率
        envelopes, arrays = {}, {}
        for key in ("old", "new"):
            dd = base.dropna(subset=[f"{key}_score"])
            s = dd[f"{key}_score"].to_numpy(float)
            y = dd[ovd_col].astype(int).to_numpy()
            amt = pd.to_numeric(dd["real_amount"], errors="coerce").fillna(0).to_numpy(float)
            arrays[key] = (s, y, amt)
            envelopes[key] = approval_envelope(s, y)

        def curve(key, steps=150):
            rate, kept = envelopes[key]
            n = len(arrays[key][0])
            idx = np.unique(np.linspace(0, len(rate) - 1, min(steps, len(rate))).astype(int))
            return [
                [round(float(rate[i]), 2), round(float(kept[i] / n * 100), 1)]
                for i in idx
            ]

        rows = []
        for target in THROUGH_TARGETS:
            row = {"target": target}
            for key in ("old", "new"):
                rate, kept = envelopes[key]
                i = int(np.searchsorted(rate, target, side="right")) - 1
                if i < 0:
                    row[key] = None
                    continue
                s, y, amt = arrays[key]
                stats = kept_stats(s, y, amt, kept[i])
                stats["hit_rate"] = round(float(rate[i]), 2)
                if stats["rate"] is None or abs(stats["rate"] - rate[i]) > 0.05:
                    raise AssertionError(
                        f"通过率包络与明细不一致：{key} 预算 {target}% "
                        f"包络 {rate[i]:.2f}% / 明细 {stats['rate']}%"
                    )
                row[key] = stats
            if row["old"] and row["new"]:
                row["extra"] = row["new"]["kept"] - row["old"]["kept"]
                row["extra_good"] = row["new"]["good"] - row["old"]["good"]
                row["extra_good_amt"] = row["new"]["good_amt"] - row["old"]["good_amt"]
            else:
                row["extra"] = row["extra_good"] = row["extra_good_amt"] = None
            rows.append(row)

        entry["through"] = {
            "targets": list(THROUGH_TARGETS),
            "rows": rows,
            "curve": {"old": curve("old"), "new": curve("new")},
        }

        # 分周
        weekly = []
        by_week = {wk: grp for wk, grp in base.groupby("disburse_week")}
        for wk in weeks:
            group = by_week.get(wk)
            row = {
                "week": wk,
                "n": int(len(group)) if group is not None else 0,
                "bad": int(group[ovd_col].sum()) if group is not None else 0,
                "rate": round(float(group[ovd_col].mean() * 100), 2) if group is not None and len(group) else None,
                "auc_old": None,
                "auc_new": None,
            }
            if group is not None:
                for key, col in (("auc_old", "old_score"), ("auc_new", "new_score")):
                    g = group.dropna(subset=[col])
                    y = g[ovd_col].astype(int).to_numpy()
                    if y.sum() >= WEEK_MIN_BAD and len(y) - y.sum() >= WEEK_MIN_BAD:
                        row[key] = round(auc_ks(g[col].to_numpy(float), y)[0], 4)
            weekly.append(row)
        entry["weekly"] = weekly

        values = [v for r in weekly for v in (r["auc_old"], r["auc_new"]) if v is not None]
        if values:
            lo_tick = int(np.floor(min(values) * 10 + 1e-9)) / 10
            hi_tick = int(np.ceil(max(values) * 10 - 1e-9)) / 10
            if hi_tick - lo_tick < 0.2 - 1e-9:
                hi_tick = lo_tick + 0.2
        else:
            lo_tick, hi_tick = 0.5, 1.0
        ticks = [round(lo_tick + i * 0.1, 2) for i in range(int(round((hi_tick - lo_tick) / 0.1)) + 1)]
        # 上下各留 0.05，避免数据贴边；网格线仍落在整刻度上
        entry["weeklyAxis"] = {
            "min": round(lo_tick - 0.05, 2),
            "max": round(hi_tick + 0.05, 2),
            "ticks": ticks,
        }

        data["windows"][str(w)] = entry

    return data


# --------------------------------------------------------------------------- 格式化


def fmt_int(value):
    if value is None:
        return "—"
    return f"{int(round(value)):,}"


def fmt_pct(value, digits=2):
    return "—" if value is None else f"{value:.{digits}f}%"


def fmt_num(value, digits=3):
    return "—" if value is None else f"{value:.{digits}f}"


def fmt_signed(value, digits=3):
    if value is None:
        return "—"
    return f"{value + 0.0:+,.{digits}f}".replace("-", "−")


def fmt_money(value):
    return "—" if value is None else f"{value:,.0f}"


def fmt_p(p):
    if p is None or p != p:
        return "—"
    return "p &lt; 0.001" if p < 0.001 else f"p = {p:.3f}"


def fmt_days(days):
    if days is None:
        return "—"
    if days * 24 < 1:
        return f"{days * 1440:.0f} 分钟"
    if days < 1:
        return f"{days * 24:.1f} 小时"
    return f"{days:.1f} 天"


def cut_for(entry, key, reject_pct):
    for cutoff in entry["models"][key]["cutoffs"]:
        if cutoff["reject_pct"] == reject_pct:
            return cutoff
    return None


def to_py(value):
    """numpy 标量、NaN 转成 JSON 安全类型。"""
    if isinstance(value, dict):
        return {k: to_py(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_py(v) for v in value]
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating, float)):
        return None if value != value or value in (float("inf"), float("-inf")) else float(value)
    if isinstance(value, (np.bool_,)):
        return bool(value)
    return value


# --------------------------------------------------------------------------- HTML 片段


def metrics_table(data) -> str:
    rows = []
    for w in WINDOWS:
        entry = data["windows"][str(w)]
        delta = entry["delta"]
        for key in ("new", "old"):
            m = entry["models"][key]
            name = NEW_NAME if key == "new" else OLD_NAME
            dot = f'<i class="dot {"new" if key == "new" else "old"}"></i>'
            rows.append(
                f"""
        <tr>
          <td class="w">{entry['label']}</td>
          <td class="model">{dot}{name}</td>
          <td>{fmt_int(m['n'])}</td>
          <td>{fmt_int(m['bad'])}</td>
          <td>{fmt_pct(m['rate'])}</td>
          <td class="strong">{fmt_num(m['auc'])}</td>
          <td class="soft">{fmt_num(m['auc_lo'])}–{fmt_num(m['auc_hi'])}</td>
          <td>{fmt_num(m['gini'])}</td>
          <td>{fmt_num(m['ks'])}</td>
          <td>{fmt_pct(m['top_rate'])}</td>
          <td>{fmt_num(m['top_lift'], 2)}×</td>
        </tr>"""
        )
        rows.append(
            f"""
        <tr class="delta">
          <td class="w">{entry['label']}</td>
          <td class="model">ΔAUC（新 − 旧）</td>
          <td colspan="3" class="soft">配对样本 {fmt_int(delta['n'])}</td>
          <td class="strong">{fmt_signed(delta['diff'])}</td>
          <td class="soft">{fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])}</td>
          <td colspan="2" class="soft">95% CI · {fmt_p(delta['p'])}</td>
          <td colspan="2" class="soft">z = {delta['z']:.1f}</td>
        </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="metrics">
          <thead>
            <tr>
              <th>窗口</th><th>模型</th><th>成熟样本</th><th>坏样本</th><th>笔数坏率</th>
              <th>AUC</th><th>AUC 95% CI</th><th>Gini</th><th>KS</th>
              <th>最高档坏率</th><th>最高档 lift</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="note">坏样本 = y_fpdN_ovd 之和；成熟样本 = y_fpdN_obs = 1（due + N &lt; 观察日）。
      最高档 = 十分位第 10 档（分数最高）；lift = 该档坏率 / 全体坏率。ΔAUC 用 DeLong 配对检验，仅取两模型都有分的样本。</p>    """


def scenario_table(data, window_key) -> str:
    entry = data["windows"][window_key]
    levels = sorted(c["reject_pct"] for c in entry["models"]["new"]["cutoffs"])

    def sub(c, reject):
        parts = []
        if c["capture"] is not None and reject:
            parts.append(f"lift {c['capture'] / reject:.2f}×")
        if c.get("capture_amt") is not None:
            parts.append(f"金额 {fmt_pct(c['capture_amt'], 1)}")
        return " · ".join(parts)

    rows = []
    for reject in levels:
        o, n = cut_for(entry, "old", reject), cut_for(entry, "new", reject)
        diff = (n["kept_rate"] - o["kept_rate"]) if None not in (n["kept_rate"], o["kept_rate"]) else None
        rows.append(
            f"""
            <tr>
              <td class="strong">{100 - reject}%</td>
              <td>{fmt_int(n['kept_n'])}</td>
              <td class="strong">{fmt_pct(n['kept_rate'])}</td>
              <td class="soft">{fmt_pct(n['capture'], 1)}<span class="n">{sub(n, reject)}</span></td>
              <td>{fmt_pct(o['kept_rate'])}</td>
              <td class="soft">{fmt_pct(o['capture'], 1)}<span class="n">{sub(o, reject)}</span></td>
              <td>{fmt_signed(diff, 2)}pp</td>
            </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="scenario">
          <thead>
            <tr>
              <th rowspan="2">通过率</th><th rowspan="2">通过笔数</th>
              <th colspan="2" class="group new">新戳额模型</th>
              <th colspan="2" class="group old">线上模型</th>
              <th rowspan="2">坏率差</th>
            </tr>
            <tr>
              <th>通过坏率</th><th>拦截坏账（笔数）</th>
              <th>通过坏率</th><th>拦截坏账（笔数）</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def decile_table(data, window_key) -> str:
    entry = data["windows"][window_key]
    old = entry["models"]["old"]["deciles"]
    new = entry["models"]["new"]["deciles"]
    rows = []
    for q in range(10):
        o, n = old[q], new[q]
        rows.append(
            f"""
            <tr>
              <td>{n['q']}</td>
              <td>{fmt_int(n['n'])}</td>
              <td class="strong">{fmt_pct(n['rate'])}</td>
              <td class="lift">{fmt_num(n['lift'], 2)}×</td>
              <td class="soft">{fmt_int(n['bad'])}</td>
              <td>{fmt_int(o['n'])}</td>
              <td>{fmt_pct(o['rate'])}</td>
              <td class="lift">{fmt_num(o['lift'], 2)}×</td>
              <td class="soft">{fmt_int(o['bad'])}</td>
            </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="decile">
          <thead>
            <tr>
              <th rowspan="2">档位</th>
              <th colspan="4" class="group new">新戳额模型</th>
              <th colspan="4" class="group old">线上模型</th>
            </tr>
            <tr>
              <th>样本</th><th>笔数坏率</th><th>lift</th><th>坏样本</th>
              <th>样本</th><th>笔数坏率</th><th>lift</th><th>坏样本</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def swap_html(data, window_key) -> str:
    entry = data["windows"][window_key]
    swap = entry["swap"]
    cells = {c["key"]: c for c in swap["cells"]}

    def cell(key, label=""):
        c = cells[key]
        accent = ' accent' if key in ("new_only", "old_only") else ""
        tag = f'<em>{label}</em>' if label else ""
        lift = (c["rate"] / swap["overall_rate"]) if swap["overall_rate"] and c["rate"] is not None else None
        return f"""
        <div class="cell{accent}">
          {tag}
          <b>{fmt_pct(c['rate'])}<i>{fmt_num(lift, 2)}×</i></b>
          <span>{fmt_int(c['n'])} 人 · 坏 {fmt_int(c['bad'])} 笔</span>
        </div>"""

    return f"""
      <div class="swap">
        <div></div>
        <div class="colhead">线上模型 · 通过</div>
        <div class="colhead">线上模型 · 拒绝</div>
        <div class="rowhead">新戳额模型 · 通过</div>
        {cell('both_pass')}
        {cell('old_only', '线上模型独有拦截')}
        <div class="rowhead">新戳额模型 · 拒绝</div>
        {cell('new_only', '新戳额模型独有拦截')}
        {cell('both_reject')}
      </div>
      <p class="note">按分数各拒绝最差的 {swap['reject_pct']}%（{fmt_int(swap['reject_n'])} 人）后交叉分组；
      全体坏率 {fmt_pct(swap['overall_rate'])}，坏率后的 × 为该组相对全体坏率的 lift。
      两模型都拒绝的人群坏率最高，都通过的最低——分歧人群的坏率差距说明谁的判断更准。</p>
    """


def weekly_table(data) -> str:
    rows = []
    weeks = data["weeks"]
    by_key = {
        (r["week"], str(w)): r
        for w in WINDOWS
        for r in data["windows"][str(w)]["weekly"]
    }
    for week in weeks:
        label = week[5:] if len(week) >= 10 else week
        cells = [f'<td>{label}</td>', f'<td>{fmt_int(data["week_counts"].get(week))}</td>']
        for w in WINDOWS:
            r = by_key.get((week, str(w)))
            if not r or not r["n"]:
                cells.append('<td class="dim">—</td>' * 4)
                continue
            cells.append(f'<td class="soft">{fmt_int(r["n"])}</td>')
            cells.append(f'<td>{fmt_pct(r["rate"])}</td>')
            cells.append(f'<td>{fmt_num(r["auc_old"])}</td>')
            cells.append(f'<td>{fmt_num(r["auc_new"])}</td>')
        rows.append(f"<tr>{''.join(cells)}</tr>")

    return f"""
      <div class="table-wrap">
        <table class="weekly">
          <thead>
            <tr>
              <th rowspan="2">放款周<br><span class="muted">周一起</span></th><th rowspan="2">放款笔数</th>
              <th colspan="4" class="group">FPD15</th>
              <th colspan="4" class="group">FPD7</th>
            </tr>
            <tr>
              <th>成熟</th><th>坏率</th><th>AUC 旧</th><th>AUC 新</th>
              <th>成熟</th><th>坏率</th><th>AUC 旧</th><th>AUC 新</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="note">AUC 在当周成熟样本内计算，坏样本或好样本少于 {WEEK_MIN_BAD} 笔的周不计算（显示 —）。
      最近几周 FPD15 尚未成熟，FPD15 的趋势实际截止到 10-05 那一周；看单周波动不如看整体水平。</p>
    """


def kpi_html(data) -> str:
    f15 = data["windows"]["15"]
    reject = data["meta"]["reject_pct"]
    new, old, delta = f15["models"]["new"], f15["models"]["old"], f15["delta"]
    cut_new, cut_old = cut_for(f15, "new", reject), cut_for(f15, "old", reject)
    return f"""
    <div class="kpis">
      <div class="kpi">
        <span class="label"><i class="dot new"></i>新戳额模型 FPD15 AUC</span>
        <b>{fmt_num(new['auc'])}</b>
        <span class="sub">Gini {fmt_num(new['gini'])} · KS {fmt_num(new['ks'])}</span>
      </div>
      <div class="kpi">
        <span class="label"><i class="dot old"></i>线上模型 FPD15 AUC</span>
        <b>{fmt_num(old['auc'])}</b>
        <span class="sub">Gini {fmt_num(old['gini'])} · KS {fmt_num(old['ks'])}</span>
      </div>
      <div class="kpi">
        <span class="label">AUC 提升</span>
        <b>{fmt_signed(delta['diff'])}</b>
        <span class="sub">95% CI {fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])} · {fmt_p(delta['p'])}</span>
      </div>
      <div class="kpi">
        <span class="label">拒绝 {reject}% 后的通过坏率</span>
        <b>{fmt_pct(cut_new['kept_rate'])} <span class="vs">vs</span> {fmt_pct(cut_old['kept_rate'])}</b>
        <span class="sub">口径：笔数坏率</span>
      </div>
    </div>
    """


def summary_html(data) -> str:
    f15 = data["windows"]["15"]
    f7 = data["windows"]["7"]
    reject = data["meta"]["reject_pct"]
    new, old, delta = f15["models"]["new"], f15["models"]["old"], f15["delta"]
    swap = {c["key"]: c for c in f15["swap"]["cells"]}
    new_only, old_only = swap["new_only"], swap["old_only"]
    cut_new, cut_old = cut_for(f15, "new", reject), cut_for(f15, "old", reject)
    ratio = cut_old["kept_rate"] / cut_new["kept_rate"] if cut_new["kept_rate"] else None
    ratio_txt = f"约 {ratio:.1f} 倍" if ratio else "明显更低"
    gap = (
        new_only["rate"] / old_only["rate"]
        if old_only["rate"] and new_only["rate"] is not None
        else None
    )
    gap_txt = f"，相差 {gap:.1f} 倍" if gap else ""
    ref = next(r for r in f15["through"]["rows"] if r["target"] == THROUGH_REF)

    return f"""
    <section class="card conclus">
      <h2>结论</h2>
      <ul>
        <li><b>区分度</b>：新戳额模型 FPD15 AUC {fmt_num(new['auc'])}，线上模型 {fmt_num(old['auc'])}，
            提升 {fmt_signed(delta['diff'])}（95% CI {fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])}，
            {fmt_p(delta['p'])}）；FPD7 口径同样提升 {fmt_signed(f7['delta']['diff'])}，结论不依赖单一标签。</li>
        <li><b>同样风控强度下坏率更低</b>：拒绝最差 {reject}% 时，新戳额模型通过人群坏率 {fmt_pct(cut_new['kept_rate'])}，
            线上模型 {fmt_pct(cut_old['kept_rate'])}（{ratio_txt}）；新戳额模型拦下 {fmt_pct(cut_new['capture'], 1)} 的坏账，线上模型 {fmt_pct(cut_old['capture'], 1)}。</li>
        <li><b>同样坏率预算下通过更多</b>：把通过坏率压在同一水平，新戳额模型能多放客户。以 {ref['target']}% 为例，
            线上模型最多通过 {fmt_pct(ref['old']['approval'], 1)}（{fmt_int(ref['old']['kept'])} 笔），新戳额模型
            {fmt_pct(ref['new']['approval'], 1)}（{fmt_int(ref['new']['kept'])} 笔），多 {fmt_int(ref['extra'])} 位客户、
            {fmt_money(ref['extra_good_amt'])} 好客户本金。</li>
        <li><b>分歧人群以新戳额模型判断为准</b>：新戳额模型拒绝而线上模型放行的 {fmt_int(new_only['n'])} 人坏率
            {fmt_pct(new_only['rate'])}，线上模型拒绝而新戳额模型放行的 {fmt_int(old_only['n'])} 人坏率仅
            {fmt_pct(old_only['rate'])}{gap_txt}。</li>
      </ul>
    </section>
    """


def roc_card(data) -> str:
    panels = []
    for w in WINDOWS:
        entry = data["windows"][str(w)]
        panels.append(
            f"""
      <div class="panel">
        <h3>{entry['label']} · ROC<span class="muted">　成熟 {fmt_int(entry['n_obs'])} 笔 · 坏 {fmt_int(entry['n_bad'])} 笔</span></h3>
        <div class="chart-wrap">
          <svg id="roc{w}" viewBox="0 0 500 500" role="img" aria-label="{entry['label']} ROC 曲线"></svg>
          <div class="tip" id="rocTip{w}"></div>
        </div>
        <div class="legend">
          <span><i class="dot new"></i>新戳额模型 <b>AUC {fmt_num(entry['models']['new']['auc'])}</b></span>
          <span><i class="dot old"></i>线上模型 <b>AUC {fmt_num(entry['models']['old']['auc'])}</b></span>
        </div>
      </div>"""
        )
    return f"""
    <section class="card">
      <h2>ROC 曲线<span class="tag" title="横轴假阳率、纵轴真阳率；对角线为随机模型">AUC 比较</span></h2>
      <p class="desc">曲线越靠左上越好；新戳额模型在两个标签口径下都明显更靠左上。</p>
      <div class="grid2">{''.join(panels)}</div>
      <p class="note">ROC 按分数降序逐点计算，等距抽样至 200 个点绘制；表值见上方「核心指标」。</p>
    </section>
    """


def decile_card(data) -> str:
    entry = data["windows"]["15"]
    new_dec = entry["models"]["new"]["deciles"]
    old_dec = entry["models"]["old"]["deciles"]
    mono = all(
        new_dec[i]["rate"] is not None
        and new_dec[i + 1]["rate"] is not None
        and new_dec[i]["rate"] <= new_dec[i + 1]["rate"]
        for i in range(9)
    )
    old_vals = [d["rate"] for d in old_dec[:9] if d["rate"] is not None]
    old_low = min(old_vals) if old_vals else None
    old_high = max(old_vals) if old_vals else None
    return f"""
    <section class="card">
      <h2>十分位坏率<span class="tag" title="按各模型分数升序切 10 等份，第 10 档风险最高">FPD15</span></h2>
      <p class="desc">新戳额模型{'从第 1 档到第 10 档单调上升' if mono else '各档基本拉开'}，最高档 {fmt_pct(new_dec[-1]['rate'])}、
      lift {fmt_num(new_dec[-1]['lift'], 2)}×；线上模型前 9 档挤在 {fmt_pct(old_low)}–{fmt_pct(old_high)} 之间，
      最高档 {fmt_pct(old_dec[-1]['rate'])}、lift {fmt_num(old_dec[-1]['lift'], 2)}×。</p>
      <div class="chart-wrap">
        <svg id="decileChart" viewBox="0 0 1000 340" role="img" aria-label="FPD15 十分位坏率对比"></svg>
        <div class="tip" id="decileTip"></div>
      </div>
      <div class="legend">
        <span><i class="dot new"></i>新戳额模型</span>
        <span><i class="dot old"></i>线上模型</span>
        <span class="muted">横轴：第 1 档 = 分数最低（最安全）· lift = 该档坏率 / 全体坏率</span>
      </div>
      <div class="subhead">分档明细</div>
      {decile_table(data, '15')}
    </section>
    """


def cross_table(data, window_key="15") -> str:
    entry = data["windows"][window_key]
    cross = entry["cross"]
    head = "".join(f"<th>{j} 档</th>" for j in range(1, 6))
    body = []
    for row in cross["rows"]:
        cells = []
        for j, c in enumerate(row["cells"], start=1):
            tip = (
                f"新戳额 {row['q']} 档 × 线上 {j} 档："
                f"{fmt_int(c['n'])} 笔，坏 {fmt_int(c['bad'])} 笔，坏率 {fmt_pct(c['rate'])}"
            )
            cells.append(
                f'<td class="h{c["level"]}" title="{tip}">'
                f"<b>{fmt_pct(c['rate'])}</b><span>{fmt_int(c['n'])} 笔</span></td>"
            )
        body.append(f'<tr><th class="rowhead">{row["q"]} 档</th>{"".join(cells)}</tr>')
    return f"""
      <div class="table-wrap">
        <table class="cross">
          <thead>
            <tr><th class="corner"></th><th colspan="5" class="group">线上模型 · 五分位</th></tr>
            <tr><th class="rowhead">新戳额模型</th>{head}</tr>
          </thead>
          <tbody>{''.join(body)}</tbody>
        </table>
      </div>
    """


def cross_card(data) -> str:
    cross = data["windows"]["15"]["cross"]
    return f"""
    <section class="card">
      <h2>五分位交叉矩阵<span class="tag" title="行 = 新戳额模型五分位，列 = 线上模型五分位，每格为该组合的笔数坏率">FPD15</span></h2>
      <p class="desc">每格是落在该组合的样本的笔数坏率。横向看（新戳额档固定、线上模型 1→5 档）坏率最多只差
      {cross['row_spread_max']:.1f}pp；纵向看（线上档固定、新戳额模型 1→5 档）至少差 {cross['col_spread_min']:.1f}pp
      ——风险差异主要由新戳额模型的分档解释，线上模型分档带来的额外区分很小。</p>
      {cross_table(data, '15')}
      <div class="heat-legend">
        <span class="muted">笔数坏率</span>
        <span><i class="sw h1"></i>&lt;1%</span>
        <span><i class="sw h2"></i>1–3%</span>
        <span><i class="sw h3"></i>3–7%</span>
        <span><i class="sw h4"></i>7–15%</span>
        <span><i class="sw h5"></i>≥15%</span>
      </div>
      <p class="note">行 = 新戳额模型五分位，列 = 线上模型五分位，1 档风险最低。样本为 FPD15 成熟且两个模型都有分的
      {fmt_int(cross['n'])} 笔，每格最少 {fmt_int(cross['min_cell'])} 笔；两模型落在同一档（对角线）的占
      {cross['diag_share']}%，其余是重排。悬停方格可看该格坏样本数。</p>
    </section>
    """


def money_overall_table(data) -> str:
    rows = []
    for w in WINDOWS:
        entry = data["windows"][str(w)]
        for key in ("new", "old"):
            m = entry["models"][key]
            name = NEW_NAME if key == "new" else OLD_NAME
            keep = m["amt"] - m["loss_amt"]
            rows.append(
                f"""
            <tr>
              <td class="w">{entry['label']}</td>
              <td class="model"><i class="dot {key}"></i>{name}</td>
              <td>{fmt_int(m['amt'])}</td>
              <td class="soft">{fmt_int(m['loss_amt'])}</td>
              <td class="strong">{fmt_pct(m['amt_rate'])}</td>
              <td class="soft">{fmt_int(keep)}</td>
              <td class="soft">{fmt_pct(m['rate'])}</td>
            </tr>"""
            )
    return f"""
      <div class="table-wrap">
        <table class="money">
          <thead>
            <tr>
              <th>窗口</th><th>模型</th><th>置入（放款本金）</th><th>置出（未还本金）</th>
              <th>置出率</th><th>留存</th><th>笔数坏率（对照）</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def money_decile_table(data, window_key="15") -> str:
    entry = data["windows"][window_key]
    new_dec = entry["models"]["new"]["deciles"]
    old_dec = entry["models"]["old"]["deciles"]
    rows = []
    for i in range(10):
        n, o = new_dec[i], old_dec[i]
        rows.append(
            f"""
            <tr>
              <td>{n['q']}</td>
              <td>{fmt_int(n['amt'])}</td>
              <td class="soft">{fmt_int(n['loss_amt'])}</td>
              <td class="strong">{fmt_pct(n['amt_rate'])}</td>
              <td>{fmt_int(o['amt'])}</td>
              <td class="soft">{fmt_int(o['loss_amt'])}</td>
              <td>{fmt_pct(o['amt_rate'])}</td>
            </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="decile">
          <thead>
            <tr>
              <th rowspan="2">档位</th>
              <th colspan="3" class="group new">新戳额模型</th>
              <th colspan="3" class="group old">线上模型</th>
            </tr>
            <tr>
              <th>置入</th><th>置出</th><th>置出率</th>
              <th>置入</th><th>置出</th><th>置出率</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def money_card(data) -> str:
    entry = data["windows"]["15"]
    m = entry["models"]["new"]
    old_m = entry["models"]["old"]
    gap = m["rate"] - m["amt_rate"]
    if gap >= 0:
        gap_txt = f"低 {gap:.2f}pp——坏样本的单笔金额小于整体平均"
    else:
        gap_txt = f"高 {-gap:.2f}pp——坏样本的单笔金额大于整体平均"
    top = m["deciles"][-1]
    top_amt_share = top["amt"] / m["amt"] * 100 if m["amt"] else 0
    top_loss_share = top["loss_amt"] / m["loss_amt"] * 100 if m["loss_amt"] else 0
    old_top_loss = old_m["deciles"][-1]["loss_amt"] / old_m["loss_amt"] * 100 if old_m["loss_amt"] else 0
    panels = ""
    for key in ("new", "old"):
        mm = entry["models"][key]
        name = NEW_NAME if key == "new" else OLD_NAME
        panels += f"""
      <div class="panel">
        <h3>{name}<span class="muted">　置入 {fmt_int(mm['amt'])} · 置出 {fmt_int(mm['loss_amt'])}（{fmt_pct(mm['amt_rate'])}）</span></h3>
        <div class="chart-wrap">
          <svg id="money{key}" viewBox="0 0 500 300" role="img" aria-label="各档置入与置出金额"></svg>
          <div class="tip" id="moneyTip{key}"></div>
        </div>
      </div>"""
    return f"""
    <section class="card">
      <h2>置入与置出<span class="tag" title="置入 = 放款本金 real_amount 之和；置出 = due+N 当天借据快照的未还本金之和">放款本金 vs 未还本金</span></h2>
      <p class="desc">前面所有坏率都是笔数口径，这里换成钱。FPD15 成熟样本上，新戳额模型口径的置入
      {fmt_int(m['amt'])}、置出 {fmt_int(m['loss_amt'])}，置出率 {fmt_pct(m['amt_rate'])}，
      比同口径的笔数坏率 {fmt_pct(m['rate'])} {gap_txt}。最高档只占置入的 {top_amt_share:.1f}%，
      却贡献 {top_loss_share:.1f}% 的置出（线上模型最高档 {old_top_loss:.1f}%）。</p>
      <div class="defs">
        <span><b>置入</b><em>放款本金（real_amount）之和</em></span>
        <span><b>置出</b><em>到期未还本金（due + N 当天借据快照）</em></span>
        <span><b>置出率</b><em>置出 ÷ 置入</em></span>
        <span><b>留存</b><em>置入 − 置出</em></span>
      </div>
      <div class="grid2">{panels}</div>
      <div class="heat-legend">
        <span class="muted">柱高 = 置入（放款本金）</span>
        <span><i class="sw loss"></i>置出（未还本金）</span>
        <span><i class="sw keep"></i>留存</span>
      </div>
      <div class="subhead">整体</div>
      {money_overall_table(data)}
      <div class="subhead">分档明细（FPD15）</div>
      {money_decile_table(data, '15')}
      <p class="note">置入 = real_amount 之和；置出 = due + N 当天借据快照的未还本金之和，成熟样本内无缺失；
      置出率 = 置出 / 置入；留存 = 置入 − 置出。金额为放款本金口径，不含利息与费用。</p>
    </section>
    """


def capture_card(data) -> str:
    entry = data["windows"]["15"]
    reject = data["meta"]["reject_pct"]
    cut_new, cut_old = cut_for(entry, "new", reject), cut_for(entry, "old", reject)
    return f"""
    <section class="card">
      <h2>拦截收益<span class="tag" title="按分数从高到低拒绝，横轴为拒绝比例，纵轴为被拒样本中的坏账占比">FPD15</span></h2>
      <p class="desc">拒绝同样比例的人，新戳额模型能拦下更多坏账。拒绝 {reject}% 时，新戳额模型捕获
      {fmt_pct(cut_new['capture'], 1)} 的坏账，线上模型 {fmt_pct(cut_old['capture'], 1)}。</p>
      <div class="chart-wrap">
        <svg id="captureChart" viewBox="0 0 1000 340" role="img" aria-label="坏账捕获曲线"></svg>
        <div class="tip" id="captureTip"></div>
      </div>
      <div class="legend">
        <span><i class="dot new"></i>新戳额模型</span>
        <span><i class="dot old"></i>线上模型</span>
        <span><i class="linekey"></i>随机拦截</span>
      </div>

      <div class="subhead">FPD15 · 通过率情景</div>
      {scenario_table(data, '15')}
      <div class="subhead">FPD7 · 通过率情景</div>
      {scenario_table(data, '7')}
      <p class="note">通过坏率 = 未被拒绝样本的笔数坏率；拦截坏账（笔数）= 被拒坏样本 / 全部坏样本；
      拦截坏账下的「金额」= 被拒样本的坏账损失本金 / 全部坏账损失本金，见「金额口径」卡。
      通过笔数按新戳额模型样本计（线上模型缺失 5 笔，各情景差异在 5 笔以内）。
      通过率 {100 - data['meta']['reject_pct']}% 为上方「结论」引用的口径。</p>
    </section>
    """


def through_table(data, window_key) -> str:
    entry = data["windows"][window_key]
    rows = []
    for r in entry["through"]["rows"]:
        o, n = r["old"], r["new"]
        if not o or not n:
            rows.append(
                f'<tr><td class="strong">≤ {r["target"]}%</td>'
                + '<td class="dim">—</td>' * 5
                + "</tr>"
            )
            continue
        rows.append(
            f"""
            <tr>
              <td class="strong">≤ {r['target']}%</td>
              <td>{fmt_pct(o['approval'], 1)}<span class="n">{fmt_int(o['kept'])} 笔</span></td>
              <td class="strong">{fmt_pct(n['approval'], 1)}<span class="n">{fmt_int(n['kept'])} 笔</span></td>
              <td>{fmt_signed(r['extra'], 0)}</td>
              <td class="soft">{fmt_signed(r['extra_good'], 0)}</td>
              <td>{fmt_money(r['extra_good_amt'])}</td>
            </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="through">
          <thead>
            <tr>
              <th>通过坏率预算</th>
              <th>线上模型通过率</th>
              <th>新戳额模型通过率</th>
              <th>多通过客户</th>
              <th>多通过好客户</th>
              <th>多通过好客户本金</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def through_card(data) -> str:
    entry = data["windows"]["15"]
    ref = next(r for r in entry["through"]["rows"] if r["target"] == THROUGH_REF)
    o, n = ref["old"], ref["new"]
    return f"""
    <section class="card">
      <h2>通过收益<span class="tag" title="把通过坏率控制在同一水平，各模型能达到的最高通过率">FPD15</span></h2>
      <p class="desc">拦截的反面是通过。同样把通过坏率压在 {ref['target']}% 以内，线上模型只能通过
      {fmt_pct(o['approval'], 1)}（{fmt_int(o['kept'])} 笔），新戳额模型可以通过 {fmt_pct(n['approval'], 1)}（{fmt_int(n['kept'])} 笔），
      多 {fmt_int(ref['extra'])} 位客户、{fmt_money(ref['extra_good_amt'])} 好客户本金。</p>
      <div class="chart-wrap">
        <svg id="approvalChart" viewBox="0 0 1000 340" role="img" aria-label="同一坏率预算下的可达通过率"></svg>
        <div class="tip" id="approvalTip"></div>
      </div>
      <div class="legend">
        <span><i class="dot new"></i>新戳额模型</span>
        <span><i class="dot old"></i>线上模型</span>
        <span class="muted">纵轴：该坏率下可达到的最高通过率</span>
      </div>

      <div class="subhead">FPD15 · 同一坏率预算下的通过空间</div>
      {through_table(data, '15')}
      <div class="subhead">FPD7 · 同一坏率预算下的通过空间</div>
      {through_table(data, '7')}
      <p class="note">坏率预算 = 通过样本的笔数坏率上限；通过率 = 该预算下可放行的最大比例，
      多通过本金 = 两边"好客户"（未坏样本）的放款本金之差。线上模型缺失 5 笔，两个样本相差 5 笔以内。
      本金为放款金额 real_amount，不含利息与费用。线上模型在低预算档只放得出极少数人，说明它无法在该坏率水平上开展业务。</p>
    </section>
    """


def swap_card(data) -> str:
    swap = data["windows"]["15"]["swap"]
    return f"""
    <section class="card">
      <h2>决策互换矩阵<span class="tag" title="两个模型各拒绝最差 30% 后的人群交叉对比">FPD15 · 拒绝 {swap['reject_pct']}%</span></h2>
      <p class="desc">同一批人、同样的拒绝比例，两个模型拒掉的人只有一部分重叠。分歧人群的实际坏率决定该信谁。</p>
      {swap_html(data, '15')}
    </section>
    """


def weekly_card(data) -> str:
    parts = []
    all_better = True
    for w in WINDOWS:
        entry = data["windows"][str(w)]
        rows = [r for r in entry["weekly"] if r["auc_old"] is not None and r["auc_new"] is not None]
        if rows:
            old_vals = [r["auc_old"] for r in rows]
            new_vals = [r["auc_new"] for r in rows]
            all_better = all_better and min(new_vals) > max(old_vals)
            span = (
                f"线上模型 {min(old_vals):.2f}–{max(old_vals):.2f}，"
                f"新戳额模型 {min(new_vals):.2f}–{max(new_vals):.2f}"
            )
            weeks_txt = f"{len(rows)} 周"
        else:
            span, weeks_txt = "样本不足", "—"
        parts.append(f"<span class=\"muted\">{entry['label']}（{weeks_txt}）：{span}</span>")

    desc_head = (
        "新戳额模型在每一个可评估的周都高于线上模型"
        if all_better
        else "新戳额模型整体领先，个别周有波动"
    )
    return f"""
    <section class="card">
      <h2>分周稳定性<span class="tag" title="按放款周（周一起）计算成熟样本内的 AUC">周度 AUC</span></h2>
      <p class="desc">{desc_head}。{'；'.join(parts)}。</p>
      <div class="grid2">
        {''.join(weekly_panel(data, w) for w in WINDOWS)}
      </div>
      {weekly_table(data)}
    </section>
    """


def weekly_panel(data, w) -> str:
    entry = data["windows"][str(w)]
    return f"""
      <div class="panel">
        <h3>{entry['label']} · AUC 按周<span class="muted">　成熟 {fmt_int(entry['n_obs'])} 笔 · 坏 {fmt_int(entry['n_bad'])} 笔</span></h3>
        <div class="chart-wrap">
          <svg id="week{w}" viewBox="0 0 500 330" role="img" aria-label="{entry['label']} 周度 AUC"></svg>
          <div class="tip" id="weekTip{w}"></div>
        </div>
        <div class="legend">
          <span><i class="dot new"></i>新戳额模型</span>
          <span><i class="dot old"></i>线上模型</span>
        </div>
      </div>
    """


def footer_html(data, generated_at, label_name, score_name) -> str:
    meta = data["meta"]
    unscored_note = (
        "均为窗口末尾放款、FPD7/FPD15 均未成熟，不影响评估。"
        if meta.get("unscored_immature")
        else "其中包含已成熟样本，评估时需注意覆盖度。"
    )
    return f"""
    <footer class="foot">
      <ul class="notes">
        <li><b>样本口径</b>：wagego_02 的新客首笔成交样本（application_rank = 1，按戳额时间 {escape(meta['start'])} 至 {escape(meta['end_display'])} 筛选），
            与新戳额模型打分文件按 last_limit_flow_id = flow_id 关联，共 {fmt_int(meta['n_sample'])} 人。
            样本表中另有 {fmt_int(meta['n_unscored'])} 笔未打分、不入样：{unscored_note}</li>
        <li><b>模型口径</b>：新戳额模型 {escape(NEW_SCORE)}（戳额场景，{NEW_DESC}）；线上模型 {escape(OLD_SCORE)}（发标场景，{OLD_DESC}）。
            两者决策时点接近——中位 {fmt_days(meta['median_days'])}、75 分位 {fmt_days(meta['p75_days'])}内即放款，比较视为同点。
            线上模型有 {fmt_int(meta['old_missing'])} 笔缺失（含 -1 哨兵值），按缺失处理，不参与排序。</li>
        <li><b>坏率口径</b>：笔数坏率 = y_fpdN_ovd 之和 / y_fpdN_obs 之和；成熟条件为 due + N &lt; 观察日（{escape(meta['obs_dt'])}），
            未成熟不判坏。本报告坏率均为笔数口径；金额仅出现在「通过收益」卡，为放款本金 real_amount，
            好客户本金 = 未坏样本的放款本金之和，不含利息与费用。</li>
        <li><b>指标口径</b>：AUC / Gini / KS 在成熟样本内计算；AUC 置信区间与两模型差异用 DeLong 法（差异检验为配对 DeLong）。
            十分位在成熟样本内按分数升序等分，第 1 档最低风险。</li>
        <li><b>lift 口径</b>：lift = 该组笔数坏率 / 全体笔数坏率。分档 lift 按档计算（第 10 档即最高档坏率 / 全体坏率）；
            互换矩阵按格计算，基数取该口径下的全体坏率；拦截 lift = 被拒人群坏率 / 全体坏率，也等于拦截坏账占比 / 拒绝比例。</li>
        <li><b>使用提示</b>：样本为首笔成交客户（不含未成交申请），结论用于排序能力与相对优劣判断；
            若要据此定准入规则，需在全申请口径（含被拒）上复核通过率与坏率。上线前建议核对新戳额模型特征时点，
            确认仅使用戳额及之前的交易数据，无跨期信息泄漏。</li>
        <li><b>数据源</b>：{escape(label_name)}、{escape(score_name)}；生成脚本 build_model_compare.py；生成时间 {escape(generated_at)}。</li>
      </ul>
    </footer>
    """


# --------------------------------------------------------------------------- 模板


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WageGo · 新戳额模型与线上模型效果对比</title>
<style>
  :root {
    color-scheme: light;
    --page: #f9f9f7;
    --surface: #fcfcfb;
    --ink: #0b0b0b;
    --ink-2: #52514e;
    --muted: #898781;
    --grid: #e1e0d9;
    --axis: #c3c2b7;
    --c1: #2a78d6;
    --c2: #eb6834;
    --keep: #dcdad2;
    --loss: #c0392b;
    --ring: rgba(11,11,11,0.10);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      color-scheme: dark;
      --page: #0d0d0d;
      --surface: #1a1a19;
      --ink: #f0efec;
      --ink-2: #c3c2b7;
      --muted: #898781;
      --grid: #2c2c2a;
      --axis: #383835;
      --c1: #3987e5;
      --c2: #d95926;
      --keep: #4a4a44;
      --loss: #b34a3f;
      --ring: rgba(255,255,255,0.10);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 36px 20px 52px;
    background: var(--page);
    color: var(--ink);
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  main { max-width: 1120px; margin: 0 auto; }
  .eyebrow {
    margin: 0 0 5px; color: var(--muted); font-size: 10.5px;
    letter-spacing: .10em; text-transform: uppercase;
  }
  h1 { font-size: 30px; line-height: 1.25; margin: 0 0 5px; }
  .sub { color: var(--ink-2); margin: 0; font-size: 14px; }
  .models {
    display: flex; flex-wrap: wrap; gap: 6px 26px;
    margin-top: 12px; font-size: 12px; color: var(--ink-2);
  }
  .models > span { display: inline-flex; align-items: center; gap: 6px; }
  .models .dot { margin-right: 0; }
  .models b { color: var(--ink); font-weight: 600; }
  .models code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 11px; color: var(--muted);
  }
  .chips { display: flex; flex-wrap: wrap; gap: 7px; margin-top: 12px; }
  .chip {
    border: 1px solid var(--ring); background: var(--surface);
    border-radius: 999px; padding: 5px 10px; font-size: 11.5px; color: var(--ink-2);
    white-space: nowrap;
  }
  .kpis {
    display: grid; grid-template-columns: repeat(4, 1fr);
    gap: 12px; margin: 20px 0 6px;
  }
  .kpi {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 13px 15px;
  }
  .kpi .label {
    display: block; color: var(--muted); font-size: 11.5px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .kpi b { display: block; font-size: 27px; line-height: 1.2; margin: 4px 0 1px; }
  .kpi b .vs { color: var(--muted); font-size: 15px; font-weight: 400; }
  .kpi .sub { display: block; color: var(--ink-2); font-size: 11.5px; line-height: 1.45; }
  .card {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 16px 18px 11px; margin: 13px 0;
  }
  .card h2 { font-size: 17px; margin: 0 0 1px; }
  .card h3 { font-size: 14px; margin: 0 0 2px; font-weight: 600; }
  .card h2 .tag {
    display: inline-block; margin-left: 7px; padding: 1px 7px;
    border: 1px solid var(--ring); border-radius: 999px;
    background: var(--page); color: var(--ink-2);
    font-size: 10.5px; font-weight: 500; vertical-align: 2px;
    cursor: help;
  }
  .desc { color: var(--ink-2); font-size: 12.5px; margin: 0 0 6px; }
  .muted { color: var(--muted); font-weight: 400; font-size: 11.5px; }
  .conclus ul { margin: 6px 0 4px; padding-left: 20px; color: var(--ink-2); font-size: 13px; }
  .conclus li { margin: 5px 0; }
  .conclus b { color: var(--ink); font-weight: 600; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  .panel { min-width: 0; }
  .chart-wrap { position: relative; margin: 3px 0 2px; }
  .chart-wrap svg { display: block; width: 100%; height: auto; }
  .legend { display: flex; flex-wrap: wrap; gap: 16px; font-size: 12px; color: var(--ink-2); margin: 4px 0 0 2px; }
  .legend b { color: var(--ink); font-weight: 600; }
  .dot {
    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
    margin-right: 6px; vertical-align: -1px;
  }
  .dot.new { background: var(--c1); }
  .dot.old { background: var(--c2); }
  .linekey {
    display: inline-block; width: 16px; height: 0; border-top: 2px solid var(--axis);
    margin-right: 6px; vertical-align: 3px;
  }
  .tip {
    position: absolute; z-index: 2; pointer-events: none; display: none;
    transform: translate(-50%, -115%);
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 8px; box-shadow: 0 4px 14px rgba(0,0,0,0.12);
    padding: 7px 10px; font-size: 12px; line-height: 1.5;
    white-space: normal; max-width: 290px; color: var(--ink);
  }
  .tip b { font-weight: 600; }
  .tip .row { display: flex; align-items: center; gap: 6px; color: var(--ink-2); }
  .tip .row strong { color: var(--ink); font-weight: 600; min-width: 52px; }
  .tip .row i { display: inline-block; width: 10px; height: 2px; border-radius: 1px; }
  .tip.down { transform: translate(-50%, 12px); }
  .table-wrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; }
  th, td { text-align: right; padding: 7px 9px; border-bottom: 1px solid var(--grid); }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--muted); font-weight: 500; font-size: 11.5px; }
  tbody tr:last-child td { border-bottom: none; }
  th.group { text-align: center; color: var(--ink-2); }
  th.group.new { border-top: 2px solid var(--c1); }
  th.group.old { border-top: 2px solid var(--c2); }
  td.w { color: var(--ink-2); white-space: nowrap; }
  td.model { white-space: nowrap; text-align: left; }
  td.strong { font-weight: 600; }
  td.soft { color: var(--ink-2); }
  td.dim { color: var(--muted); }
  td .n { display: block; color: var(--muted); font-size: 10.5px; line-height: 1.35; }
  td.good { color: var(--ink-2); }
  td.bad { color: var(--ink-2); }
  table.metrics tr.delta td { border-bottom: 1px solid var(--grid); background: var(--page); }
  table.metrics tr.delta td.strong { font-weight: 600; }
  table.decile td.lift { color: var(--ink-2); }
  table.cross { width: 100%; border-collapse: separate; border-spacing: 3px; }
  table.cross th {
    font-weight: 500; color: var(--muted); font-size: 11.5px;
    text-align: center; padding: 4px 6px; border-bottom: 0;
  }
  table.cross th.corner { border: 0; }
  table.cross th.rowhead { text-align: right; white-space: nowrap; padding-right: 12px; }
  table.cross td {
    text-align: center; padding: 11px 6px; border-radius: 6px;
    border-bottom: 0; color: var(--ink); background: var(--surface);
  }
  table.cross td b { display: block; font-size: 15px; font-weight: 600; line-height: 1.3; }
  table.cross td span { display: block; font-size: 10.5px; opacity: .72; }
  table.cross td.h1 { background: rgba(192,57,43,0.06); }
  table.cross td.h2 { background: rgba(192,57,43,0.15); }
  table.cross td.h3 { background: rgba(192,57,43,0.29); }
  table.cross td.h4 { background: rgba(192,57,43,0.46); }
  table.cross td.h5 { background: rgba(192,57,43,0.66); }
  .heat-legend {
    display: flex; flex-wrap: wrap; align-items: center; gap: 15px;
    font-size: 11.5px; color: var(--ink-2); margin: 8px 2px 0;
  }
  .heat-legend .sw {
    display: inline-block; width: 12px; height: 12px; border-radius: 3px;
    margin-right: 5px; vertical-align: -2px;
    box-shadow: inset 0 0 0 1px var(--ring);
  }
  .heat-legend .sw.h1 { background: rgba(192,57,43,0.06); }
  .heat-legend .sw.h2 { background: rgba(192,57,43,0.15); }
  .heat-legend .sw.h3 { background: rgba(192,57,43,0.29); }
  .heat-legend .sw.h4 { background: rgba(192,57,43,0.46); }
  .heat-legend .sw.h5 { background: rgba(192,57,43,0.66); }
  .heat-legend .sw.keep { background: var(--keep); }
  .heat-legend .sw.loss { background: var(--loss); }
  .defs {
    display: flex; flex-wrap: wrap; gap: 6px 22px;
    margin: 8px 0 10px; font-size: 12px; color: var(--ink-2);
  }
  .defs span { display: inline-flex; align-items: baseline; gap: 6px; }
  .defs b { color: var(--ink); font-weight: 600; }
  .defs em { font-style: normal; color: var(--muted); }
  .subhead { color: var(--muted); font-size: 11.5px; font-weight: 600; margin: 14px 1px 3px; }
  .note { color: var(--muted); font-size: 12px; line-height: 1.65; margin: 8px 2px 4px; }
  .swap {
    display: grid; grid-template-columns: 118px 1fr 1fr;
    gap: 8px; margin: 8px 0 4px;
  }
  .swap .colhead, .swap .rowhead { color: var(--muted); font-size: 11.5px; display: flex; align-items: center; }
  .swap .colhead { justify-content: center; text-align: center; }
  .swap .rowhead { justify-content: flex-end; text-align: right; padding-right: 6px; }
  .swap .cell {
    border: 1px solid var(--grid); border-radius: 10px;
    padding: 10px 12px; background: var(--surface);
  }
  .swap .cell.accent { border-left: 3px solid var(--ink-2); }
  .swap .cell em {
    display: block; font-style: normal; color: var(--muted);
    font-size: 10.5px; margin-bottom: 2px;
  }
  .swap .cell b { display: block; font-size: 22px; line-height: 1.25; }
  .swap .cell b i {
    font-style: normal; font-size: 12.5px; font-weight: 500;
    color: var(--ink-2); margin-left: 5px;
  }
  .swap .cell span { display: block; color: var(--ink-2); font-size: 11.5px; }
  .foot { margin-top: 18px; }
  ul.notes { margin: 0; padding-left: 20px; color: var(--ink-2); font-size: 12px; }
  ul.notes li { margin: 5px 0; }
  ul.notes b { color: var(--ink); font-weight: 600; }
  @media (max-width: 900px) {
    .kpis { grid-template-columns: repeat(2, 1fr); }
    .grid2 { grid-template-columns: 1fr; }
    .swap { grid-template-columns: 92px 1fr 1fr; }
  }
  @media (max-width: 560px) {
    h1 { font-size: 24px; }
    .kpis { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<main>
__HEADER__
__KPIS__
__SUMMARY__
__METRICS_CARD__
__ROC_CARD__
__DECILE_CARD__
__MONEY_CARD__
__CROSS_CARD__
__CAPTURE_CARD__
__THROUGH_CARD__
__SWAP_CARD__
__WEEKLY_CARD__
__FOOTER__
</main>
<script>
const DATA = __DATA_JSON__;
const NS = 'http://www.w3.org/2000/svg';
const fmtPct = (v, d) => (v == null ? '—' : v.toFixed(d == null ? 2 : d) + '%');
const fmtInt = n => (n == null ? '—' : n.toLocaleString('en-US'));

function svgEl(parent, tag, attrs, text) {
  const node = document.createElementNS(NS, tag);
  for (const key in attrs) node.setAttribute(key, attrs[key]);
  if (text != null) node.textContent = text;
  parent.appendChild(node);
  return node;
}

function clearSvg(svg) {
  while (svg.firstChild) svg.removeChild(svg.firstChild);
}

function tipCtl(svg, tip) {
  return {
    show(payload, cx, cy) {
      tip.replaceChildren();
      const head = document.createElement('b');
      head.textContent = payload.title;
      tip.appendChild(head);
      (payload.rows || []).forEach(row => {
        const line = document.createElement('div');
        line.className = 'row';
        if (row.color) {
          const key = document.createElement('i');
          key.style.background = row.color;
          line.appendChild(key);
        }
        const val = document.createElement('strong');
        val.textContent = row.value;
        const name = document.createElement('span');
        name.textContent = row.name;
        line.append(val, name);
        tip.appendChild(line);
      });
      const box = svg.getBoundingClientRect();
      const wrap = svg.parentElement.getBoundingClientRect();
      const px = box.left - wrap.left + cx * box.width / svg.viewBox.baseVal.width;
      const py = box.top - wrap.top + cy * box.height / svg.viewBox.baseVal.height;
      tip.style.left = px + 'px';
      tip.style.top = py + 'px';
      tip.classList.toggle('down', py < 70);
      tip.style.display = 'block';
    },
    hide() { tip.style.display = 'none'; }
  };
}

function axes(svg, cfg) {
  const { W, H, m, xTicks, yTicks, x, y, xFmt, yFmt, xLabel, yLabel } = cfg;
  yTicks.forEach(t => {
    svgEl(svg, 'line', {
      x1: m.l, x2: W - m.r, y1: y(t), y2: y(t),
      stroke: t === 0 ? 'var(--axis)' : 'var(--grid)', 'stroke-width': 1
    });
    svgEl(svg, 'text', {
      x: m.l - 9, y: y(t) + 4, 'text-anchor': 'end',
      fill: 'var(--muted)', 'font-size': cfg.tickSize || 11.5
    }, yFmt(t));
  });
  xTicks.forEach(t => {
    svgEl(svg, 'line', {
      x1: x(t), x2: x(t), y1: m.t, y2: H - m.b,
      stroke: t === 0 ? 'var(--axis)' : 'var(--grid)', 'stroke-width': 1
    });
    svgEl(svg, 'text', {
      x: x(t), y: H - m.b + 20, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': cfg.tickSize || 11.5
    }, xFmt(t));
  });
  svgEl(svg, 'text', {
    x: W - m.r, y: H - 8, 'text-anchor': 'end',
    fill: 'var(--muted)', 'font-size': cfg.tickSize || 11.5
  }, xLabel);
  if (yLabel) {
    const cy = m.t + (H - m.t - m.b) / 2;
    svgEl(svg, 'text', {
      x: 13, y: cy, 'text-anchor': 'middle',
      transform: 'rotate(-90 13 ' + cy + ')',
      fill: 'var(--muted)', 'font-size': cfg.tickSize || 11.5
    }, yLabel);
  }
}

function linePath(points, fx, fy) {
  return points.map((p, i) => (i ? 'L' : 'M') + fx(p) + ',' + fy(p)).join(' ');
}

/* ---------- ROC ---------- */
function drawRoc(windowKey) {
  const entry = DATA.windows[windowKey];
  const svg = document.getElementById('roc' + windowKey);
  const tip = tipCtl(svg, document.getElementById('rocTip' + windowKey));
  const W = 500, H = 500, m = { l: 54, r: 16, t: 16, b: 50 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const x = v => m.l + v / 100 * iw;
  const y = v => m.t + (1 - v / 100) * ih;
  clearSvg(svg);

  axes(svg, {
    W, H, m, x, y, tickSize: 13,
    xTicks: [0, 20, 40, 60, 80, 100], yTicks: [0, 20, 40, 60, 80, 100],
    xFmt: t => t + '%', yFmt: t => t + '%',
    xLabel: '假阳率 FPR', yLabel: '真阳率 TPR'
  });

  // 随机基线
  svgEl(svg, 'line', {
    x1: x(0), y1: y(0), x2: x(100), y2: y(100),
    stroke: 'var(--axis)', 'stroke-width': 1
  });

  const series = [
    { key: 'old', color: 'var(--c2)', pts: entry.models.old.roc },
    { key: 'new', color: 'var(--c1)', pts: entry.models.new.roc }
  ];
  series.forEach(s => {
    svgEl(svg, 'path', {
      d: linePath(s.pts, p => x(p[0]), p => y(p[1])),
      fill: 'none', stroke: s.color, 'stroke-width': 2,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round'
    });
  });

  const cross = svgEl(svg, 'line', {
    y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });
  const dots = series.map(s => svgEl(svg, 'circle', {
    r: 5, fill: s.color, stroke: 'var(--surface)', 'stroke-width': 2,
    opacity: 0, 'pointer-events': 'none'
  }));

  const hit = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent',
    tabindex: 0, role: 'img'
  });

  function atClient(clientX) {
    const box = svg.getBoundingClientRect();
    at((clientX - box.left) / box.width * W);
  }
  function at(sx) {
    const fpr = Math.min(100, Math.max(0, (sx - m.l) / iw * 100));
    // 每个模型取最接近该 FPR 的点
    const picks = series.map(s => {
      let best = s.pts[0], dist = Infinity;
      s.pts.forEach(p => {
        const d = Math.abs(p[0] - fpr);
        if (d < dist) { dist = d; best = p; }
      });
      return best;
    });
    const px = x(picks[0][0]);    cross.setAttribute('x1', px); cross.setAttribute('x2', px); cross.setAttribute('opacity', 1);
    picks.forEach((p, i) => {
      dots[i].setAttribute('cx', x(p[0]));
      dots[i].setAttribute('cy', y(p[1]));
      dots[i].setAttribute('opacity', 1);
    });
    tip.show({
      title: 'FPR ' + fmtPct(picks[0][0], 1),
      rows: [
        { value: fmtPct(picks[1][1], 1), name: '新戳额模型 TPR', color: 'var(--c1)' },
        { value: fmtPct(picks[0][1], 1), name: '线上模型 TPR', color: 'var(--c2)' }
      ]
    }, px, y(Math.max(picks[0][1], picks[1][1])));
  }
  hit.addEventListener('pointermove', e => atClient(e.clientX));
  hit.addEventListener('pointerleave', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
  hit.addEventListener('focus', () => at(m.l + iw * 0.2));
  hit.addEventListener('blur', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
}

/* ---------- 十分位 ---------- */
function drawDeciles() {
  const entry = DATA.windows['15'];
  const svg = document.getElementById('decileChart');
  const tip = tipCtl(svg, document.getElementById('decileTip'));
  const W = 1000, H = 340, m = { l: 52, r: 16, t: 18, b: 50 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const newD = entry.models.new.deciles, oldD = entry.models.old.deciles;
  const rawMax = Math.max(...newD.concat(oldD).map(d => d.rate || 0));
  const yMax = Math.ceil(rawMax / 10) * 10;
  const groupW = iw / 10;
  const barW = Math.min(22, groupW * 0.30);
  const gap = 2;
  const cx = q => m.l + (q - 0.5) * groupW;
  const y = v => m.t + (1 - v / yMax) * ih;
  clearSvg(svg);

  const tickStep = yMax / 5;
  axes(svg, {
    W, H, m, x: v => v, y, xTicks: [],
    yTicks: [0, 1, 2, 3, 4, 5].map(i => i * tickStep),
    xFmt: t => '', yFmt: t => t.toFixed(0) + '%', xLabel: '分档（1 = 分数最低）', yLabel: '笔数坏率'
  });

  const band = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: 0, height: ih,
    fill: 'var(--grid)', opacity: 0, 'pointer-events': 'none'
  });

  for (let q = 1; q <= 10; q++) {
    svgEl(svg, 'text', {
      x: cx(q), y: H - m.b + 20, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 11.5
    }, q);

    const bars = [
      { color: 'var(--c2)', d: oldD[q - 1], dx: -(barW + gap / 2) },
      { color: 'var(--c1)', d: newD[q - 1], dx: gap / 2 }
    ];
    bars.forEach(b => {
      const bx = cx(q) + b.dx;
      const by = y(b.d.rate || 0);
      const bh = H - m.b - by;
      const r = Math.min(4, bh, barW / 2);
      const d = bh <= 0 ? '' :
        'M' + bx + ',' + (H - m.b) +
        ' L' + bx + ',' + (by + r) +
        ' Q' + bx + ',' + by + ' ' + (bx + r) + ',' + by +
        ' L' + (bx + barW - r) + ',' + by +
        ' Q' + (bx + barW) + ',' + by + ' ' + (bx + barW) + ',' + (by + r) +
        ' L' + (bx + barW) + ',' + (H - m.b) + ' Z';
      if (d) svgEl(svg, 'path', { d, fill: b.color });
    });
  }

  // 只在最高档直接标注
  const topNew = newD[9], topOld = oldD[9];
  [['var(--c2)', topOld, -(barW + gap / 2)], ['var(--c1)', topNew, gap / 2]].forEach(([color, d, dx]) => {
    svgEl(svg, 'text', {
      x: cx(10) + dx + barW / 2, y: y(d.rate) - 7, 'text-anchor': 'middle',
      fill: 'var(--ink)', 'font-size': 11.5, 'font-weight': 600
    }, fmtPct(d.rate) + ' · ' + d.lift.toFixed(2) + '×');
  });

  const hoverRect = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent', tabindex: 0
  });
  let active = 10;
  function show(q) {
    active = q;
    band.setAttribute('x', m.l + (q - 1) * groupW);
    band.setAttribute('width', groupW);
    band.setAttribute('opacity', 0.55);
    tip.show({
      title: '第 ' + q + ' 档' + (q === 1 ? '（最安全）' : q === 10 ? '（最高风险）' : ''),
      rows: [
        { value: fmtPct(newD[q - 1].rate), name: '新戳额模型 n=' + fmtInt(newD[q - 1].n) + ' · lift ' + newD[q - 1].lift.toFixed(2) + '×', color: 'var(--c1)' },
        { value: fmtPct(oldD[q - 1].rate), name: '线上模型 n=' + fmtInt(oldD[q - 1].n) + ' · lift ' + oldD[q - 1].lift.toFixed(2) + '×', color: 'var(--c2)' }
      ]
    }, cx(q), y(Math.max(newD[q - 1].rate, oldD[q - 1].rate)) - 6);
  }
  function clear() {
    tip.hide();
    band.setAttribute('width', 0);
    band.setAttribute('opacity', 0);
  }
  function groupAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    return Math.min(10, Math.max(1, Math.floor((ux - m.l) / groupW) + 1));
  }
  hoverRect.addEventListener('pointermove', e => show(groupAt(e.clientX)));
  hoverRect.addEventListener('pointerleave', clear);
  hoverRect.addEventListener('focus', () => show(active));
  hoverRect.addEventListener('blur', clear);
}

/* ---------- 捕获曲线 ---------- */
function drawCapture() {
  const entry = DATA.windows['15'];
  const svg = document.getElementById('captureChart');
  const tip = tipCtl(svg, document.getElementById('captureTip'));
  const W = 1000, H = 340, m = { l: 52, r: 16, t: 18, b: 50 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const x = v => m.l + v / 60 * iw;
  const y = v => m.t + (1 - v / 100) * ih;
  clearSvg(svg);

  axes(svg, {
    W, H, m, x, y,
    xTicks: [0, 10, 20, 30, 40, 50, 60], yTicks: [0, 20, 40, 60, 80, 100],
    xFmt: t => t + '%', yFmt: t => t + '%',
    xLabel: '拒绝比例（按分数从高到低）', yLabel: '坏账捕获比例'
  });

  svgEl(svg, 'line', {
    x1: x(0), y1: y(0), x2: x(60), y2: y(60),
    stroke: 'var(--axis)', 'stroke-width': 1
  });

  const series = [
    { key: 'old', color: 'var(--c2)', pts: entry.models.old.capture },
    { key: 'new', color: 'var(--c1)', pts: entry.models.new.capture }
  ];
  series.forEach(s => {
    svgEl(svg, 'path', {
      d: linePath(s.pts, p => x(p[0]), p => y(p[1])),
      fill: 'none', stroke: s.color, 'stroke-width': 2,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round'
    });
  });

  // 30% 处直接标注
  [['var(--c2)', entry.models.old.capture[30], -8], ['var(--c1)', entry.models.new.capture[30], -8]].forEach(([color, p, dy]) => {
    svgEl(svg, 'text', {
      x: x(30) + 8, y: y(p[1]) + dy, 'text-anchor': 'start',
      fill: 'var(--ink)', 'font-size': 11.5, 'font-weight': 600
    }, fmtPct(p[1], 1));
  });

  const cross = svgEl(svg, 'line', {
    y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });
  const dots = series.map(s => svgEl(svg, 'circle', {
    r: 4.5, fill: s.color, stroke: 'var(--surface)', 'stroke-width': 2,
    opacity: 0, 'pointer-events': 'none'
  }));
  const hit = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent', tabindex: 0
  });
  let lastRej = 30;
  function show(rej) {
    lastRej = rej;
    const px = x(rej);
    cross.setAttribute('x1', px); cross.setAttribute('x2', px); cross.setAttribute('opacity', 1);
    series.forEach((s, i) => {
      dots[i].setAttribute('cx', px);
      dots[i].setAttribute('cy', y(s.pts[rej][1]));
      dots[i].setAttribute('opacity', 1);
    });
    tip.show({
      title: '拒绝 ' + rej + '%',
      rows: [
        { value: fmtPct(entry.models.new.capture[rej][1], 1), name: '新戳额模型捕获率', color: 'var(--c1)' },
        { value: fmtPct(entry.models.old.capture[rej][1], 1), name: '线上模型捕获率', color: 'var(--c2)' }
      ]
    }, px, y(Math.max(entry.models.new.capture[rej][1], entry.models.old.capture[rej][1])) - 6);
  }
  function rejAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    return Math.min(60, Math.max(0, Math.round((ux - m.l) / iw * 60)));
  }
  hit.addEventListener('pointermove', e => show(rejAt(e.clientX)));
  hit.addEventListener('pointerleave', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
  hit.addEventListener('focus', () => show(lastRej));
  hit.addEventListener('blur', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
}

/* ---------- 通过率包络 ---------- */
function drawApproval() {
  const entry = DATA.windows['15'];
  const svg = document.getElementById('approvalChart');
  const tip = tipCtl(svg, document.getElementById('approvalTip'));
  const W = 1000, H = 340, m = { l: 56, r: 16, t: 18, b: 50 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const xMax = 11;
  const x = v => m.l + v / xMax * iw;
  const y = v => m.t + (1 - v / 100) * ih;
  clearSvg(svg);

  axes(svg, {
    W, H, m, x, y,
    xTicks: [0, 2, 4, 6, 8, 10], yTicks: [0, 20, 40, 60, 80, 100],
    xFmt: t => t + '%', yFmt: t => t + '%',
    xLabel: '通过坏率预算（笔数）', yLabel: '可达通过率'
  });

  const series = [
    { key: 'old', color: 'var(--c2)', pts: entry.through.curve.old },
    { key: 'new', color: 'var(--c1)', pts: entry.through.curve.new }
  ];
  series.forEach(s => {
    svgEl(svg, 'path', {
      d: linePath(s.pts, p => x(p[0]), p => y(p[1])),
      fill: 'none', stroke: s.color, 'stroke-width': 2,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round'
    });
  });

  function nearest(pts, v) {
    let best = pts[0], dist = Infinity;
    pts.forEach(p => {
      const d = Math.abs(p[0] - v);
      if (d < dist) { dist = d; best = p; }
    });
    return best;
  }

  // 参考预算处直接标注
  series.forEach(s => {
    const p = nearest(s.pts, DATA.throughRef);
    svgEl(svg, 'text', {
      x: x(p[0]) - 8, y: y(p[1]) - 9, 'text-anchor': 'end',
      fill: 'var(--ink)', 'font-size': 11.5, 'font-weight': 600
    }, fmtPct(p[1], 1));
  });

  const cross = svgEl(svg, 'line', {
    y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });
  const dots = series.map(s => svgEl(svg, 'circle', {
    r: 4.5, fill: s.color, stroke: 'var(--surface)', 'stroke-width': 2,
    opacity: 0, 'pointer-events': 'none'
  }));
  const hit = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent', tabindex: 0
  });
  let last = DATA.throughRef;
  function show(v) {
    last = v;
    const picks = series.map(s => nearest(s.pts, v));
    const px = x(picks[0][0]);
    cross.setAttribute('x1', px); cross.setAttribute('x2', px); cross.setAttribute('opacity', 1);
    picks.forEach((p, i) => {
      dots[i].setAttribute('cx', x(p[0]));
      dots[i].setAttribute('cy', y(p[1]));
      dots[i].setAttribute('opacity', 1);
    });
    tip.show({
      title: '坏率预算 ' + fmtPct(picks[0][0], 1),
      rows: [
        { value: fmtPct(picks[1][1], 1), name: '新戳额模型可达通过率', color: 'var(--c1)' },
        { value: fmtPct(picks[0][1], 1), name: '线上模型可达通过率', color: 'var(--c2)' }
      ]
    }, px, y(Math.max(picks[0][1], picks[1][1])) - 6);
  }
  function valAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    return Math.min(xMax, Math.max(0, (ux - m.l) / iw * xMax));
  }
  hit.addEventListener('pointermove', e => show(valAt(e.clientX)));
  hit.addEventListener('pointerleave', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
  hit.addEventListener('focus', () => show(last));
  hit.addEventListener('blur', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
}

/* ---------- 周度 AUC ---------- */
function drawWeekly(w) {
  const entry = DATA.windows[w];
  const svg = document.getElementById('week' + w);
  const tip = tipCtl(svg, document.getElementById('weekTip' + w));
  const W = 500, H = 330, m = { l: 44, r: 14, t: 16, b: 52 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const weeks = entry.weekly;
  const axis = entry.weeklyAxis;
  const n = weeks.length;
  const x = i => (n === 1 ? m.l + iw / 2 : m.l + i / (n - 1) * iw);
  const y = v => m.t + (1 - (v - axis.min) / (axis.max - axis.min)) * ih;
  clearSvg(svg);

  axes(svg, {
    W, H, m, x: v => v, y, xTicks: [], yTicks: axis.ticks,
    xFmt: t => '', yFmt: t => t.toFixed(1),
    xLabel: '放款周（周一起）', yLabel: 'AUC', tickSize: 11
  });
  svgEl(svg, 'line', {
    x1: m.l, x2: W - m.r, y1: H - m.b, y2: H - m.b,
    stroke: 'var(--axis)', 'stroke-width': 1
  });

  weeks.forEach((r, i) => {
    svgEl(svg, 'text', {
      x: x(i), y: H - m.b + 19, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 10
    }, r.week.slice(5));
  });

  const series = [
    { key: 'auc_old', color: 'var(--c2)' },
    { key: 'auc_new', color: 'var(--c1)' }
  ];
  series.forEach(s => {
    let d = '', pen = false;
    weeks.forEach((r, i) => {
      const v = r[s.key];
      if (v == null) { pen = false; return; }
      d += (pen ? 'L' : 'M') + x(i) + ',' + y(v);
      pen = true;
    });
    if (d) {
      svgEl(svg, 'path', {
        d, fill: 'none', stroke: s.color, 'stroke-width': 2,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round'
      });
    }
    weeks.forEach((r, i) => {
      const v = r[s.key];
      if (v == null) return;
      svgEl(svg, 'circle', {
        cx: x(i), cy: y(v), r: 3.6, fill: s.color,
        stroke: 'var(--surface)', 'stroke-width': 2
      });
    });
  });

  const cross = svgEl(svg, 'line', {
    y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });
  const hit = svgEl(svg, 'rect', {
    x: m.l - 12, y: m.t, width: iw + 24, height: ih,
    fill: 'transparent', tabindex: 0
  });
  let last = 0;
  function show(i) {
    last = i;
    const r = weeks[i];
    cross.setAttribute('x1', x(i)); cross.setAttribute('x2', x(i)); cross.setAttribute('opacity', 1);
    const tops = [r.auc_old, r.auc_new].filter(v => v != null);
    tip.show({
      title: r.week + ' 起 · 成熟 ' + fmtInt(r.n) + ' 笔',
      rows: [
        { value: r.auc_new == null ? '—' : r.auc_new.toFixed(3), name: '新戳额模型 AUC', color: 'var(--c1)' },
        { value: r.auc_old == null ? '—' : r.auc_old.toFixed(3), name: '线上模型 AUC', color: 'var(--c2)' }
      ]
    }, x(i), y(Math.max.apply(null, tops.length ? tops : [axis.max])) - 10);
  }
  function idxAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    const i = Math.round((ux - m.l) / iw * (n - 1));
    return Math.min(n - 1, Math.max(0, i));
  }
  hit.addEventListener('pointermove', e => show(idxAt(e.clientX)));
  hit.addEventListener('pointerleave', () => { tip.hide(); cross.setAttribute('opacity', 0); });
  hit.addEventListener('focus', () => show(last));
  hit.addEventListener('blur', () => { tip.hide(); cross.setAttribute('opacity', 0); });
}

/* ---------- 置入 / 置出 ---------- */
function drawMoney(key) {
  const dec = DATA.windows['15'].models[key].deciles;
  const svg = document.getElementById('money' + key);
  const tip = tipCtl(svg, document.getElementById('moneyTip' + key));
  const W = 500, H = 300, m = { l: 56, r: 14, t: 14, b: 44 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const step = 50000;
  const both = DATA.windows['15'].models.new.deciles.concat(DATA.windows['15'].models.old.deciles);
  const yMax = Math.ceil(Math.max.apply(null, both.map(d => d.amt)) / step) * step;
  const groupW = iw / 10;
  const barW = Math.min(20, groupW * 0.55);
  const cx = q => m.l + (q - 0.5) * groupW;
  const y = v => m.t + (1 - v / yMax) * ih;
  const baseline = H - m.b;
  clearSvg(svg);

  const ticks = [];
  for (let v = 0; v <= yMax + 1; v += step) ticks.push(v);
  axes(svg, {
    W, H, m, x: v => v, y, xTicks: [], yTicks: ticks, tickSize: 11,
    xFmt: t => '', yFmt: v => (v === 0 ? '0' : (v / 1000) + 'K'),
    xLabel: '分档（1 = 分数最低）', yLabel: '金额（放款本金）'
  });

  const band = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: 0, height: ih,
    fill: 'var(--grid)', opacity: 0, 'pointer-events': 'none'
  });

  dec.forEach((d, i) => {
    const xb = cx(i + 1) - barW / 2;
    const yTop = y(d.amt);
    const yLoss = y(d.loss_amt);
    const keepBottom = Math.min(yLoss - 2, baseline);
    if (keepBottom > yTop) {
      const r = Math.min(4, keepBottom - yTop, barW / 2);
      svgEl(svg, 'path', {
        d: 'M' + xb + ',' + keepBottom +
           ' L' + xb + ',' + (yTop + r) +
           ' Q' + xb + ',' + yTop + ' ' + (xb + r) + ',' + yTop +
           ' L' + (xb + barW - r) + ',' + yTop +
           ' Q' + (xb + barW) + ',' + yTop + ' ' + (xb + barW) + ',' + (yTop + r) +
           ' L' + (xb + barW) + ',' + keepBottom + ' Z',
        fill: 'var(--keep)'
      });
    }
    if (yLoss < baseline) {
      svgEl(svg, 'rect', {
        x: xb, y: yLoss, width: barW, height: baseline - yLoss, fill: 'var(--loss)'
      });
    }
  });

  const hit = svgEl(svg, 'rect', {
    x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent', tabindex: 0
  });
  let active = 10;
  function show(q) {
    active = q;
    const d = dec[q - 1];
    band.setAttribute('x', m.l + (q - 1) * groupW);
    band.setAttribute('width', groupW);
    band.setAttribute('opacity', 0.55);
    tip.show({
      title: '第 ' + q + ' 档',
      rows: [
        { value: fmtInt(d.amt), name: '置入（放款本金）', color: 'var(--keep)' },
        { value: fmtInt(d.loss_amt), name: '置出（未还本金）', color: 'var(--loss)' },
        { value: fmtPct(d.amt_rate), name: '置出率', color: null }
      ]
    }, cx(q), y(d.amt) - 6);
  }
  function clear() {
    tip.hide();
    band.setAttribute('width', 0);
    band.setAttribute('opacity', 0);
  }
  function groupAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    return Math.min(10, Math.max(1, Math.floor((ux - m.l) / groupW) + 1));
  }
  hit.addEventListener('pointermove', e => show(groupAt(e.clientX)));
  hit.addEventListener('pointerleave', clear);
  hit.addEventListener('focus', () => show(active));
  hit.addEventListener('blur', clear);
}

drawRoc('15');
drawRoc('7');
drawDeciles();
drawCapture();
drawApproval();
drawWeekly('15');
drawWeekly('7');
drawMoney('new');
drawMoney('old');
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------- 组装


def build_html(data, generated_at: str, label_name: str, score_name: str) -> str:
    meta = data["meta"]
    header = f"""
    <header>
      <p class="eyebrow">WAGEGO · 风险模型评估 · 新客首借成交样本</p>
      <h1>新戳额模型与线上模型效果对比</h1>
      <p class="sub">从区分度、决策收益到周度稳定性，评估新戳额模型相对线上模型的增量价值。
      首笔成交新客，戳额时间 {escape(meta['start'])} 至 {escape(meta['end_display'])}，观察日 {meta['obs_dt']}。</p>
      <div class="models">
        <span><i class="dot new"></i><b>{NEW_NAME}</b><code>{escape(NEW_SCORE)}</code><span class="muted">戳额场景</span></span>
        <span><i class="dot old"></i><b>{OLD_NAME}</b><code>{escape(OLD_SCORE)}</code><span class="muted">发标场景</span></span>
      </div>
      <div class="chips">
        <span class="chip">样本 {fmt_int(meta['n_sample'])} 人</span>
        <span class="chip">FPD15 成熟 {fmt_int(data['windows']['15']['n_obs'])} 笔</span>
        <span class="chip">FPD7 成熟 {fmt_int(data['windows']['7']['n_obs'])} 笔</span>
        <span class="chip">笔数坏率</span>
      </div>
    </header>
    """
    f15m = data["windows"]["15"]["models"]
    metrics_card = f"""
    <section class="card">
      <h2>核心指标<span class="tag" title="AUC / Gini / KS 均在成熟样本内计算">排序能力</span></h2>
      <p class="desc">两个标签口径、两个模型放在同一批成熟样本上比。新戳额模型 AUC {fmt_num(f15m['new']['auc'], 2)}、KS {fmt_num(f15m['new']['ks'], 2)}，
      线上模型 AUC {fmt_num(f15m['old']['auc'], 2)}、KS {fmt_num(f15m['old']['ks'], 2)}。</p>
      {metrics_table(data)}
    </section>
    """
    html = HTML_TEMPLATE
    html = html.replace("__HEADER__", header)
    html = html.replace("__KPIS__", kpi_html(data))
    html = html.replace("__SUMMARY__", summary_html(data))
    html = html.replace("__METRICS_CARD__", metrics_card)
    html = html.replace("__ROC_CARD__", roc_card(data))
    html = html.replace("__DECILE_CARD__", decile_card(data))
    html = html.replace("__MONEY_CARD__", money_card(data))
    html = html.replace("__CROSS_CARD__", cross_card(data))
    html = html.replace("__CAPTURE_CARD__", capture_card(data))
    html = html.replace("__THROUGH_CARD__", through_card(data))
    html = html.replace("__SWAP_CARD__", swap_card(data))
    html = html.replace("__WEEKLY_CARD__", weekly_card(data))
    html = html.replace("__FOOTER__", footer_html(data, generated_at, label_name, score_name))
    payload = json.dumps(to_py(data), ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    html = html.replace("__DATA_JSON__", payload.replace("</", "<\\/"))
    return html


def main(argv=None):
    parser = argparse.ArgumentParser(description="新客样本新戳额模型与线上模型效果对比")
    parser.add_argument("--label-csv", default=str(DEFAULT_LABEL), help="主表 CSV")
    parser.add_argument("--score-csv", default=str(DEFAULT_SCORE), help="新戳额模型分 CSV")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出 HTML")
    parser.add_argument("--start", default="2026-08-01", help="戳额起始日")
    parser.add_argument("--end", default="2026-10-24", help="戳额结束日（不含）")
    parser.add_argument("--reject", type=int, default=30, help="互换矩阵的拒绝比例 %")
    args = parser.parse_args(argv)

    label_path = Path(args.label_csv)
    score_path = Path(args.score_csv)
    for path in (label_path, score_path):
        if not path.exists():
            parser.error(f"文件不存在：{path}")

    sample = load_sample(label_path, score_path, args.start, args.end)
    data = build_data(sample, args.reject)
    data["meta"]["start"] = args.start
    data["meta"]["end_display"] = (
        pd.Timestamp(args.end) - pd.Timedelta(days=1)
    ).strftime("%Y-%m-%d")
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
    html = build_html(data, generated_at, label_path.name, score_path.name)

    output = Path(args.output)
    output.write_text(html, encoding="utf-8")

    print(f"样本 {len(sample):,} 人 · 输出 {output}")
    for w in WINDOWS:
        e = data["windows"][str(w)]
        print(
            f"  FPD{w}: 成熟 {e['n_obs']:,} / 坏 {e['n_bad']:,} | "
            f"AUC 新 {e['models']['new']['auc']:.3f} vs 旧 {e['models']['old']['auc']:.3f} | "
            f"Δ {e['delta']['diff']:+.3f}"
        )


if __name__ == "__main__":
    main()
