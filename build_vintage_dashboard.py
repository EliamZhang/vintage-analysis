#!/usr/bin/env python3
"""Build a self-contained WageGo vintage monitoring dashboard from vintage_data.zip."""

from __future__ import annotations

import argparse
import csv
import io
import json
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
    if input_path.is_dir():
        files = {p.name: p.read_bytes() for p in input_path.glob("vintage_*.csv")}
    elif input_path.is_file() and input_path.suffix.lower() == ".zip":
        with zipfile.ZipFile(input_path) as archive:
            files = {
                Path(name).name: archive.read(name)
                for name in archive.namelist()
                if name.lower().endswith(".csv")
            }
    else:
        raise ValueError(f"输入既不是 zip 也不是目录：{input_path}")

    missing = [name for name in REQUIRED_FILES if name not in files]
    if missing:
        raise ValueError(f"缺少 CSV：{', '.join(missing)}")

    parsed = {}
    for name in REQUIRED_FILES:
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

    week_chart = {"labels": [], "weeks": [], "fpd3": [], "fpd15": [], "fpd15Low": []}
    for item in chart_weeks:
        fpd3_row = item["windows"].get(3)
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

    def score_series(segment, name, color):
        return {
            "name": name,
            "key": segment,
            "color": color,
            "points": [score[segment][q] for q in range(1, 6)],
        }

    score_chart = {
        "labels": [f"Q{q}" for q in range(1, 6)],
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
    <p class="sub">按放款周看首期逾期率（FPD），并用模型分五分位和复借期数拆分；除标注“金额”外，坏率均为笔数口径。</p>
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
    return f"""
<section class="kpis">
  <div class="kpi">
    <span class="label">整体 FPD15 · 坏率（笔数）</span>
    <b>{fmt_rate(fpd15['rate'])}</b>
    <span class="sub">n={fmt_int(fpd15['obs'])} · 坏率（金额）{fmt_rate(fpd15['amtRate'])}</span>
  </div>
  <div class="kpi">
    <span class="label">最新可用周 · 坏率（笔数）</span>
    <b>{fmt_rate(latest_rate)}</b>
    <span class="sub">{latest['week']} · {fmt_pct0(latest['fpd15Maturity'])} 成熟 · 较前周 {fmt_delta(data['latestDelta'])}</span>
  </div>
  <div class="kpi">
    <span class="label">新客 / 老客 FPD15 · 坏率（笔数）</span>
    <b class="split">{fmt_rate(new15['rate'])} / {fmt_rate(old15['rate'])}</b>
    <span class="sub">gap {fmt_delta(gap)} · n={fmt_int(new15['obs'])} / {fmt_int(old15['obs'])} · 金额 {fmt_rate(new15['amtRate'])} / {fmt_rate(old15['amtRate'])}</span>
  </div>
  <div class="kpi">
    <span class="label">模型 Q5 / Q1 · 坏率（笔数）</span>
    <b>{lift:.2f}x</b>
    <span class="sub">Q5 {fmt_rate(q5['rate'])} · Q1 {fmt_rate(q1['rate'])} · 覆盖 {data['coverage']['pct']:.2f}%</span>
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
        cells = [rate_cell(week, window) for window in (3, 7, 14, 15, 30)]
        rows.append(
            f"<tr><td>{week['week']}</td>"
            f"<td class='num'>{sample}</td>"
            f"<td class='{maturity_class}'>{maturity}</td>"
            f"{''.join(cells)}</tr>"
        )
    return f"""
<div class="table-wrap">
<table>
  <thead><tr><th>放款周</th><th>FPD15 成熟样本</th><th>FPD15 成熟度</th><th>FPD3</th><th>FPD7</th><th>FPD14</th><th>FPD15</th><th>FPD30</th></tr></thead>
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
        "坏率均为笔数口径。成熟度 = 该窗口成熟样本 / 当周 FPD3 样本。"
        "星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示（FPD30 采用 90% 阈值）。"
        f"≥90% 成熟的最后一周：FPD15 {complete['week']}（{fmt_rate(complete['windows'][15]['rate'])}）；"
        f"{latest['week']} 为 {fmt_pct0(latest['fpd15Maturity'])} 成熟（{fmt_rate(latest['windows'][15]['rate'])}*）。"
        f"{low_text}；{latest_text}。{early_text}。"
    )
    return f"""
<section class="card">
  <h2>按放款周：FPD15 与早期信号{TAG_COUNT}</h2>
  <p class="desc">纵轴为笔数坏率；FPD15 是确认指标，FPD3 是早期信号；空心点表示成熟度不足或周未完整。</p>
  <div class="chart-wrap">
    <svg id="weekChart" viewBox="0 0 1040 300" role="img" aria-label="各放款周的 FPD15 与 FPD3 笔数坏率"></svg>
    <div class="tip" id="weekTip"></div>
  </div>
  <div class="legend">
    <span><i style="background:var(--c1)"></i>FPD15</span>
    <span><i class="dash"></i>FPD3 早期信号</span>
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
            f"<tr><td>Q{q}</td><td class='range'>{range_text(q)}</td>"
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
    rows = []
    for q in range(1, 6):
        cells = []
        for week in weeks:
            row = data["scoreWeek"][week].get(q)
            if not row:
                cells.append('<td class="num dim">—</td>')
                continue
            maturity = data["weeksBy"][week]["fpd15Maturity"] if week in data["weeksBy"] else 1.0
            if maturity < 0.7:
                cells.append(
                    f'<td class="num dim" title="FPD15 成熟度 {fmt_pct0(maturity)}，仅参考">'
                    f"{fmt_rate(row['rate'])}</td>"
                )
            elif maturity < 0.9:
                cells.append(
                    f'<td class="num soft" title="FPD15 成熟度 {fmt_pct0(maturity)}，仅参考">'
                    f"{sup(fmt_rate(row['rate']), '*')}</td>"
                )
            else:
                cells.append(f'<td class="num">{fmt_rate(row["rate"])}</td>')
        rows.append(f"<tr><td>Q{q}</td>{''.join(cells)}</tr>")
    return f"""
