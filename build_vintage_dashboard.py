#!/usr/bin/env python3
"""Build a self-contained WageGo vintage monitoring dashboard from vintage_data.zip."""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import sys
import zipfile
from datetime import datetime
from html import escape
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_INPUT = PROJECT_DIR / "vintage_data.zip"
DEFAULT_OUTPUT = PROJECT_DIR / "vintage_监控看板.html"

WINDOWS = (1, 3, 7, 14, 15, 30)
WINDOW_LABELS = {1: "FPD1", 3: "FPD3", 7: "FPD7", 14: "FPD14", 15: "FPD15", 30: "FPD30"}
AUC_WINDOWS = (1, 3, 7, 15)
# 新客风险 1.0 固定分箱上限；第 5 箱为 > 最后一个阈值
SCORE_BIN_UPPER = (0.062086, 0.091284, 0.128392, 0.188973)
# 线上模型戳额分布固定 10 档上限（旧模型固定十等分切点；相邻两档合并即上面的 5 档）
CREDIT_SCORE_DECILE_UPPER = (
    0.048577, 0.062086, 0.075629, 0.091284, 0.109224,
    0.128392, 0.154584, 0.188973, 0.240037, 0.615365,
)
CREDIT_WEEK_MIN_OBS = 50
SEGMENT_META = (
    ("ALL", "整体", "var(--ink-2)"),
    ("New", "新客", "var(--c1)"),
    ("Old", "老客", "var(--c2)"),
)
REQUIRED_FILES = (
    "vintage_01_fpd_overall.csv",
    "vintage_02_fpd15_vs_fpd30.csv",
    "vintage_03_user_type.csv",
    "vintage_04_week.csv",
    "vintage_05a_score_coverage.csv",
    "vintage_05b_score_quintile.csv",
    "vintage_06_score_quintile_week.csv",
)
# 新增块允许旧 zip 缺失；缺失时对应卡片不渲染，看板仍可生成。
OPTIONAL_FILES = (
    "vintage_08_weekly_auc.csv",
    "vintage_11a_credit_score_coverage.csv",
    "vintage_11b_credit_score_dist.csv",
    "vintage_12_new_user_funnel.csv",
)


def available_windows(windows):
    return [window for window in WINDOWS if window in windows]


def to_int(value):
    return int(float(value)) if value not in (None, "") else None


def to_float(value):
    return float(value) if value not in (None, "") else None


def fmt_int(value):
    return "—" if value is None else f"{value:,}"


def fmt_rate(value):
    return "—" if value is None else f"{value:.2f}%"


def fmt_delta(value):
    if value is None:
        return "—"
    return f"{value:+.2f}pp".replace("-", "−")


def fmt_pct0(value):
    return "—" if value is None else f"{round(value * 100)}%"


def sup(text, marker):
    return f"{text}<sup>{marker}</sup>"


TAG_COUNT = (
    '<span class="tag" title="坏率 = y_fpdN_ovd 之和 / y_fpdN_obs 之和">笔数坏率</span>'
)
TAG_OVERALL = '<span class="tag" title="该模块固定按全量口径展示，不随客群切换">整体口径</span>'
SAMPLE_TAG_HTML = (
    '<span class="tag sample-tag" data-sample-tag '
    'title="当前客群对应的发标成交样本：放款成功且对应窗口成熟">'
    '样本：整体发标成交样本</span>'
)
TAG_QUALITY_SAMPLE = (
    '<span class="tag sample-tag" title="整体 FPD15 成熟发标成交样本">'
    '样本：整体发标成交样本</span>'
)
TAG_CREDIT = (
    '<span class="tag" title="每个用户全历史首次戳额样本；分数取戳额时点线上模型分">'
    '样本：新客戳额样本</span>'
)


def seg_panel(seg_key, content):
    hidden = "" if seg_key == "ALL" else " hidden"
    return f'<div data-seg-panel="{seg_key}"{hidden}>{content}</div>'



def read_csvs(input_path: Path):
    wanted = REQUIRED_FILES + OPTIONAL_FILES
    if input_path.is_dir():
        files = {
            p.name: p.read_bytes()
            for p in input_path.glob("vintage_*.csv")
            if p.name in wanted
        }
    elif input_path.is_file() and input_path.suffix.lower() == ".zip":
        with zipfile.ZipFile(input_path) as archive:
            # 只读看板需要的块结果（zip 由 sync_vintage.py 生成）
            files = {
                Path(name).name: archive.read(name)
                for name in archive.namelist()
                if Path(name).name in wanted
            }
    else:
        raise ValueError(f"输入既不是 zip 也不是目录：{input_path}")

    missing = [name for name in REQUIRED_FILES if name not in files]
    if missing:
        raise ValueError(f"缺少 CSV：{', '.join(missing)}")

    parsed = {}
    for name in wanted:
        if name not in files:
            parsed[name] = None
            continue
        text = files[name].decode("utf-8-sig")
        parsed[name] = list(csv.DictReader(io.StringIO(text)))
    return parsed


def build_week_view(week_rows, chart_week_names):
    all_weeks = sorted(week_rows)
    weeks = []
    for index, week in enumerate(all_weeks):
        windows = week_rows[week]
        base = windows.get(3, {}).get("obs") or 0
        prev_base = week_rows[all_weeks[index - 1]].get(3, {}).get("obs") if index else None
        incomplete = bool(prev_base and base < 0.6 * prev_base)
        for row in windows.values():
            row["maturity"] = min(row["obs"] / base, 1.0) if base else 0.0
        fpd15 = windows.get(15)
        weeks.append(
            {
                "week": week,
                "fpd3Obs": base,
                "incomplete": incomplete,
                "windows": windows,
                "fpd15Maturity": fpd15["maturity"] if fpd15 else 0.0,
            }
        )
    weeks_by = {item["week"]: item for item in weeks}
    chart_weeks = [weeks_by[week] for week in chart_week_names if week in weeks_by]
    return weeks, weeks_by, chart_weeks


