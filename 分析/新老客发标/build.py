#!/usr/bin/env python3
"""新老客发标样本上的模型分分析，输出自包含 HTML。

样本：wagego_07 同步的发标全量样本（wagego_02 的 all_user_bid，含未成交申请）
      + 新发标模型分 aus_wagego_bid_20261123_v1_0_txn_lgb_score。
分箱：模型侧固定十分位切点（见 BID_DECILE_*），不随样本等笔数切档。
完全独立于 分析/新客戳额/build.py；共用层仅 sync_common.py。

用法：
    python 分析/新老客发标/build.py
    python 分析/新老客发标/build.py --sample-csv 样例.xlsx --output 输出.html
"""

from __future__ import annotations

import argparse
import json
import re
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

PROJECT_DIR = Path(__file__).resolve().parents[2]
ANALYSIS_DIR = Path(__file__).resolve().parent
RAW_DIR = PROJECT_DIR / "数据" / "新老客发标"

SAMPLE_NAME = "table_tmp_eliam_wagego_all_user_bid_v1_0_txn_lgb_20260801_20261116.csv"


def _input_path(name: str) -> Path:
    """优先用同步脚本输出到 数据/新老客发标/ 的文件，其次用本目录的手工导出。"""
    for folder in (RAW_DIR, ANALYSIS_DIR):
        path = folder / name
        if path.exists():
            return path
    return RAW_DIR / name


DEFAULT_SAMPLE = _input_path(SAMPLE_NAME)
DEFAULT_OUTPUT = ANALYSIS_DIR / "新老客发标_模型分分析.html"

MODEL_NAME = "aus_wagego_bid_20261123_v1_0_txn_lgb_score"
MODEL_SHORT = "新发标模型"
MODEL_DESC = "发标交易流水 LGB 模型"

WINDOWS = (15, 7)  # 主口径在前
USER_TYPES = (("New", "新客"), ("Old", "老客"))
TYPE_NAME = dict(USER_TYPES)
SEGMENTS = (("ALL", "全部"),) + USER_TYPES

# 固定十分位分箱（模型侧切点）：thresholds 为百分位，cuts 为各档分数上界（含）。
# 分数落在档间空隙时归入较低的下一档；首档以下并入第 1 档，末档以上并入第 10 档。
BID_DECILE_THRESHOLDS = tuple(range(10, 101, 10))
BID_DECILE_MIN = (
    0.010165, 0.020966, 0.027103, 0.033934, 0.041524,
    0.051456, 0.064471, 0.083495, 0.109698, 0.157099,
)
BID_DECILE_CUTS = (
    0.020952, 0.027090, 0.033932, 0.041510, 0.051446,
    0.064469, 0.083412, 0.109672, 0.157077, 0.398999,
)

MIN_BAD = 5  # 分月计算 AUC 的最少坏样本 / 好样本
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