<div class="table-wrap">
<div class="subhead">分档 × 放款周（FPD15 笔数坏率）</div>
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
        else "整体与新客基本单调；老客 Q2/Q4 低于前一档，排序弱于新客。"
    )
    sentinel = (
        "Q1 分数下限 -1.0，疑似缺分哨兵；分档按原查询结果展示，未单独剔除。"
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
        f"坏率均为 FPD15 笔数口径。Q1 最低分，Q5 最高分。整体 Q5/Q1 = {lift['ALL']:.2f}x，"
        f"新客 {lift['New']:.2f}x，老客 {lift['Old']:.2f}x。{shape}"
        f"覆盖 {data['coverage']['pct']:.2f}%（{fmt_int(data['coverage']['scored'])}/{fmt_int(data['coverage']['obs'])}），"
        f"缺分 {fmt_int(data['coverage']['missing'])}。{heat_note}{sentinel}"
    )
    return f"""
<section class="card">
  <h2>模型分五分位{TAG_COUNT}</h2>
  <p class="desc">Q1 最低分 → Q5 最高分；整体、新客、老客的 FPD15 笔数坏率（y_fpd15_ovd / y_fpd15_obs）。</p>
  <div class="chart-wrap">
    <svg id="scoreChart" viewBox="0 0 1040 300" role="img" aria-label="模型分五分位的整体、新客、老客 FPD15 笔数坏率"></svg>
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
        "Q1 下限 -1.0，疑似缺分哨兵。"
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
    return f"""
<footer class="foot">
  <ul class="notes">
    <li>笔数坏率（看板默认口径）：y_fpdN_ovd 之和 / y_fpdN_obs 之和。FPD-X：首期应还日 due + X 天前未还清首期；成熟样本为 y_fpdN_obs = 1（is_deal = 1、观察日有借据快照且 due + X &lt; obs_dt），未成熟不判坏（即使已结清）。FPD14 由 stg_debt_snp 首期实还日补算，成熟条件同口径。</li>
    <li>金额坏率（仅总览表与 KPI 子行）：estimate_principal_remaining_fpdN 之和 / 全部成熟样本放款本金；余额取 due+X 当天借据快照（FPD14 同机制），当天无快照的不计入分子。</li>
    <li>成熟度：该窗口成熟样本 / 当周 FPD3 样本；星号 * 表示 70–90% 成熟，仅参考；† 表示放款周未完整；— 表示成熟度低于 70%，不展示；FPD30 采用 90% 阈值。</li>
    <li>新老客：user_type 按首笔放款；复借期数 application_rank，1st = 首借，2nd 起为 Old，4th+ 含 4 次及以上。</li>
    <li>模型分：FPD15 成熟样本内 pooled 五分位，Q1 最低分、Q5 最高分；分数越高越坏。</li>
    <li>数据源：{escape(input_name)}（8 个 CSV）；生成脚本：build_vintage_dashboard.py；生成时间：{escape(generated_at)}。</li>
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
    .split { grid-template-columns: 1fr; }
    .quality { grid-template-columns: 1fr; }
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
__FPD_CARD__
__WEEK_CARD__
__SCORE_CARD__
__RANK_CARD__
__QUALITY_CARD__
__FOOTER__
</main>
<script>
const DATA = __DATA_JSON__;
const NS = 'http://www.w3.org/2000/svg';
const fmtRate = v => (v == null ? '—' : v.toFixed(2) + '%');
const fmtInt = n => (n == null ? '—' : n.toLocaleString('en-US'));

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
  const { width, height, margin, labels, series, yMax, yTicks, xLabel, yLabel } = cfg;
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
    }, v + '%');
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
  const { width, height, margin, data, yMax, yTicks, color, xLabel, yLabel } = cfg;
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
    }, v + '%');
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