def build_week_chart(chart_weeks):
    chart = {
        "labels": [],
        "weeks": [],
        "fpd1": [],
        "fpd1Amt": [],
        "fpd3": [],
        "fpd3Amt": [],
        "fpd7": [],
        "fpd7Amt": [],
        "fpd7Low": [],
        "fpd15": [],
        "fpd15Low": [],
        "fpd15Amt": [],
    }
    for item in chart_weeks:
        fpd1_row = item["windows"].get(1)
        fpd3_row = item["windows"].get(3)
        fpd7_row = item["windows"].get(7)
        fpd15_row = item["windows"].get(15)
        chart["labels"].append(item["week"][5:])
        chart["weeks"].append(item["week"])
        if fpd1_row:
            chart["fpd1"].append(
                {
                    "rate": fpd1_row["rate"],
                    "obs": fpd1_row["obs"],
                    "partial": item["incomplete"],
                }
            )
            chart["fpd1Amt"].append(
                {
                    "rate": fpd1_row["amtRate"],
                    "obs": fpd1_row["obs"],
                    "partial": item["incomplete"],
                }
                if fpd1_row["amtRate"] is not None
                else None
            )
        else:
            chart["fpd1"].append(None)
            chart["fpd1Amt"].append(None)
        if fpd3_row:
            chart["fpd3"].append(
                {
                    "rate": fpd3_row["rate"],
                    "obs": fpd3_row["obs"],
                    "partial": item["incomplete"],
                }
            )
            chart["fpd3Amt"].append(
                {
                    "rate": fpd3_row["amtRate"],
                    "obs": fpd3_row["obs"],
                    "partial": item["incomplete"],
                }
                if fpd3_row["amtRate"] is not None
                else None
            )
        else:
            chart["fpd3"].append(None)
            chart["fpd3Amt"].append(None)
        if fpd7_row and fpd7_row["maturity"] >= 0.7:
            chart["fpd7"].append(
                {
                    "rate": fpd7_row["rate"],
                    "obs": fpd7_row["obs"],
                    "maturity": fpd7_row["maturity"],
                    "partial": fpd7_row["maturity"] < 0.9 or item["incomplete"],
                }
            )
            chart["fpd7Amt"].append(
                {
                    "rate": fpd7_row["amtRate"],
                    "obs": fpd7_row["obs"],
                    "maturity": fpd7_row["maturity"],
                    "partial": fpd7_row["maturity"] < 0.9 or item["incomplete"],
                }
                if fpd7_row["amtRate"] is not None
                else None
            )
            chart["fpd7Low"].append(None)
        else:
            chart["fpd7"].append(None)
            chart["fpd7Amt"].append(None)
            chart["fpd7Low"].append(
                {
                    "rate": fpd7_row["rate"],
                    "obs": fpd7_row["obs"],
                    "maturity": fpd7_row["maturity"],
                }
                if fpd7_row and fpd7_row["maturity"] > 0
                else None
            )
        if fpd15_row and fpd15_row["maturity"] >= 0.7:
            chart["fpd15"].append(
                {
                    "rate": fpd15_row["rate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                    "partial": fpd15_row["maturity"] < 0.9,
                }
            )
            chart["fpd15Low"].append(None)
        else:
            chart["fpd15"].append(None)
            chart["fpd15Low"].append(
                {
                    "rate": fpd15_row["rate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                }
                if fpd15_row and fpd15_row["maturity"] > 0
                else None
            )
        if fpd15_row and fpd15_row["maturity"] >= 0.7 and fpd15_row["amtRate"] is not None:
            chart["fpd15Amt"].append(
                {
                    "rate": fpd15_row["amtRate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                    "partial": fpd15_row["maturity"] < 0.9,
                }
            )
        else:
            chart["fpd15Amt"].append(None)
    return chart


def score_week_week_list(score_week, chart_weeks):
    if not chart_weeks:
        return []
    start = chart_weeks[0]["week"]
    weeks_all = sorted(week for week in score_week if week >= start)
    weeks = [
        week
        for week in weeks_all
        if all(q in score_week[week] for q in range(1, 6))
        and min(score_week[week][q]["obs"] for q in range(1, 6)) >= 50
    ]
    if weeks_all and weeks_all[-1] not in weeks:
        weeks.append(weeks_all[-1])
    return weeks


def build_psi_by_week(score_week, score_week_weeks, weeks_by):
    def psi_value(week, prior_weeks):
        if not prior_weeks:
            return None
        current = score_week.get(week)
        if not current or any(q not in current for q in range(1, 6)):
            return None
        base_counts = [
            sum(score_week[w][q]["obs"] for w in prior_weeks if q in score_week.get(w, {}))
            for q in range(1, 6)
        ]
        cur_counts = [current[q]["obs"] for q in range(1, 6)]
        base_total = sum(base_counts)
        cur_total = sum(cur_counts)
        if not base_total or not cur_total or min(base_counts) <= 0 or min(cur_counts) <= 0:
            return None
        total = 0.0
        for base_count, cur_count in zip(base_counts, cur_counts):
            base_share = base_count / base_total
            cur_share = cur_count / cur_total
            total += (cur_share - base_share) * math.log(cur_share / base_share)
        return total

    psi_by_week = {}
    for index, week in enumerate(score_week_weeks):
        week_item = weeks_by.get(week)
        if not week_item or week_item["incomplete"] or week_item["fpd15Maturity"] < 0.9:
            continue
        prior = [
            item
            for item in score_week_weeks[:index]
            if weeks_by.get(item, {}).get("fpd15Maturity", 0) >= 0.9
        ][-4:]
        value = psi_value(week, prior)
        if value is not None:
            psi_by_week[week] = value
    return psi_by_week


def score_range_text(q, upper):
    if q == 1:
        return f"≤ {upper[0]:.6f}"
    if q > len(upper):
        return f"> {upper[-1]:.6f}"
    return f"{upper[q - 2]:.6f}–{upper[q - 1]:.6f}"


def build_credit_dist(raw):
    coverage_rows = raw.get("vintage_11a_credit_score_coverage.csv")
    dist_rows = raw.get("vintage_11b_credit_score_dist.csv")
    if not coverage_rows or not dist_rows:
        return None

    coverage = {}
    for row in coverage_rows:
        week = (row.get("week_start") or "").strip()
        if not week:
            continue
        coverage[week] = {
            "sample": to_int(row.get("sample_cnt")),
            "scored": to_int(row.get("scored_cnt")),
            "missing": to_int(row.get("missing_cnt")),
            "pct": to_float(row.get("coverage_pct")),
        }

    deciles = {}
    for row in dist_rows:
        week = (row.get("week_start") or "").strip()
        q = to_int(row.get("q"))
        if week not in coverage or q is None or not 1 <= q <= 10:
            continue
        deciles.setdefault(week, {})[q] = to_int(row.get("obs_cnt")) or 0

    if "ALL" not in coverage or "ALL" not in deciles:
        return None

    def bin_rows(bins, week):
        source = deciles.get(week) or {}
        if bins == 5:
            rows = [
                {
                    "q": q,
                    "obs": sum(source.get(item, 0) for item in (2 * q - 1, 2 * q)),
                }
                for q in range(1, 6)
            ]
        else:
            rows = [{"q": q, "obs": source.get(q, 0)} for q in range(1, 11)]
        total = sum(row["obs"] for row in rows)
        for row in rows:
            row["share"] = round(row["obs"] / total * 100, 2) if total else 0.0
        return rows

    def psi_value(rows, base_rows):
        cur_total = sum(row["obs"] for row in rows)
        base_total = sum(row["obs"] for row in base_rows)
        if not cur_total or not base_total:
            return None
        if any(row["obs"] <= 0 for row in rows) or any(
            row["obs"] <= 0 for row in base_rows
        ):
            return None
        total = 0.0
        for row, base_row in zip(rows, base_rows):
            cur_share = row["obs"] / cur_total
            base_share = base_row["obs"] / base_total
            total += (cur_share - base_share) * math.log(cur_share / base_share)
        return total

    weeks = sorted(
        week for week in coverage if week != "ALL" and deciles.get(week)
    )
    unscored_weeks = sorted(
        week
        for week in coverage
        if week != "ALL"
        and not deciles.get(week)
        and (coverage[week]["sample"] or 0) > 0
    )

    tables = {}
    for bins in (5, 10):
        all_rows = bin_rows(bins, "ALL")
        weekly = {week: bin_rows(bins, week) for week in weeks}
        tables[bins] = {
            "all": all_rows,
            "weeks": weekly,
            "psi": {week: psi_value(weekly[week], all_rows) for week in weeks},
        }

    return {
        "weeks": weeks,
        "coverage": coverage,
        "allCoverage": coverage["ALL"],
        "tables": tables,
        "unscoredWeeks": unscored_weeks,
        "lowWeeks": [
            week
            for week in weeks
            if (coverage[week]["scored"] or 0) < CREDIT_WEEK_MIN_OBS
        ],
    }


def build_auc_chart(weekly_auc, weeks_by, window=15):
    auc_chart = {"labels": [], "weeks": [], "points": []}
    for week in sorted(weekly_auc):
        row = weekly_auc[week]
        week_item = weeks_by.get(week)
        if row["auc"] is None or (row["obs"] or 0) < 200 or not week_item:
            continue
        win_item = week_item["windows"].get(window)
        if win_item is not None:
            maturity = win_item["maturity"]
        else:
            # 块 4 只同步 FPD3/7/14/15/30；FPD1 用当周 AUC 样本 / FPD3 样本近似成熟度。
            fpd3_obs = week_item.get("fpd3Obs") or 0
            maturity = min(1.0, (row["obs"] or 0) / fpd3_obs) if fpd3_obs else 0.0
        auc_chart["labels"].append(week[5:])
        auc_chart["weeks"].append(week)
        auc_chart["points"].append(
            {
                "week": week,
                "auc": row["auc"],
                "gini": row["gini"],
                "ks": row["ks"],
                "obs": row["obs"],
                "bad": row["bad"],
                "rate": row["rate"],
                "maturity": maturity,
                "partial": maturity < 0.9 or week_item["incomplete"],
            }
        )
    return auc_chart


def build_new_user_funnel(raw):
    rows = raw.get("vintage_12_new_user_funnel.csv")
    if not rows:
        return None
    weeks = []
    for row in rows:
        weeks.append(
            {
                "week": row["week_start"],
                "creditUsers": to_int(row.get("credit_users")),
                "limitDetailUsers": to_int(row.get("limit_detail_users")),
                "limitUsers": to_int(row.get("limit_users")),
                "applyUsers": to_int(row.get("apply_users")),
                "passUsers": to_int(row.get("pass_users")),
                "dealUsers": to_int(row.get("deal_users")),
                "applyCnt": to_int(row.get("apply_cnt")),
                "passCnt": to_int(row.get("pass_cnt")),
                "dealCnt": to_int(row.get("deal_cnt")),
                "limitPassRate": to_float(row.get("limit_pass_rate_pct")),
                "applyRate": to_float(row.get("apply_rate_pct")),
                "passRate": to_float(row.get("audit_pass_rate_pct")),
                "dealRate": to_float(row.get("deal_rate_pct")),
                "passRateCnt": to_float(row.get("audit_pass_rate_cnt_pct")),
                "dealRateCnt": to_float(row.get("deal_rate_cnt_pct")),
                "creditDealRate": to_float(row.get("credit_deal_rate_pct")),
                "cohortDays": to_int(row.get("cohort_days")),
            }
        )
    weeks.sort(key=lambda item: item["week"])
    included = [item for item in weeks if (item["creditUsers"] or 0) >= CREDIT_WEEK_MIN_OBS]
    excluded = [item for item in weeks if (item["creditUsers"] or 0) < CREDIT_WEEK_MIN_OBS]
    if not included:
        return None

    def total(key):
        return sum(item[key] or 0 for item in included)

    def rate(numerator, denominator):
        return round(numerator / denominator * 100, 2) if denominator else None

    totals = {
        "creditUsers": total("creditUsers"),
        "limitDetailUsers": total("limitDetailUsers"),
        "limitUsers": total("limitUsers"),
        "applyUsers": total("applyUsers"),
        "passUsers": total("passUsers"),
        "dealUsers": total("dealUsers"),
        "applyCnt": total("applyCnt"),
        "passCnt": total("passCnt"),
        "dealCnt": total("dealCnt"),
    }
    totals.update(
        {
            "limitPassRate": rate(totals["limitUsers"], totals["limitDetailUsers"]),
            "applyRate": rate(totals["applyUsers"], totals["creditUsers"]),
            "passRate": rate(totals["passUsers"], totals["applyUsers"]),
            "dealRate": rate(totals["dealUsers"], totals["applyUsers"]),
            "passRateCnt": rate(totals["passCnt"], totals["applyCnt"]),
            "dealRateCnt": rate(totals["dealCnt"], totals["passCnt"]),
            "creditDealRate": rate(totals["dealUsers"], totals["creditUsers"]),
        }
    )
    return {
        "weeks": included,
        "totals": totals,
        "excluded": excluded,
        "firstWeek": included[0]["week"],
        "lastWeek": included[-1]["week"],
    }


def build_window_list(windows, keep_delta=False):
    items = []
    previous = None
    for window in available_windows(windows):
        row = windows[window]
        delta = row.get("delta") if keep_delta else None
        if delta is None:
            delta = None if previous is None else round(row["rate"] - previous, 2)
        items.append({**row, "window": window, "delta": delta})
        previous = row["rate"]
    return items


def build_data(raw):
    overall = []
    for row in raw["vintage_01_fpd_overall.csv"]:
        overall.append(
            {
                "window": to_int(row["window_days"]),
                "obs": to_int(row["obs_cnt"]),
                "bad": to_int(row["bad_cnt"]),
                "rate": to_float(row["bad_rate_pct"]),
                "amtRate": to_float(row["bad_rate_amt_pct"]),
                "delta": to_float(row["delta_pp"]),
            }
        )
    overall.sort(key=lambda item: item["window"])
    overall_by = {item["window"]: item for item in overall}

    user = {}
    for row in raw["vintage_03_user_type.csv"]:
        window = to_int(row["window_days"])
        user.setdefault(row["user_type"], {})[window] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "amtRate": to_float(row["bad_rate_amt_pct"]),
        }

    # FPD1 是后加窗口；旧 zip 缺少时自动跳过，避免看板无法生成。
    data_windows = [
        window
        for window in WINDOWS
        if window in overall_by and all(window in user.get(seg, {}) for seg in ("New", "Old"))
    ]

    week_rows_by_seg = {"ALL": {}, "New": {}, "Old": {}}
    for row in raw["vintage_04_week.csv"]:
        segment = row.get("user_type") or "ALL"
        week = row["week_start"]
        window = to_int(row["window_days"])
        week_rows_by_seg.setdefault(segment, {}).setdefault(week, {})[window] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "amtRate": to_float(row["bad_rate_amt_pct"]),
        }
    if not all(week_rows_by_seg.get(seg) for seg in ("ALL", "New", "Old")):
        raise ValueError(
            "vintage_04_week.csv 缺少 ALL / New / Old 分组；"
            "请重新执行 sync_vintage.py 同步块 4"
        )
    week_rows = week_rows_by_seg["ALL"]

    all_weeks = sorted(week_rows)
    weeks = []
    for index, week in enumerate(all_weeks):
        windows = week_rows[week]
        base = windows.get(3, {}).get("obs") or 0
        prev_base = week_rows[all_weeks[index - 1]].get(3, {}).get("obs") if index else None
        incomplete = bool(prev_base and base < 0.6 * prev_base)
        for row in windows.values():
            row["maturity"] = min(row["obs"] / base, 1.0) if base else 0.0
        fpd15 = windows.get(15)
        weeks.append(
            {
                "week": week,
                "fpd3Obs": base,
                "incomplete": incomplete,
                "windows": windows,
                "fpd15Maturity": fpd15["maturity"] if fpd15 else 0.0,
            }
        )
    weeks_by = {item["week"]: item for item in weeks}
    chart_weeks = [item for item in weeks if item["fpd3Obs"] >= 50]
    early_weeks = [item["week"] for item in weeks if item["fpd3Obs"] < 50]

    score = {"ALL": {}, "New": {}, "Old": {}}
    for row in raw["vintage_05b_score_quintile.csv"]:
        segment = row["segment"]
        q = to_int(row["q"])
        score.setdefault(segment, {})[q] = {
            "q": q,
            "min": to_float(row["score_min"]),
            "max": to_float(row["score_max"]),
            "avg": to_float(row["score_avg"]),
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
        }
    if any(not score[segment] for segment in score):
        raise ValueError("模型分固定 5 箱缺少 ALL / New / Old 分组")

    score_week_by_seg = {"ALL": {}, "New": {}, "Old": {}}
    for row in raw["vintage_06_score_quintile_week.csv"]:
        segment = row.get("user_type") or "ALL"
        week = row["week_start"]
        q = to_int(row["q"])
        score_week_by_seg.setdefault(segment, {}).setdefault(week, {})[q] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
        }
    if not all(score_week_by_seg.get(seg) for seg in ("ALL", "New", "Old")):
        raise ValueError(
            "vintage_06_score_quintile_week.csv 缺少 ALL / New / Old 分组；"
            "请重新执行 sync_vintage.py 同步块 6"
        )
    score_week = score_week_by_seg["ALL"]
    score_week_weeks = score_week_week_list(score_week, chart_weeks)

    weekly_auc_by_seg = {"ALL": {}, "New": {}, "Old": {}}
    for row in raw.get("vintage_08_weekly_auc.csv") or []:
        segment = row.get("user_type") or "ALL"
        window = to_int(row.get("window_days")) or 15
        weekly_auc_by_seg.setdefault(segment, {}).setdefault(window, {})[row["week_start"]] = {
            "week": row["week_start"],
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "auc": to_float(row["auc"]),
            "gini": to_float(row["gini"]),
            "ks": to_float(row["ks"]),
        }
    if not all(weekly_auc_by_seg.get(seg) for seg in ("ALL", "New", "Old")):
        raise ValueError(
            "vintage_08_weekly_auc.csv 缺少 ALL / New / Old 分组；"
            "请重新执行 sync_vintage.py 同步块 8"
        )
    auc_windows = [
        window
        for window in AUC_WINDOWS
        if any(window in weekly_auc_by_seg[seg] for seg in weekly_auc_by_seg)
    ] or [15]
    default_auc_window = 15 if 15 in auc_windows else auc_windows[-1]

    psi_by_week = build_psi_by_week(score_week, score_week_weeks, weeks_by)

    auc_charts = {
        window: build_auc_chart(weekly_auc_by_seg["ALL"].get(window, {}), weeks_by, window)
        for window in auc_windows
    }

    common_row = raw["vintage_02_fpd15_vs_fpd30.csv"][0]
    coverage_row = raw["vintage_05a_score_coverage.csv"][0]
    common = {
        "obs": to_int(common_row["obs_cnt"]),
        "bad15": to_int(common_row["bad15"]),
        "bad30": to_int(common_row["bad30"]),
        "rate15": to_float(common_row["bad_rate15_pct"]),
        "rate30": to_float(common_row["bad_rate30_pct"]),
        "retention": to_float(common_row["bad_retention_pct"]),
        "change": to_float(common_row["bad_cnt_change_pct"]),
    }
    coverage = {
        "obs": to_int(coverage_row["obs_cnt"]),
        "scored": to_int(coverage_row["scored_cnt"]),
        "missing": to_int(coverage_row["missing_cnt"]),
        "pct": to_float(coverage_row["coverage_pct"]),
    }

    fpd15 = overall_by[15]
    fpd30 = overall_by[30]
    fpd30_maturity = {
        "ALL": fpd30["obs"] / fpd15["obs"],
        "New": user["New"][30]["obs"] / user["New"][15]["obs"],
        "Old": user["Old"][30]["obs"] / user["Old"][15]["obs"],
    }

    def curve_series(name, key, color, source):
        points = []
        for window in data_windows:
            row = source[window]
            points.append(
                {
                    "rate": row["rate"],
                    "obs": row["obs"],
                    "bad": row["bad"],
                    "partial": window == 30,
                    "maturity": fpd30_maturity[key] if window == 30 else None,
                }
            )
        return {"name": name, "key": key, "color": color, "points": points}

    fpd_curve = {
        "labels": [WINDOW_LABELS[window] for window in data_windows],
        "series": [
            curve_series("整体", "ALL", "var(--ink-2)", overall_by),
            curve_series("新客", "New", "var(--c1)", user["New"]),
            curve_series("老客", "Old", "var(--c2)", user["Old"]),
        ],
    }

    week_chart = build_week_chart(chart_weeks)

    def score_series(segment, name, color):
        return {
            "name": name,
            "key": segment,
            "color": color,
            "points": [score[segment][q] for q in range(1, 6)],
        }

    score_chart = {
        "labels": [f"{q}档" for q in range(1, 6)],
        "series": [
            score_series("ALL", "整体", "var(--ink-2)"),
            score_series("New", "新客", "var(--c1)"),
            score_series("Old", "老客", "var(--c2)"),
        ],
    }

    usable_fpd15 = [item for item in chart_weeks if item["fpd15Maturity"] >= 0.7]
    latest = usable_fpd15[-1]
    previous = usable_fpd15[-2] if len(usable_fpd15) > 1 else None
    complete_fpd15 = [item for item in chart_weeks if item["fpd15Maturity"] >= 0.9]
    complete_fpd3 = [item for item in chart_weeks if not item["incomplete"]]
    complete_fpd30 = [
        item
        for item in chart_weeks
        if item["windows"].get(30) and item["windows"][30]["maturity"] >= 0.9
    ]
    low_fpd15 = next(
        (
            item
            for item in chart_weeks
            if item["windows"].get(15) and item["windows"][15]["maturity"] < 0.7
        ),
        None,
    )
    latest_week = chart_weeks[-1]
    previous_week = chart_weeks[-2] if len(chart_weeks) > 1 else None

    new15 = user["New"][15]
    old15 = user["Old"][15]
    all_q1 = score["ALL"][1]
    all_q5 = score["ALL"][5]
    lift = {
        "ALL": all_q5["rate"] / all_q1["rate"],
        "New": score["New"][5]["rate"] / score["New"][1]["rate"],
        "Old": score["Old"][5]["rate"] / score["Old"][1]["rate"],
    }
    monotonic = {}
    for segment in score:
        values = [score[segment][q]["rate"] for q in range(1, 6)]
        monotonic[segment] = all(b >= a for a, b in zip(values, values[1:]))

    chart_week_names = [item["week"] for item in chart_weeks]
    segments = {}
    for seg_key, seg_name, seg_color in SEGMENT_META:
        if seg_key == "ALL":
            seg_windows = overall_by
            seg_weeks, seg_weeks_by, seg_chart_weeks = weeks, weeks_by, chart_weeks
            seg_week_chart = week_chart
            seg_score_week = score_week
            seg_score_week_weeks = score_week_weeks
            seg_psi = psi_by_week
        else:
            seg_windows = user[seg_key]
            seg_weeks, seg_weeks_by, seg_chart_weeks = build_week_view(
                week_rows_by_seg[seg_key], chart_week_names
            )
            seg_week_chart = build_week_chart(seg_chart_weeks)
            seg_score_week = score_week_by_seg[seg_key]
            seg_score_week_weeks = score_week_week_list(seg_score_week, seg_chart_weeks)
            seg_psi = build_psi_by_week(seg_score_week, seg_score_week_weeks, seg_weeks_by)

        seg_auc_charts = {
            window: build_auc_chart(
                weekly_auc_by_seg.get(seg_key, {}).get(window, {}),
                seg_weeks_by,
                window,
            )
            for window in auc_windows
        }

        seg_score = score[seg_key]
        seg_usable = [item for item in seg_chart_weeks if item["fpd15Maturity"] >= 0.7]
        seg_latest = seg_usable[-1] if seg_usable else seg_chart_weeks[-1]
        seg_previous = seg_usable[-2] if len(seg_usable) > 1 else None
        seg_complete = [
            item for item in seg_chart_weeks if item["fpd15Maturity"] >= 0.9
        ]
        seg_low = next(
            (
                item
                for item in seg_chart_weeks
                if item["windows"].get(15) and item["windows"][15]["maturity"] < 0.7
            ),
            None,
        )
        seg_fpd30_maturity = (
            seg_windows[30]["obs"] / seg_windows[15]["obs"]
            if seg_windows[15]["obs"]
            else 0.0
        )
        lift_value = (
            seg_score[5]["rate"] / seg_score[1]["rate"]
            if seg_score[1]["rate"]
            else float("inf")
        )
        values = [seg_score[q]["rate"] for q in range(1, 6)]
        seg_monotonic = all(b >= a for a, b in zip(values, values[1:]))
        fpd15_obs = seg_windows[15]["obs"]
        if seg_key == "ALL":
            scope_hint = f"全部客群 · FPD15 成熟样本 {fmt_int(fpd15_obs)} 笔"
        else:
            share = fpd15_obs / fpd15["obs"] if fpd15["obs"] else 0
            scope_hint = (
                f"{seg_name} · FPD15 成熟样本 {fmt_int(fpd15_obs)} 笔"
                f"（占整体 {fmt_pct0(share)}）"
            )

        segments[seg_key] = {
            "key": seg_key,
            "name": seg_name,
            "color": seg_color,
            "windows": seg_windows,
            "windowList": build_window_list(seg_windows, keep_delta=seg_key == "ALL"),
            "weeks": seg_weeks,
            "weeksBy": seg_weeks_by,
            "chartWeeks": seg_chart_weeks,
            "weekChart": seg_week_chart,
            "score": seg_score,
            "scoreWeek": seg_score_week,
            "scoreWeekWeeks": seg_score_week_weeks,
            "psiByWeek": seg_psi,
            "aucCharts": seg_auc_charts,
            "lift": lift_value,
            "monotonic": seg_monotonic,
            "latest": seg_latest,
            "previous": seg_previous,
            "completeFpd15": seg_complete[-1] if seg_complete else None,
            "lowFpd15": seg_low,
            "latestWeek": seg_chart_weeks[-1],
            "previousWeek": seg_chart_weeks[-2] if len(seg_chart_weeks) > 1 else None,
            "fpd30Maturity": seg_fpd30_maturity,
            "scopeHint": scope_hint,
            "coverage": coverage,
            "common": common,
            "q1Sentinel": all_q1["min"] is not None and all_q1["min"] <= -1.0,
            "new15": new15,
            "old15": old15,
        }

    return {
        "overall": overall,
        "overallBy": overall_by,
        "windows": data_windows,
        "user": user,
        "weeks": weeks,
        "weeksBy": weeks_by,
        "chartWeeks": chart_weeks,
        "earlyWeeks": early_weeks,
        "score": score,
        "scoreWeek": score_week,
        "scoreWeekWeeks": score_week_weeks,
        "psiByWeek": psi_by_week,
        "weeklyAuc": weekly_auc_by_seg["ALL"].get(default_auc_window, {}),
        "aucCharts": auc_charts,
        "aucWindows": auc_windows,
        "aucWindowDefault": default_auc_window,
        "csvCount": len(REQUIRED_FILES)
        + sum(1 for name in OPTIONAL_FILES if raw.get(name) is not None),
        "coverage": coverage,
        "common": common,
        "fpdCurve": fpd_curve,
        "weekChart": week_chart,
        "scoreChart": score_chart,
        "latest": latest,
        "previous": previous,
        "completeFpd15": complete_fpd15[-1],
        "completeFpd3": complete_fpd3[-1],
        "completeFpd30": complete_fpd30[-1] if complete_fpd30 else None,
        "lowFpd15": low_fpd15,
        "latestWeek": latest_week,
        "previousWeek": previous_week,
        "new15": new15,
        "old15": old15,
        "lift": lift,
        "monotonic": monotonic,
        "q1Sentinel": all_q1["min"] is not None and all_q1["min"] <= -1.0,
        "fpd30Maturity": fpd30_maturity,
        "segments": segments,
        "creditDist": build_credit_dist(raw),
        "funnel": build_new_user_funnel(raw),
    }


def header_html():
    return """
<header class="hero">
  <div class="hero-copy">
    <p class="eyebrow">WAGEGO · RISK MONITORING</p>
    <h1>WageGo 风险监控看板</h1>
    <p class="sub">按放款周看首期逾期率（FPD），并按模型分分档拆分；新客视图另看全量戳额样本的模型分分布。除标注“金额”外，坏率均为笔数口径。</p>
  </div>
</header>
"""


def scope_bar_html(data):
    buttons = []
    for seg_key, seg_name, seg_color in SEGMENT_META:
        active = " on" if seg_key == "ALL" else ""
        pressed = "true" if seg_key == "ALL" else "false"
        buttons.append(
            f'<button type="button" class="scope-btn{active}" data-segment="{seg_key}" '
            f'aria-pressed="{pressed}" style="--seg-color:{seg_color}">{seg_name}</button>'
        )
    return f"""
<section class="scope-bar" aria-label="客群切换">
  <span class="scope-label">客群</span>
  <div class="scope-btns" role="group" aria-label="切换整体、新客、老客">{''.join(buttons)}</div>
  <span class="scope-hint" id="scopeHint">{escape(data['segments']['ALL']['scopeHint'])}</span>
</section>
"""


def scope_meta_html(time_text, sample_text):
    return f"""
<div class="scope-meta">
  <span class="scope-item"><b>时间口径</b><span>{time_text}</span></span>
  <span class="scope-item"><b>样本口径</b><span>{sample_text}</span></span>
</div>
"""


def overall_table(overall):
    rows = []
    for row in overall:
        rows.append(
            f"<tr><td>{WINDOW_LABELS[row['window']]}</td>"
            f"<td class='num'>{fmt_int(row['obs'])}</td>"
            f"<td class='num'>{fmt_int(row['bad'])}</td>"
            f"<td class='num'>{fmt_rate(row['rate'])}</td>"
            f"<td class='num'>{fmt_rate(row['amtRate'])}</td>"
            f"<td class='num'>{fmt_delta(row['delta'])}</td></tr>"
        )
    return f"""
<div class="table-wrap">
<table>
  <thead><tr><th>观察窗口</th><th>成熟样本（笔）</th><th>坏样本（笔）</th><th>坏率（笔数·y_fpdN_ovd）</th><th>坏率（金额·未还本金）</th><th>较上一窗口（笔数）</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def fpd_card_html(data):
    common = data["common"]
    overall15 = data["overallBy"][15]
    full_weeks = data["weeks"]
    full_first = full_weeks[0]["week"] if full_weeks else "—"
    full_last = full_weeks[-1]["week"] if full_weeks else "—"
    scope = scope_meta_html(
        f"放款周（周一）{full_first} ~ {full_last}；按观察窗口 FPD3–FPD30 汇总，不按时间滚动。",
        "借款申请（有效）→ 放款成功且有观察日借据快照 → 各窗口 due+N &lt; obs_dt 才纳入。"
        "新客 = 从未放款或首笔放款成功前（含）的申请，老客 = 其后申请（user_type）。"
        "金额分母为成熟放款本金。",
    )
    blocks = []
    for seg_key, seg_name, seg_color in SEGMENT_META:
        view = data["segments"][seg_key]
        fpd15 = view["windows"][15]
        maturity = view["fpd30Maturity"]
        if seg_key == "ALL":
            note = (
                f"笔数口径：FPD15 整体 {fmt_rate(fpd15['rate'])}，新客 {fmt_rate(data['new15']['rate'])} / 老客 {fmt_rate(data['old15']['rate'])}。"
                f"FPD30 为空心点：整体成熟样本仅为 FPD15 的 {fmt_pct0(maturity)}"
                f"（新 {fmt_pct0(data['segments']['New']['fpd30Maturity'])} / 老 {fmt_pct0(data['segments']['Old']['fpd30Maturity'])}），只作参考；"
                f"共同 cohort 上 FPD15 笔数坏率 {fmt_rate(common['rate15'])} → FPD30 {fmt_rate(common['rate30'])}。"
            )
            legend = (
                '<div class="legend">'
                '<span><i style="background:var(--ink-2)"></i>整体</span>'
                '<span><i style="background:var(--c1)"></i>新客</span>'
                '<span><i style="background:var(--c2)"></i>老客</span>'
                "</div>"
            )
        else:
            note = (
                f"{seg_name} FPD15 {fmt_rate(fpd15['rate'])}，整体 {fmt_rate(overall15['rate'])}"
                f"（gap {fmt_delta(fpd15['rate'] - overall15['rate'])}）。"
                f"FPD30 为空心点：{seg_name}成熟样本仅为 FPD15 的 {fmt_pct0(maturity)}，只作参考；"
                f"FPD14 金额坏率仅整体口径同步。共同 cohort（整体）上 FPD15 笔数坏率 "
                f"{fmt_rate(common['rate15'])} → FPD30 {fmt_rate(common['rate30'])}。"
            )
            legend = (
                '<div class="legend">'
                f'<span><i style="background:{seg_color}"></i>{seg_name}</span>'
                '<span><i class="dash" style="border-top-color:var(--ink-2)"></i>整体（参考）</span>'
                "</div>"
            )
        blocks.append(
            seg_panel(
                seg_key,
                legend + overall_table(view["windowList"]) + f'<p class="note">{note}</p>',
            )
        )
    return f"""
<section class="card">
  <h2>整体与分客群：FPD 曲线{SAMPLE_TAG_HTML}{TAG_COUNT}</h2>
  {scope}
  <p class="desc">横轴为观察窗口，纵轴为笔数坏率（坏样本笔数 / 成熟样本笔数）；FPD1 为最早预警信号，FPD30 为空心点。整体视图对比三客群；新客 / 老客视图为所选客群（实线）对比整体（虚线）。金额坏率见总览表。</p>
  <div class="chart-wrap">
    <svg id="fpdCurve" viewBox="0 0 1040 300" role="img" aria-label="整体、新客、老客在各 FPD 窗口的笔数坏率"></svg>
    <div class="tip" id="fpdTip"></div>
  </div>
  {''.join(blocks)}
</section>
"""


def rate_cell(week, window):
    row = week["windows"].get(window)
    if not row:
        return '<td class="num dim">—</td>'
    maturity = row["maturity"]
    if window in (1, 3):
        if week["incomplete"]:
            return (
                f'<td class="num soft" title="放款周未完整；{WINDOW_LABELS[window]} 样本 {fmt_int(row["obs"])}">'
                f"{sup(fmt_rate(row['rate']), '†')}</td>"
            )
        return f'<td class="num">{fmt_rate(row["rate"])}</td>'
    if maturity < 0.7:
        return (
            f'<td class="num dim" title="成熟度 {fmt_pct0(maturity)}，低于 70%，不展示">—</td>'
        )
    if maturity < 0.9:
        return (
            f'<td class="num soft" title="成熟度 {fmt_pct0(maturity)}，仅参考">'
            f"{sup(fmt_rate(row['rate']), '*')}</td>"
        )
    return f'<td class="num">{fmt_rate(row["rate"])}</td>'


def amount_cell(week):
    row = week["windows"].get(15)
    if not row or row["amtRate"] is None:
        return '<td class="num dim">—</td>'
    maturity = row["maturity"]
    if maturity < 0.7:
        return (
            f'<td class="num dim" title="成熟度 {fmt_pct0(maturity)}，低于 70%，不展示">—</td>'
        )
    if maturity < 0.9:
        return (
            f'<td class="num soft" title="成熟度 {fmt_pct0(maturity)}，仅参考">'
            f"{sup(fmt_rate(row['amtRate']), '*')}</td>"
        )
    return f'<td class="num">{fmt_rate(row["amtRate"])}</td>'


def week_table(view, include_fpd14=True):
    rows = []
    base_windows = (3, 7, 14, 15) if include_fpd14 else (3, 7, 15)
    has_fpd1 = any(1 in week["windows"] for week in view["chartWeeks"])
    windows = ((1,) if has_fpd1 else ()) + base_windows
    for week in view["chartWeeks"]:
        fpd15 = week["windows"].get(15)
        sample = fmt_int(fpd15["obs"]) if fpd15 else "—"
        maturity = fmt_pct0(week["fpd15Maturity"]) if fpd15 else "—"
        if fpd15 and week["fpd15Maturity"] < 0.7:
            maturity_class = "num dim"
        elif fpd15 and week["fpd15Maturity"] < 0.9:
            maturity_class = "num soft"
        else:
            maturity_class = "num"
        cells = [rate_cell(week, window) for window in windows]
        cells.append(amount_cell(week))
        cells.append(rate_cell(week, 30))
        rows.append(
            f"<tr><td>{week['week']}</td>"
            f"<td class='num'>{sample}</td>"
            f"<td class='{maturity_class}'>{maturity}</td>"
            f"{''.join(cells)}</tr>"
        )
    window_heads = "".join(f"<th>{WINDOW_LABELS[window]}</th>" for window in windows)
    return f"""
<div class="table-wrap">
<table>
  <thead><tr><th>放款周</th><th>FPD15 成熟样本</th><th>FPD15 成熟度</th>{window_heads}<th>FPD15 金额</th><th>FPD30</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def week_card_html(data):
    early = data["earlyWeeks"]
    early_text = (
        f"{early[0]}~{early[-1]} 的 {len(early)} 周样本仅 6–12 笔，已排除"
        if early
        else "无早期小样本周"
    )
    chart_weeks = data["chartWeeks"]
    has_fpd1 = any(1 in week["windows"] for week in chart_weeks)
    first_week = chart_weeks[0]["week"] if chart_weeks else "—"
    last_week = chart_weeks[-1]["week"] if chart_weeks else "—"
    scope = scope_meta_html(
        f"放款周（周一）{first_week} ~ {last_week}；{early_text}；最新周可能未完整。",
        "借款申请（有效）→ 放款成功且有观察日借据快照 → 按放款周归属，"
        "各窗口 due+N &lt; obs_dt 才纳入。新客 = 从未放款或首笔放款成功前（含）的申请，"
        "老客 = 其后申请（user_type）。金额分子为坏样本 due+N 未还本金。",
    )
    blocks = []
    for seg_key, seg_name, seg_color in SEGMENT_META:
        view = data["segments"][seg_key]
        latest = view["latest"]
        complete = view["completeFpd15"]
        low = view["lowFpd15"]
        latest_week = view["latestWeek"]
        previous_week = view["previousWeek"]
        low_text = (
            f"{low['week']} 的 FPD15 {fmt_rate(low['windows'][15]['rate'])}"
            f"（{fmt_pct0(low['windows'][15]['maturity'])} 成熟）未纳入"
            if low
            else "没有低于 70% 成熟的 FPD15 周"
        )
        latest_text = (
            f"{latest_week['week']} 周 FPD3 {fmt_rate(latest_week['windows'][3]['rate'])}†"
            f"（FPD3 样本 {fmt_int(latest_week['windows'][3]['obs'])}"
            f" vs 前周 {fmt_int(previous_week['windows'][3]['obs']) if previous_week else '—'}），仅参考"
        )
        complete_text = (
            f"≥90% 成熟的最后一周：FPD15 {complete['week']}（{fmt_rate(complete['windows'][15]['rate'])}）"
            if complete
            else "当前没有 FPD15 成熟度 ≥90% 的周"
        )
        fpd14_text = (
            ""
            if seg_key == "ALL"
            else "新客 / 老客视图不展示 FPD14 列：分客群 FPD14 周度值未同步。"
        )
        note = (
            f"{seg_name}口径。除标注“金额”外，坏率均为笔数口径；金额坏率 = 坏样本未还本金 / 全部成熟样本放款本金。"
            "成熟度 = 该窗口成熟样本 / 当周 FPD3 样本。"
            "星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示（FPD30 采用 90% 阈值）。"
            f"{complete_text}；"
            f"{latest['week']} 为 {fmt_pct0(latest['fpd15Maturity'])} 成熟（{fmt_rate(latest['windows'][15]['rate'])}{'' if latest['fpd15Maturity'] >= 0.9 else '*'}）。"
            f"{low_text}；{latest_text}。{early_text}。{fpd14_text}"
        )
        blocks.append(
            seg_panel(seg_key, week_table(view, include_fpd14=seg_key == "ALL") + f'<p class="note">{note}</p>')
        )
    fpd1_count_legend = (
        '<span><i class="dash" style="border-top-color:var(--c2)"></i>FPD1 早期信号</span>'
        if has_fpd1
        else ""
    )
    fpd1_amount_legend = (
        '<span><i class="dash" style="border-top-color:var(--c2)"></i>FPD1 金额坏率</span>'
        if has_fpd1
        else ""
    )
    fpd1_text = "、FPD1" if has_fpd1 else ""
    return f"""
<section class="card">
  <h2>按放款周：FPD15 与早期信号{SAMPLE_TAG_HTML}{TAG_COUNT}</h2>
  {scope}
  <p class="desc">默认笔数口径：FPD15 是确认指标，FPD7 / FPD3{fpd1_text} 是早期信号；切换到金额口径可同时看 FPD3 / FPD7{fpd1_text} / FPD15 的未还本金坏率。空心点表示成熟度不足或周未完整；阴影为 FPD15 笔数坏率的 95% 置信区间；浅灰柱为当周放款量。图表与表格随顶部客群切换。</p>
  <div class="chart-head">
    <div class="seg" role="group" aria-label="周度图口径">
      <button type="button" class="on" data-week-mode="count" aria-pressed="true">笔数</button>
      <button type="button" data-week-mode="amount" aria-pressed="false">金额</button>
    </div>
  </div>
  <div class="chart-wrap">
    <svg id="weekChart" viewBox="0 0 1040 300" role="img" aria-label="各放款周的 FPD15、FPD7、FPD3{fpd1_text} 笔数及金额坏率，含 FPD15 置信区间、放款量和金额口径切换"></svg>
    <div class="tip" id="weekTip"></div>
  </div>
  <div class="legend week-legend-count">
    <span><i style="background:var(--c1)"></i>FPD15</span>
    <span><i class="band" style="background:var(--c1)"></i>FPD15 95% CI</span>
    <span><i class="dash" style="border-top-color:var(--c3)"></i>FPD7 早期信号</span>
    <span><i class="dash"></i>FPD3 早期信号</span>
    {fpd1_count_legend}
    <span><i class="bar" style="background:var(--grid)"></i>放款量（FPD3 样本）</span>
  </div>
  <div class="legend week-legend-amount" hidden>
    <span><i style="background:var(--c1)"></i>FPD15 金额坏率</span>
    <span><i class="dash" style="border-top-color:var(--c3)"></i>FPD7 金额坏率</span>
    <span><i class="dash"></i>FPD3 金额坏率</span>
    {fpd1_amount_legend}
    <span><i class="bar" style="background:var(--grid)"></i>放款量（FPD3 样本）</span>
  </div>
  {''.join(blocks)}
</section>
"""


def score_table(score, seg_key="ALL"):
    def rate_cell(segment, q):
        row = score[segment][q]
        return (
            f"<td class='num'><b>{fmt_rate(row['rate'])}</b>"
            f"<span class='n'>n={fmt_int(row['obs'])}</span></td>"
        )

    if seg_key == "ALL":
        rows = []
        for q in range(1, 6):
            rows.append(
                f"<tr><td>{q}档</td><td class='range'>{score_range_text(q, SCORE_BIN_UPPER)}</td>"
                f"{rate_cell('ALL', q)}{rate_cell('New', q)}{rate_cell('Old', q)}</tr>"
            )
        return f"""
<div class="table-wrap">
<div class="subhead">分档汇总</div>
<table class="compact">
  <thead><tr><th>分档</th><th>分数区间</th><th>整体（笔数）</th><th>新客（笔数）</th><th>老客（笔数）</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""

    seg_name = dict((key, name) for key, name, _ in SEGMENT_META)[seg_key]
    rows = []
    for q in range(1, 6):
        diff = score[seg_key][q]["rate"] - score["ALL"][q]["rate"]
        rows.append(
            f"<tr><td>{q}档</td><td class='range'>{score_range_text(q, SCORE_BIN_UPPER)}</td>"
            f"{rate_cell(seg_key, q)}{rate_cell('ALL', q)}"
            f"<td class='num'>{fmt_delta(diff)}</td></tr>"
        )
    return f"""
<div class="table-wrap">
<div class="subhead">分档汇总</div>
<table class="compact">
  <thead><tr><th>分档</th><th>分数区间</th><th>{seg_name}（笔数）</th><th>整体（笔数）</th><th>{seg_name} − 整体</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def score_week_table(view):
    weeks = view["scoreWeekWeeks"]
    header = "".join(f"<th>{week[5:]}</th>" for week in weeks)

    def maturity_style(week):
        maturity = view["weeksBy"][week]["fpd15Maturity"] if week in view["weeksBy"] else 1.0
        if maturity < 0.7:
            return "num dim", f"FPD15 成熟度 {fmt_pct0(maturity)}，仅参考", "dim"
        if maturity < 0.9:
            return "num soft", f"FPD15 成熟度 {fmt_pct0(maturity)}，仅参考", "soft"
        return "num", None, None

    rows = []
    for q in range(1, 6):
        cells = []
        for week in weeks:
            row = view["scoreWeek"][week].get(q)
            if not row:
                cells.append('<td class="num dim">—</td>')
                continue
            cls, title, marker = maturity_style(week)
            text = sup(fmt_rate(row["rate"]), "*") if marker == "soft" else fmt_rate(row["rate"])
            attr = f' title="{title}"' if title else ""
            cells.append(f'<td class="{cls}"{attr}>{text}</td>')
        rows.append(f"<tr><td>{q}档</td>{''.join(cells)}</tr>")

    lift_cells = []
    mono_cells = []
    for week in weeks:
        week_rows = view["scoreWeek"][week]
        cls, title, marker = maturity_style(week)
        attr = f' title="{title}"' if title else ""
        q1 = week_rows.get(1)
        q5 = week_rows.get(5)
        lift_text = f"{q5['rate'] / q1['rate']:.2f}x" if q1 and q5 and q1["rate"] else "—"
        values = [week_rows[q]["rate"] for q in range(1, 6) if week_rows.get(q)]
        if len(values) < 5:
            mono_text = "—"
        else:
            mono_text = "单调" if all(b >= a for a, b in zip(values, values[1:])) else "非单调"
        if marker == "soft":
            lift_text = sup(lift_text, "*")
            mono_text = sup(mono_text, "*")
        lift_cells.append(f'<td class="{cls}"{attr}>{lift_text}</td>')
        mono_cells.append(f'<td class="{cls}"{attr}>{mono_text}</td>')
    rows.append(f"<tr><td>5档/1档</td>{''.join(lift_cells)}</tr>")
    rows.append(f"<tr><td>排序</td>{''.join(mono_cells)}</tr>")

    psi_cells = []
    for week in weeks:
        psi = view["psiByWeek"].get(week)
        cls, title, marker = maturity_style(week)
        if psi is None:
            psi_cells.append('<td class="num dim">—</td>')
            continue
        level = "alert" if psi >= 0.25 else "watch" if psi >= 0.1 else ""
        if cls == "num dim":
            cell_cls = "num dim"
        elif cls == "num soft":
            cell_cls = "num soft"
        else:
            cell_cls = f"num {level}" if level else "num"
        text = f"{psi:.2f}"
        if marker == "soft":
            text = sup(text, "*")
        title_bits = ["5档 PSI；<0.10 稳定，0.10–0.25 关注，≥0.25 预警"]
        if title:
            title_bits.append(title)
        psi_cells.append(
            f'<td class="{cell_cls}" title="{"; ".join(title_bits)}">{text}</td>'
        )
    rows.append(f"<tr><td>PSI（5档）</td>{''.join(psi_cells)}</tr>")

    return f"""
<div class="table-wrap">
<div class="subhead">分档 × 放款周（FPD15 笔数坏率）· 末三行为排序与漂移检查</div>
<table class="compact">
  <thead><tr><th>分档</th>{header}</tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def credit_dist_table(view, bins):
    upper = SCORE_BIN_UPPER if bins == 5 else CREDIT_SCORE_DECILE_UPPER
    table = view["tables"][bins]
    weeks = view["weeks"]
    header = "".join(
        f"<th title='{week}'>{week[5:]}</th>" for week in weeks
    )
    rows = []
    for row in table["all"]:
        cells = [
            f"<td>{row['q']}档</td>",
            f"<td class='range'>{score_range_text(row['q'], upper)}</td>",
            f"<td class='num'><b>{fmt_rate(row['share'])}</b></td>",
        ]
        for week in weeks:
            week_row = table["weeks"][week][row["q"] - 1]
            dim = (
                " dim"
                if (view["coverage"][week]["scored"] or 0) < CREDIT_WEEK_MIN_OBS
                else ""
            )
            cells.append(f"<td class='num{dim}'>{fmt_rate(week_row['share'])}</td>")
        rows.append(f"<tr>{''.join(cells)}</tr>")

    def summary_row(label, all_value, value_fn):
        cells = [
            f"<td>{label}</td>",
            "<td class='range'>—</td>",
            f"<td class='num'>{all_value}</td>",
        ]
        for week in weeks:
            dim = (
                " dim"
                if (view["coverage"][week]["scored"] or 0) < CREDIT_WEEK_MIN_OBS
                else ""
            )
            cells.append(f"<td class='num{dim}'>{value_fn(week)}</td>")
        rows.append(f"<tr>{''.join(cells)}</tr>")

    all_cov = view["allCoverage"]
    summary_row(
        "戳额样本",
        fmt_int(all_cov.get("sample")),
        lambda week: fmt_int(view["coverage"][week]["sample"]),
    )
    summary_row(
        "有分样本",
        fmt_int(all_cov.get("scored")),
        lambda week: fmt_int(view["coverage"][week]["scored"]),
    )
    summary_row(
        "有分率",
        fmt_rate(all_cov.get("pct")),
        lambda week: fmt_rate(view["coverage"][week]["pct"]),
    )

    psi_cells = [
        "<td>PSI（vs 全量）</td>",
        "<td class='range'>—</td>",
        "<td class='num dim'>—</td>",
    ]
    for week in weeks:
        value = table["psi"].get(week)
        scored = view["coverage"][week]["scored"] or 0
        if value is None:
            psi_cells.append("<td class='num dim'>—</td>")
            continue
        level = "alert" if value >= 0.25 else "watch" if value >= 0.1 else ""
        cls = (
            "num dim"
            if scored < CREDIT_WEEK_MIN_OBS
            else (f"num {level}" if level else "num")
        )
        psi_cells.append(
            f"<td class='{cls}' title='全量分布为基线；&lt;0.10 稳定，0.10–0.25 关注，≥0.25 预警'>"
            f"{value:.2f}</td>"
        )
    rows.append(f"<tr>{''.join(psi_cells)}</tr>")

    return f"""
<div class="table-wrap">
<div class="subhead">分档 × 戳额周（周一开始）</div>
<table class="compact">
  <thead><tr><th>档位</th><th>分数区间</th><th>全量</th>{header}</tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def funnel_card_html(data):
    funnel = data.get("funnel")
    if not funnel:
        return ""
    totals = funnel["totals"]
    excluded_text = (
        "、".join(
            f"{item['week']}（{fmt_int(item['creditUsers'])} 人）"
            for item in funnel["excluded"]
        )
        if funnel["excluded"]
        else ""
    )

    def rate_text(value, partial=False):
        return sup(fmt_rate(value), "*") if partial else fmt_rate(value)

    rows = []
    for item in funnel["weeks"]:
        partial = item["cohortDays"] is not None and item["cohortDays"] < 30
        cls = "num soft" if partial else "num"
        pass_tip = ""
        if item["passRateCnt"] is not None:
            pass_tip = f"；笔数口径 {fmt_rate(item['passRateCnt'])}"
        deal_tip = ""
        if item["dealRateCnt"] is not None:
            deal_tip = f"；笔数口径 {fmt_rate(item['dealRateCnt'])}"
        rows.append(
            f"<tr><td>{item['week']}</td>"
            f"<td class='num'>{fmt_int(item['creditUsers'])}</td>"
            f"<td class='{cls}'>{rate_text(item['limitPassRate'], partial)}</td>"
            f"<td class='{cls}'>{rate_text(item['applyRate'], partial)}</td>"
            f"<td class='{cls}' title='用户级：审核通过用户 / 有借款申请用户{pass_tip}'>"
            f"{rate_text(item['passRate'], partial)}</td>"
            f"<td class='{cls}' title='用户级：放款成功用户 / 有借款申请用户{deal_tip}'>"
            f"{rate_text(item['dealRate'], partial)}</td>"
            f"<td class='{cls}'>{rate_text(item['creditDealRate'], partial)}</td>"
            f"<td class='{cls}'>{fmt_int(item['cohortDays'])}</td></tr>"
        )

    kpis = [
        ("戳额人数", fmt_int(totals["creditUsers"]), "新客出额样本用户数"),
        ("出额审批通过率", fmt_rate(totals["limitPassRate"]), "有额用户 / 可匹配出额明细用户"),
        ("借款申请率", fmt_rate(totals["applyRate"]), "戳额后有借款申请的用户 / 戳额用户"),
        ("借款审核通过率", fmt_rate(totals["passRate"]), "审核通过用户 / 有借款申请用户"),
        ("成交率", fmt_rate(totals["dealRate"]), "放款成功用户 / 有借款申请用户"),
        ("出额→成交率", fmt_rate(totals["creditDealRate"]), "放款成功用户 / 戳额用户"),
    ]
    kpi_html = "".join(
        f'<div class="kpi" title="{escape(tip)}"><span>{escape(label)}</span>'
        f"<b>{value}</b></div>"
        for label, value, tip in kpis
    )
    scope = scope_meta_html(
        f"戳额周（周一）{funnel['firstWeek']} ~ {funnel['lastWeek']}；"
        f"最新周距同步日不足 30 天时标 *，仅参考。",
        "出额样本 = 每个用户全历史首次戳额申请（不设时间窗）；出额结果取出额转化明细，"
        "借款申请取戳额日之后的 Y 标签申请记录；用户级去重。"
        f"样本少于 {CREDIT_WEEK_MIN_OBS} 人的戳额周已排除"
        + (f"（{excluded_text}）" if excluded_text else "")
        + "。",
    )
    return f"""
<section class="card">
  <h2>新客出额转化漏斗<span class="tag" title="固定展示新客出额样本，不随顶部客群切换">固定口径</span><span class="tag" title="出额审批通过率、借款申请审核通过率与成交率；均为用户级口径">业务指标</span></h2>
  {scope}
  <p class="desc">从戳额申请到借款申请的转化漏斗；出额审批通过率看出额环节，借款审核通过率与成交率看借款环节。</p>
  <div class="kpis">{kpi_html}</div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>戳额周</th><th>戳额人数</th><th>出额审批通过率</th><th>借款申请率</th>
      <th>借款审核通过率</th><th>成交率</th><th>出额→成交率</th><th>观察天数</th></tr></thead>
      <tbody>{''.join(rows)}</tbody>
    </table>
  </div>
  <p class="note">出额审批通过率 = 有额用户 / 可匹配出额明细用户；借款审核通过率 = 审核通过用户 / 有借款申请用户；
  成交率 = 放款成功用户 / 有借款申请用户；出额→成交率 = 放款成功用户 / 戳额用户。
  审核通过含审核通过、放款成功与放款失败；审核中与信息变更不计入通过。星号 * 表示戳额周距同步日不足 30 天，转化仍在累积。</p>
</section>
"""


def credit_dist_card_html(data):
    view = data.get("creditDist")
    if not view:
        return ""
    all_cov = view["allCoverage"]
    weeks = view["weeks"]
    week_text = f"{weeks[0]} ~ {weeks[-1]}" if weeks else "—"
    scope = scope_meta_html(
        f"戳额周（周一）{week_text}；样本覆盖全历史，不设起止时间窗，随数据同步滚动。",
        "额度申请表（isactive=1、biz_type=400）优先，风控事件表"
        "（is_active=1、biz_id=10000）兜底 → 每个 user_id 取全历史最早 credit_time 一条 → "
        "用戳额 flow_id 关联模型日志（model_code=aus_wagego_new_risk_3rd_v1_0）取最新分 → "
        "负分 / 无日志算缺分，分档只算有分用户。此样本不按 user_type 过滤，"
        "“新客”由每个用户的首次戳额定义。",
    )
    low_text = (
        f"{'、'.join(week[5:] for week in view['lowWeeks'])} 有分样本少于 "
        f"{CREDIT_WEEK_MIN_OBS}，灰显仅参考。"
        if view["lowWeeks"]
        else ""
    )
    unscored_text = (
        f"另有 {len(view['unscoredWeeks'])} 个周无有分样本"
        f"（{view['unscoredWeeks'][0]} ~ {view['unscoredWeeks'][-1]}），未列入表格。"
        if view["unscoredWeeks"]
        else ""
    )
    note = (
        "样本为每个用户全历史首次戳额申请（额度申请表优先、风控事件兜底），不设时间窗；"
        "分数取戳额时点线上模型日志最新一条，负分按缺分处理。"
        f"全量 {fmt_int(all_cov.get('sample'))} 人中 {fmt_int(all_cov.get('scored'))} 人有分"
        f"（{fmt_rate(all_cov.get('pct'))}）；表内为戳额周（周一开始）{week_text}，"
        "分母为当周有分用户。"
        "分数越高档位越高；5 档为固定 10 档相邻两档合并。"
        "PSI 以全量分布为基线：&lt;0.10 稳定，0.10–0.25 关注，≥0.25 预警。"
        f"{low_text}{unscored_text}"
    )
    return f"""
<section class="card" data-seg-panel="New" hidden>
  <h2>新客戳额模型分分布{TAG_CREDIT}</h2>
  {scope}
  <p class="desc">按戳额时点的线上模型分，展示全历史新客首次戳额样本按戳额周（周一开始）的 5 档 / 10 档分布；不依赖放款和 FPD 成熟度，用于监控进件客群的分数结构。该卡片仅在“新客”视图展示。</p>
  <div class="chart-head">
    <div class="seg" role="group" aria-label="分档粒度">
      <button type="button" class="on" data-credit-bins="5" aria-pressed="true">5档</button>
      <button type="button" data-credit-bins="10" aria-pressed="false">10档</button>
    </div>
  </div>
  <div data-credit-table="5">{credit_dist_table(view, 5)}</div>
  <div data-credit-table="10" hidden>{credit_dist_table(view, 10)}</div>
  <p class="note">{note}</p>
</section>
"""


def score_card_html(data):
    overall_lift = data["lift"]
    sentinel = (
        "1档分数下限 -1.0，疑似缺分哨兵；分档按原查询结果展示，未单独剔除。"
        if data["q1Sentinel"]
        else ""
    )
    overall_score = data["score"]
    full_weeks = data["weeks"]
    full_first = full_weeks[0]["week"] if full_weeks else "—"
    full_last = full_weeks[-1]["week"] if full_weeks else "—"
    heat_weeks = data["scoreWeekWeeks"]
    heat_range = f"{heat_weeks[0]} ~ {heat_weeks[-1]}" if heat_weeks else "—"
    scope = scope_meta_html(
        f"放款周（周一）{full_first} ~ {full_last}；分档汇总为全期，分档×周表为 {heat_range}。",
        f"借款申请 → 放款成功且 FPD15 成熟（due+15 &lt; obs_dt）→ 模型分非空"
        f"（整体覆盖 {data['coverage']['pct']:.2f}%）→ 按固定阈值分 5 档，缺分不纳入。"
        "周表每档样本 ≥50 的周才纳入（末周保留）。",
    )
    blocks = []
    for seg_key, seg_name, seg_color in SEGMENT_META:
        view = data["segments"][seg_key]
        score = view["score"]
        lift = view["lift"]
        monotonic = view["monotonic"]
        heat_weeks = view["scoreWeekWeeks"]
        heat_first = heat_weeks[0] if heat_weeks else None
        soft_heat = [
            week
            for week in heat_weeks
            if 0.7 <= view["weeksBy"].get(week, {}).get("fpd15Maturity", 1) < 0.9
        ]
        low_heat = [
            week
            for week in heat_weeks
            if view["weeksBy"].get(week, {}).get("fpd15Maturity", 1) < 0.7
        ]
        heat_bits = []
        if heat_first:
            heat_bits.append(f"分档×周表从 {heat_first[5:]} 起，更早周每档样本不足，未纳入")
        if soft_heat:
            heat_bits.append(f"{'、'.join(week[5:] for week in soft_heat)} 标 *（70–90% 成熟）")
        if low_heat:
            low_text = "、".join(
                f"{week[5:]}（{fmt_pct0(view['weeksBy'].get(week, {}).get('fpd15Maturity', 0))} 成熟）"
                for week in low_heat
            )
            heat_bits.append(f"{low_text} 灰显，仅参考")
        heat_note = "；".join(heat_bits) + "。" if heat_bits else ""

        total = sum(score[q]["obs"] for q in range(1, 6))
        q1_share = score[1]["obs"] / total if total else 0
        q5_share = score[5]["obs"] / total if total else 0
        if seg_key == "ALL":
            lift_text = (
                f"整体 5档/1档 = {lift:.2f}x，"
                f"新客 {overall_lift['New']:.2f}x，老客 {overall_lift['Old']:.2f}x。"
            )
            shape = (
                "整体、新客、老客均基本单调。"
                if all(data["monotonic"].values())
                else "整体与新客基本单调；老客 2档/4档 低于前一档，排序弱于新客。"
            )
            legend = (
                '<div class="legend">'
                '<span><i style="background:var(--ink-2)"></i>整体</span>'
                '<span><i style="background:var(--c1)"></i>新客</span>'
                '<span><i style="background:var(--c2)"></i>老客</span>'
                "</div>"
            )
        else:
            lift_text = f"{seg_name} 5档/1档 = {lift:.2f}x（整体 {overall_lift['ALL']:.2f}x）。"
            shape = (
                f"{seg_name}分档基本单调。"
                if monotonic
                else f"{seg_name}分档出现非单调，排序弱于整体。"
            )
            legend = (
                '<div class="legend">'
                f'<span><i style="background:{seg_color}"></i>{seg_name}</span>'
                '<span><i class="dash" style="border-top-color:var(--ink-2)"></i>整体（参考）</span>'
                "</div>"
            )
        note = (
            f"坏率均为 FPD15 笔数口径。1档最低分，5档最高分；固定阈值下各档样本占比不等"
            f"（1档 {fmt_pct0(q1_share)}、5档 {fmt_pct0(q5_share)}）。"
            f"{lift_text}{shape}"
            f"覆盖 {data['coverage']['pct']:.2f}%（{fmt_int(data['coverage']['scored'])}/{fmt_int(data['coverage']['obs'])}，整体口径），"
            f"缺分 {fmt_int(data['coverage']['missing'])}。{heat_note}{sentinel}"
            "分档×周表末三行为周度 5档/1档 倍数、排序单调性和 5 档 PSI。"
            "倍数明显低于全期或出现非单调时关注；PSI 基线为前最多 4 个确认周，"
            "仅对确认周计算（放款周完整且 FPD15 成熟度 ≥90%）；"
            "<0.10 稳定，0.10–0.25 关注，≥0.25 预警（5 档粒度为近似）。"
        )
        blocks.append(
            seg_panel(
                seg_key,
                legend
                + f'<div class="split">{score_table(overall_score, seg_key)}{score_week_table(view)}</div>'
                + f'<p class="note">{note}</p>',
            )
        )
    return f"""
<section class="card">
  <h2>模型分分档{SAMPLE_TAG_HTML}{TAG_COUNT}</h2>
  {scope}
  <p class="desc">1档最低分 → 5档最高分（按新客风险 1.0 固定阈值切分）；整体视图对比三客群，新客 / 老客视图为所选客群（实线）对比整体（虚线）。</p>
  <div class="chart-wrap">
    <svg id="scoreChart" viewBox="0 0 1040 300" role="img" aria-label="模型分分档的整体、新客、老客 FPD15 笔数坏率"></svg>
    <div class="tip" id="scoreTip"></div>
  </div>
  {''.join(blocks)}
</section>
"""


def stability_card_html(data):
    def mark(text, marker):
        return sup(text, marker) if marker and text != "—" else text

    auc_windows = data["aucWindows"]
    default_window = data["aucWindowDefault"]
    default_chart = data["aucCharts"].get(default_window) or {"points": []}
    points_all = default_chart["points"]
    point_range = (
        f"{points_all[0]['week']} ~ {points_all[-1]['week']}" if points_all else "—"
    )
    window_names = " / ".join(WINDOW_LABELS[window] for window in auc_windows)
    scope = scope_meta_html(
        f"放款周（周一）{point_range}；可切换 {window_names} 观察窗口；按周计算排序力；"
        "PSI 仅使用确认周（放款周完整且 FPD15 成熟度 ≥90%）。",
        "各窗口成熟放款 + 模型分非空 → 按周内分数排名计算 AUC / Gini / KS"
        "（并列取平均秩）→ 周成熟样本 &lt;200 剔除；客群按 user_type 过滤。",
    )
    toggle = ""
    if len(auc_windows) > 1:
        buttons = "".join(
            f'<button type="button" class="{"on" if window == default_window else ""}" '
            f'data-auc-window="{window}" '
            f'aria-pressed="{"true" if window == default_window else "false"}">'
            f"{WINDOW_LABELS[window]}</button>"
            for window in auc_windows
        )
        toggle = f"""
  <div class="chart-head">
    <div class="seg" role="group" aria-label="AUC 观察窗口">{buttons}</div>
  </div>"""
    blocks = []
    for seg_key, seg_name, seg_color in SEGMENT_META:
        view = data["segments"][seg_key]
        panels = []
        for window in auc_windows:
            label = WINDOW_LABELS[window]
            hidden = "" if window == default_window else " hidden"
            chart = view["aucCharts"].get(window) or {"points": []}
            points = chart["points"]
            if not points:
                panels.append(
                    f'<div data-auc-panel="{window}"{hidden}>'
                    f'<p class="note">{label} 周度排序力样本不足，暂无可展示的确认周。</p>'
                    "</div>"
                )
                continue

            rows = []
            for point in points:
                maturity = point["maturity"]
                if maturity < 0.7:
                    cls, marker = "num dim", None
                elif maturity < 0.9 or point["partial"]:
                    cls, marker = "num soft", "*"
                else:
                    cls, marker = "num", None
                auc_text = mark(f"{point['auc']:.3f}", marker)
                gini_text = mark(
                    f"{point['gini']:.3f}" if point["gini"] is not None else "—", marker
                )
                ks_text = mark(
                    f"{point['ks']:.3f}" if point["ks"] is not None else "—", marker
                )
                rows.append(
                    f"<tr><td>{point['week']}</td><td class='num'>{fmt_int(point['obs'])}</td>"
                    f"<td class='{cls}'>{auc_text}</td>"
                    f"<td class='{cls}'>{gini_text}</td>"
                    f"<td class='{cls}'>{ks_text}</td>"
                    f"<td class='num'>{fmt_rate(point['rate'])}</td>"
                    f"<td class='{cls}'>{fmt_pct0(maturity)}</td></tr>"
                )

            confirmed = [point for point in points if not point["partial"]]
            latest = confirmed[-1] if confirmed else points[-1]
            prior = [
                point for point in points
                if point["week"] < latest["week"] and not point["partial"]
            ][-4:]
            baseline_text = ""
            if prior:
                mean_auc = sum(point["auc"] for point in prior) / len(prior)
                baseline_text = (
                    f"最新确认周 {latest['week']} AUC {latest['auc']:.3f}"
                    f"（前 {len(prior)} 周均值 {mean_auc:.3f}）"
                    f"，Gini {latest['gini']:.3f}，KS {latest['ks']:.3f}。"
                )
            psi = view["psiByWeek"]
            psi_text = ""
            if psi:
                last_week = sorted(psi)[-1]
                psi_text = f"最近一周 PSI {psi[last_week]:.2f}（{last_week}）。"
            scope_text = (
                f"AUC / Gini / KS 基于 {label} 成熟样本，按周内分数排名计算"
                if seg_key == "ALL"
                else f"AUC / Gini / KS 基于{seg_name}{label}成熟样本，按周内分数排名计算"
            )
            note = (
                f"{scope_text}，AUC 对并列分数取平均秩；"
                "周样本少于 200 的周不纳入。星号 * 表示 70–90% 成熟，仅参考。"
                f"{baseline_text}{psi_text}"
                "AUC 连续走低或 KS 明显收缩时，优先检查模型分分布和入催客群变化。"
            )
            panels.append(
                f"""
<div data-auc-panel="{window}"{hidden}>
<div class="table-wrap">
<table class="compact">
  <thead><tr><th>放款周</th><th>成熟样本</th><th>AUC</th><th>Gini</th><th>KS</th><th>{label} 坏率</th><th>成熟度</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
<p class="note">{note}</p>
</div>
"""
            )
        blocks.append(seg_panel(seg_key, "".join(panels)))
    return f"""
<section class="card">
  <h2>周度排序力{SAMPLE_TAG_HTML}<span class="tag" title="AUC = P(坏样本分数高于好样本) + 0.5 × P(并列)；Gini = 2 × AUC − 1">模型监控</span></h2>
  {scope}
  <p class="desc">按放款周看模型分对各 FPD 窗口的排序能力，可切换 {window_names}；AUC 和 KS 越高越好。灰柱为当周该窗口成熟样本量。图表与表格随顶部客群切换，窗口对三个客群同时生效。</p>
  {toggle}
  <div class="chart-wrap">
    <svg id="aucChart" viewBox="0 0 1040 280" role="img" aria-label="周度 AUC 与 KS"></svg>
    <div class="tip" id="aucTip"></div>
  </div>
  <div class="legend" id="aucLegend"></div>
  {''.join(blocks)}
</section>
"""


def quality_card_html(data):
    common = data["common"]
    coverage = data["coverage"]
    earliest = data["chartWeeks"][0]["week"]
    latest = data["latestWeek"]["week"]
    previous = data["previousWeek"]
    early = data["earlyWeeks"]
    early_text = (
        f"{early[0]}~{early[-1]} 的 {len(early)} 周样本 6–12 笔，已排除"
        if early
        else "无早期小样本周"
    )
    latest_obs = data["latestWeek"]["windows"][3]["obs"]
    prev_obs = previous["windows"][3]["obs"] if previous else None
    sentinel = (
        "1档分数下限 -1.0，疑似缺分哨兵。"
        if data["q1Sentinel"]
        else "分档内无 -1.0 哨兵。"
    )
    scope = scope_meta_html(
        f"放款周（周一）{earliest} ~ {latest}；汇总共同 cohort、模型分覆盖与周样本质量。",
        "共同 cohort = FPD15 与 FPD30 均成熟（y_fpd15_obs=1 且 y_fpd30_obs=1）的同一批放款；"
        "模型分覆盖 = FPD15 成熟放款中有分占比；周样本按 FPD3 样本量检查 &lt;50 周排除、末周完整性。",
    )
    return f"""
<section class="card">
  <h2>数据质量与口径{TAG_QUALITY_SAMPLE}{TAG_OVERALL}</h2>
  {scope}
  <div class="quality">
    <div>
      <span class="q-label">FPD15 → FPD30（共同 cohort · 笔数）</span>
      <b>{fmt_rate(common['retention'])}</b>
      <span>{fmt_int(common['obs'])} 笔；笔数坏率 FPD15 {fmt_rate(common['rate15'])} → FPD30 {fmt_rate(common['rate30'])}，
      {fmt_rate(100 - common['retention'])} 在 due+30 前还清。</span>
    </div>
    <div>
      <span class="q-label">模型分覆盖</span>
      <b>{coverage['pct']:.2f}%</b>
      <span>{fmt_int(coverage['scored'])} / {fmt_int(coverage['obs'])} 有分，缺分 {fmt_int(coverage['missing'])}。{sentinel}</span>
    </div>
    <div>
      <span class="q-label">周样本</span>
      <b>{len(data['chartWeeks'])} 周</b>
      <span>{earliest} ~ {latest}；{early_text}；{latest} 周未完整
      （FPD3 {fmt_int(latest_obs)} vs 前周 {fmt_int(prev_obs)}）。</span>
    </div>
  </div>
</section>
"""


def footer_html(data, generated_at, input_name):
    extras = []
    if any(chart.get("points") for chart in data["aucCharts"].values()):
        window_names = " / ".join(
            WINDOW_LABELS[window] for window in data["aucWindows"]
        )
        extras.append(
            "<li>周度排序力与漂移：观察窗口支持 "
            f"{window_names}（成熟样本各自独立）；"
            "AUC 按周内分数排名计算，并列分数取平均秩；"
            "Gini = 2×AUC−1；KS 按分数分组累计好坏分布计算；周样本少于 200 的周不纳入。"
            "PSI 固定按 FPD15 的 5 档份额计算，基线为前最多 4 个确认周；&lt;0.10 稳定，"
            "0.10–0.25 关注，≥0.25 预警（5 档粒度为近似）。</li>"
        )
    if data.get("creditDist"):
        extras.append(
            "<li>新客戳额模型分分布：样本为每个用户全历史首次戳额申请"
            "（额度申请表优先、风控事件兜底），不设时间窗；分数取戳额时点线上模型分"
            "（scene_id = 戳额流水，取模型日志最新一条），负分按缺分处理。"
            "表内按戳额周（周一开始）展示；"
            "10 档按线上模型固定十等分切点，5 档为相邻两档合并；PSI 以全量分布为基线；"
            "该卡片仅在“新客”视图展示。</li>"
        )
    if data.get("funnel"):
        extras.append(
            "<li>新客出额转化漏斗：出额样本为每个用户全历史首次戳额申请"
            "（额度申请表优先、风控事件兜底），不设时间窗；"
            "出额审批通过率取出额转化明细表（edw_ewa.dwb_user_fst_conv_dtl），"
            "借款审核通过率与成交率取 Y 标签主表中戳额日之后的借款申请；"
            "均为用户级去重，审核通过含审核通过、放款成功与放款失败。"
            "戳额周样本少于 50 人的周已排除，最新周距同步日不足 30 天时标 *。</li>"
        )
    bin_text = " / ".join(f"≤{value:.6f}" for value in SCORE_BIN_UPPER)
    bin_text += f" / &gt;{SCORE_BIN_UPPER[-1]:.6f}"
    return f"""
<footer class="foot">
  <ul class="notes">
    <li>笔数坏率（看板默认口径）：y_fpdN_ovd 之和 / y_fpdN_obs 之和。FPD-X：首期应还日 due + X 天前未还清首期；成熟样本为 y_fpdN_obs = 1（is_deal = 1、观察日有借据快照且 due + X &lt; obs_dt），未成熟不判坏（即使已结清）。FPD14 由 stg_debt_snp 首期实还日补算，成熟条件同口径。</li>
    <li>金额坏率（仅总览表）：estimate_principal_remaining_fpdN 之和 / 全部成熟样本放款本金；余额取 due+X 当天借据快照（FPD14 同机制），当天无快照的不计入分子。</li>
    <li>成熟度：该窗口成熟样本 / 当周 FPD3 样本；星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示；FPD30 采用 90% 阈值。</li>
    <li>周度图：阴影为 FPD15 的 Wilson 95% 置信区间；浅灰柱为当周 FPD3 成熟样本数（放款量代理）。周度图可在笔数 / 金额口径间切换。</li>
    {''.join(extras)}
    <li>新老客：user_type 按首笔放款。分客群 FPD14 周度值与金额坏率未单独同步，新客 / 老客视图不展示 FPD14 金额与周度列。</li>
    <li>客群切换：顶部“整体 / 新客 / 老客”按钮联动 FPD 曲线、周度表、分档表与排序力表；新客 / 老客视图以所选客群实线对比整体虚线。数据质量卡固定为整体口径。</li>
    <li>模型分：按新客风险 1.0 固定阈值切 5 档（{bin_text}），1档最低分、5档最高分；分数越高越坏。固定阈值下各档样本占比不等。</li>
    <li>数据源：{escape(input_name)}（{data['csvCount']} 个 CSV）；生成脚本：build_vintage_dashboard.py；生成时间：{escape(generated_at)}。</li>
  </ul>
</footer>
"""


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WageGo 风险监控看板</title>
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
    --c3: #008300;
    --ok: #008300;
    --warn: #9a6700;
    --bad: #b3261e;
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
      --c3: #008300;
      --ok: #4caf50;
      --warn: #e0a000;
      --bad: #ef6b62;
      --ring: rgba(255,255,255,0.10);
    }
  }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  .scope-bar {
    display: flex; align-items: center; flex-wrap: wrap;
    gap: 10px 14px; margin: 18px 0 0;
  }
  .scope-label { color: var(--muted); font-size: 11.5px; }
  .scope-btns {
    display: inline-flex; border: 1px solid var(--ring);
    border-radius: 999px; overflow: hidden; background: var(--surface);
  }
  .scope-btn {
    appearance: none; border: 0; background: transparent;
    color: var(--ink-2); font: inherit; font-size: 13px; font-weight: 600;
    padding: 7px 20px; cursor: pointer;
  }
  .scope-btn + .scope-btn { border-left: 1px solid var(--ring); }
  .scope-btn:hover { background: var(--page); }
  .scope-btn.on { background: var(--seg-color); color: #fff; }
  .scope-hint { color: var(--ink-2); font-size: 12px; }
  body {
    margin: 0;
    padding: 36px 20px 52px;
    background: var(--page);
    color: var(--ink);
    font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  main { max-width: 1120px; margin: 0 auto; }
  .hero {
    display: flex; justify-content: space-between; align-items: flex-end;
    gap: 24px; margin-bottom: 4px;
  }
  .eyebrow {
    margin: 0 0 5px; color: var(--muted); font-size: 10.5px;
    letter-spacing: .10em; text-transform: uppercase;
  }
  h1 { font-size: 30px; line-height: 1.25; margin: 0 0 5px; }
  .sub { color: var(--ink-2); margin: 0; font-size: 14px; }
  .card {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 16px 18px 11px; margin: 13px 0;
  }
  .card h2 { font-size: 17px; margin: 0 0 1px; }
  .card h2 .tag {
    display: inline-block; margin-left: 7px; padding: 1px 7px;
    border: 1px solid var(--ring); border-radius: 999px;
    background: var(--page); color: var(--ink-2);
    font-size: 10.5px; font-weight: 500; vertical-align: 2px;
    cursor: help;
  }
  .card h2 .sample-tag {
    border-color: var(--axis); background: var(--grid); color: var(--ink);
  }
  .desc { color: var(--ink-2); font-size: 12.5px; margin: 0 0 6px; }
  .kpis {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 8px; margin: 8px 0 10px;
  }
  .kpi {
    background: var(--page); border: 1px solid var(--grid);
    border-radius: 8px; padding: 8px 10px;
  }
  .kpi span { display: block; color: var(--muted); font-size: 10.5px; }
  .kpi b {
    display: block; font-size: 18px; line-height: 1.35;
    font-variant-numeric: tabular-nums;
  }
  .scope-meta {
    display: flex; flex-wrap: wrap; gap: 5px 18px;
    margin: 6px 0 7px; padding: 7px 10px;
    background: var(--page); border: 1px solid var(--grid);
    border-left: 3px solid var(--axis); border-radius: 7px;
    color: var(--ink-2); font-size: 11.5px; line-height: 1.55;
  }
  .scope-meta .scope-item { display: flex; gap: 7px; flex: 1 1 460px; min-width: 0; }
  .scope-meta b {
    flex: none; align-self: flex-start; color: var(--ink); font-weight: 600;
    font-size: 11px; line-height: 1.6; white-space: nowrap;
    border-right: 1px solid var(--axis); padding-right: 7px;
  }
  .chart-wrap { position: relative; margin: 3px 0 2px; }
  .chart-wrap svg { display: block; width: 100%; height: auto; }
  .legend {
    display: flex; flex-wrap: wrap; gap: 16px;
    font-size: 12px; color: var(--ink-2); margin: 4px 0 0 2px;
  }
  .legend i {
    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
    margin-right: 6px; vertical-align: -1px;
  }
  .legend i.dash {
    width: 16px; height: 0; border-radius: 0; border-top: 2px dashed var(--muted);
    vertical-align: 3px;
  }
  .legend i.band {
    width: 14px; height: 8px; border-radius: 2px; opacity: .35;
  }
  .legend i.bar {
    width: 10px; height: 10px; border-radius: 2px; opacity: .65;
  }
  .chart-head { display: flex; justify-content: flex-end; margin: -2px 0 2px; }
  .seg {
    display: inline-flex; border: 1px solid var(--ring);
    border-radius: 999px; overflow: hidden;
  }
  .seg button {
    appearance: none; border: 0; background: transparent;
    color: var(--muted); font: inherit; font-size: 11.5px;
    padding: 4px 11px; cursor: pointer;
  }
  .seg button.on { background: var(--ink); color: var(--surface); }
  .tip {
    position: absolute; z-index: 2; pointer-events: none; display: none;
    transform: translate(-50%, -115%);
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 8px; box-shadow: 0 4px 14px rgba(0,0,0,0.12);
    padding: 7px 10px; font-size: 12px; line-height: 1.5;
    white-space: normal; max-width: 290px; color: var(--ink);
  }
  .tip b { font-variant-numeric: tabular-nums; }
  .tip span { color: var(--ink-2); }
  .tip i {
    display: inline-block; width: 8px; height: 8px; border-radius: 50%;
    margin-right: 5px; vertical-align: -1px;
  }
  .tip.down { transform: translate(-50%, 12px); }
  .table-wrap { overflow-x: auto; }
  table {
    width: 100%; border-collapse: collapse; font-size: 13px;
    font-variant-numeric: tabular-nums;
  }
  th, td { text-align: right; padding: 7px 9px; border-bottom: 1px solid var(--grid); }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--muted); font-weight: 500; font-size: 11.5px; }
  tbody tr:last-child td { border-bottom: none; }
  table.compact { font-size: 12.5px; }
  table.compact th, table.compact td { padding: 6px 7px; }
  td.dim { color: var(--muted); }
  td.soft { color: var(--ink-2); }
  td.watch { color: var(--warn); font-weight: 600; }
  td.alert { color: var(--bad); font-weight: 600; }
  td.range { color: var(--ink-2); font-size: 11.5px; white-space: nowrap; }
  td .n { display: block; color: var(--muted); font-size: 10.5px; line-height: 1.3; }
  sup { font-size: 9px; color: var(--c2); margin-left: 1px; }
  .subhead {
    color: var(--muted); font-size: 11.5px; font-weight: 600;
    margin: 10px 1px 3px;
  }
  .note {
    color: var(--muted); font-size: 12px; line-height: 1.65;
    margin: 8px 2px 4px;
  }
  .split {
    display: grid; grid-template-columns: 1fr 1fr;
    gap: 18px; align-items: start;
  }
  .split > div { min-width: 0; }
  .quality {
    display: grid; grid-template-columns: repeat(3, 1fr);
    gap: 12px; margin-top: 8px;
  }
  .quality > div {
    border: 1px solid var(--grid); border-radius: 10px;
    padding: 10px 12px;
  }
  .quality .q-label { display: block; color: var(--muted); font-size: 11.5px; }
  .quality b {
    display: block; font-size: 20px; line-height: 1.3;
    margin: 3px 0 2px; font-variant-numeric: tabular-nums;
  }
  .quality span:last-child { display: block; color: var(--ink-2); font-size: 11.5px; line-height: 1.5; }
  .foot { margin-top: 18px; }
  ul.notes { margin: 0; padding-left: 20px; color: var(--ink-2); font-size: 12px; }
  ul.notes li { margin: 4px 0; }
  @media (max-width: 900px) {
    .split { grid-template-columns: 1fr; }
    .quality { grid-template-columns: 1fr; }
  }
  @media (max-width: 560px) {
    h1 { font-size: 24px; }
  }
