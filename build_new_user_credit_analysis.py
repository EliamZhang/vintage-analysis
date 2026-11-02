#!/usr/bin/env python3
"""新客样本上的模型分分析（新戳额模型 vs 线上模型），输出自包含 HTML。

样本：wagego_02 中的新客首笔成交样本（application_rank = 1，戳额时间落在窗口内）。
新戳额模型分数取自戳额成交样本，按 last_limit_flow_id = 打分文件的 flow_id 关联；线上模型分数取自主表。

用法：
    python build_new_user_credit_analysis.py
    python build_new_user_credit_analysis.py --score-csv xxx.csv --output 新客戳额_模型分分析.html
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
RAW_DIR = PROJECT_DIR / "同步数据"


def _input_path(name: str) -> Path:
    """优先用同步脚本输出到 同步数据/ 的文件，其次用项目根目录的手工导出。"""
    for folder in (RAW_DIR, PROJECT_DIR):
        path = folder / name
        if path.exists():
            return path
    return PROJECT_DIR / name


DEFAULT_LABEL = RAW_DIR / "table_tmp_eliam_wagego_dwd_loan_apply_label.csv"
DEFAULT_SCORE = _input_path("aus_new_wagego_credit_20261028_v1_0_txn_lgb_score.csv")
DEFAULT_LIMIT_SCORE = _input_path("wagego_new_user_credit_20260801_20261023_score.csv")
DEFAULT_LIMIT_OLD_SCORE = _input_path("wagego_new_user_credit_20260801_20261023_old_score.csv")
DEFAULT_OUTPUT = PROJECT_DIR / "新客戳额_模型分分析.html"

OLD_SCORE = "aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626"
NEW_SCORE = "aus_new_wagego_credit_20261028_v1_0_txn_lgb_score"

OLD_NAME = "线上模型"
NEW_NAME = "新戳额模型"
OLD_DESC = "发标 3rd 模型"
NEW_DESC = "交易流水 LGB 模型"

WINDOWS = (15, 7)  # 主口径在前
# 固定十等分分箱：thresholds = 10%~100% 百分位，max 为各档分数上界。
# 两个模型各用自己的一套固定切点，线上模型不再按当前样本等笔数切档。
NEW_DECILE_THRESHOLDS = tuple(range(10, 101, 10))
NEW_DECILE_MIN = (
    0.021107, 0.041028, 0.050928, 0.062087, 0.074097,
    0.087432, 0.104708, 0.124508, 0.156964, 0.211074,
)
NEW_DECILE_CUTS = (
    0.040977, 0.050916, 0.062045, 0.074019, 0.087427,
    0.104648, 0.124452, 0.156853, 0.210134, 0.431317,
)
OLD_DECILE_THRESHOLDS = tuple(range(10, 101, 10))
OLD_DECILE_MIN = (
    0.020419, 0.048631, 0.062116, 0.075668, 0.091289,
    0.109264, 0.128397, 0.154598, 0.189020, 0.240060,
)
OLD_DECILE_CUTS = (
    0.048577, 0.062086, 0.075629, 0.091284, 0.109224,
    0.128392, 0.154584, 0.188973, 0.240037, 0.615365,
)
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


def deciles(score, label, amount=None, loss=None, cuts=None):
    """按分数切 10 档（第 1 档最低风险）；可选带放款规模与坏账损失本金。

    cuts 为 None 时按当前样本等笔数切档；传入升序上界时按固定切点分箱，
    首档以下、末档以上的分数分别并入首档、末档。
    """
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n = len(score)
    if cuts is not None:
        edges = np.asarray(cuts, dtype=float)
        q = np.searchsorted(edges, score, side="left").clip(0, len(edges) - 1) + 1
    else:
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
            "score_min": float(score[mask].min()) if mask.any() else None,
            "score_max": float(score[mask].max()) if mask.any() else None,
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


def segment_metrics(base, ovd_col, mask):
    """成熟样本内某一段的 AUC / KS / 配对 ΔAUC。"""
    seg = base[mask]
    out = {
        "n": int(len(seg)),
        "bad": int(seg[ovd_col].sum()),
        "rate": round(float(seg[ovd_col].mean() * 100), 2) if len(seg) else None,
        "models": {},
    }
    for key in ("old", "new"):
        d = seg.dropna(subset=[f"{key}_score"])
        y = d[ovd_col].astype(int).to_numpy()
        s = d[f"{key}_score"].to_numpy(float)
        auc, ks = auc_ks(s, y)
        out["models"][key] = {
            "n": int(len(d)),
            "bad": int(y.sum()),
            "auc": round(auc, 4) if auc is not None else None,
            "ks": round(ks, 4) if ks is not None else None,
        }
    pair = seg.dropna(subset=["old_score", "new_score"])
    if len(pair):
        y = pair[ovd_col].astype(int).to_numpy()
        test = delong_paired(
            pair["old_score"].to_numpy(float), pair["new_score"].to_numpy(float), y
        )["diff"]
        out["delta"] = {
            "n": int(len(pair)),
            "diff": round(test["diff"], 4),
            "ci_low": round(test["ci_low"], 4),
            "ci_high": round(test["ci_high"], 4),
            "p": test["p"],
            "z": round(test["z"], 2),
        }
    else:
        out["delta"] = None
    return out


def _decile_of(values, cuts):
    edges = np.asarray(cuts, dtype=float)
    return np.searchsorted(edges, np.asarray(values, dtype=float), side="left").clip(
        0, len(edges) - 1
    ) + 1


def _dist_rows(values, cuts, mins) -> list[dict]:
    arr = np.asarray(values, dtype=float)
    q = _decile_of(arr, cuts)
    rows = []
    cum = 0
    for k in range(1, 11):
        mask = q == k
        n = int(mask.sum())
        cum += n
        rows.append(
            {
                "q": k,
                "n": n,
                "share": round(n / len(arr) * 100, 2),
                "cum": round(cum / len(arr) * 100, 2),
                "dev": round(n / len(arr) * 100 - 10, 2),
                "score_min": float(arr[mask].min()) if n else None,
                "score_max": float(arr[mask].max()) if n else None,
                "rule_min": mins[k - 1],
                "rule_max": cuts[k - 1],
            }
        )
    return rows


def _pct(num: int, den: int) -> float | None:
    return round(num / den * 100, 2) if den else None


def _conversion_stats(df: pd.DataFrame, obs_dt: pd.Timestamp) -> dict:
    """用户级转化漏斗：戳额 → 借款申请 → 成交。"""
    n = int(len(df))
    applied = int(df["has_apply"].sum())
    disbursed = int(df["has_disburse"].sum())
    age = (obs_dt.normalize() - df["sample_datetime"].dt.normalize()).dt.days

    def window(days: int, label: str) -> dict:
        mature = df[age >= days]
        den = int(len(mature))
        apply_n = int((mature["days_to_apply"] <= days).sum())
        disb_n = int((mature["days_to_disburse"] <= days).sum())
        return {
            "key": f"t{days}",
            "label": label,
            "n": den,
            "applied": apply_n,
            "apply_rate": _pct(apply_n, den),
            "disbursed": disb_n,
            "disburse_rate": _pct(disb_n, den),
        }

    apply_days = df.loc[df["has_apply"], "days_to_apply"].dropna()
    disb_days = df.loc[df["has_disburse"], "days_to_disburse"].dropna()
    amount_total = float(df["disburse_amount"].sum())
    return {
        "n": n,
        "applied": applied,
        "disbursed": disbursed,
        "apply_rate": _pct(applied, n),
        "disburse_rate": _pct(disbursed, n),
        "apply_to_disburse": _pct(disbursed, applied),
        "amount_per_disbursed": round(amount_total / disbursed, 2) if disbursed else None,
        "median_days_to_apply": float(apply_days.median()) if len(apply_days) else None,
        "p90_days_to_apply": float(apply_days.quantile(0.9)) if len(apply_days) else None,
        "median_days_to_disburse": float(disb_days.median()) if len(disb_days) else None,
        "p90_days_to_disburse": float(disb_days.quantile(0.9)) if len(disb_days) else None,
        "windows": [
            window(0, "t0 当天"),
            window(1, "t1 0–1 天"),
            window(7, "t7 0–7 天"),
        ],
    }


def _load_conversion(limit: pd.DataFrame, label_csv: Path) -> dict | None:
    """用戳额全量分关联借款申请，计算用户级转化；不依赖成交样本的 Y 标签。"""
    if limit.empty:
        return None
    apps = pd.read_csv(
        label_csv,
        encoding="utf-8-sig",
        usecols=[
            "user_id",
            "apply_time",
            "is_disburse_success",
            "disburse_time",
            "real_amount",
            "obs_dt",
        ],
    )
    apps["apply_time"] = pd.to_datetime(apps["apply_time"], errors="coerce")
    apps["disburse_time"] = pd.to_datetime(apps["disburse_time"], errors="coerce")
    apps["is_disburse_success"] = (
        pd.to_numeric(apps["is_disburse_success"], errors="coerce").fillna(0).astype(int)
    )
    apps["real_amount"] = pd.to_numeric(apps["real_amount"], errors="coerce").fillna(0.0)
    obs_dt = pd.to_datetime(apps["obs_dt"], errors="coerce").max()
    if pd.isna(obs_dt):
        obs_dt = pd.Timestamp.today().normalize()

    base = limit.dropna(subset=["sample_datetime"]).drop_duplicates("user_id").copy()
    base["sample_datetime"] = pd.to_datetime(base["sample_datetime"], errors="coerce")
    base = base.dropna(subset=["sample_datetime"])
    events = apps.merge(
        base[["user_id", "sample_datetime"]], on="user_id", how="inner"
    )
    events = events[
        events["apply_time"].notna()
        & (events["apply_time"] >= events["sample_datetime"])
    ].copy()
    events["success_amount"] = np.where(
        events["is_disburse_success"] == 1, events["real_amount"], 0.0
    )
    events["success_disburse_time"] = events["disburse_time"].where(
        events["is_disburse_success"] == 1
    )

    agg = events.groupby("user_id", as_index=False).agg(
        n_apps=("apply_time", "size"),
        first_apply_time=("apply_time", "min"),
        any_disburse=("is_disburse_success", "max"),
        first_disburse_time=("success_disburse_time", "min"),
        disburse_amount=("success_amount", "sum"),
    )
    conv = base.merge(agg, on="user_id", how="left")
    conv["has_apply"] = conv["n_apps"].fillna(0).gt(0)
    conv["has_disburse"] = conv["any_disburse"].fillna(0).gt(0)
    conv["disburse_amount"] = (
        pd.to_numeric(conv["disburse_amount"], errors="coerce").fillna(0.0)
    )
    conv["days_to_apply"] = (
        conv["first_apply_time"].dt.normalize()
        - conv["sample_datetime"].dt.normalize()
    ).dt.days
    conv["days_to_disburse"] = (
        conv["first_disburse_time"].dt.normalize()
        - conv["sample_datetime"].dt.normalize()
    ).dt.days

    scored = conv.dropna(subset=["score"]).copy()
    paired = (
        scored.dropna(subset=["old_score"]).copy()
        if "old_score" in scored
        else scored.iloc[0:0]
    )
    new_rows, old_rows = [], []
    if len(paired):
        paired["new_q"] = _decile_of(paired["score"], NEW_DECILE_CUTS)
        paired["old_q"] = _decile_of(paired["old_score"], OLD_DECILE_CUTS)
        for q in range(1, 11):
            new_rows.append(
                {"q": q, **_conversion_stats(paired[paired["new_q"] == q], obs_dt)}
            )
            old_rows.append(
                {"q": q, **_conversion_stats(paired[paired["old_q"] == q], obs_dt)}
            )
    elif len(scored):
        scored["new_q"] = _decile_of(scored["score"], NEW_DECILE_CUTS)
        for q in range(1, 11):
            new_rows.append(
                {"q": q, **_conversion_stats(scored[scored["new_q"] == q], obs_dt)}
            )

    return {
        "obs_dt": obs_dt.strftime("%Y-%m-%d"),
        "scored_n": int(len(scored)),
        "paired_n": int(len(paired)),
        "has_old": bool(old_rows),
        "new_deciles": new_rows,
        "old_deciles": old_rows,
        **_conversion_stats(conv, obs_dt),
    }


def load_limit_data(
    limit_csv: Path,
    old_score_csv: Path | None = None,
    label_csv: Path | None = None,
) -> dict:
    """戳额生产打分全量样本的分数分布、档位迁移与戳额后转化。"""
    limit = pd.read_csv(
        limit_csv,
        encoding="utf-8-sig",
        usecols=["user_id", "application_id", "sample_datetime", NEW_SCORE],
    )
    limit["flow_id"] = limit["application_id"].astype(str).str.strip()
    limit["sample_datetime"] = pd.to_datetime(limit["sample_datetime"], errors="coerce")
    limit["score"] = pd.to_numeric(limit[NEW_SCORE], errors="coerce")

    if old_score_csv is not None:
        old = pd.read_csv(old_score_csv, encoding="utf-8-sig", usecols=["flow_id", "old_score"])
        old["flow_id"] = old["flow_id"].astype(str).str.strip()
        old["old_score"] = pd.to_numeric(old["old_score"], errors="coerce")
        old.loc[old["old_score"] < 0, "old_score"] = np.nan
        limit = limit.merge(old.drop_duplicates("flow_id", keep="last"), on="flow_id", how="left")
    else:
        limit["old_score"] = np.nan

    scored = limit.dropna(subset=["score"])
    base = scored.dropna(subset=["old_score"]) if old_score_csv is not None else scored
    rows = _dist_rows(base["score"], NEW_DECILE_CUTS, NEW_DECILE_MIN)
    old_rows = (
        _dist_rows(base["old_score"], OLD_DECILE_CUTS, OLD_DECILE_MIN)
        if old_score_csv is not None
        else []
    )

    migration = None
    if old_score_csv is not None:
        q_new = _decile_of(base["score"], NEW_DECILE_CUTS)
        q_old = _decile_of(base["old_score"], OLD_DECILE_CUTS)
        counts = [[0] * 10 for _ in range(10)]
        for a, b in zip(q_new, q_old):
            counts[int(a) - 1][int(b) - 1] += 1
        totals = [sum(row) for row in counts]
        row_share = [
            [round(c / total * 100, 1) if total else 0.0 for c in row]
            for row, total in zip(counts, totals)
        ]
        diag = sum(counts[i][i] for i in range(10))
        adjacent = sum(
            counts[i][j] for i in range(10) for j in range(10) if abs(i - j) <= 1
        )
        rank_new = base["score"].rank(method="average").to_numpy(float)
        rank_old = base["old_score"].rank(method="average").to_numpy(float)
        migration = {
            "n": int(len(base)),
            "counts": counts,
            "row_share": row_share,
            "diag_share": round(diag / len(base) * 100, 1) if len(base) else None,
            "adjacent_share": round(adjacent / len(base) * 100, 1) if len(base) else None,
            "spearman": round(float(np.corrcoef(rank_new, rank_old)[0, 1]), 3)
            if len(base)
            else None,
        }

    monthly = []
    month_key = limit["sample_datetime"].dt.strftime("%Y-%m")
    for month, grp in limit.groupby(month_key, dropna=True):
        monthly.append(
            {
                "month": str(month),
                "n": int(len(grp)),
                "missing_rate": round(float(grp["score"].isna().mean() * 100), 2),
            }
        )

    score_arr = scored["score"].to_numpy(float)
    return {
        "n": int(len(limit)),
        "n_scored": int(len(scored)),
        "n_missing": int(limit["score"].isna().sum()),
        "missing_rate": round(float(limit["score"].isna().mean() * 100), 2),
        "dt_min": limit["sample_datetime"].min().strftime("%Y-%m-%d"),
        "dt_max": limit["sample_datetime"].max().strftime("%Y-%m-%d"),
        "score_min": float(score_arr.min()),
        "score_max": float(score_arr.max()),
        "median": float(np.median(score_arr)),
        "p90": float(np.percentile(score_arr, 90)),
        "below_min": int((score_arr < NEW_DECILE_MIN[0]).sum()),
        "above_max": int((score_arr > NEW_DECILE_CUTS[-1]).sum()),
        "deciles": rows,
        "old_deciles": old_rows,
        "old_n": int(limit["old_score"].notna().sum()),
        "old_missing": int(limit["old_score"].isna().sum()),
        "old_coverage": round(float(limit["old_score"].notna().mean() * 100), 2),
        "pair_n": int(len(base)),
        "migration": migration,
        "conversion": _load_conversion(limit, label_csv) if label_csv else None,
        "monthly": monthly,
    }


def build_data(sample: pd.DataFrame, reject_pct: int, oot_start: str) -> dict:
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
            "oot_start": oot_start,
            "new_decile_rule": {
                "thresholds": list(NEW_DECILE_THRESHOLDS),
                "min_score": list(NEW_DECILE_MIN),
                "max_score": list(NEW_DECILE_CUTS),
            },
            "old_decile_rule": {
                "thresholds": list(OLD_DECILE_THRESHOLDS),
                "min_score": list(OLD_DECILE_MIN),
                "max_score": list(OLD_DECILE_CUTS),
            },
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
            dec = deciles(
                s,
                y,
                amt,
                loss,
                cuts=NEW_DECILE_CUTS if key == "new" else OLD_DECILE_CUTS,
            )
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

        # 样本内 / OOT 分段指标（OOT 按戳额时间切）
        oot_mask = (base["last_limit_time"] >= pd.Timestamp(oot_start)).to_numpy()
        entry["segments"] = {
            "all": segment_metrics(base, ovd_col, np.ones(len(base), dtype=bool)),
            "pre_oot": segment_metrics(base, ovd_col, ~oot_mask),
            "oot": segment_metrics(base, ovd_col, oot_mask),
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

        # 五分位交叉矩阵：行 / 列分别为两个模型的固定十分位相邻两档合并
        pair_all = base.dropna(subset=["old_score", "new_score"])
        label_all = pair_all[ovd_col].astype(int).to_numpy()
        n_pair_all = len(pair_all)

        def quintile(values, cuts):
            decile = (
                np.searchsorted(cuts, np.asarray(values, dtype=float), side="left")
                .clip(0, len(cuts) - 1)
                + 1
            )
            return (decile + 1) // 2

        q_new = quintile(pair_all["new_score"].to_numpy(float), NEW_DECILE_CUTS)
        q_old = quintile(pair_all["old_score"].to_numpy(float), OLD_DECILE_CUTS)
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


def fmt_elapsed_days(days):
    if days is None:
        return "—"
    if days <= 0:
        return "当天"
    return f"{days:.0f} 天"


def fmt_range(lo, hi):
    if lo is None or hi is None:
        return "—"
    return f"{lo:.4f}–{hi:.4f}"


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
              <th>窗口</th><th>模型</th><th>成熟笔数</th><th>坏样本</th><th>笔数坏率</th>
              <th>AUC</th><th>AUC 95% CI</th><th>Gini</th><th>KS</th>
              <th>最高档坏率</th><th>最高档 lift</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="note">样本为全样本成熟成交样本（含 OOT 时段），每人一笔；坏样本 = y_fpdN_ovd 之和；
      成熟样本 = y_fpdN_obs = 1（due + N &lt; 观察日）。
      最高档 = 十分位第 10 档（分数最高）；两个模型均按各自的固定切点分档。
      lift = 该档坏率 / 全体坏率。各模型 AUC 用各自有分样本计算；ΔAUC 用 DeLong 配对检验，仅取两模型都有分的样本。</p>    """