def auc_ci(score, label):
    """单模型 DeLong：返回 (AUC, SE)。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    pos, neg = label == 1, label == 0
    n1, n0 = int(pos.sum()), int(neg.sum())
    if n1 == 0 or n0 == 0:
        return None, None
    ranks_all = midrank(score)
    ranks_pos = midrank(score[pos])
    ranks_neg = midrank(score[neg])
    auc = float((ranks_all[pos].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))
    if n1 < 2 or n0 < 2:
        return auc, None
    v10 = (ranks_all[pos] - ranks_pos) / n0
    v01 = 1 - (ranks_all[neg] - ranks_neg) / n1
    var = v10.var(ddof=1) / n1 + v01.var(ddof=1) / n0
    return auc, sqrt(var)


def roc_points(score, label, steps=200):
    """ROC 点：[[FPR%, TPR%], ...]，从原点出发。"""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=int)
    n1, n0 = int(label.sum()), int(len(label) - label.sum())
    if n1 == 0 or n0 == 0:
        return [[0.0, 0.0], [100.0, 100.0]]
    order = np.argsort(score, kind="mergesort")
    sorted_score = score[order]
    sorted_label = label[order]
    unique = np.unique(sorted_score)
    first = np.searchsorted(sorted_score, unique, side="left")
    pos_ge = np.cumsum(sorted_label[::-1])[::-1][first]
    neg_ge = np.cumsum((1 - sorted_label)[::-1])[::-1][first]
    fpr = np.concatenate([[0.0], (neg_ge / n0)[::-1], [1.0]])
    tpr = np.concatenate([[0.0], (pos_ge / n1)[::-1], [1.0]])
    idx = np.unique(np.linspace(0, len(fpr) - 1, min(steps, len(fpr))).astype(int))
    return [[round(float(fpr[i] * 100), 2), round(float(tpr[i] * 100), 2)] for i in idx]


def bin_index(score):
    edges = np.asarray(BID_DECILE_CUTS, dtype=float)
    return np.searchsorted(edges, np.asarray(score, dtype=float), side="left").clip(
        0, len(edges) - 1
    ) + 1


# --------------------------------------------------------------------------- 数据


def load_sample(path: Path) -> pd.DataFrame:
    if path.suffix.lower() in (".xlsx", ".xls"):
        frame = pd.read_excel(path)
    else:
        frame = pd.read_csv(path, encoding="utf-8-sig")
    if frame.empty:
        raise ValueError(f"样本为空：{path}")

    score_col = next(
        (col for col in frame.columns if col.lower().endswith("_score")), None
    )
    if score_col is None:
        score_col = next((col for col in frame.columns if "score" in col.lower()), None)
    if score_col is None:
        raise ValueError(f"样本中找不到模型分列：{list(frame.columns)}")

    frame["score"] = pd.to_numeric(frame[score_col], errors="coerce")
    for w in WINDOWS:
        col = f"y_fpd{w}_ovd"
        if col in frame.columns:
            frame[col] = pd.to_numeric(frame[col], errors="coerce")

    if "sample_datetime" in frame.columns:
        frame["sample_datetime"] = pd.to_datetime(
            frame["sample_datetime"], errors="coerce"
        )
    if "sample_month" not in frame.columns:
        frame["sample_month"] = frame["sample_datetime"].dt.strftime("%Y-%m")

    def norm_type(value):
        text = str(value).strip().lower() if pd.notna(value) else ""
        if text in ("new", "新客"):
            return "New"
        if text in ("old", "老客"):
            return "Old"
        return "Unknown"

    frame["user_type"] = (
        frame["user_type"].map(norm_type)
        if "user_type" in frame.columns
        else "Unknown"
    )
    frame["score"] = frame["score"].where(frame["score"] >= 0)
    frame.attrs["score_col"] = score_col
    return frame


def _seg_frame(frame, seg):
    return frame if seg == "ALL" else frame[frame["user_type"] == seg]


def segment_metrics(frame, seg, label_col):
    sub = _seg_frame(frame, seg)
    sub = sub[sub["score"].notna() & sub[label_col].notna()]
    n_obs = int(len(sub))
    bad = int(sub[label_col].sum())
    auc, ks = auc_ks(sub["score"], sub[label_col])
    se = None
    if auc is not None:
        _, se = auc_ci(sub["score"], sub[label_col])
    return {
        "n_obs": n_obs,
        "bad": bad,
        "good": n_obs - bad,
        "rate": round(bad / n_obs * 100, 2) if n_obs else None,
        "auc": round(auc, 4) if auc is not None else None,
        "ks": round(ks, 4) if ks is not None else None,
        "auc_lo": round(max(auc - Z95 * se, 0), 4) if auc is not None and se is not None else None,
        "auc_hi": round(min(auc + Z95 * se, 1), 4) if auc is not None and se is not None else None,
    }


def segment_deciles(frame, seg, label_col):
    """固定十分位分箱：返回 10 档的笔数、坏率、lift 与分数区间。"""
    sub = _seg_frame(frame, seg)
    sub = sub[sub["score"].notna() & sub[label_col].notna()]
    if sub.empty:
        return []
    score = sub["score"].to_numpy(dtype=float)
    label = sub[label_col].to_numpy(dtype=int)
    q = bin_index(score)
    overall = label.mean() * 100
    rows = []
    for k in range(1, 11):
        mask = q == k
        n = int(mask.sum())
        bad = int(label[mask].sum())
        rate = bad / n * 100 if n else None
        rows.append(
            {
                "q": k,
                "n": n,
                "bad": bad,
                "rate": round(rate, 2) if rate is not None else None,
                "lift": round(rate / overall, 2) if n and overall else None,
                "rule_min": BID_DECILE_MIN[k - 1],
                "rule_max": BID_DECILE_CUTS[k - 1],
                "score_min": round(float(score[mask].min()), 6) if n else None,
                "score_max": round(float(score[mask].max()), 6) if n else None,
            }
        )
    return rows


def distribution_rows(frame, seg):
    sub = _seg_frame(frame, seg)
    sub = sub[sub["score"].notna()]
    if sub.empty:
        return []
    q = bin_index(sub["score"].to_numpy(dtype=float))
    rows = []
    for k in range(1, 11):
        n = int((q == k).sum())
        rows.append(
            {
                "q": k,
                "n": n,
                "share": round(n / len(q) * 100, 2),
                "rule_min": BID_DECILE_MIN[k - 1],
                "rule_max": BID_DECILE_CUTS[k - 1],
            }
        )
    return rows


def monthly_rows(frame, min_bad):
    labeled = frame[frame["score"].notna()].copy()
    labeled = labeled[labeled["sample_month"].notna()]
    rows = []
    for month, grp in labeled.groupby("sample_month", sort=True):
        item = {"key": str(month), "label": str(month), "n": int(len(grp)), "windows": {}}
        for w in WINDOWS:
            col = f"y_fpd{w}_ovd"
            if col not in grp.columns:
                continue
            sub = grp[grp[col].notna()]
            n_obs, bad = int(len(sub)), int(sub[col].sum())
            good = n_obs - bad
            auc = None
            if n_obs and bad >= min_bad and good >= min_bad:
                auc, _ = auc_ks(sub["score"], sub[col])
            item["windows"][str(w)] = {
                "n_obs": n_obs,
                "bad": bad,
                "rate": round(bad / n_obs * 100, 2) if n_obs else None,
                "auc": round(auc, 4) if auc is not None else None,
            }
        rows.append(item)
    return rows


def build_data(frame, min_bad):
    scored = frame[frame["score"].notna()]
    meta = {
        "n": int(len(frame)),
        "n_scored": int(len(scored)),
        "n_new": int((frame["user_type"] == "New").sum()),
        "n_old": int((frame["user_type"] == "Old").sum()),
        "n_unknown": int((frame["user_type"] == "Unknown").sum()),
        "score_col": frame.attrs.get("score_col", ""),
        "start": scored["sample_datetime"].min().strftime("%Y-%m-%d")
        if "sample_datetime" in scored and scored["sample_datetime"].notna().any()
        else "",
        "end_display": scored["sample_datetime"].max().strftime("%Y-%m-%d")
        if "sample_datetime" in scored and scored["sample_datetime"].notna().any()
        else "",
        "months": sorted(
            str(m) for m in frame["sample_month"].dropna().unique().tolist()
        ),
        "min_bad": min_bad,
    }

    windows = {}
    for w in WINDOWS:
        col = f"y_fpd{w}_ovd"
        if col not in frame.columns:
            continue
        groups = {seg: segment_metrics(frame, seg, col) for seg, _ in SEGMENTS}
        roc = {}
        for seg, _ in SEGMENTS:
            sub = _seg_frame(frame, seg)
            sub = sub[sub["score"].notna() & sub[col].notna()]
            roc[seg] = roc_points(sub["score"], sub[col]) if len(sub) else []
        windows[str(w)] = {
            "label": f"FPD{w}",
            "groups": groups,
            "roc": roc,
            "deciles": {
                seg: segment_deciles(frame, seg, col) for seg, _ in SEGMENTS
            },
        }
    if not windows:
        raise ValueError("样本中找不到 y_fpd*_ovd 标签列")

    return {
        "meta": meta,
        "windows": windows,
        "dist": {
            "total": int(len(scored)),
            "groups": {seg: distribution_rows(frame, seg) for seg, _ in SEGMENTS},
        },
        "monthly": monthly_rows(frame, min_bad),
    }


# --------------------------------------------------------------------------- 格式化


def fmt_int(value):
    return "—" if value is None else f"{int(value):,}"


def fmt_pct(value, digits=2):
    return "—" if value is None else f"{value:.{digits}f}%"


def fmt_num(value, digits=3):
    return "—" if value is None else f"{value:.{digits}f}"


def fmt_ci(entry):
    lo, hi = entry.get("auc_lo"), entry.get("auc_hi")
    if lo is None or hi is None:
        return ""
    return f'<span class="n">[{lo:.3f}, {hi:.3f}]</span>'


def fmt_score(value):
    return "—" if value is None else f"{value:.6f}"


def takeaway(text: str) -> str:
    return (
        f'<div class="takeaway"><span class="takeaway-label">解读</span>'
        f"<div>{text}</div></div>"
    )


def to_py(value):
    if isinstance(value, dict):
        return {str(k): to_py(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_py(v) for v in value]
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating,)):
        return None if np.isnan(value) else float(value)
    if isinstance(value, float) and np.isnan(value):
        return None
    return value


# --------------------------------------------------------------------------- HTML 片段


def kpi_html(data) -> str:
    w15 = data["windows"].get("15", {})
    groups = w15.get("groups", {})
    all15 = groups.get("ALL", {})
    new15 = groups.get("New", {})
    old15 = groups.get("Old", {})

    def kpi(label, value, sub):
        return f"""
      <div class="kpi">
        <span class="label">{label}</span>
        <b>{value}</b>
        <span class="sub">{sub}</span>
      </div>"""

    cards = [
        kpi(
            "FPD15 AUC（全体）",
            fmt_num(all15.get("auc")),
            f"95% CI {fmt_num(all15.get('auc_lo'))} – {fmt_num(all15.get('auc_hi'))}",
        ),
        kpi(
            "FPD15 KS（全体）",
            fmt_num(all15.get("ks")),
            f"成熟 {fmt_int(all15.get('n_obs'))} 笔",
        ),
        kpi(
            "FPD15 坏率（全体）",
            fmt_pct(all15.get("rate")),
            f"坏样本 {fmt_int(all15.get('bad'))} 笔",
        ),
        kpi(
            "新客 FPD15 AUC",
            fmt_num(new15.get("auc")),
            f"成熟 {fmt_int(new15.get('n_obs'))} 笔 · 坏率 {fmt_pct(new15.get('rate'))}",
        ),
        kpi(
            "老客 FPD15 AUC",
            fmt_num(old15.get("auc")),
            f"成熟 {fmt_int(old15.get('n_obs'))} 笔 · 坏率 {fmt_pct(old15.get('rate'))}",
        ),
    ]
    return f'\n<div class="kpis">{"".join(cards)}\n</div>\n'


def metrics_table(data) -> str:
    rows = []
    for w in WINDOWS:
        entry = data["windows"].get(str(w))
        if not entry:
            continue
        for seg, name in SEGMENTS:
            m = entry["groups"][seg]
            if m["n_obs"] == 0:
                continue
            rows.append(
                f"""
        <tr>
          <td class="w">{entry['label']}</td>
          <td>{name}</td>
          <td>{fmt_int(m['n_obs'])}</td>
          <td>{fmt_int(m['bad'])}</td>
          <td>{fmt_pct(m['rate'])}</td>
          <td class="strong">{fmt_num(m['auc'])}{fmt_ci(m)}</td>
          <td>{fmt_num(m['ks'])}</td>
        </tr>"""
            )
    return f"""
      <div class="table-wrap">
        <table class="metrics">
          <thead>
            <tr>
              <th>窗口</th><th>客群</th><th>成熟笔数</th><th>坏样本</th>
              <th>坏率</th><th>AUC（95% CI）</th><th>KS</th>
            </tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def decile_table(data, w, compact=False) -> str:
    entry = data["windows"].get(str(w))
    if not entry:
        return ""
    groups = entry["deciles"]
    all_rows = {r["q"]: r for r in groups.get("ALL", [])}
    new_rows = {r["q"]: r for r in groups.get("New", [])}
    old_rows = {r["q"]: r for r in groups.get("Old", [])}
    body = []
    for q in range(1, 11):
        a = all_rows.get(q, {})
        n = new_rows.get(q, {})
        o = old_rows.get(q, {})
        body.append(
            f"""
        <tr>
          <td class="w">{q}</td>
          <td class="soft">{fmt_score(a.get('rule_min'))} – {fmt_score(a.get('rule_max'))}</td>
          <td>{fmt_int(a.get('n'))}</td>
          <td>{fmt_pct(a.get('rate'))}</td>
          <td class="lift">{fmt_num(a.get('lift'), 2)}×</td>
          <td>{fmt_int(n.get('n'))}</td>
          <td>{fmt_pct(n.get('rate'))}</td>
          <td>{fmt_int(o.get('n'))}</td>
          <td>{fmt_pct(o.get('rate'))}</td>
        </tr>"""
        )
    return f"""
      <h3>{entry['label']} 分箱明细<span class="muted">　固定切点，第 1 档最低风险</span></h3>
      <div class="table-wrap">
        <table class="metrics">
          <thead>
            <tr>
              <th>档位</th><th>分数区间（规则）</th>
              <th>全体笔数</th><th>全体坏率</th><th>lift</th>
              <th>新客笔数</th><th>新客坏率</th>
              <th>老客笔数</th><th>老客坏率</th>
            </tr>
          </thead>
          <tbody>{''.join(body)}</tbody>
        </table>
      </div>
    """