</style>
</head>
<body>
<main>
__HEADER__
__SCOPE_BAR__
__FPD_CARD__
__WEEK_CARD__
__FUNNEL_CARD__
__SCORE_CARD__
__CREDIT_DIST_CARD__
__STABILITY_CARD__
__QUALITY_CARD__
__FOOTER__
</main>
<script>
const DATA = __DATA_JSON__;
const NS = 'http://www.w3.org/2000/svg';
const fmtRate = v => (v == null ? '—' : v.toFixed(2) + '%');
const fmtInt = n => (n == null ? '—' : n.toLocaleString('en-US'));

const state = { segment: 'ALL', weekMode: 'count', aucWindow: String(DATA.aucWindowDefault) };
const sampleTagBySegment = {
  ALL: '样本：整体发标成交样本',
  New: '样本：新客发标成交样本',
  Old: '样本：老客发标成交样本'
};
const segData = () => DATA.segments[state.segment];
const isAllSeg = () => state.segment === 'ALL';

function wilsonCi(obs, ratePct, z = 1.96) {
  if (!obs || ratePct == null) return null;
  const n = obs;
  const p = ratePct / 100;
  const denom = 1 + z * z / n;
  const center = (p + z * z / (2 * n)) / denom;
  const half = z * Math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom;
  return { lo: Math.max(0, (center - half) * 100), hi: Math.min(100, (center + half) * 100) };
}

