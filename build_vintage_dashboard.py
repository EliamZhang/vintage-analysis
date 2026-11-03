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

WINDOWS = (3, 7, 14, 15, 30)
WINDOW_LABELS = {3: "FPD3", 7: "FPD7", 14: "FPD14", 15: "FPD15", 30: "FPD30"}
REQUIRED_FILES = (
    "vintage_01_fpd_overall.csv",
    "vintage_02_fpd15_vs_fpd30.csv",
    "vintage_03_user_type.csv",
    "vintage_04_week.csv",
    "vintage_05a_score_coverage.csv",
    "vintage_05b_score_quintile.csv",
    "vintage_06_score_quintile_week.csv",
    "vintage_07_application_rank.csv",
)
# 新增块允许旧 zip 缺失；缺失时对应卡片不渲染，看板仍可生成。
OPTIONAL_FILES = (
    "vintage_08_weekly_auc.csv",
    "vintage_09_week_user_type.csv",
    "vintage_10_auc_month_user_type.csv",
)


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

    week_rows = {}
    for row in raw["vintage_04_week.csv"]:
        week = row["week_start"]
        window = to_int(row["window_days"])
        week_rows.setdefault(week, {})[window] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "amtRate": to_float(row["bad_rate_amt_pct"]),
        }

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
        raise ValueError("模型分五分位缺少 ALL / New / Old 分组")

    score_week = {}
    for row in raw["vintage_06_score_quintile_week.csv"]:
        week = row["week_start"]
        q = to_int(row["q"])
        score_week.setdefault(week, {})[q] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
        }
    score_week_all = sorted(week for week in score_week if week >= chart_weeks[0]["week"])
    score_week_weeks = [
        week
        for week in score_week_all
        if min(score_week[week][q]["obs"] for q in range(1, 6)) >= 200
    ]
    if score_week_all and score_week_all[-1] not in score_week_weeks:
        score_week_weeks.append(score_week_all[-1])

    weekly_auc = {}
    for row in raw.get("vintage_08_weekly_auc.csv") or []:
        weekly_auc[row["week_start"]] = {
            "week": row["week_start"],
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "auc": to_float(row["auc"]),
            "gini": to_float(row["gini"]),
            "ks": to_float(row["ks"]),
        }

    week_user = {}
    for row in raw.get("vintage_09_week_user_type.csv") or []:
        week_user.setdefault(row["week_start"], {})[row["user_type"]] = {
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "amtRate": to_float(row["bad_rate_amt_pct"]),
        }

    monthly_auc = {}
    for row in raw.get("vintage_10_auc_month_user_type.csv") or []:
        monthly_auc.setdefault(row["month_key"], {})[row["user_type"]] = {
            "month": row["month_key"],
            "userType": row["user_type"],
            "obs": to_int(row["obs_cnt"]),
            "bad": to_int(row["bad_cnt"]),
            "rate": to_float(row["bad_rate_pct"]),
            "auc": to_float(row["auc"]),
            "gini": to_float(row["gini"]),
            "ks": to_float(row["ks"]),
        }

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
        if (
            not week_item
            or week_item["incomplete"]
            or week_item["fpd15Maturity"] < 0.9
        ):
            continue
        prior = [
            item
            for item in score_week_weeks[:index]
            if weeks_by.get(item, {}).get("fpd15Maturity", 0) >= 0.9
        ][-4:]
        value = psi_value(week, prior)
        if value is not None:
            psi_by_week[week] = value

    auc_chart = {"labels": [], "weeks": [], "points": []}
    for week in sorted(weekly_auc):
        row = weekly_auc[week]
        week_item = weeks_by.get(week)
        if row["auc"] is None or (row["obs"] or 0) < 200 or not week_item:
            continue
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
                "maturity": week_item["fpd15Maturity"],
                "partial": week_item["fpd15Maturity"] < 0.9 or week_item["incomplete"],
            }
        )

    mix_chart = {"labels": [], "weeks": [], "new": [], "old": []}
    for item in chart_weeks:
        week = item["week"]
        row = week_user.get(week)
        if not row or item["fpd15Maturity"] < 0.7:
            continue
        mix_chart["labels"].append(week[5:])
        mix_chart["weeks"].append(week)
        for key, segment in (("new", "New"), ("old", "Old")):
            value = row.get(segment)
            if not value or value["rate"] is None:
                mix_chart[key].append(None)
            else:
                mix_chart[key].append(
                    {
                        "rate": value["rate"],
                        "amtRate": value["amtRate"],
                        "obs": value["obs"],
                        "bad": value["bad"],
                        "maturity": item["fpd15Maturity"],
                        "partial": item["fpd15Maturity"] < 0.9 or item["incomplete"],
                    }
                )

    rank = []
    for row in raw["vintage_07_application_rank.csv"]:
        rank.append(
            {
                "order": to_int(row["rank_order"]),
                "band": row["rank_band"],
                "userType": row["user_type"],
                "obs": to_int(row["obs_cnt"]),
                "bad": to_int(row["bad_cnt"]),
                "rate": to_float(row["bad_rate_pct"]),
            }
        )
    rank.sort(key=lambda item: item["order"])

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
        for window in WINDOWS:
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
        "labels": [WINDOW_LABELS[window] for window in WINDOWS],
        "series": [
            curve_series("整体", "ALL", "var(--ink-2)", overall_by),
            curve_series("新客", "New", "var(--c1)", user["New"]),
            curve_series("老客", "Old", "var(--c2)", user["Old"]),
        ],
    }

    week_chart = {
        "labels": [],
        "weeks": [],
        "fpd3": [],
        "fpd7": [],
        "fpd7Low": [],
        "fpd15": [],
        "fpd15Low": [],
        "fpd15Amt": [],
    }
    for item in chart_weeks:
        fpd3_row = item["windows"].get(3)
        fpd7_row = item["windows"].get(7)
        fpd15_row = item["windows"].get(15)
        week_chart["labels"].append(item["week"][5:])
        week_chart["weeks"].append(item["week"])
        week_chart["fpd3"].append(
            {
                "rate": fpd3_row["rate"],
                "obs": fpd3_row["obs"],
                "partial": item["incomplete"],
            }
            if fpd3_row
            else None
        )
        if fpd7_row and fpd7_row["maturity"] >= 0.7:
            week_chart["fpd7"].append(
                {
                    "rate": fpd7_row["rate"],
                    "obs": fpd7_row["obs"],
                    "maturity": fpd7_row["maturity"],
                    "partial": fpd7_row["maturity"] < 0.9 or item["incomplete"],
                }
            )
            week_chart["fpd7Low"].append(None)
        else:
            week_chart["fpd7"].append(None)
            week_chart["fpd7Low"].append(
                {
                    "rate": fpd7_row["rate"],
                    "obs": fpd7_row["obs"],
                    "maturity": fpd7_row["maturity"],
                }
                if fpd7_row and fpd7_row["maturity"] > 0
                else None
            )
        if fpd15_row and fpd15_row["maturity"] >= 0.7:
            week_chart["fpd15"].append(
                {
                    "rate": fpd15_row["rate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                    "partial": fpd15_row["maturity"] < 0.9,
                }
            )
            week_chart["fpd15Low"].append(None)
        else:
            week_chart["fpd15"].append(None)
            week_chart["fpd15Low"].append(
                {
                    "rate": fpd15_row["rate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                }
                if fpd15_row and fpd15_row["maturity"] > 0
                else None
            )
        if fpd15_row and fpd15_row["maturity"] >= 0.7 and fpd15_row["amtRate"] is not None:
            week_chart["fpd15Amt"].append(
                {
                    "rate": fpd15_row["amtRate"],
                    "obs": fpd15_row["obs"],
                    "maturity": fpd15_row["maturity"],
                    "partial": fpd15_row["maturity"] < 0.9,
                }
            )
        else:
            week_chart["fpd15Amt"].append(None)

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

    rank_chart = [
        {
            "label": item["band"],
            "sub": item["userType"],
            "rate": item["rate"],
            "obs": item["obs"],
            "bad": item["bad"],
        }
        for item in rank
    ]

    usable_fpd15 = [item for item in chart_weeks if item["fpd15Maturity"] >= 0.7]
    latest = usable_fpd15[-1]
    previous = usable_fpd15[-2] if len(usable_fpd15) > 1 else None
    latest_delta = (
        latest["windows"][15]["rate"] - previous["windows"][15]["rate"]
        if previous
        else None
    )
    complete_fpd15 = [item for item in chart_weeks if item["fpd15Maturity"] >= 0.9]
    def mix_total_obs(week):
        segments = week_user.get(week, {})
        return sum(segments.get(seg, {}).get("obs", 0) for seg in ("New", "Old"))

    confirmed_mix_weeks = [
        item["week"]
        for item in complete_fpd15
        if "New" in week_user.get(item["week"], {})
        and "Old" in week_user.get(item["week"], {})
        and mix_total_obs(item["week"]) >= 500
    ]
    mix_effect = None
    if len(confirmed_mix_weeks) >= 2:
        latest_mix_week = confirmed_mix_weeks[-1]
        base_weeks = confirmed_mix_weeks[:-1][-4:]

        def segment_pool(weeks_list, segment):
            obs = sum(week_user[w][segment]["obs"] for w in weeks_list)
            bad = sum(week_user[w][segment]["bad"] for w in weeks_list)
            return obs, bad

        obs_nb, bad_nb = segment_pool(base_weeks, "New")
        obs_ob, bad_ob = segment_pool(base_weeks, "Old")
        obs_nc, bad_nc = segment_pool([latest_mix_week], "New")
        obs_oc, bad_oc = segment_pool([latest_mix_week], "Old")
        total_b = obs_nb + obs_ob
        total_c = obs_nc + obs_oc
        if min(obs_nb, obs_ob, obs_nc, obs_oc) > 0:
            rn_b, ro_b = bad_nb / obs_nb * 100, bad_ob / obs_ob * 100
            rn_c, ro_c = bad_nc / obs_nc * 100, bad_oc / obs_oc * 100
            wn_b, wo_b = obs_nb / total_b, obs_ob / total_b
            wn_c, wo_c = obs_nc / total_c, obs_oc / total_c
            mix_effect = {
                "week": latest_mix_week,
                "baseWeeks": base_weeks,
                "within": wn_c * (rn_c - rn_b) + wo_c * (ro_c - ro_b),
                "mix": rn_b * (wn_c - wn_b) + ro_b * (wo_c - wo_b),
                "total": (bad_nc + bad_oc) / total_c * 100 - (bad_nb + bad_ob) / total_b * 100,
                "newShare": wn_c,
                "newShareBase": wn_b,
            }
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

    return {
        "overall": overall,
        "overallBy": overall_by,
        "user": user,
        "weeks": weeks,
        "weeksBy": weeks_by,
        "chartWeeks": chart_weeks,
        "earlyWeeks": early_weeks,
        "score": score,
        "scoreWeek": score_week,
        "scoreWeekWeeks": score_week_weeks,
        "psiByWeek": psi_by_week,
        "weeklyAuc": weekly_auc,
        "aucChart": auc_chart,
        "monthlyAuc": monthly_auc,
        "weekUser": week_user,
        "mixChart": mix_chart,
        "mixEffect": mix_effect,
        "csvCount": len(REQUIRED_FILES)
        + sum(1 for name in OPTIONAL_FILES if raw.get(name) is not None),
        "coverage": coverage,
        "rank": rank,
        "common": common,
        "fpdCurve": fpd_curve,
        "weekChart": week_chart,
        "scoreChart": score_chart,
        "rankChart": rank_chart,
        "latest": latest,
        "latestDelta": latest_delta,
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
    }


def header_html(data):
    first = data["chartWeeks"][0]["week"]
    last = data["latestWeek"]["week"]
    latest = data["latest"]
    chips = [
        "坏率口径 · 笔数",
        f"放款周 {first} ~ {last}",
        f"FPD15 最新可用周 {latest['week']}（{fmt_pct0(latest['fpd15Maturity'])} 成熟）",
        f"分数覆盖 {data['coverage']['pct']:.2f}%",
    ]
    chip_html = "".join(f'<span class="chip">{escape(chip)}</span>' for chip in chips)
    return f"""
<header class="hero">
  <div class="hero-copy">
    <p class="eyebrow">WAGEGO · RISK MONITORING</p>
    <h1>Vintage 监控看板</h1>
    <p class="sub">按放款周看首期逾期率（FPD），并用模型分分档和复借期数拆分；除标注“金额”外，坏率均为笔数口径。</p>
  </div>
  <div class="chips">{chip_html}</div>
</header>
"""


def kpi_html(data):
    fpd15 = data["overallBy"][15]
    latest = data["latest"]
    latest_rate = latest["windows"][15]["rate"]
    new15 = data["new15"]
    old15 = data["old15"]
    gap = new15["rate"] - old15["rate"]
    lift = data["lift"]["ALL"]
    q1 = data["score"]["ALL"][1]
    q5 = data["score"]["ALL"][5]
    latest_confirmed = latest["fpd15Maturity"] >= 0.9
    latest_label = "最新可用周 · 坏率（笔数）" if latest_confirmed else "最新可用周（未确认）· 坏率（笔数）"
    latest_note = "" if latest_confirmed else " · 仅参考"
    return f"""
<section class="kpis">
  <div class="kpi">
    <span class="label">整体 FPD15 · 坏率（笔数）</span>
    <b>{fmt_rate(fpd15['rate'])}</b>
    <span class="sub">n={fmt_int(fpd15['obs'])} · 坏率（金额）{fmt_rate(fpd15['amtRate'])}</span>
  </div>
  <div class="kpi">
    <span class="label">{latest_label}</span>
    <b>{fmt_rate(latest_rate)}</b>
    <span class="sub">{latest['week']} · {fmt_pct0(latest['fpd15Maturity'])} 成熟{latest_note} · 较前周 {fmt_delta(data['latestDelta'])}</span>
  </div>
  <div class="kpi">
    <span class="label">新客 / 老客 FPD15 · 坏率（笔数）</span>
    <b class="split">{fmt_rate(new15['rate'])} / {fmt_rate(old15['rate'])}</b>
    <span class="sub">gap {fmt_delta(gap)} · n={fmt_int(new15['obs'])} / {fmt_int(old15['obs'])} · 金额 {fmt_rate(new15['amtRate'])} / {fmt_rate(old15['amtRate'])}</span>
  </div>
  <div class="kpi">
    <span class="label">模型 5档 / 1档 · 坏率（笔数）</span>
    <b>{lift:.2f}x</b>
    <span class="sub">5档 {fmt_rate(q5['rate'])} · 1档 {fmt_rate(q1['rate'])} · 覆盖 {data['coverage']['pct']:.2f}%</span>
  </div>
</section>
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
    fpd15 = data["overallBy"][15]
    fpd30 = data["overallBy"][30]
    maturity = data["fpd30Maturity"]
    common = data["common"]
    note = (
        f"笔数口径：FPD15 整体 {fmt_rate(fpd15['rate'])}，新客 {fmt_rate(data['new15']['rate'])} / 老客 {fmt_rate(data['old15']['rate'])}。"
        f"FPD30 为空心点：整体成熟样本仅为 FPD15 的 {fmt_pct0(maturity['ALL'])}"
        f"（新 {fmt_pct0(maturity['New'])} / 老 {fmt_pct0(maturity['Old'])}），只作参考；"
        f"共同 cohort 上 FPD15 笔数坏率 {fmt_rate(common['rate15'])} → FPD30 {fmt_rate(common['rate30'])}。"
    )
    return f"""
<section class="card">
  <h2>整体与分客群：FPD 曲线{TAG_COUNT}</h2>
  <p class="desc">横轴为观察窗口，纵轴为笔数坏率（坏样本笔数 / 成熟样本笔数）；FPD30 为空心点。金额坏率见下方总览表。</p>
  <div class="chart-wrap">
    <svg id="fpdCurve" viewBox="0 0 1040 300" role="img" aria-label="整体、新客、老客在各 FPD 窗口的笔数坏率"></svg>
    <div class="tip" id="fpdTip"></div>
  </div>
  <div class="legend">
    <span><i style="background:var(--ink-2)"></i>整体</span>
    <span><i style="background:var(--c1)"></i>新客</span>
    <span><i style="background:var(--c2)"></i>老客</span>
  </div>
  {overall_table(data['overall'])}
  <p class="note">{note}</p>
</section>
"""


def rate_cell(week, window):
    row = week["windows"].get(window)
    if not row:
        return '<td class="num dim">—</td>'
    maturity = row["maturity"]
    if window == 3:
        if week["incomplete"]:
            return (
                f'<td class="num soft" title="放款周未完整；FPD3 样本 {fmt_int(row["obs"])}">'
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


def week_table(data):
    rows = []
    for week in data["chartWeeks"]:
        fpd15 = week["windows"].get(15)
        sample = fmt_int(fpd15["obs"]) if fpd15 else "—"
        maturity = fmt_pct0(week["fpd15Maturity"]) if fpd15 else "—"
        if fpd15 and week["fpd15Maturity"] < 0.7:
            maturity_class = "num dim"
        elif fpd15 and week["fpd15Maturity"] < 0.9:
            maturity_class = "num soft"
        else:
            maturity_class = "num"
        cells = [rate_cell(week, window) for window in (3, 7, 14, 15)]
        cells.append(amount_cell(week))
        cells.append(rate_cell(week, 30))
        rows.append(
            f"<tr><td>{week['week']}</td>"
            f"<td class='num'>{sample}</td>"
            f"<td class='{maturity_class}'>{maturity}</td>"
            f"{''.join(cells)}</tr>"
        )
    return f"""
<div class="table-wrap">
<table>
  <thead><tr><th>放款周</th><th>FPD15 成熟样本</th><th>FPD15 成熟度</th><th>FPD3</th><th>FPD7</th><th>FPD14</th><th>FPD15</th><th>FPD15 金额</th><th>FPD30</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def week_card_html(data):
    latest = data["latest"]
    complete = data["completeFpd15"]
    low = data["lowFpd15"]
    latest_week = data["latestWeek"]
    previous_week = data["previousWeek"]
    early = data["earlyWeeks"]
    early_text = (
        f"{early[0]}~{early[-1]} 的 {len(early)} 周样本仅 6–12 笔，已排除"
        if early
        else "无早期小样本周"
    )
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
    note = (
        "除标注“金额”外，坏率均为笔数口径；金额坏率 = 坏样本未还本金 / 全部成熟样本放款本金。"
        "成熟度 = 该窗口成熟样本 / 当周 FPD3 样本。"
        "星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示（FPD30 采用 90% 阈值）。"
        f"≥90% 成熟的最后一周：FPD15 {complete['week']}（{fmt_rate(complete['windows'][15]['rate'])}）；"
        f"{latest['week']} 为 {fmt_pct0(latest['fpd15Maturity'])} 成熟（{fmt_rate(latest['windows'][15]['rate'])}*）。"
        f"{low_text}；{latest_text}。{early_text}。"
    )
    return f"""
<section class="card">
  <h2>按放款周：FPD15 与早期信号{TAG_COUNT}</h2>
  <p class="desc">默认笔数口径：FPD15 是确认指标，FPD7 / FPD3 是早期信号；切换到金额口径可看 FPD15 未还本金坏率。空心点表示成熟度不足或周未完整；阴影为 FPD15 笔数坏率的 95% 置信区间；浅灰柱为当周放款量。</p>
  <div class="chart-head">
    <div class="seg" role="group" aria-label="周度图口径">
      <button type="button" class="on" data-week-mode="count" aria-pressed="true">笔数</button>
      <button type="button" data-week-mode="amount" aria-pressed="false">金额</button>
    </div>
  </div>
  <div class="chart-wrap">
    <svg id="weekChart" viewBox="0 0 1040 300" role="img" aria-label="各放款周的 FPD15、FPD7 与 FPD3 坏率，含 FPD15 置信区间、放款量和金额口径切换"></svg>
    <div class="tip" id="weekTip"></div>
  </div>
  <div class="legend" id="weekLegendCount">
    <span><i style="background:var(--c1)"></i>FPD15</span>
    <span><i class="band" style="background:var(--c1)"></i>FPD15 95% CI</span>
    <span><i class="dash" style="border-top-color:var(--c3)"></i>FPD7 早期信号</span>
    <span><i class="dash"></i>FPD3 早期信号</span>
    <span><i class="bar" style="background:var(--grid)"></i>放款量（FPD3 样本）</span>
  </div>
  <div class="legend" id="weekLegendAmount" hidden>
    <span><i style="background:var(--c1)"></i>FPD15 金额坏率</span>
    <span><i class="bar" style="background:var(--grid)"></i>放款量（FPD3 样本）</span>
  </div>
  {week_table(data)}
  <p class="note">{note}</p>
</section>
"""


def score_table(score):
    def range_text(q):
        if q == 1:
            return f"≤ {score['ALL'][1]['max']:.5f}"
        if q == 5:
            return f"> {score['ALL'][5]['min']:.5f}"
        return f"{score['ALL'][q]['min']:.5f}–{score['ALL'][q]['max']:.5f}"

    def rate_cell(segment, q):
        row = score[segment][q]
        return (
            f"<td class='num'><b>{fmt_rate(row['rate'])}</b>"
            f"<span class='n'>n={fmt_int(row['obs'])}</span></td>"
        )

    rows = []
    for q in range(1, 6):
        rows.append(
            f"<tr><td>{q}档</td><td class='range'>{range_text(q)}</td>"
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


def score_week_table(data):
    weeks = data["scoreWeekWeeks"]
    header = "".join(f"<th>{week[5:]}</th>" for week in weeks)

    def maturity_style(week):
        maturity = data["weeksBy"][week]["fpd15Maturity"] if week in data["weeksBy"] else 1.0
        if maturity < 0.7:
            return "num dim", f"FPD15 成熟度 {fmt_pct0(maturity)}，仅参考", "dim"
        if maturity < 0.9:
            return "num soft", f"FPD15 成熟度 {fmt_pct0(maturity)}，仅参考", "soft"
        return "num", None, None

    rows = []
    for q in range(1, 6):
        cells = []
        for week in weeks:
            row = data["scoreWeek"][week].get(q)
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
        week_rows = data["scoreWeek"][week]
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
        psi = data["psiByWeek"].get(week)
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


def score_card_html(data):
    lift = data["lift"]
    monotonic = data["monotonic"]
    shape = (
        "整体、新客、老客均基本单调。"
        if all(monotonic.values())
        else "整体与新客基本单调；老客 2档/4档 低于前一档，排序弱于新客。"
    )
    sentinel = (
        "1档分数下限 -1.0，疑似缺分哨兵；分档按原查询结果展示，未单独剔除。"
        if data["q1Sentinel"]
        else ""
    )
    heat_weeks = data["scoreWeekWeeks"]
    heat_first = heat_weeks[0] if heat_weeks else None
    soft_heat = [
        week
        for week in heat_weeks
        if 0.7 <= data["weeksBy"].get(week, {}).get("fpd15Maturity", 1) < 0.9
    ]
    low_heat = [
        week
        for week in heat_weeks
        if data["weeksBy"].get(week, {}).get("fpd15Maturity", 1) < 0.7
    ]
    heat_bits = []
    if heat_first:
        heat_bits.append(f"分档×周表从 {heat_first[5:]} 起，更早周每档样本不足，未纳入")
    if soft_heat:
        heat_bits.append(f"{'、'.join(week[5:] for week in soft_heat)} 标 *（70–90% 成熟）")
    if low_heat:
        low_text = "、".join(
            f"{week[5:]}（{fmt_pct0(data['weeksBy'].get(week, {}).get('fpd15Maturity', 0))} 成熟）"
            for week in low_heat
        )
        heat_bits.append(f"{low_text} 灰显，仅参考")
    heat_note = "；".join(heat_bits) + "。" if heat_bits else ""
    note = (
        f"坏率均为 FPD15 笔数口径。1档最低分，5档最高分。整体 5档/1档 = {lift['ALL']:.2f}x，"
        f"新客 {lift['New']:.2f}x，老客 {lift['Old']:.2f}x。{shape}"
        f"覆盖 {data['coverage']['pct']:.2f}%（{fmt_int(data['coverage']['scored'])}/{fmt_int(data['coverage']['obs'])}），"
        f"缺分 {fmt_int(data['coverage']['missing'])}。{heat_note}{sentinel}"
        "分档×周表末三行为周度 5档/1档 倍数、排序单调性和 5 档 PSI。"
        "倍数明显低于全期或出现非单调时关注；PSI 基线为前最多 4 个确认周，"
        "仅对确认周计算（放款周完整且 FPD15 成熟度 ≥90%）；"
        "<0.10 稳定，0.10–0.25 关注，≥0.25 预警（5 档粒度为近似）。"
    )
    return f"""
<section class="card">
  <h2>模型分分档{TAG_COUNT}</h2>
  <p class="desc">1档最低分 → 5档最高分（FPD15 成熟样本内 pooled 五分位）；整体、新客、老客的 FPD15 笔数坏率（y_fpd15_ovd / y_fpd15_obs）。</p>
  <div class="chart-wrap">
    <svg id="scoreChart" viewBox="0 0 1040 300" role="img" aria-label="模型分分档的整体、新客、老客 FPD15 笔数坏率"></svg>
    <div class="tip" id="scoreTip"></div>
  </div>
  <div class="legend">
    <span><i style="background:var(--ink-2)"></i>整体</span>
    <span><i style="background:var(--c1)"></i>新客</span>
    <span><i style="background:var(--c2)"></i>老客</span>
  </div>
  <div class="split">
    {score_table(data['score'])}
    {score_week_table(data)}
  </div>
  <p class="note">{note}</p>
</section>
"""


def stability_card_html(data):
    points = data["aucChart"]["points"]
    if not points:
        return ""

    def mark(text, marker):
        return sup(text, marker) if marker and text != "—" else text

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
    psi = data["psiByWeek"]
    psi_text = ""
    if psi:
        last_week = sorted(psi)[-1]
        psi_text = f"最近一周 PSI {psi[last_week]:.2f}（{last_week}）。"
    note = (
        "AUC / Gini / KS 基于 FPD15 成熟样本，按周内分数排名计算，AUC 对并列分数取平均秩；"
        "周样本少于 200 的周不纳入。星号 * 表示 70–90% 成熟，仅参考。"
        f"{baseline_text}{psi_text}"
        "AUC 连续走低或 KS 明显收缩时，优先检查模型分分布和入催客群变化。"
    )
    return f"""
<section class="card">
  <h2>周度排序力<span class="tag" title="AUC = P(坏样本分数高于好样本) + 0.5 × P(并列)；Gini = 2 × AUC − 1">模型监控</span></h2>
  <p class="desc">按放款周看模型分对 FPD15 的排序能力；AUC 和 KS 越高越好。灰柱为当周 FPD15 成熟样本量。</p>
  <div class="chart-wrap">
    <svg id="aucChart" viewBox="0 0 1040 280" role="img" aria-label="周度 AUC 与 KS"></svg>
    <div class="tip" id="aucTip"></div>
  </div>
  <div class="legend">
    <span><i style="background:var(--c1)"></i>AUC</span>
    <span><i class="dash" style="border-top-color:var(--c3)"></i>KS</span>
    <span><i class="bar" style="background:var(--grid)"></i>FPD15 成熟样本</span>
  </div>
  <div class="table-wrap">
  <table class="compact">
    <thead><tr><th>放款周</th><th>成熟样本</th><th>AUC</th><th>Gini</th><th>KS</th><th>FPD15 坏率</th><th>成熟度</th></tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table>
  </div>
  <p class="note">{note}</p>
</section>
"""


def mix_card_html(data):
    chart = data["mixChart"]
    if not chart["weeks"]:
        return ""

    rows = []
    for week in chart["weeks"]:
        segments = data["weekUser"][week]
        new = segments.get("New")
        old = segments.get("Old")
        if not new or not old:
            continue
        total = new["obs"] + old["obs"]
        share = new["obs"] / total if total else None
        maturity = data["weeksBy"].get(week, {}).get("fpd15Maturity")
        marker = "*" if maturity is not None and maturity < 0.9 else ""

        def cell(row):
            amount = fmt_rate(row["amtRate"]) if row["amtRate"] is not None else "—"
            rate_text = sup(fmt_rate(row["rate"]), marker) if marker else fmt_rate(row["rate"])
            return (
                f"<td class='num'><b>{rate_text}</b>"
                f"<span class='n'>n={fmt_int(row['obs'])} · 金额 {amount}</span></td>"
            )

        maturity_cls = "num soft" if marker else "num"
        rows.append(
            f"<tr><td>{week}</td>{cell(new)}{cell(old)}"
            f"<td class='num'>{fmt_pct0(share)}</td>"
            f"<td class='{maturity_cls}'>{fmt_pct0(maturity)}</td></tr>"
        )

    mix_note = ""
    effect = data["mixEffect"]
    if effect:
        mix_note = (
            f"最新确认周 {effect['week']} 较前 {len(effect['baseWeeks'])} 周："
            f"整体 FPD15 {fmt_delta(effect['total'])} = 组内 {fmt_delta(effect['within'])}"
            f" + 结构 {fmt_delta(effect['mix'])}；"
            f"新客占比 {fmt_pct0(effect['newShare'])}（基线 {fmt_pct0(effect['newShareBase'])}）。"
        )
    return f"""
<section class="card">
  <h2>周度新老客与结构<span class="tag" title="坏率 = y_fpd15_ovd 之和 / y_fpd15_obs 之和">FPD15</span></h2>
  <p class="desc">新客 / 老客的 FPD15 坏率（笔数）与金额坏率；结构拆分用于区分“客群本身变坏”和“新老客占比变化”。</p>
  <div class="chart-wrap">
    <svg id="mixChart" viewBox="0 0 1040 280" role="img" aria-label="新客与老客的周度 FPD15 笔数坏率"></svg>
    <div class="tip" id="mixTip"></div>
  </div>
  <div class="legend">
    <span><i style="background:var(--c1)"></i>新客</span>
    <span><i style="background:var(--c2)"></i>老客</span>
  </div>
  <div class="table-wrap">
  <table class="compact">
    <thead><tr><th>放款周</th><th>新客</th><th>老客</th><th>新客占比</th><th>成熟度</th></tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table>
  </div>
  <p class="note">坏率为 FPD15 笔数口径，金额坏率列在样本下方。{mix_note}</p>
</section>
"""


def rank_table(rank):
    rows = []
    for item in rank:
        rows.append(
            f"<tr><td>{item['band']}</td><td>{item['userType']}</td>"
            f"<td class='num'>{fmt_int(item['obs'])}</td>"
            f"<td class='num'>{fmt_int(item['bad'])}</td>"
            f"<td class='num'>{fmt_rate(item['rate'])}</td></tr>"
        )
    return f"""
<div class="table-wrap">
<table class="compact">
  <thead><tr><th>复借期数</th><th>客群</th><th>样本（笔）</th><th>坏样本（笔）</th><th>FPD15 坏率（笔数）</th></tr></thead>
  <tbody>{''.join(rows)}</tbody>
</table>
</div>
"""


def rank_card_html(data):
    rank = {item["band"]: item for item in data["rank"]}
    second = rank.get("2nd")
    fourth = rank.get("4th+")
    note = (
        "坏率为 FPD15 笔数口径。首借 = New；2nd 起为 Old；4th+ 含 4 次及以上。"
        + (
            f"老客中 2nd 最高（{fmt_rate(second['rate'])}），"
            f"4th+ 最低（{fmt_rate(fourth['rate'])}）；复借越多坏率越低。"
            if second and fourth
            else ""
        )
    )
    return f"""
<section class="card">
  <h2>复借期数{TAG_COUNT}</h2>
  <p class="desc">纵轴为 FPD15 笔数坏率；首借风险最高，复借 4 次以上最低。</p>
  <div class="split rank-split">
    <div class="chart-wrap">
      <svg id="rankChart" viewBox="0 0 520 300" role="img" aria-label="首借与复借期数的 FPD15 笔数坏率"></svg>
      <div class="tip" id="rankTip"></div>
    </div>
    <div>{rank_table(data['rank'])}</div>
  </div>
  <p class="note">{note}</p>
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
    return f"""
<section class="card">
  <h2>数据质量与口径</h2>
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
    if data["aucChart"].get("points"):
        extras.append(
            "<li>周度排序力与漂移：AUC 按周内分数排名计算，并列分数取平均秩；"
            "Gini = 2×AUC−1；KS 按分数分组累计好坏分布计算；周样本少于 200 的周不纳入。"
            "PSI 按 5 档份额计算，基线为前最多 4 个确认周；&lt;0.10 稳定，"
            "0.10–0.25 关注，≥0.25 预警（5 档粒度为近似）。</li>"
        )
    if data["mixChart"].get("weeks"):
        extras.append(
            "<li>周度新老客：按放款周 × user_type 拆分 FPD15；结构拆分为组内变化"
            "（最新权重）+ 新老客占比变化（基线坏率），两者相加等于整体变化。</li>"
        )
    return f"""
<footer class="foot">
  <ul class="notes">
    <li>笔数坏率（看板默认口径）：y_fpdN_ovd 之和 / y_fpdN_obs 之和。FPD-X：首期应还日 due + X 天前未还清首期；成熟样本为 y_fpdN_obs = 1（is_deal = 1、观察日有借据快照且 due + X &lt; obs_dt），未成熟不判坏（即使已结清）。FPD14 由 stg_debt_snp 首期实还日补算，成熟条件同口径。</li>
    <li>金额坏率（仅总览表与 KPI 子行）：estimate_principal_remaining_fpdN 之和 / 全部成熟样本放款本金；余额取 due+X 当天借据快照（FPD14 同机制），当天无快照的不计入分子。</li>
    <li>成熟度：该窗口成熟样本 / 当周 FPD3 样本；星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示；FPD30 采用 90% 阈值。</li>
    <li>监控状态与周度图：确认周 = 放款周完整且 FPD15 成熟度 ≥90%；基线 = 其前最多 4 个确认周（样本 ≥500）均值；±1σ / ±2σ 仅作波动提示。周度阴影为 FPD15 的 Wilson 95% 置信区间；浅灰柱为当周 FPD3 成熟样本数（放款量代理）。周度图可在笔数 / 金额口径间切换。</li>
    {''.join(extras)}
    <li>新老客：user_type 按首笔放款；复借期数 application_rank，1st = 首借，2nd 起为 Old，4th+ 含 4 次及以上。</li>
    <li>模型分：FPD15 成熟样本内 pooled 五分位切 5 档，1档最低分、5档最高分；分数越高越坏。</li>
    <li>数据源：{escape(input_name)}（{data['csvCount']} 个 CSV）；生成脚本：build_vintage_dashboard.py；生成时间：{escape(generated_at)}。</li>
  </ul>
</footer>
"""


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WageGo Vintage 监控看板</title>
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
  .chips { display: flex; flex-wrap: wrap; gap: 7px; justify-content: flex-end; }
  .chip {
    border: 1px solid var(--ring); background: var(--surface);
    border-radius: 999px; padding: 5px 10px; font-size: 11.5px; color: var(--ink-2);
    white-space: nowrap;
  }
  .kpis {
    display: grid; grid-template-columns: repeat(4, 1fr);
    gap: 12px; margin: 20px 0 14px;
  }
  .kpi {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 13px 15px;
  }
  .kpi .label { display: block; color: var(--muted); font-size: 11.5px; }
  .kpi b {
    display: block; font-size: 27px; line-height: 1.2;
    margin: 4px 0 1px; font-variant-numeric: tabular-nums;
  }
  .kpi b.split { font-size: 21px; }
  .kpi .sub { display: block; color: var(--ink-2); font-size: 11.5px; line-height: 1.45; }
  .monitor-wrap { margin: 0 0 14px; }
  .monitor {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
    gap: 12px;
  }
  .m-item {
    display: flex; flex-direction: column; gap: 2px;
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 11px 13px;
  }
  .m-label { color: var(--muted); font-size: 11.5px; }
  .m-value {
    font-size: 19px; font-weight: 650; line-height: 1.25;
    font-variant-numeric: tabular-nums;
  }
  .m-value small { color: var(--muted); font-size: 11px; font-weight: 500; margin-left: 4px; }
  .m-sub { color: var(--ink-2); font-size: 11.5px; line-height: 1.45; }
  .m-status {
    align-self: flex-start; margin-top: 3px;
    border-radius: 999px; padding: 1px 8px;
    font-size: 10.5px; font-weight: 600;
    border: 1px solid var(--ring); color: var(--ink-2);
  }
  .m-status.ok { color: var(--ok); border-color: var(--ok); }
  .m-status.watch { color: var(--warn); border-color: var(--warn); }
  .m-status.alert { color: var(--bad); border-color: var(--bad); }
  .m-status.na { color: var(--muted); }
  .m-note { margin: 6px 2px 0; }
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
  .desc { color: var(--ink-2); font-size: 12.5px; margin: 0 0 6px; }
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
  .rank-split { grid-template-columns: 1.05fr .95fr; }
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
    .hero { flex-direction: column; align-items: flex-start; }
    .chips { justify-content: flex-start; }
    .kpis { grid-template-columns: repeat(2, 1fr); }
    .monitor { grid-template-columns: repeat(2, 1fr); }
    .split { grid-template-columns: 1fr; }
    .quality { grid-template-columns: 1fr; }
  }
  @media (max-width: 560px) {
    h1 { font-size: 24px; }
    .kpis { grid-template-columns: 1fr; }
    .monitor { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<main>
__HEADER__
__KPIS__
<section class="monitor-wrap" aria-label="监控状态">
  <div class="monitor" id="monitorStrip"></div>
  <p class="note m-note">监控口径：确认周 = 放款周完整且 FPD15 成熟度 ≥90%；基线 = 其前最多 4 个确认周（样本 ≥500）均值；状态按 ±1σ / ±2σ 提示（σ 下限 0.5pp），只用于发现异常波动，不替代业务阈值。放款量为当周 FPD3 成熟样本数；新鲜度按生成时间计算。</p>
</section>
__FPD_CARD__
__WEEK_CARD__
__SCORE_CARD__
__STABILITY_CARD__
<section class="card" id="monthlyCard" hidden>
  <h2>月度排序力 · 新老客<span class="tag" title="月度值 = 当月全部 FPD15 成熟样本的 pooled AUC">模型监控</span></h2>
  <p class="desc">按放款月统计 FPD15 成熟样本的 AUC / Gini / KS；月度值为当月全部样本的 pooled 值，不是周度 AUC 的平均。</p>
  <div class="table-wrap">
    <table>
      <thead><tr><th>月份</th><th>客群</th><th>成熟样本</th><th>坏样本</th><th>坏率</th><th>AUC</th><th>Gini</th><th>KS</th></tr></thead>
      <tbody id="monthlyAucBody"></tbody>
    </table>
  </div>
  <p class="note">客群口径：New 首借 / Old 复借 / ALL 合计。最近月份可能尚未完全成熟，请结合成熟样本与坏样本量判断。</p>
</section>
__MIX_CARD__
__RANK_CARD__
__QUALITY_CARD__
__FOOTER__
</main>
<script id="mbr-summary" type="application/json">__MBR_JSON__</script>
<script>
const DATA = __DATA_JSON__;
const NS = 'http://www.w3.org/2000/svg';
const fmtRate = v => (v == null ? '—' : v.toFixed(2) + '%');
const fmtInt = n => (n == null ? '—' : n.toLocaleString('en-US'));
const fmtSigned = (v, digits = 2, unit = '') => (v == null ? '—' : (v >= 0 ? '+' : '−') + Math.abs(v).toFixed(digits) + unit);

function wilsonCi(obs, ratePct, z = 1.96) {
  if (!obs || ratePct == null) return null;
  const n = obs;
  const p = ratePct / 100;
  const denom = 1 + z * z / n;
  const center = (p + z * z / (2 * n)) / denom;
  const half = z * Math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom;
  return { lo: Math.max(0, (center - half) * 100), hi: Math.min(100, (center + half) * 100) };
}

function meanStd(values) {
  const n = values.length;
  if (!n) return null;
  const mean = values.reduce((sum, value) => sum + value, 0) / n;
  const variance = n > 1 ? values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / (n - 1) : 0;
  return { mean, std: Math.sqrt(variance), n };
}

function statusOf(latest, base) {
  if (latest == null || !base) return { cls: 'na', text: '样本不足' };
  const sigma = Math.max(base.std, 0.5);
  const z = (latest - base.mean) / sigma;
  if (z >= 2) return { cls: 'alert', text: '预警', z };
  if (z >= 1) return { cls: 'watch', text: '关注', z };
  if (z <= -1) return { cls: 'ok', text: '改善', z };
  return { cls: 'ok', text: '正常', z };
}

function confirmedIndices(points, getMaturity) {
  const out = [];
  points.forEach((point, index) => {
    if (!point || point.partial) return;
    const maturity = getMaturity ? getMaturity(point) : 1;
    if (maturity >= 0.9) out.push(index);
  });
  return out;
}

function baselineStats(indices, points) {
  const pool = indices.slice(0, -1).filter(index => points[index].obs >= 500).slice(-4);
  if (!pool.length) return null;
  const stats = meanStd(pool.map(index => points[index].rate));
  return { ...stats, indices: pool };
}

function monitorItem(label, value, sub, status) {
  return `<div class="m-item"><span class="m-label">${label}</span>`
    + `<span class="m-value">${value}</span>`
    + `<span class="m-sub">${sub}</span>`
    + `<span class="m-status ${status.cls}">${status.text}</span></div>`;
}

function renderMonitor() {
  const strip = document.getElementById('monitorStrip');
  if (!strip) return;
  const chart = DATA.weekChart;
  const fpd15Idx = confirmedIndices(chart.fpd15, point => point.maturity == null ? 1 : point.maturity);
  const fpd3Idx = confirmedIndices(chart.fpd3);
  const items = [];

  const i15 = fpd15Idx[fpd15Idx.length - 1];
  const b15 = baselineStats(fpd15Idx, chart.fpd15);
  const p15 = chart.fpd15[i15];
  const s15 = statusOf(p15.rate, b15);
  const d15 = b15 ? p15.rate - b15.mean : null;
  items.push(monitorItem(
    'FPD15 确认周 · 坏率',
    `${fmtRate(p15.rate)} <small>${chart.weeks[i15].slice(5)}</small>`,
    `n=${fmtInt(p15.obs)} · 基线 ${fmtRate(b15 ? b15.mean : null)}（${b15 ? b15.n : 0} 周）· 较基线 ${fmtSigned(d15, 2, 'pp')} · z=${fmtSigned(s15.z, 2, 'σ')}`,
    s15
  ));

  const i3 = fpd3Idx[fpd3Idx.length - 1];
  const b3 = baselineStats(fpd3Idx, chart.fpd3);
  const p3 = chart.fpd3[i3];
  const s3 = statusOf(p3.rate, b3);
  const d3 = b3 ? p3.rate - b3.mean : null;
  items.push(monitorItem(
    'FPD3 早期信号 · 坏率',
    `${fmtRate(p3.rate)} <small>${chart.weeks[i3].slice(5)}</small>`,
    `n=${fmtInt(p3.obs)} · 基线 ${fmtRate(b3 ? b3.mean : null)}（${b3 ? b3.n : 0} 周）· 较基线 ${fmtSigned(d3, 2, 'pp')} · z=${fmtSigned(s3.z, 2, 'σ')}`,
    s3
  ));

  const volumes = fpd3Idx.map(index => chart.fpd3[index].obs);
  const latestVolume = volumes[volumes.length - 1];
  const volumeBase = meanStd(volumes.slice(0, -1).slice(-4));
  const volumeDelta = volumeBase ? (latestVolume / volumeBase.mean - 1) * 100 : null;
  const volumeStatus = volumeDelta == null
    ? { cls: 'na', text: '样本不足' }
    : volumeDelta >= 15 ? { cls: 'watch', text: '放量' }
    : volumeDelta <= -15 ? { cls: 'watch', text: '缩量' }
    : { cls: 'ok', text: '平稳' };
  items.push(monitorItem(
    '放款量 · 最新完整周',
    `${fmtInt(latestVolume)} 笔 <small>${chart.weeks[i3].slice(5)}</small>`,
    `前 4 周均值 ${fmtInt(volumeBase ? Math.round(volumeBase.mean) : null)} · 变化 ${fmtSigned(volumeDelta, 1, '%')}`,
    volumeStatus
  ));

  const aucPoints = (DATA.aucChart && DATA.aucChart.points) || [];
  const psiMap = DATA.psiByWeek || {};
  if (aucPoints.length || Object.keys(psiMap).length) {
    let aucIdx = -1;
    aucPoints.forEach((point, index) => { if (!point.partial) aucIdx = index; });
    if (aucIdx < 0 && aucPoints.length) aucIdx = aucPoints.length - 1;
    const aucPoint = aucIdx >= 0 ? aucPoints[aucIdx] : null;
    const priorAuc = aucPoints
      .filter((point, index) => index < aucIdx && !point.partial)
      .slice(-4);
    const aucBase = priorAuc.length ? meanStd(priorAuc.map(point => point.auc)) : null;
    const psiWeek = aucPoint ? aucPoint.week : Object.keys(psiMap).sort().pop();
    const psi = psiWeek != null ? psiMap[psiWeek] : null;
    const psiCls = psi == null ? 'na' : psi >= 0.25 ? 'alert' : psi >= 0.1 ? 'watch' : 'ok';
    let aucCls = 'na';
    if (aucPoint && aucBase) {
      const sigma = Math.max(aucBase.std, 0.01);
      const z = (aucPoint.auc - aucBase.mean) / sigma;
      aucCls = z <= -2 ? 'alert' : z <= -1 ? 'watch' : 'ok';
    }
    const cls = [psiCls, aucCls].includes('alert') ? 'alert'
      : [psiCls, aucCls].includes('watch') ? 'watch'
      : (psi != null || aucPoint) ? 'ok' : 'na';
    const text = cls === 'alert'
      ? (psiCls === 'alert' ? '分数漂移' : '排序走弱')
      : cls === 'watch'
        ? (psiCls === 'watch' ? '分数波动' : '排序关注')
        : cls === 'ok' ? '稳定' : '样本不足';
    const value = aucPoint
      ? `AUC ${aucPoint.auc.toFixed(3)} <small>${aucPoint.week.slice(5)}</small>`
      : psi != null
        ? `PSI ${psi.toFixed(2)} <small>${psiWeek.slice(5)}</small>`
        : '—';
    const subBits = [];
    if (aucPoint) {
      subBits.push(`KS ${aucPoint.ks == null ? '—' : aucPoint.ks.toFixed(2)}`);
      if (aucBase) subBits.push(`基线 AUC ${aucBase.mean.toFixed(3)}（${priorAuc.length} 周）`);
      subBits.push(`PSI ${psi == null ? '—' : psi.toFixed(2)}`);
    }
    items.push(monitorItem(
      aucPoint ? '排序力与分数漂移 · 最新确认周' : '分数漂移 · 最新确认周',
      value,
      subBits.join(' · '),
      { cls, text }
    ));
  }

  const generated = DATA.generatedAt ? new Date(DATA.generatedAt) : null;
  let freshness = { cls: 'na', text: '未知' };
  let freshnessValue = '—';
  let freshnessSub = '未记录生成时间';
  if (generated && !Number.isNaN(generated.getTime())) {
    const days = Math.max(0, Math.floor((Date.now() - generated.getTime()) / 86400000));
    freshnessValue = `${days} 天`;
    freshnessSub = `生成于 ${generated.toLocaleDateString('zh-CN')} · 最新放款周 ${chart.weeks[chart.weeks.length - 1]}`;
    freshness = days > 14 ? { cls: 'alert', text: '需刷新' }
      : days > 7 ? { cls: 'watch', text: '偏旧' }
      : { cls: 'ok', text: '正常' };
  }
  items.push(monitorItem('数据新鲜度 · 距生成', freshnessValue, freshnessSub, freshness));

  strip.innerHTML = items.join('');
}

renderMonitor();

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

function makeBarChart(svgId, tipId, cfg) {
  const svg = document.getElementById(svgId);
  const tip = document.getElementById(tipId);
  const { width, height, margin, data, yMax, yTicks, color, xLabel, yLabel, yFormat } = cfg;
  const fmtY = yFormat || (value => value + '%');
  const innerW = width - margin.l - margin.r;
  const innerH = height - margin.t - margin.b;
  const y = v => margin.t + (1 - v / yMax) * innerH;
  const band = innerW / data.length;
  const barW = Math.min(58, band * 0.52);
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

  data.forEach((item, index) => {
    const cx = margin.l + band * (index + 0.5);
    const x0 = cx - barW / 2;
    const y0 = y(0);
    const yTop = y(item.rate);
    const r = 4;
    const path = `M${x0},${y0} L${x0},${yTop + r} Q${x0},${yTop} ${x0 + r},${yTop} L${x0 + barW - r},${yTop} Q${x0 + barW},${yTop} ${x0 + barW},${yTop + r} L${x0 + barW},${y0} Z`;
    const bar = svgEl(svg, 'path', { d: path, fill: color });
    svgEl(svg, 'text', {
      x: cx, y: yTop - 8, 'text-anchor': 'middle',
      fill: 'var(--ink)', 'font-size': 12, 'font-weight': 600
    }, fmtRate(item.rate));
    svgEl(svg, 'text', {
      x: cx, y: height - margin.b + 18, 'text-anchor': 'middle',
      fill: 'var(--ink-2)', 'font-size': 11.5
    }, item.label);
    svgEl(svg, 'text', {
      x: cx, y: height - margin.b + 31, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 10.5
    }, item.sub);
    svgEl(svg, 'text', {
      x: cx, y: height - margin.b + 44, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 10.5
    }, `n=${fmtInt(item.obs)}`);

    const hit = svgEl(svg, 'rect', {
      x: margin.l + band * index, y: margin.t, width: band, height: innerH,
      fill: 'transparent'
    });
    hit.addEventListener('mousemove', event => {
      const box = svg.getBoundingClientRect();
      bar.setAttribute('opacity', 0.82);
      tip.innerHTML = `<b>${item.label} · ${item.sub}</b><br><span>FPD15 笔数坏率 <b>${fmtRate(item.rate)}</b> · n=${fmtInt(item.obs)} · 坏 ${fmtInt(item.bad)}</span>`;
      tip.classList.toggle('down', yTop * (box.height / height) < 90);
      tip.style.left = Math.max(100, Math.min(box.width - 100, cx * (box.width / width))) + 'px';
      tip.style.top = yTop * (box.height / height) + 'px';
      tip.style.display = 'block';
    });
    hit.addEventListener('mouseleave', () => {
      bar.setAttribute('opacity', 1);
      tip.style.display = 'none';
    });
  });

  svgEl(svg, 'text', {
    x: width - margin.r, y: height - 6, 'text-anchor': 'end',
    fill: 'var(--muted)', 'font-size': 11.5
  }, xLabel);
}

const fpdSeries = DATA.fpdCurve.series;
makeLineChart('fpdCurve', 'fpdTip', {
  width: 1040, height: 300, margin: { t: 30, r: 130, b: 46, l: 56 },
  labels: DATA.fpdCurve.labels,
  series: fpdSeries,
  yMax: 20, yTicks: [0, 5, 10, 15, 20], xLabel: '观察窗口', yLabel: '笔数坏率',
  directLabels: fpdSeries.map((series, index) => ({
    series: index, index: 3,
    text: `${series.name} ${fmtRate(series.points[3].rate)}`,
    dx: 0, dy: index === 1 ? -12 : 18, anchor: 'middle'
  })),
  tooltip: index => {
    const rows = fpdSeries.map(series => {
      const point = series.points[index];
      return `<span><i style="background:${series.color}"></i>${series.name} <b>${fmtRate(point.rate)}</b> · n=${fmtInt(point.obs)}</span>`;
    }).join('<br>');
    const age = index === 4
      ? `<br><span>30 天成熟：整体 ${Math.round(fpdSeries[0].points[4].maturity * 100)}% · 新 ${Math.round(fpdSeries[1].points[4].maturity * 100)}% · 老 ${Math.round(fpdSeries[2].points[4].maturity * 100)}%</span>`
      : '';
    return `<b>${DATA.fpdCurve.labels[index]} · 笔数坏率</b><br>${rows}${age}`;
  }
});

const lastPointIndex = points => {
  for (let i = points.length - 1; i >= 0; i--) if (points[i]) return i;
  return -1;
};

function renderWeekChart(mode) {
  const amount = mode === 'amount';
  const countSeries = [
    { name: 'FPD3', key: 'fpd3', color: 'var(--muted)', points: DATA.weekChart.fpd3, dash: '5 4', width: 1.8 },
    { name: 'FPD7', key: 'fpd7', color: 'var(--c3)', points: DATA.weekChart.fpd7, dash: '5 4', width: 1.8 },
    { name: 'FPD15', key: 'fpd15', color: 'var(--c1)', points: DATA.weekChart.fpd15, width: 2 }
  ];
  const amountSeries = [
    { name: 'FPD15 金额', key: 'fpd15Amt', color: 'var(--c1)', points: DATA.weekChart.fpd15Amt, width: 2 }
  ];
  const series = amount ? amountSeries : countSeries;
  const last15 = lastPointIndex(DATA.weekChart.fpd15);
  const last7 = lastPointIndex(DATA.weekChart.fpd7);
  const last3 = lastPointIndex(DATA.weekChart.fpd3);
  const lastAmt = lastPointIndex(DATA.weekChart.fpd15Amt);
  const directLabels = amount ? [] : [
    {
      series: 2, index: last15,
      text: `FPD15 ${fmtRate(DATA.weekChart.fpd15[last15].rate)}${DATA.weekChart.fpd15[last15].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 1, index: last7,
      text: `FPD7 ${fmtRate(DATA.weekChart.fpd7[last7].rate)}${DATA.weekChart.fpd7[last7].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 0, index: last3,
      text: `FPD3 ${fmtRate(DATA.weekChart.fpd3[last3].rate)}${DATA.weekChart.fpd3[last3].partial ? '†' : ''}`,
      dx: -8, dy: -10, anchor: 'end'
    }
  ];
  if (amount && lastAmt >= 0) {
    directLabels.push({
      series: 0, index: lastAmt,
      text: `FPD15 金额 ${fmtRate(DATA.weekChart.fpd15Amt[lastAmt].rate)}${DATA.weekChart.fpd15Amt[lastAmt].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    });
  }
  makeLineChart('weekChart', 'weekTip', {
    width: 1040, height: 300, margin: { t: 30, r: 100, b: 46, l: 56 },
    labels: DATA.weekChart.labels,
    series,
    volume: { values: DATA.weekChart.fpd3.map(point => point ? point.obs : null) },
    ciSeries: amount ? null : 2,
    yMax: 20, yTicks: [0, 5, 10, 15, 20], xLabel: '放款周（2026）', yLabel: amount ? '金额坏率' : '笔数坏率',
    directLabels,
    tooltip: index => {
      const fpd3 = DATA.weekChart.fpd3[index];
      const fpd7 = DATA.weekChart.fpd7[index];
      const fpd15 = DATA.weekChart.fpd15[index];
      if (amount) {
        const parts = [`<b>${DATA.weekChart.weeks[index]} · 金额坏率</b>`];
        const amt = DATA.weekChart.fpd15Amt[index];
        parts.push(amt
          ? `<span><i style="background:var(--c1)"></i>FPD15 金额 <b>${fmtRate(amt.rate)}</b> · n=${fmtInt(amt.obs)} · ${Math.round(amt.maturity * 100)}% 成熟${amt.partial ? '*' : ''}</span>`
          : '<span>FPD15 金额坏率尚未达到 70% 成熟</span>');
        if (fpd15) parts.push(`<span>笔数坏率 ${fmtRate(fpd15.rate)}（n=${fmtInt(fpd15.obs)}）</span>`);
        if (fpd3) parts.push(`<span>FPD3 早期信号 ${fmtRate(fpd3.rate)}</span>`);
        return parts.join('<br>');
      }
      const parts = [`<b>${DATA.weekChart.weeks[index]} · 笔数坏率</b>`];
      if (fpd3) parts.push(`<span><i style="background:var(--muted)"></i>FPD3 <b>${fmtRate(fpd3.rate)}</b> · n=${fmtInt(fpd3.obs)}${fpd3.partial ? ' · 周未完整' : ''}</span>`);
      if (fpd7) parts.push(`<span><i style="background:var(--c3)"></i>FPD7 <b>${fmtRate(fpd7.rate)}</b> · n=${fmtInt(fpd7.obs)} · ${Math.round(fpd7.maturity * 100)}% 成熟${fpd7.partial ? '*' : ''}</span>`);
      else {
        const low7 = DATA.weekChart.fpd7Low[index];
        parts.push(low7
          ? `<span><i style="background:var(--c3)"></i>FPD7 <b>${fmtRate(low7.rate)}</b> · n=${fmtInt(low7.obs)} · ${Math.round(low7.maturity * 100)}% 成熟（低于 70%，未入图）</span>`
          : '<span>FPD7 尚未达到 70% 成熟</span>');
      }
      if (fpd15) {
        const ci = wilsonCi(fpd15.obs, fpd15.rate);
        parts.push(`<span><i style="background:var(--c1)"></i>FPD15 <b>${fmtRate(fpd15.rate)}</b> · n=${fmtInt(fpd15.obs)} · ${Math.round(fpd15.maturity * 100)}% 成熟${fpd15.partial ? '*' : ''}${ci ? ` · 95% CI ${fmtRate(ci.lo)}–${fmtRate(ci.hi)}` : ''}</span>`);
      }
      else {
        const low = DATA.weekChart.fpd15Low[index];
        parts.push(low
          ? `<span><i style="background:var(--muted)"></i>FPD15 <b>${fmtRate(low.rate)}</b> · n=${fmtInt(low.obs)} · ${Math.round(low.maturity * 100)}% 成熟（低于 70%，未入图）</span>`
          : '<span>FPD15 尚未达到 70% 成熟</span>');
      }
      return parts.join('<br>');
    }
  });
  const countLegend = document.getElementById('weekLegendCount');
  const amountLegend = document.getElementById('weekLegendAmount');
  if (countLegend) countLegend.hidden = amount;
  if (amountLegend) amountLegend.hidden = !amount;
}

const weekButtons = document.querySelectorAll('[data-week-mode]');
weekButtons.forEach(button => {
  button.addEventListener('click', () => {
    weekButtons.forEach(item => {
      const active = item === button;
      item.classList.toggle('on', active);
      item.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
    renderWeekChart(button.dataset.weekMode);
  });
});
renderWeekChart('count');

const scoreSeries = DATA.scoreChart.series;
makeLineChart('scoreChart', 'scoreTip', {
  width: 1040, height: 300, margin: { t: 30, r: 135, b: 46, l: 56 },
  labels: DATA.scoreChart.labels,
  series: scoreSeries,
  yMax: 20, yTicks: [0, 5, 10, 15, 20], xLabel: '模型分分档（低 → 高）', yLabel: '笔数坏率',
  directLabels: scoreSeries.map((series, index) => ({
    series: index, index: 4,
    text: `${series.name} ${fmtRate(series.points[4].rate)}`,
    dx: 8, dy: -10, anchor: 'start'
  })),
  tooltip: index => {
    const base = scoreSeries[0].points[index];
    const rows = scoreSeries.map(series => {
      const point = series.points[index];
      return `<span><i style="background:${series.color}"></i>${series.name} <b>${fmtRate(point.rate)}</b> · n=${fmtInt(point.obs)}</span>`;
    }).join('<br>');
    return `<b>${DATA.scoreChart.labels[index]} · ${base.min.toFixed(4)} ~ ${base.max.toFixed(4)} · 笔数坏率</b><br>${rows}`;
  }
});

if (DATA.aucChart && DATA.aucChart.points.length > 1) {
  const aucPoints = DATA.aucChart.points;
  const aucSeries = [
    {
      name: 'AUC', key: 'auc', color: 'var(--c1)', width: 2,
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
  makeLineChart('aucChart', 'aucTip', {
    width: 1040, height: 280, margin: { t: 30, r: 110, b: 46, l: 56 },
    labels: DATA.aucChart.labels,
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
      return `<b>${point.week} · 排序力</b><br>`
        + `<span><i style="background:var(--c1)"></i>AUC <b>${point.auc.toFixed(3)}</b> · Gini ${gini}</span><br>`
        + `<span><i style="background:var(--c3)"></i>KS <b>${ks}</b></span><br>`
        + `<span>n=${fmtInt(point.obs)} · 坏 ${fmtInt(point.bad)} · ${Math.round(point.maturity * 100)}% 成熟${point.partial ? '*' : ''}</span>`;
    }
  });
}

if (DATA.mixChart && DATA.mixChart.weeks.length) {
  const mixSeries = [
    { name: '新客', key: 'New', color: 'var(--c1)', points: DATA.mixChart.new, width: 2 },
    { name: '老客', key: 'Old', color: 'var(--c2)', points: DATA.mixChart.old, width: 2 }
  ];
  const lastNew = lastPointIndex(mixSeries[0].points);
  const lastOld = lastPointIndex(mixSeries[1].points);
  const mixLabels = [];
  if (lastNew >= 0) {
    mixLabels.push({
      series: 0, index: lastNew,
      text: `新客 ${fmtRate(mixSeries[0].points[lastNew].rate)}`,
      dx: 8, dy: -10, anchor: 'start'
    });
  }
  if (lastOld >= 0) {
    mixLabels.push({
      series: 1, index: lastOld,
      text: `老客 ${fmtRate(mixSeries[1].points[lastOld].rate)}`,
      dx: 8, dy: 16, anchor: 'start'
    });
  }
  makeLineChart('mixChart', 'mixTip', {
    width: 1040, height: 280, margin: { t: 30, r: 110, b: 46, l: 56 },
    labels: DATA.mixChart.labels,
    series: mixSeries,
    yMax: 20, yTicks: [0, 5, 10, 15, 20],
    xLabel: '放款周（2026）', yLabel: 'FPD15 笔数坏率',
    directLabels: mixLabels,
    tooltip: index => {
      const parts = [`<b>${DATA.mixChart.weeks[index]} · FPD15 新老客</b>`];
      mixSeries.forEach(series => {
        const point = series.points[index];
        if (!point) {
          parts.push(`<span>${series.name} 尚未达到 70% 成熟</span>`);
          return;
        }
        const amount = point.amtRate == null ? '—' : fmtRate(point.amtRate);
        parts.push(
          `<span><i style="background:${series.color}"></i>${series.name} <b>${fmtRate(point.rate)}</b>`
          + ` · n=${fmtInt(point.obs)} · 金额 ${amount}`
          + ` · ${Math.round(point.maturity * 100)}% 成熟${point.partial ? '*' : ''}</span>`
        );
      });
      return parts.join('<br>');
    }
  });
}

makeBarChart('rankChart', 'rankTip', {
  width: 520, height: 300, margin: { t: 30, r: 24, b: 64, l: 52 },
  data: DATA.rankChart,
  yMax: 12, yTicks: [0, 3, 6, 9, 12],
  color: 'var(--c1)', xLabel: '复借期数', yLabel: '笔数坏率'
});

function renderMonthlyAuc() {
  const card = document.getElementById('monthlyCard');
  const body = document.getElementById('monthlyAucBody');
  if (!card || !body) return;
  const monthly = DATA.monthlyAuc || {};
  const months = Object.keys(monthly).sort().reverse();
  if (!months.length) { card.hidden = true; return; }
  card.hidden = false;
  body.textContent = '';
  months.forEach(month => {
    ['ALL', 'New', 'Old'].forEach(userType => {
      const row = monthly[month][userType];
      if (!row) return;
      const tr = document.createElement('tr');
      const cells = [
        month,
        userType,
        row.obs == null ? '—' : fmtInt(row.obs),
        row.bad == null ? '—' : fmtInt(row.bad),
        row.rate == null ? '—' : fmtRate(row.rate),
        row.auc == null ? '—' : row.auc.toFixed(4),
        row.gini == null ? '—' : row.gini.toFixed(4),
        row.ks == null ? '—' : row.ks.toFixed(4),
      ];
      cells.forEach(text => {
        const td = document.createElement('td');
        td.textContent = text;
        tr.appendChild(td);
      });
      body.appendChild(tr);
    });
  });
}
renderMonthlyAuc();
</script>
</body>
</html>
"""


def build_mbr_summary(data, generated_iso):
    """MBR PPT 取数用的稳定 JSON：月度新老客 AUC + 最近 12 周整体 AUC + 头部 KPI。"""
    metrics = []
    for month in sorted(data["monthlyAuc"]):
        for user_type in ("ALL", "New", "Old"):
            row = data["monthlyAuc"][month].get(user_type)
            if not row:
                continue
            metrics.append({
                "userType": user_type,
                "granularity": "month",
                "period": month,
                "auc": row["auc"],
                "gini": row["gini"],
                "ks": row["ks"],
                "n": row["obs"],
                "bad": row["bad"],
                "rate": row["rate"],
            })
    for point in data["aucChart"]["points"][-12:]:
        metrics.append({
            "userType": "ALL",
            "granularity": "week",
            "period": point["week"],
            "auc": point["auc"],
            "gini": point["gini"],
            "ks": point["ks"],
            "n": point["obs"],
            "bad": point["bad"],
            "rate": point["rate"],
            "maturity": point["maturity"],
            "partial": point["partial"],
        })

    latest15 = data["latest"]["windows"].get(15) or {}
    return {
        "source": "wagego",
        "generatedAt": generated_iso,
        "metrics": metrics,
        "headline": {
            "fpd15Week": data["latest"]["week"],
            "fpd15Maturity": data["latest"]["fpd15Maturity"],
            "fpd15": latest15,
            "new15": data["new15"],
            "old15": data["old15"],
            "lift": data["lift"],
            "fpd30Maturity": data["fpd30Maturity"],
        },
    }


def render_html(data, generated_at, input_name, generated_iso):
    chart_data = {
        "fpdCurve": data["fpdCurve"],
        "weekChart": data["weekChart"],
        "scoreChart": data["scoreChart"],
        "rankChart": data["rankChart"],
        "aucChart": data["aucChart"],
        "monthlyAuc": data["monthlyAuc"],
        "mixChart": data["mixChart"],
        "psiByWeek": data["psiByWeek"],
        "generatedAt": generated_iso,
    }
    data_json = json.dumps(chart_data, ensure_ascii=False).replace("</", "<\\/")
    mbr_json = json.dumps(build_mbr_summary(data, generated_iso), ensure_ascii=False).replace("</", "<\\/")
    html = HTML_TEMPLATE
    replacements = {
        "__HEADER__": header_html(data),
        "__KPIS__": kpi_html(data),
        "__FPD_CARD__": fpd_card_html(data),
        "__WEEK_CARD__": week_card_html(data),
        "__SCORE_CARD__": score_card_html(data),
        "__STABILITY_CARD__": stability_card_html(data),
        "__MIX_CARD__": mix_card_html(data),
        "__RANK_CARD__": rank_card_html(data),
        "__QUALITY_CARD__": quality_card_html(data),
        "__FOOTER__": footer_html(data, generated_at, input_name),
        "__DATA_JSON__": data_json,
        "__MBR_JSON__": mbr_json,
    }
    for key, value in replacements.items():
        html = html.replace(key, value)
    return html


def main(argv=None):
    parser = argparse.ArgumentParser(description="从 vintage_data.zip 生成 Vintage 监控看板。")
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