def dist_table(data) -> str:
    groups = data["dist"]["groups"]
    new_rows = {r["q"]: r for r in groups.get("New", [])}
    old_rows = {r["q"]: r for r in groups.get("Old", [])}
    all_rows = {r["q"]: r for r in groups.get("ALL", [])}
    body = []
    for q in range(1, 11):
        a = all_rows.get(q, {})
        n = new_rows.get(q, {})
        o = old_rows.get(q, {})
        body.append(
            f"""
        <tr>
          <td class="w">{q}</td>
          <td class="soft">{fmt_score(a.get('rule_min'))} – {fmt_score(a.get('rule_max'))}</td>
          <td>{fmt_int(n.get('n'))}</td>
          <td>{fmt_pct(n.get('share'))}</td>
          <td>{fmt_int(o.get('n'))}</td>
          <td>{fmt_pct(o.get('share'))}</td>
          <td>{fmt_int(a.get('n'))}</td>
          <td>{fmt_pct(a.get('share'))}</td>
        </tr>"""
        )
    return f"""
      <div class="table-wrap">
        <table class="metrics">
          <thead>
            <tr>
              <th>档位</th><th>分数区间（规则）</th>
              <th>新客笔数</th><th>新客占比</th>
              <th>老客笔数</th><th>老客占比</th>
              <th>合计笔数</th><th>合计占比</th>
            </tr>
          </thead>
          <tbody>{''.join(body)}</tbody>
        </table>
      </div>
    """