const weekSeries = [
  { name: 'FPD3', key: 'fpd3', color: 'var(--muted)', points: DATA.weekChart.fpd3, dash: '5 4', width: 1.8 },
  { name: 'FPD15', key: 'fpd15', color: 'var(--c1)', points: DATA.weekChart.fpd15, width: 2 }
];
const lastPointIndex = points => {
  for (let i = points.length - 1; i >= 0; i--) if (points[i]) return i;
  return -1;
};
const last15 = lastPointIndex(DATA.weekChart.fpd15);
const last3 = lastPointIndex(DATA.weekChart.fpd3);
makeLineChart('weekChart', 'weekTip', {
  width: 1040, height: 300, margin: { t: 30, r: 100, b: 46, l: 56 },
  labels: DATA.weekChart.labels,
  series: weekSeries,
  yMax: 20, yTicks: [0, 5, 10, 15, 20], xLabel: '放款周（2026）', yLabel: '笔数坏率',
  directLabels: [
    {
      series: 1, index: last15,
      text: `FPD15 ${fmtRate(DATA.weekChart.fpd15[last15].rate)}${DATA.weekChart.fpd15[last15].partial ? '*' : ''}`,
      dx: 8, dy: -10, anchor: 'start'
    },
    {
      series: 0, index: last3,
      text: `FPD3 ${fmtRate(DATA.weekChart.fpd3[last3].rate)}${DATA.weekChart.fpd3[last3].partial ? '†' : ''}`,
      dx: -8, dy: -10, anchor: 'end'
    }
  ],
  tooltip: index => {
    const parts = [`<b>${DATA.weekChart.weeks[index]} · 笔数坏率</b>`];
    const fpd3 = DATA.weekChart.fpd3[index];
    const fpd15 = DATA.weekChart.fpd15[index];
    if (fpd3) parts.push(`<span><i style="background:var(--muted)"></i>FPD3 <b>${fmtRate(fpd3.rate)}</b> · n=${fmtInt(fpd3.obs)}${fpd3.partial ? ' · 周未完整' : ''}</span>`);
    if (fpd15) parts.push(`<span><i style="background:var(--c1)"></i>FPD15 <b>${fmtRate(fpd15.rate)}</b> · n=${fmtInt(fpd15.obs)} · ${Math.round(fpd15.maturity * 100)}% 成熟${fpd15.partial ? '*' : ''}</span>`);
    else {
      const low = DATA.weekChart.fpd15Low[index];
      parts.push(low
        ? `<span><i style="background:var(--muted)"></i>FPD15 <b>${fmtRate(low.rate)}</b> · n=${fmtInt(low.obs)} · ${Math.round(low.maturity * 100)}% 成熟（低于 70%，未入图）</span>`
        : '<span>FPD15 尚未达到 70% 成熟</span>');
    }
    return parts.join('<br>');
  }
});

const scoreSeries = DATA.scoreChart.series;
makeLineChart('scoreChart', 'scoreTip', {
  width: 1040, height: 300, margin: { t: 30, r: 135, b: 46, l: 56 },
  labels: DATA.scoreChart.labels,
  series: scoreSeries,
  yMax: 20, yTicks: [0, 5, 10, 15, 20], xLabel: '模型分五分位（低 → 高）', yLabel: '笔数坏率',
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

makeBarChart('rankChart', 'rankTip', {
  width: 520, height: 300, margin: { t: 30, r: 24, b: 64, l: 52 },
  data: DATA.rankChart,
  yMax: 12, yTicks: [0, 3, 6, 9, 12],
  color: 'var(--c1)', xLabel: '复借期数', yLabel: '笔数坏率'
});
</script>
</body>
</html>
"""


def render_html(data, generated_at, input_name):
    chart_data = {
        "fpdCurve": data["fpdCurve"],
        "weekChart": data["weekChart"],
        "scoreChart": data["scoreChart"],
        "rankChart": data["rankChart"],
    }
    data_json = json.dumps(chart_data, ensure_ascii=False).replace("</", "<\\/")
    html = HTML_TEMPLATE
    replacements = {
        "__HEADER__": header_html(data),
        "__KPIS__": kpi_html(data),
        "__FPD_CARD__": fpd_card_html(data),
        "__WEEK_CARD__": week_card_html(data),
        "__SCORE_CARD__": score_card_html(data),
        "__RANK_CARD__": rank_card_html(data),
        "__QUALITY_CARD__": quality_card_html(data),
        "__FOOTER__": footer_html(data, generated_at, input_name),
        "__DATA_JSON__": data_json,
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

    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    html = render_html(data, generated_at, input_path.name)
    output_path.write_text(html, encoding="utf-8")
    print(f"已生成：{output_path}")
    print(f"图表周：{data['chartWeeks'][0]['week']} ~ {data['latestWeek']['week']}（{len(data['chartWeeks'])} 周）")
    print(f"FPD15 最新可用周：{data['latest']['week']}（{fmt_pct0(data['latest']['fpd15Maturity'])} 成熟）")
    print(f"整体 FPD15：{fmt_rate(data['overallBy'][15]['rate'])}；模型 Q5/Q1：{data['lift']['ALL']:.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