function svgEl(svg, tag, attrs, text) {
  const node = document.createElementNS(NS, tag);
  for (const key in attrs) node.setAttribute(key, attrs[key]);
  if (text != null) node.textContent = text;
  svg.appendChild(node);
  return node;
}

function clearSvg(svg) {
  while (svg.firstChild) svg.removeChild(svg.firstChild);
}

function makeLineChart(svgId, tipId, cfg) {
  const svg = document.getElementById(svgId);
  const tip = document.getElementById(tipId);
  const { width, height, margin, labels, series, yMax, yTicks, xLabel, yLabel, volume, ciSeries, yFormat } = cfg;
  const fmtY = yFormat || (value => value + '%');
  const innerW = width - margin.l - margin.r;
  const innerH = height - margin.t - margin.b;
  const n = labels.length;
  const x = i => (n === 1 ? margin.l + innerW / 2 : margin.l + i / (n - 1) * innerW);
  const y = v => margin.t + (1 - v / yMax) * innerH;
  clearSvg(svg);

  yTicks.forEach(v => {
    svgEl(svg, 'line', {
      x1: margin.l, x2: width - margin.r, y1: y(v), y2: y(v),
      stroke: v === 0 ? 'var(--axis)' : 'var(--grid)', 'stroke-width': 1
    });
    svgEl(svg, 'text', {
      x: margin.l - 8, y: y(v) + 1, 'text-anchor': 'end',
      fill: 'var(--muted)', 'font-size': 11.5
    }, fmtY(v));
  });

  if (yLabel) {
    const cy = margin.t + innerH / 2;
    svgEl(svg, 'text', {
      x: 13, y: cy, 'text-anchor': 'middle',
      transform: `rotate(-90 13 ${cy})`,
      fill: 'var(--muted)', 'font-size': 11.5
    }, yLabel);
  }

  labels.forEach((label, i) => {
    svgEl(svg, 'text', {
      x: x(i), y: height - margin.b + 18,
      'text-anchor': 'middle', fill: 'var(--muted)', 'font-size': 11.5
    }, label);
  });
  svgEl(svg, 'text', {
    x: width - margin.r, y: height - 6, 'text-anchor': 'end',
    fill: 'var(--muted)', 'font-size': 11.5
  }, xLabel);

  if (volume && volume.values) {
    const values = volume.values.filter(value => value != null);
    if (values.length) {
      const maxVolume = Math.max(...values);
      const volumeHeight = innerH * 0.28;
      const barWidth = Math.min(46, innerW / n * 0.55);
      const yVolume = value => margin.t + innerH - (value / maxVolume) * volumeHeight;
      volume.values.forEach((value, i) => {
        if (value == null) return;
        const left = Math.max(margin.l, Math.min(width - margin.r - barWidth, x(i) - barWidth / 2));
        svgEl(svg, 'rect', {
          x: left, y: yVolume(value), width: barWidth, height: margin.t + innerH - yVolume(value),
          fill: 'var(--grid)', opacity: 0.65, rx: 2
        });
      });
      svgEl(svg, 'text', {
        x: margin.l + 2, y: margin.t + innerH - volumeHeight - 4,
        fill: 'var(--muted)', 'font-size': 10
      }, '放款量');
    }
  }

  if (ciSeries != null) {
    const target = series[ciSeries];
    const band = [];
    target.points.forEach((point, i) => {
      if (!point || point.rate == null || !point.obs) return;
      const ci = wilsonCi(point.obs, point.rate);
      if (ci) band.push({ i, lo: ci.lo, hi: ci.hi });
    });
    if (band.length > 1) {
      const top = band.map(item => `${x(item.i)},${y(item.hi)}`).join(' L');
      const bottom = band.slice().reverse().map(item => `${x(item.i)},${y(item.lo)}`).join(' L');
      svgEl(svg, 'path', {
        d: `M${top} L${bottom} Z`,
        fill: target.color, opacity: 0.13, stroke: 'none'
      });
    }
  }

  series.forEach(s => {
    for (let i = 0; i < n - 1; i++) {
      const a = s.points[i], b = s.points[i + 1];
      if (!a || !b) continue;
      const dashed = Boolean(s.dash || a.partial || b.partial);
      svgEl(svg, 'path', {
        d: `M${x(i)},${y(a.rate)} L${x(i + 1)},${y(b.rate)}`,
        fill: 'none', stroke: s.color, 'stroke-width': s.width || 2,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round',
        'stroke-dasharray': dashed ? '5 4' : ''
      });
    }
    s.points.forEach((p, i) => {
      if (!p) return;
      svgEl(svg, 'circle', {
        cx: x(i), cy: y(p.rate), r: 4.5,
        fill: p.partial ? 'var(--surface)' : s.color,
        stroke: p.partial ? s.color : 'var(--surface)',
        'stroke-width': 2
      });
    });
  });

  (cfg.directLabels || []).forEach(label => {
    const s = series[label.series];
    const p = s.points[label.index];
    if (!p) return;
    svgEl(svg, 'text', {
      x: x(label.index) + (label.dx || 0),
      y: y(p.rate) + (label.dy || 0),
      'text-anchor': label.anchor || 'middle',
      fill: 'var(--ink)', 'font-size': 11.5, 'font-weight': 600
    }, label.text);
  });

  const cross = svgEl(svg, 'line', {
    y1: margin.t, y2: margin.t + innerH, stroke: 'var(--axis)',
    'stroke-width': 1, opacity: 0, 'pointer-events': 'none'
  });
  const dots = series.map(s => svgEl(svg, 'circle', {
    r: 6, fill: s.color, stroke: 'var(--surface)', 'stroke-width': 2,
    opacity: 0, 'pointer-events': 'none'
  }));
  const hit = svgEl(svg, 'rect', {
    x: margin.l - 12, y: margin.t, width: innerW + 24, height: innerH,
    fill: 'transparent'
  });

  hit.addEventListener('mousemove', event => {
    const box = svg.getBoundingClientRect();
    const sx = (event.clientX - box.left) / box.width * width;
    let index = 0;
    let best = Infinity;
    for (let i = 0; i < n; i++) {
      const distance = Math.abs(x(i) - sx);
      if (distance < best) { best = distance; index = i; }
    }
    cross.setAttribute('x1', x(index));
    cross.setAttribute('x2', x(index));
    cross.setAttribute('opacity', 1);
    series.forEach((s, seriesIndex) => {
      const point = s.points[index];
      if (point) {
        dots[seriesIndex].setAttribute('cx', x(index));
        dots[seriesIndex].setAttribute('cy', y(point.rate));
        dots[seriesIndex].setAttribute('opacity', 1);
      } else {
        dots[seriesIndex].setAttribute('opacity', 0);
      }
    });
    tip.innerHTML = cfg.tooltip(index);
    const scale = box.width / width;
    const topY = Math.min(...series.map(s => s.points[index] ? y(s.points[index].rate) : Infinity));
    tip.classList.toggle('down', topY * scale < 110);
    tip.style.left = Math.max(150, Math.min(box.width - 150, x(index) * scale)) + 'px';
    tip.style.top = topY * scale + 'px';
    tip.style.display = 'block';
  });

  hit.addEventListener('mouseleave', () => {
    cross.setAttribute('opacity', 0);
    dots.forEach(dot => dot.setAttribute('opacity', 0));
    tip.style.display = 'none';
  });
}