def monthly_table(data) -> str:
    rows = []
    for item in data["monthly"]:
        cells = [f"<td class=\"w\">{escape(item['label'])}</td>", f"<td>{fmt_int(item['n'])}</td>"]
        for w in WINDOWS:
            m = item["windows"].get(str(w), {})
            cells.append(
                f"<td>{fmt_int(m.get('n_obs'))}</td>"
                f"<td>{fmt_int(m.get('bad'))}</td>"
                f"<td>{fmt_pct(m.get('rate'))}</td>"
                f"<td class=\"strong\">{fmt_num(m.get('auc'))}</td>"
            )
        rows.append("<tr>" + "".join(cells) + "</tr>")
    heads = "".join(
        f'<th colspan="4" class="group">{f"FPD{w}"}</th>' for w in WINDOWS if str(w) in data["windows"]
    )
    subheads = "".join(
        "<th>成熟</th><th>坏</th><th>坏率</th><th>AUC</th>"
        for w in WINDOWS
        if str(w) in data["windows"]
    )
    return f"""
      <div class="table-wrap">
        <table class="metrics">
          <thead>
            <tr><th rowspan="2">月份</th><th rowspan="2">申请笔数</th>{heads}</tr>
            <tr>{subheads}</tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    """


def footer_html(data, generated_at: str, sample_name: str) -> str:
    meta = data["meta"]
    windows_desc = "、".join(
        f"{data['windows'][str(w)]['label']} 成熟 {fmt_int(data['windows'][str(w)]['groups']['ALL']['n_obs'])} 笔"
        for w in WINDOWS
        if str(w) in data["windows"]
    )
    return f"""
    <footer class="foot">
      <ul class="notes">
        <li><b>样本口径</b>：wagego_02 的新老客发标全量样本（all_user_bid，含未成交申请）叠加新发标模型分，
            共 {fmt_int(meta['n'])} 笔申请、有分 {fmt_int(meta['n_scored'])} 笔；申请时间 {escape(meta['start'])} 至 {escape(meta['end_display'])}。
            新客 {fmt_int(meta['n_new'])} 笔、老客 {fmt_int(meta['n_old'])} 笔。
            Y 只对放款成功的申请成熟：{windows_desc}。</li>
        <li><b>客群口径</b>：新客 / 老客取自主表 user_type；全部口径包含 user_type 缺失的 {fmt_int(meta['n_unknown'])} 笔（若有）。</li>
        <li><b>坏率口径</b>：笔数坏率 = y_fpdN_ovd 之和 / 非空标签笔数；未成熟（标签为空）不计入对应窗口。
            AUC 用 midrank 法处理并列分数，95% 置信区间用 DeLong 法；KS 为成熟样本上的最大 TPR−FPR。</li>
        <li><b>分箱口径</b>：固定十分位切点由模型侧给出，切点见各分箱明细表；第 1 档最低风险，lift = 该档坏率 / 同客群全体坏率。
            分月 AUC 仅在当月坏样本与好样本各 ≥ {fmt_int(meta['min_bad'])} 笔时计算，其余月份显示为空。</li>
        <li><b>模型</b>：{escape(MODEL_NAME)}（{escape(MODEL_DESC)}）；报告为单模型评估，无新旧模型对比。</li>
        <li><b>数据源</b>：wagego_07_新老客发标模型分分析.sql 块 1（{escape(sample_name)}）；
            生成脚本 分析/新老客发标/build.py；生成时间 {escape(generated_at)}。</li>
      </ul>
    </footer>
    """


# --------------------------------------------------------------------------- 组装