def oot_card(data) -> str:
    meta = data["meta"]
    start = meta["start"]
    oot_start = meta["oot_start"]
    pre_end = (pd.Timestamp(oot_start) - pd.Timedelta(days=1)).strftime("%Y-%m-%d")
    rows = []
    for w in WINDOWS:
        entry = data["windows"][str(w)]
        for key, name in (("all", "全样本"), ("pre_oot", "OOT 前"), ("oot", "OOT 后")):
            seg = entry["segments"][key]
            new_m, old_m, delta = seg["models"]["new"], seg["models"]["old"], seg["delta"]
            cls = ' class="oot"' if key == "oot" else ""
            rows.append(
                f"""
            <tr{cls}>
              <td class="w">{entry['label']}</td>
              <td>{name}</td>
              <td>{fmt_int(seg['n'])}</td>
              <td>{fmt_int(seg['bad'])}</td>
              <td>{fmt_pct(seg['rate'])}</td>
              <td class="strong">{fmt_num(new_m['auc'])}</td>
              <td>{fmt_num(old_m['auc'])}</td>
              <td class="strong">{fmt_signed(delta['diff'])}</td>
              <td class="soft">{fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])}</td>
              <td>{fmt_num(new_m['ks'])}</td>
              <td>{fmt_num(old_m['ks'])}</td>
            </tr>"""
            )
    return f"""
    <section class="card" id="oot">
      <h2>OOT 表现<span class="tag" title="OOT 后 = 戳额时间不早于 {escape(oot_start)} 的样本；OOT 前 = 早于该切点的样本">OOT 后 vs OOT 前</span></h2>
      <p class="desc">把 OOT 前和 OOT 后分开看，避免整体表现掩盖上线后的真实区分度。两个分段都用原始分数、各自的成熟样本重新计算 AUC / KS，
      不与前面的全样本指标混算。下图每行是一组对照，蓝点越靠右区分度越高，右侧数字为 ΔAUC。</p>
      <div class="chart-wrap">
        <svg id="ootChart" viewBox="0 0 1000 320" role="img" aria-label="全样本、OOT 前与 OOT 后的 AUC 对比"></svg>
        <div class="tip" id="ootTip"></div>
      </div>
      <div class="legend">
        <span><i class="dot new"></i>新戳额模型</span>
        <span><i class="dot old"></i>线上模型</span>
        <span class="muted">右侧数字：ΔAUC（新 − 旧）· 灰底行 = OOT 后</span>
      </div>
      <div class="table-wrap">
        <table class="oot">
          <thead>
            <tr>
              <th>窗口</th><th>分段</th><th>成熟样本</th><th>坏样本</th><th>笔数坏率</th>
              <th>新 AUC</th><th>线上 AUC</th><th>ΔAUC（新 − 旧）</th><th>ΔAUC 95% CI</th>
              <th>新 KS</th><th>线上 KS</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="note">OOT 按戳额时间 last_limit_time ≥ {escape(oot_start)} 划分，OOT 后为 {escape(oot_start)} 及以后，
      OOT 前为 {escape(start)} 至 {escape(pre_end)}。各分段只统计已成熟样本，各模型 AUC 用各自有分样本计算；
      ΔAUC 用配对 DeLong 检验，仅取两模型都有分的样本。OOT 样本若尚未成熟，不计入对应窗口。</p>
    </section>
    """