function renderFpd() {
  const keys = isAllSeg() ? ['ALL', 'New', 'Old'] : [state.segment, 'ALL'];
  const fpdSeries = keys.map(key => {
    const curve = DATA.fpdCurves[key];
    const reference = !isAllSeg() && key === 'ALL';
    return {
      name: reference ? '整体（参考）' : curve.name,
      key,
      color: curve.color,
      points: curve.points,
      dash: reference ? '5 4' : '',
      width: reference ? 1.8 : 2
    };
  });
  const fpd15Index = DATA.fpdLabels.indexOf('FPD15');
  const fpd30Index = DATA.fpdLabels.indexOf('FPD30');
  const fpdSelectedAbove = !isAllSeg() && fpd15Index >= 0 && fpdSeries[0].points[fpd15Index].rate >= fpdSeries[1].points[fpd15Index].rate;
  const fpdMaxRate = Math.max(...fpdSeries.flatMap(series => series.points.map(point => point && point.rate != null ? point.rate : 0)));
  const fpdYMax = Math.max(25, Math.ceil(fpdMaxRate / 5) * 5);
  const fpdYTicks = [];
  for (let value = 0; value <= fpdYMax; value += 5) fpdYTicks.push(value);
  makeLineChart('fpdCurve', 'fpdTip', {
    width: 1040, height: 300, margin: { t: 30, r: 130, b: 46, l: 56 },
    labels: DATA.fpdLabels,
    series: fpdSeries,
    yMax: fpdYMax, yTicks: fpdYTicks, xLabel: '观察窗口', yLabel: '笔数坏率',
    directLabels: fpdSeries.map((series, index) => ({
      series: index, index: fpd15Index,
      text: `${series.name} ${fmtRate(series.points[fpd15Index].rate)}`,
      dx: 0,
      dy: isAllSeg() ? (index === 1 ? -12 : 18) : (index === 0 ? (fpdSelectedAbove ? -14 : 20) : (fpdSelectedAbove ? 20 : -14)),
      anchor: 'middle'
    })),
    tooltip: index => {
      const rows = fpdSeries.map(series => {
        const point = series.points[index];
        return `<span><i style="background:${series.color}"></i>${series.name} <b>${fmtRate(point.rate)}</b> · n=${fmtInt(point.obs)}</span>`;
      }).join('<br>');
      const age = index === fpd30Index
        ? `<br><span>30 天成熟：${fpdSeries.map(series => `${series.name} ${Math.round(series.points[fpd30Index].maturity * 100)}%`).join(' · ')}</span>`
        : '';
      return `<b>${DATA.fpdLabels[index]} · 笔数坏率</b><br>${rows}${age}`;
    }
  });
}

