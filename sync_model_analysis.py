#!/usr/bin/env python3
"""同步模型分分析输入：执行 wagego_05_模型分分析.sql 的查询块。

产出：同步数据/ 下的主表、戳额成交样本新模型分、戳额生产打分全量新模型分，以及 model_analysis_data.zip。
只服务模型分分析；监控看板见 sync_vintage.py。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from sync_common import (
    RAW_DIR,
    RAW_DIR_NAME,
    export_sql_blocks,
    load_query_fn,
    split_statements,
    table_name_from_sql,
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
SQL_FILE = PROJECT_DIR / "wagego_05_模型分分析.sql"
ZIP_FILE = PROJECT_DIR / "model_analysis_data.zip"
FAILED_FILE = PROJECT_DIR / "model_analysis_sync_failed.csv"

# 块号 → 输出文件。顺序必须与 SQL 中的 SELECT 一一对应。
# 文件名是 build_model_analysis.py 的默认输入名，导出时保持同名。
QUERY_SPECS = (
    {"id": "1", "file": "table_tmp_eliam_wagego_dwd_loan_apply_label.csv", "title": "Y 标签主表"},
    {"id": "2", "file": "aus_new_wagego_credit_20261028_v1_0_txn_lgb_score.csv", "title": "戳额成交样本新模型分"},
    {"id": "3", "file": "wagego_new_user_credit_20260801_20261023_score.csv", "title": "戳额生产打分全量新模型分"},
)


def build_queries():
    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    if len(statements) != len(QUERY_SPECS):
        raise ValueError(
            f"SQL 查询数 {len(statements)} 与 QUERY_SPECS 的 {len(QUERY_SPECS)} 条不一致；"
            "请同步更新 sync_model_analysis.py 的块号/文件名"
        )
    return [
        {**spec, "sql": statement, "table": table_name_from_sql(statement)}
        for spec, statement in zip(QUERY_SPECS, statements)
    ]


def select_queries(queries, raw):
    if not raw:
        return queries
    selected = [item.strip() for item in raw.split(",") if item.strip()]
    known = {query["table"] for query in queries}
    unknown = sorted(set(selected) - known)
    if unknown:
        raise ValueError(
            f"未知表名：{', '.join(unknown)}；可选：{', '.join(q['table'] for q in queries)}"
        )
    return [query for query in queries if query["table"] in selected]


def main(argv=None):
    parser = argparse.ArgumentParser(description="同步模型分分析输入表。")
    parser.add_argument("--tables", help="只同步指定表，逗号分隔（按 SQL 中 FROM 的表名匹配）")
    parser.add_argument("--dry-run", action="store_true", help="只检查块号和输出文件名，不连接数据库")
    args = parser.parse_args(argv)

    try:
        queries = select_queries(build_queries(), args.tables)
    except ValueError as exc:
        parser.error(str(exc))

    print(f"共 {len(queries)} 条查询：{SQL_FILE}")
    if args.dry_run:
        for query in queries:
            print(
                f"- {query['id']}. {query['title']} | {query['table']} "
                f"→ {RAW_DIR_NAME}/{query['file']}"
            )
        return 0

    query_fn = load_query_fn()
    if query_fn is None:
        return 2

    succeeded, failed = export_sql_blocks(
        queries, query_fn, zip_path=ZIP_FILE, failed_path=FAILED_FILE
    )

    print(f"\n成功：{len(succeeded)} / 本次失败：{len(failed)}")
    print(f"输出目录：{RAW_DIR.resolve()}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
