#!/usr/bin/env python3
"""<slug> 模型分分析骨架：读 数据/<slug>/ 的同步结果，输出自包含 HTML。

用法：
    python 分析/<slug>/build.py

正式报告建议直接复制最接近的已有 build.py（分析/新客戳额/build.py 或
分析/新老客发标/build.py）后改常量，本文件只演示目录、路径与内嵌数据的写法。
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from html import escape
from pathlib import Path

import pandas as pd

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

PROJECT_DIR = Path(__file__).resolve().parents[2]
ANALYSIS_DIR = Path(__file__).resolve().parent
RAW_DIR = PROJECT_DIR / "数据" / "<slug>"

DEFAULT_SAMPLE = RAW_DIR / "sample.csv"
DEFAULT_OUTPUT = ANALYSIS_DIR / "<报告名>.html"

MODEL_NAME = "<model_score_column>"
WINDOWS = (15, 7)


def load_sample(path):
    path = Path(path)
    if path.suffix.lower() in (".xlsx", ".xls"):
        df = pd.read_excel(path)
    else:
        df = pd.read_csv(path, encoding="utf-8-sig")
    if MODEL_NAME not in df.columns:
        raise ValueError(f"{path.name} 缺少模型分列 {MODEL_NAME}")
    return df


def build_data(df):
    bad = {f"fpd{w}": int(df[f"y_fpd{w}_ovd"].fillna(0).astype(int).sum()) for w in WINDOWS}
    mature = {f"fpd{w}": int(df[f"y_fpd{w}_ovd"].notna().sum()) for w in WINDOWS}
    return {
        "rows": int(len(df)),
        "bad": bad,
        "mature": mature,
        "generatedAt": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }


def render(data):
    rows = "".join(
        f"<tr><td>{escape(k.upper())}</td><td>{data['mature'][k]:,}</td>"
        f"<td>{data['bad'][k]:,}</td>"
        f"<td>{(data['bad'][k] / data['mature'][k] * 100 if data['mature'][k] else 0):.2f}%</td></tr>"
        for k in data["bad"]
    )
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title><slug> 模型分分析</title>
<style>
body{{font:14px/1.6 system-ui,sans-serif;margin:32px;color:#1d2433}}
table{{border-collapse:collapse}}th,td{{border:1px solid #d6dbe6;padding:6px 12px;text-align:right}}
th{{background:#f2f5fa}}td:first-child,th:first-child{{text-align:left}}
</style></head><body>
<h1><slug> 模型分分析</h1>
<p>样本 {data['rows']:,} 行</p>
<table><thead><tr><th>窗口</th><th>成熟笔数</th><th>坏笔数</th><th>笔数坏率</th></tr></thead>
<tbody>{rows}</tbody></table>
<p style="color:#6b7482">生成脚本 分析/<slug>/build.py；生成时间 {escape(data['generatedAt'])}。</p>
<script>const DATA = {json.dumps(data, ensure_ascii=False)};</script>
</body></html>
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description="<slug> 模型分分析。")
    parser.add_argument("--sample-csv", default=str(DEFAULT_SAMPLE), help="同步输出的样本 CSV")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="输出 HTML")
    args = parser.parse_args(argv)

    df = load_sample(args.sample_csv)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(build_data(df)), encoding="utf-8")
    print(f"已生成：{output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