const lastPointIndex = points => {
  for (let i = points.length - 1; i >= 0; i--) if (points[i]) return i;
  return -1;
};

function renderWeekChart(mode) {
  const amount = mode === 'amount';
  const chart = segData().weekChart;
  const countSeries = [
    { name: 'FPD3', key: 'fpd3', color: 'var(--muted)', points: chart.fpd3, dash: '5 4', width: 1.8 },
    { name: 'FPD7', key: 'fpd7', color: 'var(--c3)', points: chart.fpd7, dash: '5 4', width: 1.8 },
    { name: 'FPD15', key: 'fpd15', color: 'var(--c1)', points: chart.fpd15, width: 2 }
  ];
  const amountSeries = [
    { name: 'FPD3 金额', key: 'fpd3Amt', color: 'var(--muted)', points: chart.fpd3Amt, dash: '5 4', width: 1.8 },
    { name: 'FPD7 金额', key: 'fpd7Amt', color: 'var(--c3)', points: chart.fpd7Amt, dash: '5 4', width: 1.8 },
    { name: 'FPD15 金额', key: 'fpd15Amt', color: 'var(--c1)', points: chart.fpd15Amt, width: 2 }
  ];
  if (chart.fpd1 && chart.fpd1.some(point => point)) {
    countSeries.push({ name: 'FPD1', key: 'fpd1', color: 'var(--c2)', points: chart.fpd1, dash: '2 3', width: 1.4 });
  }
  if (chart.fpd1Amt && chart.fpd1Amt.some(point => point)) {
    amountSeries.push({ name: 'FPD1 金额', key: 'fpd1Amt', color: 'var(--c2)', points: chart.fpd1Amt, dash: '2 3', width: 1.4 });
  }
  const series = amount ? amountSeries : countSeries;
  const weekMaxRate = Math.max(...series.flatMap(item => (item.points || []).map(point => point && point.rate != null ? point.rate : 0)));
  const weekYMax = Math.max(25, Math.ceil(weekMaxRate / 5) * 5);
  const weekYTicks = [];
  for (let value = 0; value <= weekYMax; value += 5) weekYTicks.push(value);
  const last15 = lastPointIndex(chart.fpd15);
  const last7 = lastPointIndex(chart.fpd7);
  const last3 = lastPointIndex(chart.fpd3);
  const lastAmt3 = lastPointIndex(chart.fpd3Amt);
  const lastAmt7 = lastPointIndex(chart.fpd7Amt);
  const lastAmt15 = lastPointIndex(chart.fpd15Amt);
  const directLabels = amount ? [
    {
      series: 2, index: lastAmt15,
      text: `FPD15 金额 ${fmtRate(chart.fpd15Amt[lastAmt15].rate)}${chart.fpd15Amt[lastAmt15].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 1, index: lastAmt7,
      text: `FPD7 金额 ${fmtRate(chart.fpd7Amt[lastAmt7].rate)}${chart.fpd7Amt[lastAmt7].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 0, index: lastAmt3,
      text: `FPD3 金额 ${fmtRate(chart.fpd3Amt[lastAmt3].rate)}${chart.fpd3Amt[lastAmt3].partial ? '†' : ''}`,
      dx: -8, dy: -26, anchor: 'end'
    }
  ] : [
    {
      series: 2, index: last15,
      text: `FPD15 ${fmtRate(chart.fpd15[last15].rate)}${chart.fpd15[last15].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 1, index: last7,
      text: `FPD7 ${fmtRate(chart.fpd7[last7].rate)}${chart.fpd7[last7].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 0, index: last3,
      text: `FPD3 ${fmtRate(chart.fpd3[last3].rate)}${chart.fpd3[last3].partial ? '†' : ''}`,
      dx: -8, dy: -10, anchor: 'end'
    }
  ];
  makeLineChart('weekChart', 'weekTip', {
    width: 1040, height: 300, margin: { t: 30, r: 100, b: 46, l: 56 },
    labels: chart.labels,
    series,
    volume: { values: chart.fpd3.map(point => point ? point.obs : null) },
    ciSeries: amount ? null : 2,
    yMax: weekYMax, yTicks: weekYTicks, xLabel: '放款周（2026）', yLabel: amount ? '金额坏率' : '笔数坏率',
    directLabels,
    tooltip: index => {
      const fpd3 = chart.fpd3[index];
      const fpd7 = chart.fpd7[index];
      const fpd15 = chart.fpd15[index];
      if (amount) {
        const parts = [`<b>${chart.weeks[index]} · 金额坏率</b>`];
        const amt1 = chart.fpd1Amt[index];
        const amt3 = chart.fpd3Amt[index];
        const amt7 = chart.fpd7Amt[index];
        const amt15 = chart.fpd15Amt[index];
        if (amt1) parts.push(`<span><i style="background:var(--c2)"></i>FPD1 金额 <b>${fmtRate(amt1.rate)}</b> · n=${fmtInt(amt1.obs)}${amt1.partial ? ' · 周未完整' : ''}</span>`);
        parts.push(amt3
          ? `<span><i style="background:var(--muted)"></i>FPD3 金额 <b>${fmtRate(amt3.rate)}</b> · n=${fmtInt(amt3.obs)}${amt3.partial ? ' · 周未完整' : ''}</span>`
          : '<span>FPD3 金额无数据</span>');
        parts.push(amt7
          ? `<span><i style="background:var(--c3)"></i>FPD7 金额 <b>${fmtRate(amt7.rate)}</b> · n=${fmtInt(amt7.obs)} · ${Math.round(amt7.maturity * 100)}% 成熟${amt7.partial ? '*' : ''}</span>`
          : '<span>FPD7 金额坏率尚未达到 70% 成熟</span>');
        parts.push(amt15
          ? `<span><i style="background:var(--c1)"></i>FPD15 金额 <b>${fmtRate(amt15.rate)}</b> · n=${fmtInt(amt15.obs)} · ${Math.round(amt15.maturity * 100)}% 成熟${amt15.partial ? '*' : ''}</span>`
          : '<span>FPD15 金额坏率尚未达到 70% 成熟</span>');
        if (fpd15) parts.push(`<span>笔数坏率 FPD15 ${fmtRate(fpd15.rate)}（n=${fmtInt(fpd15.obs)}）</span>`);
        return parts.join('<br>');
      }
      const parts = [`<b>${chart.weeks[index]} · 笔数坏率</b>`];
      const fpd1 = chart.fpd1[index];
      if (fpd1) parts.push(`<span><i style="background:var(--c2)"></i>FPD1 <b>${fmtRate(fpd1.rate)}</b> · n=${fmtInt(fpd1.obs)}${fpd1.partial ? ' · 周未完整' : ''}</span>`);
      if (fpd3) parts.push(`<span><i style="background:var(--muted)"></i>FPD3 <b>${fmtRate(fpd3.rate)}</b> · n=${fmtInt(fpd3.obs)}${fpd3.partial ? ' · 周未完整' : ''}</span>`);
      if (fpd7) parts.push(`<span><i style="background:var(--c3)"></i>FPD7 <b>${fmtRate(fpd7.rate)}</b> · n=${fmtInt(fpd7.obs)} · ${Math.round(fpd7.maturity * 100)}% 成熟${fpd7.partial ? '*' : ''}</span>`);
      else {
        const low7 = chart.fpd7Low[index];
        parts.push(low7
          ? `<span><i style="background:var(--c3)"></i>FPD7 <b>${fmtRate(low7.rate)}</b> · n=${fmtInt(low7.obs)} · ${Math.round(low7.maturity * 100)}% 成熟（低于 70%，未入图）</span>`
          : '<span>FPD7 尚未达到 70% 成熟</span>');
      }
      if (fpd15) {
        const ci = wilsonCi(fpd15.obs, fpd15.rate);
        parts.push(`<span><i style="background:var(--c1)"></i>FPD15 <b>${fmtRate(fpd15.rate)}</b> · n=${fmtInt(fpd15.obs)} · ${Math.round(fpd15.maturity * 100)}% 成熟${fpd15.partial ? '*' : ''}${ci ? ` · 95% CI ${fmtRate(ci.lo)}–${fmtRate(ci.hi)}` : ''}</span>`);
      }
      else {
        const low = chart.fpd15Low[index];
        parts.push(low
          ? `<span><i style="background:var(--muted)"></i>FPD15 <b>${fmtRate(low.rate)}</b> · n=${fmtInt(low.obs)} · ${Math.round(low.maturity * 100)}% 成熟（低于 70%，未入图）</span>`
          : '<span>FPD15 尚未达到 70% 成熟</span>');
      }
      return parts.join('<br>');
    }
  });
  document.querySelectorAll('.week-legend-count').forEach(el => { el.hidden = amount; });
  document.querySelectorAll('.week-legend-amount').forEach(el => { el.hidden = !amount; });
}

const weekButtons = document.querySelectorAll('[data-week-mode]');
weekButtons.forEach(button => {
  button.addEventListener('click', () => {
    weekButtons.forEach(item => {
      const active = item === button;
      item.classList.toggle('on', active);
      item.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
    state.weekMode = button.dataset.weekMode;
    renderWeekChart(state.weekMode);
  });
});

const creditBinButtons = document.querySelectorAll('[data-credit-bins]');
creditBinButtons.forEach(button => {
  button.addEventListener('click', () => {
    creditBinButtons.forEach(item => {
      const active = item === button;
      item.classList.toggle('on', active);
      item.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
    document.querySelectorAll('[data-credit-table]').forEach(table => {
      table.hidden = table.dataset.creditTable !== button.dataset.creditBins;
    });
  });
});

function renderScoreChart() {
  const keys = isAllSeg() ? ['ALL', 'New', 'Old'] : [state.segment, 'ALL'];
  const scoreSeries = keys.map(key => {
    const curve = DATA.scoreCurves[key];
    const reference = !isAllSeg() && key === 'ALL';
    return {
      name: reference ? '整体（参考）' : curve.name,
      key,
      color: curve.color,
      points: curve.points,
      dash: reference ? '5 4' : '',
      width: reference ? 1.8 : 2
    };
  });
  const maxRate = Math.max(...scoreSeries.flatMap(series => series.points.map(point => point.rate)));
  const yMax = Math.max(20, Math.ceil(maxRate / 5) * 5);
  const tickStep = yMax <= 25 ? 5 : 10;
  const yTicks = [];
  for (let value = 0; value <= yMax; value += tickStep) yTicks.push(value);
  const selectedAbove = !isAllSeg() && scoreSeries[0].points[4].rate >= scoreSeries[1].points[4].rate;
  makeLineChart('scoreChart', 'scoreTip', {
    width: 1040, height: 300, margin: { t: 30, r: 135, b: 46, l: 56 },
    labels: ['1档', '2档', '3档', '4档', '5档'],
    series: scoreSeries,
    yMax, yTicks, xLabel: '模型分分档（低 → 高）', yLabel: '笔数坏率',
    directLabels: scoreSeries.map((series, index) => ({
      series: index, index: 4,
      text: `${series.name} ${fmtRate(series.points[4].rate)}`,
      dx: 8,
      dy: isAllSeg() ? -10 : (index === 0 ? (selectedAbove ? -14 : 20) : (selectedAbove ? 20 : -14)),
      anchor: 'start'
    })),
    tooltip: index => {
      const base = DATA.scoreCurves.ALL.points[index];
      const rows = scoreSeries.map(series => {
        const point = series.points[index];
        return `<span><i style="background:${series.color}"></i>${series.name} <b>${fmtRate(point.rate)}</b> · n=${fmtInt(point.obs)}</span>`;
      }).join('<br>');
      return `<b>${['1档', '2档', '3档', '4档', '5档'][index]} · ${base.min.toFixed(4)} ~ ${base.max.toFixed(4)} · 笔数坏率</b><br>${rows}`;
    }
  });
}

function renderAucChart() {
  const view = segData();
  const windowKey = state.aucWindow;
  const windowLabel = DATA.windowLabels[windowKey] || ('FPD' + windowKey);
  const chart = (view.aucCharts && view.aucCharts[windowKey]) || { points: [], weeks: [], labels: [] };
  const aucPoints = chart.points || [];
  const legend = document.getElementById('aucLegend');
  if (aucPoints.length < 2) {
    const svg = document.getElementById('aucChart');
    if (svg) clearSvg(svg);
    if (legend) legend.innerHTML = `<span>${windowLabel} 暂无可展示的周度排序力样本</span>`;
    return;
  }
  const segColor = isAllSeg() ? 'var(--c1)' : view.color;
  const aucSeries = [
    {
      name: 'AUC', key: 'auc', color: segColor, width: 2,
      points: aucPoints.map(point => ({
        rate: point.auc, obs: point.obs,
        maturity: point.maturity, partial: point.partial
      }))
    },
    {
      name: 'KS', key: 'ks', color: 'var(--c3)', width: 1.8, dash: '5 4',
      points: aucPoints.map(point => point.ks == null ? null : ({
        rate: point.ks, obs: point.obs,
        maturity: point.maturity, partial: point.partial
      }))
    }
  ];
  let overallSeries = null;
  let overallByWeek = null;
  if (!isAllSeg() && DATA.aucCharts && DATA.aucCharts[windowKey] && DATA.aucCharts[windowKey].points.length > 1) {
    overallByWeek = new Map(DATA.aucCharts[windowKey].points.map(point => [point.week, point]));
    overallSeries = {
      name: '整体 AUC（参考）', key: 'overallAuc', color: 'var(--ink-2)', width: 1.8, dash: '5 4',
      points: chart.weeks.map(week => {
        const point = overallByWeek.get(week);
        return point ? {
          rate: point.auc, obs: point.obs,
          maturity: point.maturity, partial: point.partial
        } : null;
      })
    };
    aucSeries.push(overallSeries);
  }
  const lastAuc = lastPointIndex(aucSeries[0].points);
  const lastKs = lastPointIndex(aucSeries[1].points);
  const aucLabels = [];
  if (lastAuc >= 0) {
    aucLabels.push({
      series: 0, index: lastAuc,
      text: `AUC ${aucPoints[lastAuc].auc.toFixed(3)}`,
      dx: 8, dy: -10, anchor: 'start'
    });
  }
  if (lastKs >= 0) {
    aucLabels.push({
      series: 1, index: lastKs,
      text: `KS ${aucPoints[lastKs].ks.toFixed(3)}`,
      dx: 8, dy: 16, anchor: 'start'
    });
  }
  if (overallSeries) {
    const lastOverall = lastPointIndex(overallSeries.points);
    if (lastOverall >= 0) {
      const overallPoint = overallByWeek.get(chart.weeks[lastOverall]);
      aucLabels.push({
        series: 2, index: lastOverall,
        text: `整体 ${overallPoint.auc.toFixed(3)}`,
        dx: 8, dy: 30, anchor: 'start'
      });
    }
  }
  makeLineChart('aucChart', 'aucTip', {
    width: 1040, height: 280, margin: { t: 30, r: 110, b: 46, l: 56 },
    labels: chart.labels,
    series: aucSeries,
    volume: { values: aucPoints.map(point => point.obs) },
    yMax: 1, yTicks: [0, 0.25, 0.5, 0.75, 1],
    yFormat: value => value.toFixed(2),
    xLabel: '放款周（2026）', yLabel: 'AUC / KS',
    directLabels: aucLabels,
    tooltip: index => {
      const point = aucPoints[index];
      const gini = point.gini == null ? '—' : point.gini.toFixed(3);
      const ks = point.ks == null ? '—' : point.ks.toFixed(3);
      let html = `<b>${point.week} · ${view.name}${windowLabel}排序力</b><br>`
        + `<span><i style="background:${segColor}"></i>AUC <b>${point.auc.toFixed(3)}</b> · Gini ${gini}</span><br>`
        + `<span><i style="background:var(--c3)"></i>KS <b>${ks}</b></span><br>`
        + `<span>n=${fmtInt(point.obs)} · 坏 ${fmtInt(point.bad)} · ${Math.round(point.maturity * 100)}% 成熟${point.partial ? '*' : ''}</span>`;
      if (overallSeries) {
        const overall = overallByWeek.get(point.week);
        if (overall) html += `<br><span><i style="background:var(--ink-2)"></i>整体 AUC <b>${overall.auc.toFixed(3)}</b></span>`;
      }
      return html;
    }
  });
  if (legend) {
    legend.innerHTML = [
      `<span><i style="background:${segColor}"></i>${view.name} AUC</span>`,
      '<span><i class="dash" style="border-top-color:var(--c3)"></i>KS</span>',
      overallSeries ? '<span><i class="dash" style="border-top-color:var(--ink-2)"></i>整体 AUC（参考）</span>' : '',
      `<span><i class="bar" style="background:var(--grid)"></i>${windowLabel} 成熟样本</span>`
    ].join('');
  }
}

function applyAucWindow(windowKey) {
  state.aucWindow = String(windowKey);
  document.querySelectorAll('[data-auc-window]').forEach(button => {
    const active = button.dataset.aucWindow === state.aucWindow;
    button.classList.toggle('on', active);
    button.setAttribute('aria-pressed', active ? 'true' : 'false');
  });
  document.querySelectorAll('[data-auc-panel]').forEach(panel => {
    panel.hidden = panel.dataset.aucPanel !== state.aucWindow;
  });
  renderAucChart();
}

function applySegment(seg) {
  state.segment = seg;
  document.querySelectorAll('[data-segment]').forEach(button => {
    const active = button.dataset.segment === seg;
    button.classList.toggle('on', active);
    button.setAttribute('aria-pressed', active ? 'true' : 'false');
  });
  document.querySelectorAll('[data-seg-panel]').forEach(panel => {
    panel.hidden = panel.dataset.segPanel !== seg;
  });
  document.querySelectorAll('[data-sample-tag]').forEach(tag => {
    tag.textContent = sampleTagBySegment[seg] || '';
  });
  const hint = document.getElementById('scopeHint');
  if (hint) hint.textContent = segData().scopeHint;
  renderFpd();
  renderWeekChart(state.weekMode);
  renderScoreChart();
  renderAucChart();
}

document.querySelectorAll('[data-segment]').forEach(button => {
  button.addEventListener('click', () => applySegment(button.dataset.segment));
});

document.querySelectorAll('[data-auc-window]').forEach(button => {
  button.addEventListener('click', () => applyAucWindow(button.dataset.aucWindow));
});

applyAucWindow(state.aucWindow);
applySegment('ALL');
</script>
</body>
</html>
"""


def render_html(data, generated_at, input_name, generated_iso):
    fpd_curves = {}
    score_curves = {}
    segments = {}
    for seg_key, seg_name, seg_color in SEGMENT_META:
        view = data["segments"][seg_key]
        windows = view["windows"]
        fpd_curves[seg_key] = {
            "name": seg_name,
            "key": seg_key,
            "color": seg_color,
            "points": [
                {
                    "rate": windows[window]["rate"],
                    "obs": windows[window]["obs"],
                    "bad": windows[window]["bad"],
                    "partial": window == 30,
                    "maturity": view["fpd30Maturity"] if window == 30 else None,
                }
                for window in data["windows"]
            ],
        }
        score_curves[seg_key] = {
            "name": seg_name,
            "key": seg_key,
            "color": seg_color,
            "points": [view["score"][q] for q in range(1, 6)],
        }
        segments[seg_key] = {
            "name": seg_name,
            "color": seg_color,
            "scopeHint": view["scopeHint"],
            "weekChart": view["weekChart"],
            "aucCharts": view["aucCharts"],
            "psiByWeek": view["psiByWeek"],
            "latestWeek": view["latestWeek"]["week"],
        }

    chart_data = {
        "fpdLabels": [WINDOW_LABELS[window] for window in data["windows"]],
        "fpdCurves": fpd_curves,
        "scoreCurves": score_curves,
        "segments": segments,
        "aucCharts": data["aucCharts"],
        "aucWindows": data["aucWindows"],
        "aucWindowDefault": data["aucWindowDefault"],
        "windowLabels": {
            str(window): WINDOW_LABELS[window] for window in data["aucWindows"]
        },
    }
    data_json = json.dumps(chart_data, ensure_ascii=False).replace("</", "<\\/")
    html = HTML_TEMPLATE
    replacements = {
        "__HEADER__": header_html(),
        "__SCOPE_BAR__": scope_bar_html(data),
        "__FPD_CARD__": fpd_card_html(data),
        "__WEEK_CARD__": week_card_html(data),
        "__FUNNEL_CARD__": funnel_card_html(data),
        "__SCORE_CARD__": score_card_html(data),
        "__CREDIT_DIST_CARD__": credit_dist_card_html(data),
        "__STABILITY_CARD__": stability_card_html(data),
        "__QUALITY_CARD__": quality_card_html(data),
        "__FOOTER__": footer_html(data, generated_at, input_name),
        "__DATA_JSON__": data_json,
    }
    for key, value in replacements.items():
        html = html.replace(key, value)
    return html


def main(argv=None):
    parser = argparse.ArgumentParser(description="从 vintage_data.zip 生成 WageGo 风险监控看板。")
    parser.add_argument("--input", default=str(DEFAULT_INPUT), help="vintage_data.zip 或存有 vintage_*.csv 的目录")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出 HTML 路径")
    args = parser.parse_args(argv)

    input_path = Path(args.input).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    if not input_path.exists():
        parser.error(f"输入不存在：{input_path}")

    try:
        raw = read_csvs(input_path)
        data = build_data(raw)
    except ValueError as exc:
        parser.error(str(exc))

    generated_dt = datetime.now().astimezone()
    generated_at = generated_dt.strftime("%Y-%m-%d %H:%M %Z")
    generated_iso = generated_dt.isoformat(timespec="seconds")
    html = render_html(data, generated_at, input_path.name, generated_iso)
    output_path.write_text(html, encoding="utf-8")
    print(f"已生成：{output_path}")
    print(f"图表周：{data['chartWeeks'][0]['week']} ~ {data['latestWeek']['week']}（{len(data['chartWeeks'])} 周）")
    print(f"FPD15 最新可用周：{data['latest']['week']}（{fmt_pct0(data['latest']['fpd15Maturity'])} 成熟）")
    print(f"整体 FPD15：{fmt_rate(data['overallBy'][15]['rate'])}；模型 5档/1档：{data['lift']['ALL']:.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