def build_html(data, generated_at: str, sample_name: str) -> str:
    meta = data["meta"]
    w15 = data["windows"].get("15", {})
    g15 = w15.get("groups", {})
    all15, new15, old15 = g15.get("ALL", {}), g15.get("New", {}), g15.get("Old", {})
    w7 = data["windows"].get("7", {}).get("groups", {})
    all7 = w7.get("ALL", {})

    months = meta["months"]
    month_span = f"{months[0]} ~ {months[-1]}" if months else "—"

    header = f"""
    <header>
      <p class="eyebrow">WAGEGO · 新老客发标样本</p>
      <h1>新老客发标风险模型效果评估报告</h1>
      <p class="sub">在发标全量样本（含未成交申请）上评估新发标模型的排序能力，并按新客 / 老客拆分。
      申请时间 {escape(meta['start'])} 至 {escape(meta['end_display'])}，固定十分位分箱。</p>
      <div class="models">
        <span><i class="dot model"></i><b>{MODEL_SHORT}</b><code>{escape(MODEL_NAME)}</code><span class="muted">{escape(MODEL_DESC)}</span></span>
      </div>
      <div class="chips">
        <span class="chip">申请 {fmt_int(meta['n'])} 笔 · 有分 {fmt_int(meta['n_scored'])} 笔</span>
        <span class="chip">新客 {fmt_int(meta['n_new'])} · 老客 {fmt_int(meta['n_old'])} 笔</span>
        <span class="chip">FPD15 成熟 {fmt_int(all15.get('n_obs'))} · FPD7 成熟 {fmt_int(all7.get('n_obs'))} 笔</span>
        <span class="chip">月份 {escape(month_span)}</span>
        <span class="chip">固定十分位分箱</span>
        <span class="chip">笔数坏率</span>
      </div>
    </header>
    """

    metrics_card = f"""
    <section class="card" id="metrics">
      <h2>核心指标<span class="tag" title="AUC / KS / 坏率均在成熟样本上计算">成熟样本</span></h2>
      <p class="desc">按客群拆分 FPD7 / FPD15 的区分度与坏率。全体 FPD15 AUC {fmt_num(all15.get('auc'))}
      （KS {fmt_num(all15.get('ks'))}，坏率 {fmt_pct(all15.get('rate'))}）；
      新客 AUC {fmt_num(new15.get('auc'))}、老客 AUC {fmt_num(old15.get('auc'))}。</p>
      {metrics_table(data)}
      {takeaway(
          f"<b>全体：</b>FPD15 AUC {fmt_num(all15.get('auc'))}（95% CI {fmt_num(all15.get('auc_lo'))}–{fmt_num(all15.get('auc_hi'))}），"
          f"KS {fmt_num(all15.get('ks'))}；FPD7 AUC {fmt_num(all7.get('auc'))}，坏率 {fmt_pct(all7.get('rate'))}。"
          f"<br><br><b>分客群：</b>新客 FPD15 AUC {fmt_num(new15.get('auc'))}、坏率 {fmt_pct(new15.get('rate'))}；"
          f"老客 FPD15 AUC {fmt_num(old15.get('auc'))}、坏率 {fmt_pct(old15.get('rate'))}。"
          "若两客群 AUC 差异明显，分客群阈值或分客群建模更合适；坏率差异则主要反映客群风险水位。"
      )}
    </section>
    """

    toc_entries = [
        ("metrics", "核心指标"),
        ("roc", "ROC 曲线"),
        ("decile", "分箱坏率"),
        ("monthly", "分月稳定性"),
        ("dist", "分数分布"),
    ]
    toc_links = "".join(
        f'<li><a href="#{anchor}">{escape(title)}</a></li>' for anchor, title in toc_entries
    )
    toc = f"""
    <nav class="toc" aria-label="目录" tabindex="0">
      <div class="toc-head"><h2>目录</h2><span class="muted">点击跳转</span></div>
      <ol>{toc_links}</ol>
    </nav>
    """

    html = HTML_TEMPLATE
    html = html.replace("__TOC__", toc)
    html = html.replace("__HEADER__", header)
    html = html.replace("__KPIS__", kpi_html(data))
    html = html.replace("__METRICS_CARD__", metrics_card)
    html = html.replace("__DECILE_CARD__", decile_card(data))
    html = html.replace("__MONTHLY_CARD__", monthly_card(data))
    html = html.replace("__DIST_CARD__", dist_card(data))
    html = html.replace("__FOOTER__", footer_html(data, generated_at, sample_name))
    payload = json.dumps(to_py(data), ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    html = html.replace("__DATA_JSON__", payload.replace("</", "<\\/"))
    return html


def decile_card(data) -> str:
    w15 = data["windows"].get("15")
    w7 = data["windows"].get("7")
    panels = []
    for w, entry in ((15, w15), (7, w7)):
        if not entry:
            continue
        panels.append(
            f"""
      <div class="panel">
        <h3>{entry['label']} · 分箱坏率<span class="muted">　新客 vs 老客</span></h3>
        <div class="chart-wrap">
          <svg id="bin{w}" viewBox="0 0 520 330" role="img" aria-label="{entry['label']} 分箱坏率"></svg>
          <div class="tip" id="binTip{w}"></div>
        </div>
      </div>"""
        )

    g15 = w15["groups"]["ALL"] if w15 else {}
    dec15 = w15["deciles"]["ALL"] if w15 else []
    hi = dec15[-1] if dec15 else {}
    lo = dec15[0] if dec15 else {}
    ratio = (
        hi.get("rate") / lo["rate"]
        if hi.get("rate") is not None and lo.get("rate")
        else None
    )
    return f"""
    <section class="card" id="decile">
      <h2>分箱坏率<span class="tag" title="按模型侧固定十分位切点分档，不随样本等笔数切档">固定十分位</span></h2>
      <p class="desc">第 1 档最低风险。分组柱为新客 / 老客坏率，深色折线为全体坏率；横轴为分箱档位，纵轴为笔数坏率。</p>
      <div class="grid2">{''.join(panels)}</div>
      <div class="legend">
        <span><i class="sq newcust"></i>新客</span>
        <span><i class="sq oldcust"></i>老客</span>
        <span><i class="linekey all"></i>全体坏率</span>
      </div>
      {decile_table(data, 15)}
      {decile_table(data, 7)}
      {takeaway(
          f"<b>头尾差：</b>FPD15 第 10 档坏率 {fmt_pct(hi.get('rate'))}、第 1 档 {fmt_pct(lo.get('rate'))}"
          + (f"，约 {ratio:.1f} 倍" if ratio is not None else "")
          + f"；全体坏率 {fmt_pct(g15.get('rate'))}。"
          "分箱坏率应随档位单调上行；若中间档出现明显倒挂，需要结合分档样本量与分数分布判断是噪声还是模型结构问题。"
      )}
    </section>
    """


def monthly_card(data) -> str:
    return f"""
    <section class="card" id="monthly">
      <h2>分月稳定性<span class="tag" title="按 sample_month 汇总；仅当月坏样本与好样本各不少于阈值时计算 AUC">月度</span></h2>
      <p class="desc">左图为逐月 AUC（FPD15 实线、FPD7 虚线），右图为逐月坏率；用于观察模型表现随时间的漂移。</p>
      <div class="grid2">
        <div class="panel">
          <h3>AUC 趋势</h3>
          <div class="chart-wrap">
            <svg id="monthAuc" viewBox="0 0 520 300" role="img" aria-label="逐月 AUC"></svg>
            <div class="tip" id="monthAucTip"></div>
          </div>
        </div>
        <div class="panel">
          <h3>坏率趋势</h3>
          <div class="chart-wrap">
            <svg id="monthRate" viewBox="0 0 520 300" role="img" aria-label="逐月坏率"></svg>
            <div class="tip" id="monthRateTip"></div>
          </div>
        </div>
      </div>
      <div class="legend">
        <span><i class="linekey fpd15"></i>FPD15</span>
        <span><i class="linekey fpd7"></i>FPD7（虚线）</span>
      </div>
      {monthly_table(data)}
    </section>
    """


def dist_card(data) -> str:
    return f"""
    <section class="card" id="dist">
      <h2>分数分布<span class="tag" title="只统计有模型分的申请，不要求标签成熟">有分样本</span></h2>
      <p class="desc">按固定分箱统计各档申请笔数，分组柱为新客 / 老客；用于观察进件客群的分数结构与客群差异。</p>
      <div class="chart-wrap">
        <svg id="distChart" viewBox="0 0 1040 330" role="img" aria-label="分箱笔数分布"></svg>
        <div class="tip" id="distTip"></div>
      </div>
      <div class="legend">
        <span><i class="sq newcust"></i>新客</span>
        <span><i class="sq oldcust"></i>老客</span>
      </div>
      {dist_table(data)}
    </section>
    """


# --------------------------------------------------------------------------- 模板


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WageGo 新老客发标风险模型效果评估报告</title>
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
  .kpis { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin: 20px 0 6px; }
  .kpi {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 13px 15px;
  }
  .kpi .label {
    display: block; color: var(--muted); font-size: 11.5px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .kpi b { display: block; font-size: 27px; line-height: 1.2; margin: 4px 0 1px; }
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
  .toc ol { list-style: none; margin: 0; padding: 0; counter-reset: toc; display: grid; gap: 0; }
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
  .card {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 16px 18px 11px; margin: 13px 0;
  }
  .card h2 { font-size: 17px; margin: 0 0 1px; }
  .card h3 { font-size: 14px; margin: 8px 0 2px; font-weight: 600; }
  .card h2 .tag {
    display: inline-block; margin-left: 7px; padding: 1px 7px;
    border: 1px solid var(--ring); border-radius: 999px;
    background: var(--page); color: var(--ink-2);
    font-size: 10.5px; font-weight: 500; vertical-align: 2px;
    cursor: help;
  }
  .desc { color: var(--ink-2); font-size: 12.5px; margin: 0 0 6px; }
  .muted { color: var(--muted); font-weight: 400; font-size: 11.5px; }
  .takeaway {
    display: flex; gap: 10px; align-items: flex-start;
    margin: 9px 0 6px; padding: 8px 12px;
    border: 1px solid var(--ring); border-left: 3px solid var(--c1);
    border-radius: 8px; background: var(--page);
    color: var(--ink-2); font-size: 12.5px; line-height: 1.65;
  }
  .takeaway-label {
    flex: none; color: var(--ink); font-size: 11px; font-weight: 600;
    letter-spacing: .08em; padding-top: 2px;
  }
  .takeaway b { color: var(--ink); font-weight: 600; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  .panel { min-width: 0; }
  .chart-wrap { position: relative; margin: 3px 0 2px; }
  .chart-wrap svg { display: block; width: 100%; height: auto; }
  .legend { display: flex; flex-wrap: wrap; gap: 16px; font-size: 12px; color: var(--ink-2); margin: 4px 0 0 2px; }
  .dot {
    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
    margin-right: 6px; vertical-align: -1px;
  }
  .dot.model { background: var(--ink); }
  .sq {
    display: inline-block; width: 10px; height: 10px; border-radius: 2px;
    margin-right: 6px; vertical-align: -1px;
  }
  .sq.newcust { background: var(--c1); }
  .sq.oldcust { background: var(--c2); }
  .linekey {
    display: inline-block; width: 16px; height: 0; border-top: 2px solid var(--axis);
    margin-right: 6px; vertical-align: 3px;
  }
  .linekey.all { border-top-color: var(--ink); }
  .linekey.newcust { border-top-color: var(--c1); }
  .linekey.oldcust { border-top-color: var(--c2); }
  .linekey.fpd15 { border-top-color: var(--ink); }
  .linekey.fpd7 { border-top-style: dashed; border-top-color: var(--ink-2); }
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
  td.w { color: var(--ink-2); white-space: nowrap; }
  td.strong { font-weight: 600; }
  td.soft { color: var(--ink-2); }
  td.lift { color: var(--ink-2); }
  td .n { display: block; color: var(--muted); font-size: 10.5px; line-height: 1.35; }
  .note { color: var(--muted); font-size: 12px; line-height: 1.65; margin: 8px 2px 4px; }
  .foot { margin-top: 18px; }
  ul.notes { margin: 0; padding-left: 20px; color: var(--ink-2); font-size: 12px; }
  ul.notes li { margin: 5px 0; }
  ul.notes b { color: var(--ink); font-weight: 600; }
  @media (max-width: 1580px) {
    .toc { width: 44px; padding: 9px 0; overflow: hidden; }
    .toc-head { justify-content: center; margin: 0; }
    .toc-head .muted { display: none; }
    .toc ol { display: none; }
    .toc:hover, .toc:focus-within { width: 200px; padding: 12px 14px; }
    .toc:hover ol, .toc:focus-within ol { display: grid; }
  }
  @media (max-width: 1279px) { .toc { display: none; } }
  @media (max-width: 900px) {
    .kpis { grid-template-columns: repeat(2, 1fr); }
    .grid2 { grid-template-columns: 1fr; }
  }
  @media (max-width: 560px) { h1 { font-size: 24px; } .kpis { grid-template-columns: 1fr; } }
  @media print { .toc { display: none; } }
</style>
</head>
<body>
<main>
__TOC__
__HEADER__
__KPIS__
__METRICS_CARD__
<section class="card" id="roc">
  <h2>ROC 曲线<span class="tag" title="成熟样本；新客 / 老客 / 全体三条曲线">成熟样本</span></h2>
  <p class="desc">横轴为假阳率、纵轴为真阳率；三条曲线分别为全体、新客、老客。</p>
  <div class="grid2">
    <div class="panel">
      <h3>FPD15 · ROC</h3>
      <div class="chart-wrap">
        <svg id="roc15" viewBox="0 0 500 460" role="img" aria-label="FPD15 ROC"></svg>
        <div class="tip" id="rocTip15"></div>
      </div>
    </div>
    <div class="panel">
      <h3>FPD7 · ROC</h3>
      <div class="chart-wrap">
        <svg id="roc7" viewBox="0 0 500 460" role="img" aria-label="FPD7 ROC"></svg>
        <div class="tip" id="rocTip7"></div>
      </div>
    </div>
  </div>
  <div class="legend">
    <span><i class="linekey all"></i>全体</span>
    <span><i class="linekey newcust"></i>新客</span>
    <span><i class="linekey oldcust"></i>老客</span>
  </div>
</section>
__DECILE_CARD__
__MONTHLY_CARD__
__DIST_CARD__
__FOOTER__
</main>
<script>
const DATA = __DATA_JSON__;
const NS = 'http://www.w3.org/2000/svg';
const fmtPct = (v, d) => (v == null ? '—' : v.toFixed(d == null ? 2 : d) + '%');
const fmtInt = n => (n == null ? '—' : n.toLocaleString('en-US'));
const fmtNum = (v, d) => (v == null ? '—' : v.toFixed(d == null ? 3 : d));
const SEG_COLOR = { ALL: 'var(--ink)', New: 'var(--c1)', Old: 'var(--c2)' };
const SEG_NAME = { ALL: '全体', New: '新客', Old: '老客' };

function svgEl(parent, tag, attrs, text) {
  const node = document.createElementNS(NS, tag);
  for (const key in attrs) node.setAttribute(key, attrs[key]);
  if (text != null) node.textContent = text;
  parent.appendChild(node);
  return node;
}
function clearSvg(svg) { while (svg.firstChild) svg.removeChild(svg.firstChild); }

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
      stroke: 'var(--grid)', 'stroke-width': 1
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

function niceTicks(maxValue, count) {
  if (!(maxValue > 0)) return [0, 1];
  const step = maxValue / count;
  const mag = Math.pow(10, Math.floor(Math.log10(step)));
  const norm = step / mag;
  const nice = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10;
  const unit = nice * mag;
  const ticks = [];
  for (let v = 0; v <= maxValue + 1e-9; v += unit) ticks.push(+v.toFixed(6));
  return ticks;
}

/* ---------- ROC ---------- */
function drawRoc(w) {
  const entry = DATA.windows[w];
  const svg = document.getElementById('roc' + w);
  const tip = tipCtl(svg, document.getElementById('rocTip' + w));
  const W = 500, H = 460, m = { l: 56, r: 18, t: 16, b: 52 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const x = v => m.l + v / 100 * iw;
  const y = v => m.t + (1 - v / 100) * ih;
  clearSvg(svg);
  axes(svg, {
    W, H, m, x, y,
    xTicks: [0, 20, 40, 60, 80, 100], yTicks: [0, 20, 40, 60, 80, 100],
    xFmt: t => t + '%', yFmt: t => t + '%',
    xLabel: '假阳率 FPR', yLabel: '真阳率 TPR'
  });
  svgEl(svg, 'line', { x1: x(0), y1: y(0), x2: x(100), y2: y(100), stroke: 'var(--axis)', 'stroke-width': 1 });
  const series = ['ALL', 'New', 'Old'].filter(k => (entry.roc[k] || []).length);
  series.forEach(k => {
    svgEl(svg, 'path', {
      d: linePath(entry.roc[k], p => x(p[0]), p => y(p[1])),
      fill: 'none', stroke: SEG_COLOR[k], 'stroke-width': 2,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round'
    });
  });
  const cross = svgEl(svg, 'line', { y1: m.t, y2: H - m.b, stroke: 'var(--axis)', 'stroke-width': 1, opacity: 0, 'pointer-events': 'none' });
  const dots = series.map(k => svgEl(svg, 'circle', {
    r: 5, fill: SEG_COLOR[k], stroke: 'var(--surface)', 'stroke-width': 2, opacity: 0, 'pointer-events': 'none'
  }));
  const hit = svgEl(svg, 'rect', { x: m.l, y: m.t, width: iw, height: ih, fill: 'transparent' });

  function at(sx) {
    const fpr = Math.min(100, Math.max(0, (sx - m.l) / iw * 100));
    const picks = series.map(k => {
      let best = entry.roc[k][0], dist = Infinity;
      entry.roc[k].forEach(p => {
        const d = Math.abs(p[0] - fpr);
        if (d < dist) { dist = d; best = p; }
      });
      return best;
    });
    const px = x(picks[0][0]);
    cross.setAttribute('x1', px); cross.setAttribute('x2', px); cross.setAttribute('opacity', 1);
    picks.forEach((p, i) => {
      dots[i].setAttribute('cx', x(p[0]));
      dots[i].setAttribute('cy', y(p[1]));
      dots[i].setAttribute('opacity', 1);
    });
    tip.show({
      title: 'FPR ' + fmtPct(fpr, 1),
      rows: series.map((k, i) => ({
        value: fmtPct(picks[i][1], 1), name: SEG_NAME[k] + ' TPR', color: SEG_COLOR[k]
      }))
    }, px, y(Math.max(...picks.map(p => p[1]))));
  }
  hit.addEventListener('pointermove', e => {
    const box = svg.getBoundingClientRect();
    at((e.clientX - box.left) / box.width * W);
  });
  hit.addEventListener('pointerleave', () => {
    tip.hide(); cross.setAttribute('opacity', 0);
    dots.forEach(d => d.setAttribute('opacity', 0));
  });
}

/* ---------- 分箱坏率 ---------- */
function drawBins(w) {
  const entry = DATA.windows[w];
  const svg = document.getElementById('bin' + w);
  const tip = tipCtl(svg, document.getElementById('binTip' + w));
  const W = 520, H = 330, m = { l: 52, r: 16, t: 16, b: 48 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  clearSvg(svg);
  const rows = {};
  ['ALL', 'New', 'Old'].forEach(k => rows[k] = entry.deciles[k] || []);
  const maxRate = Math.max(0, ...['ALL', 'New', 'Old'].flatMap(k => rows[k].map(r => r.rate || 0)));
  const ticks = niceTicks(maxRate * 1.15 || 1, 4);
  const yMax = ticks[ticks.length - 1];
  const x = q => m.l + (q - 1 + 0.5) * iw / 10;
  const y = v => m.t + (1 - v / yMax) * ih;
  axes(svg, {
    W, H, m, x, y,
    xTicks: Array.from({ length: 10 }, (_, i) => i + 1), yTicks: ticks,
    xFmt: t => t, yFmt: t => t + '%',
    xLabel: '分箱档位（1 = 最低风险）', yLabel: '坏率'
  });
  const bw = iw / 10 * 0.30;
  ['New', 'Old'].forEach((k, gi) => {
    rows[k].forEach(r => {
      if (r.rate == null) return;
      svgEl(svg, 'rect', {
        x: x(r.q) - bw + gi * bw, y: y(r.rate), width: bw * 0.92, height: Math.max(y(0) - y(r.rate), 1),
        fill: SEG_COLOR[k], rx: 2
      });
    });
  });
  const allPts = rows.ALL.filter(r => r.rate != null).map(r => [x(r.q), y(r.rate)]);
  if (allPts.length) {
    svgEl(svg, 'path', {
      d: linePath(allPts, p => p[0], p => p[1]),
      fill: 'none', stroke: 'var(--ink)', 'stroke-width': 1.6, 'stroke-dasharray': '0'
    });
    allPts.forEach(p => svgEl(svg, 'circle', { cx: p[0], cy: p[1], r: 2.5, fill: 'var(--ink)' }));
  }
  for (let q = 1; q <= 10; q++) {
    const hit = svgEl(svg, 'rect', {
      x: x(q) - iw / 10 / 2, y: m.t, width: iw / 10, height: ih, fill: 'transparent'
    });
    hit.addEventListener('pointerenter', () => {
      const payloadRows = ['New', 'Old', 'ALL'].map(k => {
        const r = rows[k].find(v => v.q === q) || {};
        return {
          value: fmtPct(r.rate) + (r.n != null ? ' · n=' + fmtInt(r.n) : ''),
          name: SEG_NAME[k], color: k === 'ALL' ? 'var(--ink)' : SEG_COLOR[k]
        };
      });
      const all = rows.ALL.find(v => v.q === q) || {};
      tip.show({
        title: '第 ' + q + ' 档 · ' + fmtNum(all.rule_min, 4) + ' ~ ' + fmtNum(all.rule_max, 4),
        rows: payloadRows
      }, x(q), m.t + 12);
    });
    hit.addEventListener('pointerleave', () => tip.hide());
  }
}

/* ---------- 分月稳定性 ---------- */
function drawMonthly(svgId, tipId, field) {
  const svg = document.getElementById(svgId);
  const tip = tipCtl(svg, document.getElementById(tipId));
  const months = DATA.monthly;
  const W = 520, H = 300, m = { l: 56, r: 18, t: 16, b: 48 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  clearSvg(svg);
  const allValues = [];
  months.forEach(item => Object.keys(item.windows).forEach(k => {
    const v = item.windows[k][field];
    if (v != null) allValues.push(v);
  }));
  let yMin = 0, yMax = 1, ticks = [];
  if (field === 'auc') {
    yMin = Math.min(0.5, Math.floor((Math.min(...allValues, 1) - 0.05) * 10) / 10);
    yMax = 1.0;
    ticks = [];
    for (let v = yMin; v <= yMax + 1e-9; v += 0.1) ticks.push(+v.toFixed(2));
  } else {
    const top = Math.max(...allValues, 1) * 1.3;
    ticks = niceTicks(top, 4);
    yMax = ticks[ticks.length - 1];
  }
  const n = Math.max(months.length, 1);
  const x = i => m.l + (n === 1 ? iw / 2 : i * iw / (n - 1));
  const y = v => m.t + (1 - (v - yMin) / (yMax - yMin)) * ih;
  axes(svg, {
    W, H, m, x, y,
    xTicks: months.map((_, i) => i), yTicks: ticks,
    xFmt: i => months[i] ? months[i].label.slice(2) : '', yFmt: t => field === 'auc' ? t.toFixed(1) : t + '%',
    xLabel: '月份', yLabel: field === 'auc' ? 'AUC' : '坏率'
  });
  const windows = Object.keys(DATA.windows);
  windows.forEach((k, idx) => {
    const pts = [];
    months.forEach((item, i) => {
      const v = item.windows[k] ? item.windows[k][field] : null;
      if (v != null) pts.push([x(i), y(v)]);
    });
    if (!pts.length) return;
    svgEl(svg, 'path', {
      d: linePath(pts, p => p[0], p => p[1]),
      fill: 'none', stroke: idx === 0 ? 'var(--ink)' : 'var(--ink-2)',
      'stroke-width': 2, 'stroke-dasharray': idx === 0 ? '0' : '5 4',
      'stroke-linecap': 'round'
    });
    pts.forEach(p => svgEl(svg, 'circle', {
      cx: p[0], cy: p[1], r: 3,
      fill: idx === 0 ? 'var(--ink)' : 'var(--surface)',
      stroke: idx === 0 ? 'none' : 'var(--ink-2)', 'stroke-width': 1.5
    }));
  });
  months.forEach((item, i) => {
    const hit = svgEl(svg, 'rect', {
      x: x(i) - iw / n / 2, y: m.t, width: iw / n, height: ih, fill: 'transparent'
    });
    hit.addEventListener('pointerenter', () => {
      const rows = windows.map((k, idx) => {
        const win = item.windows[k] || {};
        const value = field === 'auc'
          ? fmtNum(win.auc)
          : fmtPct(win.rate) + (win.n_obs != null ? ' · n=' + fmtInt(win.n_obs) : '');
        return {
          value, name: 'FPD' + k,
          color: idx === 0 ? 'var(--ink)' : 'var(--ink-2)'
        };
      });
      tip.show({ title: item.label, rows }, x(i), m.t + 12);
    });
    hit.addEventListener('pointerleave', () => tip.hide());
  });
}

/* ---------- 分数分布 ---------- */
function drawDist() {
  const svg = document.getElementById('distChart');
  const tip = tipCtl(svg, document.getElementById('distTip'));
  const W = 1040, H = 330, m = { l: 56, r: 16, t: 16, b: 48 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  clearSvg(svg);
  const groups = DATA.dist.groups;
  const rows = {};
  ['New', 'Old'].forEach(k => rows[k] = groups[k] || []);
  const maxN = Math.max(1, ...['New', 'Old'].flatMap(k => rows[k].map(r => r.n || 0)));
  const ticks = niceTicks(maxN * 1.1, 4);
  const yMax = ticks[ticks.length - 1];
  const x = q => m.l + (q - 1 + 0.5) * iw / 10;
  const y = v => m.t + (1 - v / yMax) * ih;
  axes(svg, {
    W, H, m, x, y,
    xTicks: Array.from({ length: 10 }, (_, i) => i + 1), yTicks: ticks,
    xFmt: t => t, yFmt: t => fmtInt(t),
    xLabel: '分箱档位（1 = 最低风险）', yLabel: '申请笔数'
  });
  const bw = iw / 10 * 0.3;
  ['New', 'Old'].forEach((k, gi) => {
    rows[k].forEach(r => {
      svgEl(svg, 'rect', {
        x: x(r.q) - bw + gi * bw, y: y(r.n), width: bw * 0.92, height: Math.max(y(0) - y(r.n), 0),
        fill: SEG_COLOR[k], rx: 2
      });
    });
  });
  for (let q = 1; q <= 10; q++) {
    const hit = svgEl(svg, 'rect', {
      x: x(q) - iw / 10 / 2, y: m.t, width: iw / 10, height: ih, fill: 'transparent'
    });
    hit.addEventListener('pointerenter', () => {
      const values = ['New', 'Old'].map(k => {
        const r = rows[k].find(v => v.q === q) || {};
        return {
          value: fmtInt(r.n) + (r.share != null ? ' · ' + fmtPct(r.share, 1) : ''),
          name: SEG_NAME[k], color: SEG_COLOR[k]
        };
      });
      tip.show({ title: '第 ' + q + ' 档', rows: values }, x(q), m.t + 12);
    });
    hit.addEventListener('pointerleave', () => tip.hide());
  }
}

Object.keys(DATA.windows).forEach(w => { drawRoc(w); drawBins(w); });
drawMonthly('monthAuc', 'monthAucTip', 'auc');
drawMonthly('monthRate', 'monthRateTip', 'rate');
drawDist();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------- 入口


def main(argv=None):
    parser = argparse.ArgumentParser(description="新老客发标样本模型分分析")
    parser.add_argument("--sample-csv", default=str(DEFAULT_SAMPLE), help="发标样本 + 模型分 CSV/XLSX")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出 HTML")
    parser.add_argument("--min-bad", type=int, default=MIN_BAD,
                        help="分月计算 AUC 的最少坏样本/好样本数")
    args = parser.parse_args(argv)

    path = Path(args.sample_csv)
    if not path.exists():
        parser.error(f"文件不存在：{path}")

    frame = load_sample(path)
    data = build_data(frame, args.min_bad)
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
    html = build_html(data, generated_at, path.name)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(html, encoding="utf-8")

    meta = data["meta"]
    print(f"申请 {meta['n']:,} 笔 · 有分 {meta['n_scored']:,} 笔 · 输出 {output}")
    for w in WINDOWS:
        entry = data["windows"].get(str(w))
        if not entry:
            continue
        g = entry["groups"]
        parts = []
        for seg, name in SEGMENTS:
            m = g[seg]
            auc = "—" if m["auc"] is None else f"{m['auc']:.3f}"
            parts.append(f"{name} AUC {auc} / 坏率 {m['rate'] if m['rate'] is not None else '—'}%")
        print(f"  FPD{w}: 成熟 {g['ALL']['n_obs']:,} / 坏 {g['ALL']['bad']:,} | " + " | ".join(parts))


if __name__ == "__main__":
    main()
