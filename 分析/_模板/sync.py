#!/usr/bin/env python3
"""同步 <slug> 分析输入：执行 <slug>.sql 的查询块。

产出：数据/<slug>/ 下的 CSV 与数据/<slug>/analysis_data.zip。
只服务 <slug> 分析；共用层仅根目录 sync_common.py。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[2]
if str(PROJECT_DIR) not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR))

from sync_common import (  # noqa: E402
    export_sql_blocks,
    load_query_fn,
    split_statements,
    table_name_from_sql,
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


ANALYSIS_DIR = Path(__file__).resolve().parent
SQL_FILE = ANALYSIS_DIR / "<slug>.sql"
RAW_DIR = PROJECT_DIR / "数据" / "<slug>"
RAW_DIR_NAME = "数据/<slug>"
ZIP_FILE = RAW_DIR / "analysis_data.zip"
FAILED_FILE = RAW_DIR / "sync_failed.csv"

# 块号 → 输出文件。顺序必须与 SQL 中的 SELECT 一一对应。
# 文件名是本目录 build.py 的默认输入名，导出时保持同名。
QUERY_SPECS = (
    {"id": "1", "file": "sample.csv", "title": "样本 + 模型分 + Y 标签"},
)


def build_queries():
    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    if len(statements) != len(QUERY_SPECS):
        raise ValueError(
            f"SQL 查询数 {len(statements)} 与 QUERY_SPECS 的 {len(QUERY_SPECS)} 条不一致；"
            "请同步更新 分析/<slug>/sync.py 的块号/文件名"
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
    parser = argparse.ArgumentParser(description="同步 <slug> 分析输入表。")
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
        queries,
        query_fn,
        raw_dir=RAW_DIR,
        raw_dir_name=RAW_DIR_NAME,
        zip_path=ZIP_FILE,
        failed_path=FAILED_FILE,
    )

    print(f"\n成功：{len(succeeded)} / 本次失败：{len(failed)}")
    print(f"输出目录：{RAW_DIR.resolve()}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