def _share_level(share: float) -> int:
    if share >= 20:
        return 5
    if share >= 10:
        return 4
    if share >= 5:
        return 3
    if share >= 2:
        return 2
    return 1


def limit_card(limit) -> str:
    if not limit:
        return ""
    has_old = bool(limit["old_n"] and limit["migration"])
    rows = []
    for d in limit["deciles"]:
        if has_old:
            o = limit["old_deciles"][d["q"] - 1]
            diff = d["share"] - o["share"]
            cls = "strong" if abs(diff) >= 2 else "soft"
            rows.append(
                f"""
            <tr>
              <td>{d['q']}</td>
              <td class="soft">{fmt_range(d['score_min'], d['score_max'])}</td>
              <td>{fmt_int(d['n'])}</td>
              <td>{fmt_pct(d['share'])}</td>
              <td>{fmt_pct(d['cum'])}</td>
              <td class="soft">{fmt_range(o['score_min'], o['score_max'])}</td>
              <td>{fmt_int(o['n'])}</td>
              <td>{fmt_pct(o['share'])}</td>
              <td>{fmt_pct(o['cum'])}</td>
              <td class="{cls}">{diff:+.2f}pp</td>
            </tr>"""
            )
        else:
            cls = "strong" if abs(d["dev"]) >= 2 else "soft"
            rows.append(
                f"""
            <tr>
              <td>{d['q']}</td>
              <td class="soft">{fmt_range(d['rule_min'], d['rule_max'])}</td>
              <td class="soft">{fmt_range(d['score_min'], d['score_max'])}</td>
              <td>{fmt_int(d['n'])}</td>
              <td>{fmt_pct(d['share'])}</td>
              <td>{fmt_pct(d['cum'])}</td>
              <td class="{cls}">{d['dev']:+.2f}pp</td>
            </tr>"""
            )
    if has_old:
        header = """
            <tr>
              <th rowspan="2">档位</th>
              <th colspan="4" class="group new">新戳额模型</th>
              <th colspan="4" class="group old">线上模型</th>
              <th rowspan="2">占比差<br><span class="muted">新 − 旧</span></th>
            </tr>
            <tr>
              <th>分数区间</th><th>人数</th><th>占比</th><th>累计</th>
              <th>分数区间</th><th>人数</th><th>占比</th><th>累计</th>
            </tr>"""
    else:
        header = """
            <tr>
              <th>档位</th><th>规则分数区间</th><th>实际分数范围</th><th>人数</th>
              <th>占已打分</th><th>累计占比</th><th>与参考 10% 偏差</th>
            </tr>"""

    migration_html = ""
    if has_old:
        m = limit["migration"]
        head = "".join(f"<th>{j}</th>" for j in range(1, 11))
        body = []
        for i, row in enumerate(m["row_share"], start=1):
            cells = []
            for j, share in enumerate(row, start=1):
                n = m["counts"][i - 1][j - 1]
                cells.append(
                    f'<td class="m{_share_level(share)}" '
                    f'title="新 {i} 档 × 旧 {j} 档：{fmt_int(n)} 人，占该新档 {share:.1f}%">'
                    f"<b>{share:.1f}%</b><span>{fmt_int(n)} 人</span></td>"
                )
            body.append(f'<tr><th class="rowhead">{i} 档</th>{"".join(cells)}</tr>')
        migration_html = f"""
      <div class="subhead">新旧档位迁移矩阵</div>
      <p class="desc">行 = 新戳额模型档位，列 = 线上模型档位；每格显示该新档人群落到各旧档的比例，颜色越深占比越高。</p>
      <div class="table-wrap">
        <table class="cross migration">
          <thead>
            <tr><th class="corner"></th><th colspan="10" class="group">线上模型 · 十分位</th></tr>
            <tr><th class="rowhead">新戳额模型</th>{head}</tr>
          </thead>
          <tbody>{''.join(body)}</tbody>
        </table>
      </div>
      <div class="heat-legend">
        <span class="muted">占该新档比例</span>
        <span><i class="sw m1"></i>&lt;2%</span>
        <span><i class="sw m2"></i>2–5%</span>
        <span><i class="sw m3"></i>5–10%</span>
        <span><i class="sw m4"></i>10–20%</span>
        <span><i class="sw m5"></i>≥20%</span>
      </div>
      <p class="note">迁移矩阵只使用新旧分都非空的 {fmt_int(limit['pair_n'])} 人；两模型落在同一档（对角线）的占
      {fmt_pct(m['diag_share'], 1)}，相邻档（±1 档）合计占 {fmt_pct(m['adjacent_share'], 1)}，
      新旧分数秩相关 {fmt_num(m['spearman'], 3)}。由于两个模型各用自己的固定切点，档位差异同时包含排序差异和分数分布差异。
      旧模型分从模型运行日志按戳额流水取得，覆盖 {fmt_int(limit['old_n'])} / {fmt_int(limit['n'])} 人
      （{fmt_pct(limit['old_coverage'])}）。</p>"""

    months = "、".join(
        f"{m['month']} {fmt_int(m['n'])} 人（缺分 {fmt_pct(m['missing_rate'])}）"
        for m in limit["monthly"]
    )
    top2 = limit["deciles"][8]["share"] + limit["deciles"][9]["share"]
    old_desc = (
        f"；旧模型按日志取分 {fmt_int(limit['old_n'])} 人（覆盖 {fmt_pct(limit['old_coverage'])}）"
        if has_old
        else ""
    )
    title = "新旧十分位对比" if has_old else "分数分布"
    tag = "生产全量 · 无标签" if has_old else "生产全量"
    return f"""
    <section class="card" id="limit">
      <h2>戳额生产打分全量：{title}<span class="tag" title="新客戳额环节的生产打分全量，不按成交筛选">{tag}</span></h2>
      <p class="desc">这份样本是新客戳额环节的生产打分全量，覆盖 {escape(limit['dt_min'])} 至 {escape(limit['dt_max'])} 共
      {fmt_int(limit['n'])} 人；新模型已打分 {fmt_int(limit['n_scored'])} 人（{fmt_pct(limit['n_scored'] / limit['n'] * 100)}），
      缺分 {fmt_int(limit['n_missing'])} 人（{fmt_pct(limit['missing_rate'])}）{old_desc}。
      两个模型各按自身固定十分位切点分档，第 1 档分数最低。</p>
      <div class="table-wrap">
        <table class="decile">
          <thead>{header}
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="note">该样本的分数整体偏高于固定切点：新模型实际中位数 {fmt_num(limit['median'], 4)}、P90 {fmt_num(limit['p90'], 4)}，
      而切点的中位上界为 {fmt_num(NEW_DECILE_CUTS[4], 4)}；第 9–10 档合计占 {fmt_pct(top2)}，并非十等分。
      新模型分数范围 {fmt_num(limit['score_min'], 4)}–{fmt_num(limit['score_max'], 4)}，低于首档下界 {fmt_int(limit['below_min'])} 人、
      高于末档上界 {fmt_int(limit['above_max'])} 人，分别并入第 1 / 10 档。分月看：{months}。</p>{migration_html}
      <p class="note">该样本不含标签：未成交申请没有放款与表现数据，因此这里只比较分数分布和档位迁移，
      不计算坏率 / AUC / KS；这些指标仅在戳额成交样本上计算，见前文各卡片。</p>
    </section>
    """


def conversion_card(limit, data) -> str:
    if not limit:
        return ""
    conv = limit.get("conversion")
    if not conv:
        return ""
    f15 = data["windows"]["15"]["models"]
    new_bad = {r["q"]: r["rate"] for r in f15["new"]["deciles"]}
    old_bad = {r["q"]: r["rate"] for r in f15["old"]["deciles"]}
    has_old = bool(conv["has_old"] and conv["old_deciles"])

    window_rows = "".join(
        f"""
            <tr>
              <td>{w['label']}</td>
              <td>{fmt_int(w['n'])}</td>
              <td>{fmt_pct(w['apply_rate'])}<span class="n">{fmt_int(w['applied'])} 人</span></td>
              <td>{fmt_pct(w['disburse_rate'])}<span class="n">{fmt_int(w['disbursed'])} 人</span></td>
            </tr>"""
        for w in conv["windows"]
    )

    def cells(row, bad_map):
        return f"""
              <td>{fmt_int(row['n'])}</td>
              <td>{fmt_pct(row['apply_rate'])}</td>
              <td>{fmt_pct(row['disburse_rate'])}</td>
              <td class="soft">{fmt_elapsed_days(row['median_days_to_disburse'])}</td>
              <td class="soft">{fmt_pct(bad_map.get(row['q']))}</td>"""

    decile_html = ""
    if conv["new_deciles"]:
        rows = []
        for i, nrow in enumerate(conv["new_deciles"]):
            orow = conv["old_deciles"][i] if has_old else None
            rows.append(
                f"<tr><td>{nrow['q']}</td>{cells(nrow, new_bad)}"
                f"{cells(orow, old_bad) if orow else ''}</tr>"
            )
        if has_old:
            head = """
            <tr>
              <th rowspan="2">档位</th>
              <th colspan="5" class="group new">新戳额模型</th>
              <th colspan="5" class="group old">线上模型</th>
            </tr>
            <tr>
              <th>人数</th><th>申请率</th><th>成交率</th><th>成交中位天数</th><th>FPD15 坏率</th>
              <th>人数</th><th>申请率</th><th>成交率</th><th>成交中位天数</th><th>FPD15 坏率</th>
            </tr>"""
        else:
            head = """
            <tr>
              <th rowspan="2">档位</th>
              <th colspan="5" class="group new">新戳额模型</th>
            </tr>
            <tr>
              <th>人数</th><th>申请率</th><th>成交率</th><th>成交中位天数</th><th>FPD15 坏率</th>
            </tr>"""
        sample_note = (
            f"分档表使用新旧分都有的 {fmt_int(conv['paired_n'])} 人"
            if has_old
            else f"分档表使用已打分 {fmt_int(conv['scored_n'])} 人"
        )
        legend_parts = ['<span><i class="linekey new"></i>新戳额模型</span>']
        if has_old:
            legend_parts.append('<span><i class="linekey old"></i>线上模型</span>')
        legend_parts.append('<span class="muted">横轴：第 1 档 = 分数最低（最安全）</span>')
        conv_chart_html = f"""
      <div class="grid2 conv-charts">
        <div class="panel">
          <h3>分档申请率<span class="muted">　戳额 → 借款申请</span></h3>
          <div class="chart-wrap">
            <svg id="convApplyChart" viewBox="0 0 500 280" role="img" aria-label="分档借款申请率对比"></svg>
            <div class="tip" id="convApplyTip"></div>
          </div>
        </div>
        <div class="panel">
          <h3>分档成交率<span class="muted">　戳额 → 成交</span></h3>
          <div class="chart-wrap">
            <svg id="convDisburseChart" viewBox="0 0 500 280" role="img" aria-label="分档成交率对比"></svg>
            <div class="tip" id="convDisburseTip"></div>
          </div>
        </div>
      </div>
      <div class="legend">{''.join(legend_parts)}</div>"""
        decile_html = f"""
      <div class="subhead">分档转化（{sample_note}）</div>
      <p class="desc">第 1 档分数最低、第 10 档分数最高；曲线越低表示该档转化越弱。坏率来自戳额成交样本的 FPD15 成熟样本，仅作同档对照。</p>{conv_chart_html}
      <div class="table-wrap">
        <table class="decile">
          <thead>{head}
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>"""

    return f"""
    <section class="card" id="conversion">
      <h2>戳额转化漏斗<span class="tag" title="戳额生产打分全量关联借款申请，仅做描述性分析">生产全量 · 描述性</span></h2>
      <p class="desc">从戳额到借款申请、成交的转化；分母为戳额打分全量，成交按任意一笔成功计算。
      观察日 {escape(conv['obs_dt'])}，戳额全量 {fmt_int(conv['n'])} 人。</p>
      <div class="conv-kpis">
        <div class="kpi">
          <span class="label">戳额打分全量</span>
          <b>{fmt_int(conv['n'])}</b>
          <span class="sub">观察日 {escape(conv['obs_dt'])}</span>
        </div>
        <div class="kpi">
          <span class="label">戳额 → 借款申请</span>
          <b>{fmt_pct(conv['apply_rate'])}</b>
          <span class="sub">{fmt_int(conv['applied'])} 人</span>
        </div>
        <div class="kpi">
          <span class="label">戳额 → 成交</span>
          <b>{fmt_pct(conv['disburse_rate'])}</b>
          <span class="sub">{fmt_int(conv['disbursed'])} 人</span>
        </div>
        <div class="kpi">
          <span class="label">申请 → 成交</span>
          <b>{fmt_pct(conv['apply_to_disburse'])}</b>
          <span class="sub">{fmt_int(conv['disbursed'])} / {fmt_int(conv['applied'])} 人</span>
        </div>
      </div>
      <div class="subhead">转化速度</div>
      <p class="desc">从戳额日起算，t0 为当天、t1 为 0–1 天、t7 为 0–7 天；t1 / t7 只使用观察窗已满的用户。</p>
      <div class="table-wrap">
        <table class="decile">
          <thead>
            <tr><th>窗口</th><th>可观察人数</th><th>戳额 → 申请</th><th>戳额 → 成交</th></tr>
          </thead>
          <tbody>{window_rows}</tbody>
        </table>
      </div>
      <p class="note">申请中位用时 {fmt_elapsed_days(conv['median_days_to_apply'])}（P90 {fmt_elapsed_days(conv['p90_days_to_apply'])}），
      成交中位用时 {fmt_elapsed_days(conv['median_days_to_disburse'])}（P90 {fmt_elapsed_days(conv['p90_days_to_disburse'])}），
      成交用户人均放款金额 {fmt_money(conv['amount_per_disbursed'])}。</p>{decile_html}
      <p class="note">转化率分母为戳额打分全量（含未申请用户），成交按任意一笔成功计算，一人多次申请不重复计入人数。
      FPD15 坏率来自成交样本的成熟样本，和转化率分母不同，仅作同档对照。
      新模型尚未上线，分档转化率不受新模型审批影响；旧模型分档受现行审批策略影响，新旧绝对水平不可直接比较，重点看排序方向。</p>
    </section>
    """.strip()


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
              <td class="soft">{fmt_range(n['score_min'], n['score_max'])}</td>
              <td class="strong">{fmt_pct(n['rate'])}</td>
              <td class="lift">{fmt_num(n['lift'], 2)}×</td>
              <td class="soft">{fmt_int(n['bad'])}</td>
              <td>{fmt_int(o['n'])}</td>
              <td class="soft">{fmt_range(o['score_min'], o['score_max'])}</td>
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
              <th colspan="5" class="group new">新戳额模型</th>
              <th colspan="5" class="group old">线上模型</th>
            </tr>
            <tr>
              <th>样本</th><th>分数区间</th><th>笔数坏率</th><th>lift</th><th>坏样本</th>
              <th>样本</th><th>分数区间</th><th>笔数坏率</th><th>lift</th><th>坏样本</th>
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
      <p class="note">样本为全样本 FPD15 成熟且两个模型都有分的配对样本。按分数各拒绝最差的 {swap['reject_pct']}%（{fmt_int(swap['reject_n'])} 人）后交叉分组；
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
      <p class="note">AUC 在当周成熟样本上计算，坏样本或好样本少于 {WEEK_MIN_BAD} 笔的周不计算（显示 —）。
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
        <span class="sub">全样本成熟 {fmt_int(new['n'])} 笔 · Gini {fmt_num(new['gini'])} · KS {fmt_num(new['ks'])}</span>
      </div>
      <div class="kpi">
        <span class="label"><i class="dot old"></i>线上模型 FPD15 AUC</span>
        <b>{fmt_num(old['auc'])}</b>
        <span class="sub">全样本成熟 {fmt_int(old['n'])} 笔 · Gini {fmt_num(old['gini'])} · KS {fmt_num(old['ks'])}</span>
      </div>
      <div class="kpi">
        <span class="label">AUC 提升</span>
        <b>{fmt_signed(delta['diff'])}</b>
        <span class="sub">全样本配对 {fmt_int(delta['n'])} 笔 · 95% CI {fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])} · {fmt_p(delta['p'])}</span>
      </div>
      <div class="kpi">
        <span class="label">拒绝 {reject}% 后的通过坏率</span>
        <b>{fmt_pct(cut_new['kept_rate'])} <span class="vs">vs</span> {fmt_pct(cut_old['kept_rate'])}</b>
        <span class="sub">全样本成熟 · 笔数坏率</span>
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
    oot15, oot7 = f15["segments"]["oot"], f7["segments"]["oot"]
    oot_start = data["meta"]["oot_start"]
    oot_consistent = oot15["delta"]["diff"] > 0 and oot7["delta"]["diff"] > 0
    oot_txt = "与 OOT 前方向一致" if oot_consistent else "需关注 OOT 前后差异"

    conv = data.get("conversion")
    conv_bullet = ""
    if conv and conv.get("new_deciles"):
        first_q, last_q = conv["new_deciles"][0], conv["new_deciles"][-1]
        decile_n = conv["paired_n"] or conv["scored_n"]
        conv_bullet = f"""
        <li><b>戳额转化</b>：戳额全量 {fmt_int(conv['n'])} 人，借款申请率 {fmt_pct(conv['apply_rate'])}，
            成交率 {fmt_pct(conv['disburse_rate'])}，申请到成交 {fmt_pct(conv['apply_to_disburse'])}；
            在 {fmt_int(decile_n)} 人分档样本中，新戳额模型最低分档申请率 {fmt_pct(first_q['apply_rate'])}、
            最高分档 {fmt_pct(last_q['apply_rate'])}，转化随分数升高而下降，与坏率方向一致。
            该指标为描述性口径，新模型尚未上线，绝对水平不代表上线后效果。</li>"""

    return f"""
    <section class="card conclus" id="conclusion">
      <h2>结论</h2>
      <ul>
        <li><b>区分度</b>（全样本成熟）：新戳额模型 FPD15 AUC {fmt_num(new['auc'])}，线上模型 {fmt_num(old['auc'])}，
            提升 {fmt_signed(delta['diff'])}（95% CI {fmt_signed(delta['ci_low'])} ~ {fmt_signed(delta['ci_high'])}，
            {fmt_p(delta['p'])}）；FPD7 口径同样提升 {fmt_signed(f7['delta']['diff'])}，结论不依赖单一标签。</li>
        <li><b>OOT 表现</b>（OOT 后，{escape(oot_start)} 起）：FPD15 成熟 {fmt_int(oot15['n'])} 笔，
            新戳额模型 AUC {fmt_num(oot15['models']['new']['auc'])} vs 线上 {fmt_num(oot15['models']['old']['auc'])}，
            提升 {fmt_signed(oot15['delta']['diff'])}；FPD7 成熟 {fmt_int(oot7['n'])} 笔，
            AUC {fmt_num(oot7['models']['new']['auc'])} vs {fmt_num(oot7['models']['old']['auc'])}，
            提升 {fmt_signed(oot7['delta']['diff'])}，{oot_txt}。</li>
        <li><b>同样风控强度下坏率更低</b>（全样本成熟）：拒绝最差 {reject}% 时，新戳额模型通过人群坏率 {fmt_pct(cut_new['kept_rate'])}，
            线上模型 {fmt_pct(cut_old['kept_rate'])}（{ratio_txt}）；新戳额模型拦下 {fmt_pct(cut_new['capture'], 1)} 的坏账，线上模型 {fmt_pct(cut_old['capture'], 1)}。</li>
        <li><b>同样坏率预算下通过更多</b>（全样本成熟）：把通过坏率压在同一水平，新戳额模型能多放客户。以 {ref['target']}% 为例，
            线上模型最多通过 {fmt_pct(ref['old']['approval'], 1)}（{fmt_int(ref['old']['kept'])} 笔），新戳额模型
            {fmt_pct(ref['new']['approval'], 1)}（{fmt_int(ref['new']['kept'])} 笔），多 {fmt_int(ref['extra'])} 位客户、
            {fmt_money(ref['extra_good_amt'])} 好客户本金。</li>
        <li><b>分歧人群以新戳额模型判断为准</b>（全样本成熟）：新戳额模型拒绝而线上模型放行的 {fmt_int(new_only['n'])} 人坏率
            {fmt_pct(new_only['rate'])}，线上模型拒绝而新戳额模型放行的 {fmt_int(old_only['n'])} 人坏率仅
            {fmt_pct(old_only['rate'])}{gap_txt}。</li>{conv_bullet}
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
        <h3>{entry['label']} · ROC<span class="muted">　全样本成熟 {fmt_int(entry['n_obs'])} 笔 · 坏 {fmt_int(entry['n_bad'])} 笔</span></h3>
        <div class="chart-wrap">
          <svg id="roc{w}" viewBox="0 0 500 500" role="img" aria-label="{entry['label']} ROC 曲线"></svg>
          <div class="tip" id="rocTip{w}"></div>
        </div>
        <div class="legend">
          <span><i class="linekey new"></i>新戳额模型 <b>AUC {fmt_num(entry['models']['new']['auc'])}</b></span>
          <span><i class="linekey old"></i>线上模型 <b>AUC {fmt_num(entry['models']['old']['auc'])}</b></span>
        </div>
      </div>"""
        )
    return f"""
    <section class="card" id="roc">
      <h2>ROC 曲线<span class="tag" title="横轴假阳率、纵轴真阳率；对角线为随机模型；全样本成熟成交样本（含 OOT）">全样本成熟 · AUC 比较</span></h2>
      <p class="desc">曲线越靠左上越好；这里展示全样本成熟成交样本（含 OOT），OOT 切点前后的分段表现见「OOT 表现」卡。
      新戳额模型在两个标签口径下都明显更靠左上。</p>
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
    rule_txt = " / ".join(f"{v:.4f}" for v in NEW_DECILE_CUTS)
    old_rule_txt = " / ".join(f"{v:.4f}" for v in OLD_DECILE_CUTS)
    return f"""
    <section class="card" id="decile">
      <h2>十分位坏率<span class="tag" title="全样本成熟成交样本（含 OOT）；两个模型均按各自的固定十分位切点分档，第 10 档风险最高">全样本成熟 · FPD15</span></h2>
      <p class="desc">样本为全样本成熟成交样本（含 OOT）。新戳额模型{'从第 1 档到第 10 档单调上升' if mono else '各档基本拉开'}，最高档 {fmt_pct(new_dec[-1]['rate'])}、
      lift {fmt_num(new_dec[-1]['lift'], 2)}×；线上模型第 1–9 档坏率在 {fmt_pct(old_low)}–{fmt_pct(old_high)} 之间，
      最高档 {fmt_pct(old_dec[-1]['rate'])}、lift {fmt_num(old_dec[-1]['lift'], 2)}×。</p>
      <div class="chart-wrap">
        <svg id="decileChart" viewBox="0 0 1000 340" role="img" aria-label="FPD15 十分位坏率对比"></svg>
        <div class="tip" id="decileTip"></div>
      </div>
      <div class="legend">
        <span><i class="sq new"></i>新戳额模型</span>
        <span><i class="sq old"></i>线上模型</span>
        <span class="muted">横轴：第 1 档 = 分数最低（最安全）· lift = 该档坏率 / 全体坏率</span>
      </div>
      <div class="subhead">分档明细</div>
      {decile_table(data, '15')}
      <p class="note">两个模型均按各自的固定十分位切点分档：新戳额模型各档上界 {rule_txt}；
      线上模型各档上界 {old_rule_txt}。首档以下并入第 1 档，末档以上并入第 10 档，
      落在相邻档间隔内的分数并入下一档。分数区间为本次样本实际最小–最大值，不是固定规则区间。</p>
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
    <section class="card" id="cross">
      <h2>五分位交叉矩阵<span class="tag" title="全样本成熟成交样本（含 OOT）；行 = 新戳额模型五分位，列 = 线上模型五分位，均由各自固定十分位相邻两档合并；每格为该组合的笔数坏率">全样本成熟 · FPD15</span></h2>
      <p class="desc">每格是落在该组合的样本的笔数坏率；行、列均由低到高，1 档 = 分数最低（最安全），5 档 = 分数最高。横向看（新戳额档固定、线上模型 1→5 档）坏率最多只差
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
      <p class="note">行 = 新戳额模型五分位，列 = 线上模型五分位，均由各自固定十分位第 1–2、3–4、…、9–10 档合并，
      1 档风险最低。样本为全样本 FPD15 成熟且两个模型都有分的
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
    <section class="card" id="money">
      <h2>置入与置出<span class="tag" title="全样本 FPD15 成熟成交样本（含 OOT）；置入 = 放款本金 real_amount 之和；置出 = due+N 当天借据快照的未还本金之和">全样本成熟 · FPD15 · 金额</span></h2>
      <p class="desc">前面所有坏率都是笔数口径，这里换成钱。全样本 FPD15 成熟成交样本上，新戳额模型口径的置入
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
      <p class="note">置入 = real_amount 之和；置出 = due + N 当天借据快照的未还本金之和，成熟样本上无缺失；
      置出率 = 置出 / 置入；留存 = 置入 − 置出。金额为放款本金口径，不含利息与费用。</p>
    </section>
    """


def capture_card(data) -> str:
    entry = data["windows"]["15"]
    reject = data["meta"]["reject_pct"]
    cut_new, cut_old = cut_for(entry, "new", reject), cut_for(entry, "old", reject)
    return f"""
    <section class="card" id="capture">
      <h2>拦截收益<span class="tag" title="全样本成熟成交样本（含 OOT）；按分数从高到低拒绝，横轴为拒绝比例，纵轴为被拒样本中的坏账占比">全样本成熟 · FPD15</span></h2>
      <p class="desc">在全样本成熟成交样本上，拒绝同样比例的人，新戳额模型能拦下更多坏账。拒绝 {reject}% 时，新戳额模型捕获
      {fmt_pct(cut_new['capture'], 1)} 的坏账，线上模型 {fmt_pct(cut_old['capture'], 1)}。</p>
      <div class="chart-wrap">
        <svg id="captureChart" viewBox="0 0 1000 340" role="img" aria-label="坏账捕获曲线"></svg>
        <div class="tip" id="captureTip"></div>
      </div>
      <div class="legend">
        <span><i class="linekey new"></i>新戳额模型</span>
        <span><i class="linekey old"></i>线上模型</span>
        <span><i class="linekey"></i>随机拦截</span>
      </div>

      <div class="subhead">FPD15 · 通过率情景</div>
      {scenario_table(data, '15')}
      <div class="subhead">FPD7 · 通过率情景</div>
      {scenario_table(data, '7')}
      <p class="note">样本为全样本 FPD15 成熟成交样本（含 OOT）。通过坏率 = 未被拒绝样本的笔数坏率；拦截坏账（笔数）= 被拒坏样本 / 全部坏样本；
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
    <section class="card" id="through">
      <h2>通过收益<span class="tag" title="全样本成熟成交样本（含 OOT）；把通过坏率控制在同一水平，各模型能达到的最高通过率">全样本成熟 · FPD15</span></h2>
      <p class="desc">在全样本成熟成交样本上，把通过坏率压在同一水平，各模型能达到的最高通过率不同。以 {ref['target']}% 以内为例，线上模型只能通过
      {fmt_pct(o['approval'], 1)}（{fmt_int(o['kept'])} 笔），新戳额模型可以通过 {fmt_pct(n['approval'], 1)}（{fmt_int(n['kept'])} 笔），
      多 {fmt_int(ref['extra'])} 位客户、{fmt_money(ref['extra_good_amt'])} 好客户本金。</p>
      <div class="chart-wrap">
        <svg id="approvalChart" viewBox="0 0 1000 340" role="img" aria-label="同一坏率预算下的可达通过率"></svg>
        <div class="tip" id="approvalTip"></div>
      </div>
      <div class="legend">
        <span><i class="linekey new"></i>新戳额模型</span>
        <span><i class="linekey old"></i>线上模型</span>
        <span class="muted">纵轴：该坏率下可达到的最高通过率</span>
      </div>

      <div class="subhead">FPD15 · 同一坏率预算下的通过空间</div>
      {through_table(data, '15')}
      <div class="subhead">FPD7 · 同一坏率预算下的通过空间</div>
      {through_table(data, '7')}
      <p class="note">样本为全样本 FPD15 成熟成交样本（含 OOT）。坏率预算 = 通过样本的笔数坏率上限；通过率 = 该预算下可放行的最大比例，
      多通过本金 = 两边"好客户"（未坏样本）的放款本金之差。线上模型缺失 5 笔，两个样本相差 5 笔以内。
      本金为放款金额 real_amount，不含利息与费用。线上模型在低预算档只放得出极少数人，说明它无法在该坏率水平上开展业务。</p>
    </section>
    """


def swap_card(data) -> str:
    swap = data["windows"]["15"]["swap"]
    return f"""
    <section class="card" id="swap">
      <h2>决策互换矩阵<span class="tag" title="全样本成熟成交样本（含 OOT）；两个模型各拒绝最差 30% 后的人群交叉对比">全样本成熟 · FPD15 · 拒绝 {swap['reject_pct']}%</span></h2>
      <p class="desc">同一批全样本成熟且两个模型都有分的人、同样的拒绝比例，两个模型拒掉的人只有一部分重叠。分歧人群的实际坏率决定该信谁。</p>
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
    <section class="card" id="weekly">
      <h2>分周稳定性<span class="tag" title="按放款周逐周重算；不是 OOT 的单一切分，OOT 见上一张卡">逐周重算 · AUC</span></h2>
      <p class="desc">{desc_head}。这是按放款周在每一周的成熟样本上逐周重算，和「OOT 表现」的单一切分不同。{'；'.join(parts)}。</p>
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
        <h3>{entry['label']} · AUC 按周<span class="muted">　当周成熟 {fmt_int(entry['n_obs'])} 笔 · 坏 {fmt_int(entry['n_bad'])} 笔</span></h3>
        <div class="chart-wrap">
          <svg id="week{w}" viewBox="0 0 500 330" role="img" aria-label="{entry['label']} 周度 AUC"></svg>
          <div class="tip" id="weekTip{w}"></div>
        </div>
        <div class="legend">
          <span><i class="linekey new"></i>新戳额模型</span>
          <span><i class="linekey old"></i>线上模型</span>
        </div>
      </div>
    """


def footer_html(data, generated_at, label_name, score_name, limit=None, limit_name="") -> str:
    meta = data["meta"]
    unscored_note = (
        "均为窗口末尾放款、FPD7/FPD15 均未成熟，不影响评估。"
        if meta.get("unscored_immature")
        else "其中包含已成熟样本，评估时需注意覆盖度。"
    )
    oot_start = meta["oot_start"]
    pre_end = (pd.Timestamp(oot_start) - pd.Timedelta(days=1)).strftime("%Y-%m-%d")
    limit_note = ""
    if limit:
        limit_note = f"""
        <li><b>戳额生产打分全量</b>：{escape(limit_name)} 为新客戳额环节的生产打分全量，共 {fmt_int(limit['n'])} 人，
            覆盖 {escape(limit['dt_min'])} 至 {escape(limit['dt_max'])}；已打分 {fmt_int(limit['n_scored'])} 人、
            缺分 {fmt_int(limit['n_missing'])} 人（{fmt_pct(limit['missing_rate'])}）。
            该样本不含标签（未成交申请无表现数据），分布卡只比较新旧分数分布与档位迁移；AUC / KS 仅在戳额成交样本上计算。</li>"""
    return f"""
    <footer class="foot">
      <ul class="notes">
        <li><b>样本口径</b>：wagego_02 的新客首笔成交样本（application_rank = 1，按戳额时间 {escape(meta['start'])} 至 {escape(meta['end_display'])} 筛选），
            与新戳额模型打分文件按 last_limit_flow_id = flow_id 关联，共 {fmt_int(meta['n_sample'])} 人。首借客户每人一笔，人数与笔数一致。
            样本表中另有 {fmt_int(meta['n_unscored'])} 笔未打分、不入样：{unscored_note}</li>
        <li><b>OOT 口径</b>：OOT 按戳额时间 last_limit_time ≥ {escape(oot_start)} 划分；OOT 后为 {escape(oot_start)} 及以后，
            OOT 前（切点之前）为 {escape(meta['start'])} 至 {escape(pre_end)}。
            OOT 分段的 AUC / KS / ΔAUC 见「OOT 表现」卡，未成熟样本不计入对应窗口。</li>{limit_note}
        <li><b>模型口径</b>：新戳额模型 {escape(NEW_SCORE)}（戳额场景，{NEW_DESC}）；线上模型 {escape(OLD_SCORE)}（发标场景，{OLD_DESC}）。
            两者决策时点接近——中位 {fmt_days(meta['median_days'])}、75 分位 {fmt_days(meta['p75_days'])}内即放款，比较视为同点。
            线上模型有 {fmt_int(meta['old_missing'])} 笔缺失（含 -1 哨兵值），按缺失处理，不参与排序。</li>
        <li><b>坏率口径</b>：笔数坏率 = y_fpdN_ovd 之和 / y_fpdN_obs 之和；成熟条件为 due + N &lt; 观察日（{escape(meta['obs_dt'])}），
            未成熟不判坏。本报告坏率均为笔数口径；金额仅出现在「通过收益」卡，为放款本金 real_amount，
            好客户本金 = 未坏样本的放款本金之和，不含利息与费用。</li>
        <li><b>指标口径</b>：除「OOT 表现」「分周稳定性」单独标注外，正文 AUC / Gini / KS 均为<b>全样本成熟成交样本</b>口径
            （全部成熟样本，含 OOT 时段，不是只算 OOT，也不是只算 OOT 前）。OOT 卡为切点后 / 切点前子样本，
            周度卡为逐周成熟子样本。各模型 AUC 用各自有分样本计算；AUC 置信区间与两模型差异用 DeLong 法（差异检验为配对 DeLong）。
            两个模型的十分位均按各自的固定分箱规则切档（切点见「十分位坏率」分档明细），第 1 档最低风险。</li>
        <li><b>lift 口径</b>：lift = 该组笔数坏率 / 全体笔数坏率。分档 lift 按档计算（第 10 档即最高档坏率 / 全体坏率）；
            互换矩阵按格计算，基数取该口径下的全体坏率；拦截 lift = 被拒人群坏率 / 全体坏率，也等于拦截坏账占比 / 拒绝比例。</li>
        <li><b>使用提示</b>：样本为首笔成交客户（不含未成交申请），结论用于排序能力与相对优劣判断；
            若要据此定准入规则，需在全申请口径（含被拒）上复核通过率与坏率。上线前建议核对新戳额模型特征时点，
            确认仅使用戳额及之前的交易数据，无跨期信息泄漏。</li>
        <li><b>数据源</b>：{escape(label_name)}、{escape(score_name)}；生成脚本 build_new_user_credit_analysis.py；生成时间 {escape(generated_at)}。</li>
      </ul>
    </footer>
    """


# --------------------------------------------------------------------------- 模板


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WageGo 新客戳额风险模型效果评估报告</title>
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
  .conv-kpis {
    display: grid; grid-template-columns: repeat(4, 1fr);
    gap: 10px; margin: 8px 0 4px;
  }
  .conv-kpis .kpi { padding: 10px 12px; }
  .conv-kpis .kpi b { font-size: 22px; }
  .conv-charts { margin-top: 8px; }
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
  .toc {
    position: fixed; top: 36px; z-index: 20;
    left: max(24px, calc((100vw - 1532px) / 2));
    width: 190px; max-height: calc(100vh - 72px); overflow-y: auto;
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 12px 14px;
    transition: width .18s ease, padding .18s ease;
  }
  .toc-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 5px; }
  .toc-head h2 { font-size: 13px; margin: 0; letter-spacing: .02em; }
  .toc ol {
    list-style: none; margin: 0; padding: 0; counter-reset: toc;
    display: grid; grid-template-columns: 1fr; gap: 0;
  }
  .toc li { counter-increment: toc; min-width: 0; }
  .toc a {
    display: flex; gap: 8px; padding: 4px 0; border-bottom: 1px solid transparent;
    color: var(--ink-2); text-decoration: none; font-size: 12.5px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .toc a::before {
    content: counter(toc, decimal-leading-zero); color: var(--muted);
    font-size: 10.5px; line-height: 1.85; font-variant-numeric: tabular-nums;
  }
  .toc a:hover { color: var(--ink); border-bottom-color: var(--grid); }
  html { scroll-behavior: smooth; }
  section[id] { scroll-margin-top: 14px; }
  @media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
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
  .sq {
    display: inline-block; width: 10px; height: 10px; border-radius: 2px;
    margin-right: 6px; vertical-align: -1px;
  }
  .sq.new { background: var(--c1); }
  .sq.old { background: var(--c2); }
  .linekey {
    display: inline-block; width: 16px; height: 0; border-top: 2px solid var(--axis);
    margin-right: 6px; vertical-align: 3px;
  }
  .linekey.new { border-top-color: var(--c1); }
  .linekey.old { border-top-color: var(--c2); }
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
  table.oot tr.oot td { background: var(--page); border-top: 1px solid var(--grid); }
  table.oot tr.oot td.strong { font-weight: 600; }
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
    cursor: help;
  }
  table.cross td:hover { outline: 2px solid var(--ink-2); outline-offset: -2px; }
  table.cross td b { display: block; font-size: 15px; font-weight: 600; line-height: 1.3; }
  table.cross td span { display: block; font-size: 10.5px; opacity: .72; }
  table.cross td.h1 { background: rgba(192,57,43,0.06); }
  table.cross td.h2 { background: rgba(192,57,43,0.15); }
  table.cross td.h3 { background: rgba(192,57,43,0.29); }
  table.cross td.h4 { background: rgba(192,57,43,0.46); }
  table.cross td.h5 { background: rgba(192,57,43,0.66); }
  table.cross td.m1 { background: rgba(42,120,214,0.06); }
  table.cross td.m2 { background: rgba(42,120,214,0.14); }
  table.cross td.m3 { background: rgba(42,120,214,0.27); }
  table.cross td.m4 { background: rgba(42,120,214,0.42); }
  table.cross td.m5 { background: rgba(42,120,214,0.58); }
  table.cross.migration td { padding: 8px 4px; }
  table.cross.migration td b { font-size: 12px; }
  table.cross.migration td span { font-size: 9.5px; }
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
  .heat-legend .sw.m1 { background: rgba(42,120,214,0.06); }
  .heat-legend .sw.m2 { background: rgba(42,120,214,0.14); }
  .heat-legend .sw.m3 { background: rgba(42,120,214,0.27); }
  .heat-legend .sw.m4 { background: rgba(42,120,214,0.42); }
  .heat-legend .sw.m5 { background: rgba(42,120,214,0.58); }
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
  @media (max-width: 1580px) {
    .toc { width: 44px; padding: 9px 0; overflow: hidden; }
    .toc-head { justify-content: center; margin: 0; }
    .toc-head h2 { letter-spacing: .02em; font-size: 12px; }
    .toc-head .muted { display: none; }
    .toc ol { display: none; }
    .toc:hover, .toc:focus-within { width: 200px; padding: 12px 14px; }
    .toc:hover .toc-head, .toc:focus-within .toc-head { justify-content: space-between; }
    .toc:hover .toc-head h2, .toc:focus-within .toc-head h2 { font-size: 13px; }
    .toc:hover ol, .toc:focus-within ol { display: grid; }
  }
  @media (max-width: 1279px) {
    .toc { display: none; }
  }
  @media (max-width: 900px) {
    .kpis { grid-template-columns: repeat(2, 1fr); }
    .conv-kpis { grid-template-columns: repeat(2, 1fr); }
    .grid2 { grid-template-columns: 1fr; }
    .swap { grid-template-columns: 92px 1fr 1fr; }
  }
  @media (max-width: 560px) {
    h1 { font-size: 24px; }
    .kpis { grid-template-columns: 1fr; }
    .conv-kpis { grid-template-columns: 1fr; }
  }
  @media (prefers-reduced-motion: reduce) {
    .toc { transition: none; }
  }
  @media print {
    .toc { display: none; }
  }
</style>
</head>
<body>
<main>
__TOC__
__HEADER__
__KPIS__
__CONVERSION_CARD__
__METRICS_CARD__
__ROC_CARD__
__DECILE_CARD__
__CROSS_CARD__
__OOT_CARD__
__WEEKLY_CARD__
__MONEY_CARD__
__CAPTURE_CARD__
__THROUGH_CARD__
__SWAP_CARD__
__LIMIT_CARD__
__SUMMARY__
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
      x: 16, y: cy, 'text-anchor': 'middle',
      transform: 'rotate(-90 16 ' + cy + ')',
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

/* ---------- 分档转化率 ---------- */
function drawConversionMetric(svgId, tipId, field) {
  const conv = DATA.conversion;
  if (!conv) return;
  const svg = document.getElementById(svgId);
  if (!svg) return;
  const tip = tipCtl(svg, document.getElementById(tipId));
  const W = 500, H = 280, m = { l: 48, r: 76, t: 18, b: 48 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const series = [
    { name: '线上模型', color: 'var(--c2)', rows: conv.old_deciles || [] },
    { name: '新戳额模型', color: 'var(--c1)', rows: conv.new_deciles || [] }
  ].filter(s => s.rows.length);
  const vals = [];
  series.forEach(s => s.rows.forEach(r => {
    if (r[field] != null) vals.push(r[field]);
  }));
  if (!vals.length) return;
  const yMax = Math.max(10, Math.ceil(Math.max.apply(null, vals) / 20) * 20);
  const x = q => m.l + (q - 1) / 9 * iw;
  const y = v => m.t + (1 - v / yMax) * ih;
  clearSvg(svg);

  axes(svg, {
    W, H, m, x, y, xTicks: [],
    yTicks: [0, 0.25, 0.5, 0.75, 1].map(t => t * yMax),
    xFmt: t => '', yFmt: t => t.toFixed(0) + '%',
    xLabel: '分档（1 = 分数最低）', tickSize: 11
  });
  for (let q = 1; q <= 10; q++) {
    svgEl(svg, 'text', {
      x: x(q), y: H - m.b + 20, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 11
    }, q);
  }

  const cross = svgEl(svg, 'line', {
    y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });

  series.forEach(s => {
    let d = '', pen = false;
    s.rows.forEach((r, i) => {
      const v = r[field];
      if (v == null) { pen = false; return; }
      d += (pen ? 'L' : 'M') + x(i + 1) + ',' + y(v);
      pen = true;
    });
    if (d) {
      svgEl(svg, 'path', {
        d, fill: 'none', stroke: s.color, 'stroke-width': 2,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round'
      });
    }
    s.rows.forEach((r, i) => {
      if (r[field] == null) return;
      svgEl(svg, 'circle', {
        cx: x(i + 1), cy: y(r[field]), r: 4,
        fill: s.color, stroke: 'var(--surface)', 'stroke-width': 2
      });
    });
  });

  // 末端直接标注；两条线靠得太近时用引线错开
  const ends = [];
  series.forEach(s => {
    for (let i = s.rows.length - 1; i >= 0; i--) {
      if (s.rows[i][field] != null) {
        ends.push({ v: s.rows[i][field], color: s.color, q: i + 1 });
        break;
      }
    }
  });
  ends.sort((a, b) => b.v - a.v);
  let labelY = ends.map(e => y(e.v));
  if (labelY.length === 2 && Math.abs(labelY[0] - labelY[1]) < 16) {
    const mid = (labelY[0] + labelY[1]) / 2;
    labelY = [mid - 9, mid + 9];
  }
  ends.forEach((e, i) => {
    const ex = x(e.q);
    if (Math.abs(labelY[i] - y(e.v)) > 1) {
      svgEl(svg, 'line', {
        x1: ex + 5, y1: y(e.v), x2: ex + 11, y2: labelY[i],
        stroke: 'var(--axis)', 'stroke-width': 1
      });
    }
    svgEl(svg, 'circle', { cx: ex + 15, cy: labelY[i], r: 3, fill: e.color });
    svgEl(svg, 'text', {
      x: ex + 22, y: labelY[i] + 4, fill: 'var(--ink)',
      'font-size': 11.5, 'font-weight': 600
    }, fmtPct(e.v));
  });

  const hit = svgEl(svg, 'rect', {
    x: m.l - 10, y: m.t, width: iw + 20, height: ih,
    fill: 'transparent', tabindex: 0
  });
  let lastQ = 1;
  function show(q) {
    lastQ = q;
    cross.setAttribute('x1', x(q));
    cross.setAttribute('x2', x(q));
    cross.setAttribute('opacity', 1);
    const rows = [];
    let top = yMax;
    series.forEach(s => {
      const r = s.rows[q - 1];
      if (!r || r[field] == null) return;
      top = Math.min(top, r[field]);
      rows.push({
        value: fmtPct(r[field]),
        name: s.name + ' n=' + fmtInt(r.n),
        color: s.color
      });
    });
    tip.show({
      title: '第 ' + q + ' 档' + (q === 1 ? '（分数最低）' : q === 10 ? '（分数最高）' : ''),
      rows
    }, x(q), y(top) - 8);
  }
  function qAt(clientX) {
    const box = svg.getBoundingClientRect();
    const ux = (clientX - box.left) / box.width * W;
    return Math.min(10, Math.max(1, Math.round((ux - m.l) / iw * 9) + 1));
  }
  hit.addEventListener('pointermove', e => show(qAt(e.clientX)));
  hit.addEventListener('pointerleave', () => {
    tip.hide();
    cross.setAttribute('opacity', 0);
  });
  hit.addEventListener('focus', () => show(lastQ));
  hit.addEventListener('blur', () => {
    tip.hide();
    cross.setAttribute('opacity', 0);
  });
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

/* ---------- OOT AUC 对比 ---------- */
function drawOot() {
  const svg = document.getElementById('ootChart');
  if (!svg) return;
  const tip = tipCtl(svg, document.getElementById('ootTip'));
  const rows = [];
  ['15', '7'].forEach(w => {
    const segs = DATA.windows[w].segments;
    [['all', '全样本'], ['pre_oot', 'OOT 前'], ['oot', 'OOT 后']].forEach(pair => {
      const seg = segs[pair[0]];
      rows.push({
        label: 'FPD' + w + ' · ' + pair[1],
        old: seg.models.old.auc,
        new: seg.models.new.auc,
        delta: seg.delta,
        n: seg.n,
        bad: seg.bad,
        oot: pair[0] === 'oot'
      });
    });
  });
  const vals = [];
  rows.forEach(r => {
    if (r.old != null) vals.push(r.old);
    if (r.new != null) vals.push(r.new);
  });
  if (!vals.length) return;
  const lo = Math.floor((Math.min.apply(null, vals) - 0.015) * 20) / 20;
  const hi = Math.ceil((Math.max.apply(null, vals) + 0.015) * 20) / 20;
  const span = hi - lo || 0.1;
  const W = 1000, H = 320, m = { l: 116, r: 122, t: 18, b: 48 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const x = v => m.l + (v - lo) / span * iw;
  const groupGap = 8;
  const rowH = (ih - groupGap) / rows.length;
  const cy = i => m.t + i * rowH + (i >= 3 ? groupGap : 0) + rowH / 2;
  clearSvg(svg);

  const ticks = [];
  for (let t = lo; t <= hi + 1e-9; t += 0.05) ticks.push(Math.round(t * 100) / 100);

  rows.forEach((r, i) => {
    if (!r.oot) return;
    svgEl(svg, 'rect', {
      x: m.l, y: cy(i) - rowH / 2 + 2, width: iw, height: rowH - 4,
      rx: 4, fill: 'var(--grid)', opacity: 0.55
    });
  });

  axes(svg, {
    W, H, m, x, y: v => v, xTicks: ticks, yTicks: [],
    xFmt: t => t.toFixed(2), yFmt: t => '',
    xLabel: 'AUC（越高越好）', tickSize: 11.5
  });

  rows.forEach((r, i) => {
    const yy = cy(i);
    svgEl(svg, 'text', {
      x: m.l - 14, y: yy + 4, 'text-anchor': 'end',
      fill: r.oot ? 'var(--ink)' : 'var(--ink-2)',
      'font-size': 12, 'font-weight': r.oot ? 600 : 400
    }, r.label);
    if (r.old == null || r.new == null) return;
    const xo = x(r.old), xn = x(r.new);
    svgEl(svg, 'line', {
      x1: xo, y1: yy, x2: xn, y2: yy,
      stroke: 'var(--axis)', 'stroke-width': 2, 'stroke-linecap': 'round'
    });
    svgEl(svg, 'circle', {
      cx: xo, cy: yy, r: 4.5, fill: 'var(--c2)',
      stroke: 'var(--surface)', 'stroke-width': 2
    });
    svgEl(svg, 'circle', {
      cx: xn, cy: yy, r: 4.5, fill: 'var(--c1)',
      stroke: 'var(--surface)', 'stroke-width': 2
    });
    const right = r.new >= r.old;
    svgEl(svg, 'text', {
      x: xn + (right ? 10 : -10), y: yy + 4,
      'text-anchor': right ? 'start' : 'end',
      fill: 'var(--ink)', 'font-size': 11.5, 'font-weight': 600
    }, r.new.toFixed(3));
    svgEl(svg, 'text', {
      x: W - 14, y: yy + 4, 'text-anchor': 'end',
      fill: r.oot ? 'var(--ink)' : 'var(--muted)',
      'font-size': 11.5, 'font-weight': r.oot ? 600 : 400
    }, (r.delta.diff >= 0 ? '+' : '') + r.delta.diff.toFixed(3));
  });

  const frame = svgEl(svg, 'rect', {
    x: m.l, y: 0, width: iw, height: rowH - 4,
    rx: 4, fill: 'none', stroke: 'var(--ink-2)', 'stroke-width': 1,
    opacity: 0, 'pointer-events': 'none'
  });
  const hit = svgEl(svg, 'rect', {
    x: m.l - 104, y: m.t, width: iw + 104, height: ih,
    fill: 'transparent', tabindex: 0
  });
  let last = 2;
  function show(i) {
    last = i;
    const r = rows[i];
    frame.setAttribute('y', cy(i) - rowH / 2 + 2);
    frame.setAttribute('opacity', 1);
    tip.show({
      title: r.label + ' · 成熟 ' + fmtInt(r.n) + ' 笔 · 坏 ' + fmtInt(r.bad) + ' 笔',
      rows: [
        { value: r.new == null ? '—' : r.new.toFixed(3), name: '新戳额模型 AUC', color: 'var(--c1)' },
        { value: r.old == null ? '—' : r.old.toFixed(3), name: '线上模型 AUC', color: 'var(--c2)' },
        {
          value: r.delta == null ? '—' : (r.delta.diff >= 0 ? '+' : '') + r.delta.diff.toFixed(3),
          name: r.delta == null ? 'ΔAUC（新 − 旧）' : 'ΔAUC 95% CI ' + r.delta.ci_low.toFixed(3) + ' ~ ' + r.delta.ci_high.toFixed(3)
        }
      ]
    }, Math.max(x(r.old || lo), x(r.new || lo)), cy(i) - 8);
  }
  function rowAt(clientY) {
    const box = svg.getBoundingClientRect();
    const uy = (clientY - box.top) / box.height * H;
    let best = 0, dist = Infinity;
    rows.forEach((r, i) => {
      const d = Math.abs(uy - cy(i));
      if (d < dist) { dist = d; best = i; }
    });
    return best;
  }
  hit.addEventListener('pointermove', e => show(rowAt(e.clientY)));
  hit.addEventListener('pointerleave', () => {
    tip.hide();
    frame.setAttribute('opacity', 0);
  });
  hit.addEventListener('focus', () => show(last));
  hit.addEventListener('blur', () => {
    tip.hide();
    frame.setAttribute('opacity', 0);
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
drawConversionMetric('convApplyChart', 'convApplyTip', 'apply_rate');
drawConversionMetric('convDisburseChart', 'convDisburseTip', 'disburse_rate');
drawOot();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------- 组装


def build_html(data, generated_at: str, label_name: str, score_name: str,
               limit=None, limit_name: str = "") -> str:
    meta = data["meta"]
    header = f"""
    <header>
      <p class="eyebrow">WAGEGO · 新客首借成交样本</p>
      <h1>新客戳额风险模型效果评估报告</h1>
      <p class="sub">从区分度、决策收益到周度稳定性，评估新戳额模型相对线上模型的增量价值。
      首笔成交新客，戳额时间 {escape(meta['start'])} 至 {escape(meta['end_display'])}，观察日 {meta['obs_dt']}。
      除特别标注外，正文 AUC / KS / 坏率均为<b>全样本成熟成交样本</b>口径（含 OOT 时段）；OOT 与周度稳定性单独切分。</p>
      <div class="models">
        <span><i class="dot new"></i><b>{NEW_NAME}</b><code>{escape(NEW_SCORE)}</code><span class="muted">戳额场景</span></span>
        <span><i class="dot old"></i><b>{OLD_NAME}</b><code>{escape(OLD_SCORE)}</code><span class="muted">发标场景</span></span>
      </div>
      <div class="chips">
        <span class="chip">样本 {fmt_int(meta['n_sample'])} 人（每人一笔）</span>
        {f'<span class="chip">戳额全量 {fmt_int(limit["n"])} 人</span>' if limit else ''}
        {f'<span class="chip">戳额→成交 {fmt_pct(limit["conversion"]["disburse_rate"])}</span>' if limit and limit.get("conversion") else ''}
        <span class="chip">主指标：全样本成熟（含 OOT）</span>
        <span class="chip">FPD15 成熟 {fmt_int(data['windows']['15']['n_obs'])} 笔</span>
        <span class="chip">FPD7 成熟 {fmt_int(data['windows']['7']['n_obs'])} 笔</span>
        <span class="chip">OOT 切点 {escape(meta['oot_start'])}</span>
        <span class="chip">笔数坏率</span>
      </div>
    </header>
    """
    f15m = data["windows"]["15"]["models"]
    metrics_card = f"""
    <section class="card" id="metrics">
      <h2>核心指标<span class="tag" title="AUC / Gini / KS 均在全样本成熟成交样本上计算（含 OOT 时段）">全样本成熟 · 排序能力</span></h2>
      <p class="desc">两个标签口径、两个模型都在全样本成熟成交样本上计算；ΔAUC 另取两个模型都有分的配对样本。
      新戳额模型 AUC {fmt_num(f15m['new']['auc'], 2)}、KS {fmt_num(f15m['new']['ks'], 2)}，
      线上模型 AUC {fmt_num(f15m['old']['auc'], 2)}、KS {fmt_num(f15m['old']['ks'], 2)}。</p>
      {metrics_table(data)}
    </section>
    """
    toc_entries = []
    if limit and limit.get("conversion"):
        toc_entries.append(("conversion", "转化漏斗"))
    toc_entries += [
        ("metrics", "核心指标"),
        ("roc", "ROC 曲线"),
        ("decile", "十分位坏率"),
        ("cross", "五分位交叉矩阵"),
        ("oot", "OOT 表现"),
        ("weekly", "分周稳定性"),
        ("money", "置入与置出"),
        ("capture", "拦截收益"),
        ("through", "通过收益"),
        ("swap", "决策互换矩阵"),
    ]
    if limit:
        toc_entries.append(("limit", "戳额生产打分全量"))
    toc_entries.append(("conclusion", "结论"))
    toc_links = "".join(
        f'<li><a href="#{anchor}">{escape(title)}</a></li>'
        for anchor, title in toc_entries
    )
    toc = f"""
    <nav class="toc" aria-label="目录" tabindex="0">
      <div class="toc-head"><h2>目录</h2><span class="muted">点击跳转</span></div>
      <ol>{toc_links}</ol>
    </nav>
    """
    html = HTML_TEMPLATE
    html = html.replace("__HEADER__", header)
    html = html.replace("__KPIS__", kpi_html(data))
    html = html.replace("__CONVERSION_CARD__", conversion_card(limit, data))
    html = html.replace("__TOC__", toc)
    html = html.replace("__SUMMARY__", summary_html(data))
    html = html.replace("__METRICS_CARD__", metrics_card)
    html = html.replace("__OOT_CARD__", oot_card(data))
    html = html.replace("__LIMIT_CARD__", limit_card(limit))
    html = html.replace("__ROC_CARD__", roc_card(data))
    html = html.replace("__DECILE_CARD__", decile_card(data))
    html = html.replace("__MONEY_CARD__", money_card(data))
    html = html.replace("__CROSS_CARD__", cross_card(data))
    html = html.replace("__CAPTURE_CARD__", capture_card(data))
    html = html.replace("__THROUGH_CARD__", through_card(data))
    html = html.replace("__SWAP_CARD__", swap_card(data))
    html = html.replace("__WEEKLY_CARD__", weekly_card(data))
    html = html.replace("__FOOTER__", footer_html(
        data, generated_at, label_name, score_name, limit, limit_name
    ))
    payload = json.dumps(to_py(data), ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    html = html.replace("__DATA_JSON__", payload.replace("</", "<\\/"))
    return html


def main(argv=None):
    parser = argparse.ArgumentParser(description="新客样本模型分分析（新戳额模型 vs 线上模型）")
    parser.add_argument("--label-csv", default=str(DEFAULT_LABEL), help="主表 CSV")
    parser.add_argument("--score-csv", default=str(DEFAULT_SCORE), help="戳额成交样本新模型分 CSV")
    parser.add_argument("--limit-score-csv", default=str(DEFAULT_LIMIT_SCORE),
                        help="戳额生产打分全量新模型分 CSV")
    parser.add_argument("--limit-old-score-csv", default=str(DEFAULT_LIMIT_OLD_SCORE),
                        help="戳额生产打分全量线上旧模型分 CSV（按 flow_id 关联）")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出 HTML")
    parser.add_argument("--start", default="2026-08-01", help="戳额起始日")
    parser.add_argument("--end", default="2026-10-24", help="戳额结束日（不含）")
    parser.add_argument("--oot-start", default="2026-09-30", help="OOT 起始日（按戳额时间）")
    parser.add_argument("--reject", type=int, default=30, help="互换矩阵的拒绝比例 %")
    args = parser.parse_args(argv)

    label_path = Path(args.label_csv)
    score_path = Path(args.score_csv)
    limit_path = Path(args.limit_score_csv)
    limit_old_path = Path(args.limit_old_score_csv)
    for path in (label_path, score_path):
        if not path.exists():
            parser.error(f"文件不存在：{path}")

    sample = load_sample(label_path, score_path, args.start, args.end)
    data = build_data(sample, args.reject, args.oot_start)
    data["meta"]["start"] = args.start
    data["meta"]["end_display"] = (
        pd.Timestamp(args.end) - pd.Timedelta(days=1)
    ).strftime("%Y-%m-%d")
    limit_data = None
    if limit_path.exists():
        if not limit_old_path.exists():
            print(f"未找到戳额旧模型分，分布卡仅展示新模型：{limit_old_path}")
        limit_data = load_limit_data(
            limit_path,
            limit_old_path if limit_old_path.exists() else None,
            label_path,
        )
        if limit_data.get("conversion"):
            data["conversion"] = limit_data["conversion"]
    else:
        print(f"未找到戳额生产打分全量，跳过分布卡：{limit_path}")
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
    html = build_html(
        data, generated_at, label_path.name, score_path.name,
        limit_data, limit_path.name,
    )

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

    if limit_data and limit_data["migration"]:
        m = limit_data["migration"]
        print(
            f"  戳额全量配对 {m['n']:,} 人 | 新旧同档 {m['diag_share']:.1f}% | "
            f"秩相关 {m['spearman']:.3f}"
        )

    if limit_data and limit_data.get("conversion"):
        c = limit_data["conversion"]
        print(
            f"  戳额转化 {c['n']:,} 人 | 申请 {c['apply_rate']:.2f}% | "
            f"成交 {c['disburse_rate']:.2f}% | 申请→成交 {c['apply_to_disburse']:.2f}%"
        )


if __name__ == "__main__":
    main()
