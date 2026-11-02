#!/usr/bin/env python3
"""同步 Vintage 监控看板数据：执行 wagego_04_vintage分析.sql 的 8 个查询块。

产出：原始数据/vintage_01~07.csv、vintage_data.zip、同步日志/vintage_manifest.json。
只服务监控看板；模型比对的表同步见 sync_model_compare.py。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from sync_common import (
    LOG_DIR,
    RAW_DIR,
    RAW_DIR_NAME,
    file_digest,
    load_query_fn,
    new_manifest,
    now,
    query_digest,
    run_query_to_csv,
    save_manifest,
    write_failures,
    zip_outputs,
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
SQL_FILE = PROJECT_DIR / "wagego_04_vintage分析.sql"
MANIFEST_FILE = LOG_DIR / "vintage_manifest.json"
FAILED_FILE = LOG_DIR / "vintage_failed_queries.csv"
ZIP_FILE = PROJECT_DIR / "vintage_data.zip"

# 块号 → 输出文件。顺序必须与 SQL 中 SET 之后的 SELECT 一一对应。
QUERY_SPECS = (
    {"id": "1", "file": "vintage_01_fpd_overall", "title": "各窗口成熟样本、坏样本、笔数坏率、金额坏率"},
    {"id": "2", "file": "vintage_02_fpd15_vs_fpd30", "title": "共同 cohort 上 FPD15 vs FPD30"},
    {"id": "3", "file": "vintage_03_user_type", "title": "新老客拆分（每个 FPD 窗口 × user_type）"},
    {"id": "4", "file": "vintage_04_week", "title": "按放款周的 vintage 路径"},
    {"id": "5a", "file": "vintage_05a_score_coverage", "title": "模型分覆盖（FPD15 成熟样本）"},
    {"id": "5b", "file": "vintage_05b_score_quintile", "title": "模型分五分位 × 新老客"},
    {"id": "6", "file": "vintage_06_score_quintile_week", "title": "模型分五分位 × 放款周"},
    {"id": "7", "file": "vintage_07_application_rank", "title": "老客复借期数（FPD15）"},
)

_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", flags=re.S)
_LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def split_statements(sql_text):
    """去掉注释后按分号拆分；返回 SQL 语句列表。"""
    body = _BLOCK_COMMENT_RE.sub(" ", sql_text)
    body = _LINE_COMMENT_RE.sub(" ", body)
    return [part.strip() for part in body.split(";") if part.strip()]


def build_queries():
    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    setup = []
    while statements and statements[0].lstrip().upper().startswith("SET "):
        setup.append(statements.pop(0))
    if len(statements) != len(QUERY_SPECS):
        raise ValueError(
            f"SQL 查询数 {len(statements)} 与 QUERY_SPECS 的 {len(QUERY_SPECS)} 条不一致；"
            "请同步更新 sync_vintage.py 的块号/文件名"
        )
    queries = [
        {**spec, "sql": statement}
        for spec, statement in zip(QUERY_SPECS, statements)
    ]
    return setup, queries


def select_queries(queries, raw):
    if not raw:
        return queries
    selected = [item.strip() for item in raw.split(",") if item.strip()]
    known = {query["id"] for query in queries}
    unknown = sorted(set(selected) - known)
    if unknown:
        raise ValueError(
            f"未知块号：{', '.join(unknown)}；可选：{', '.join(q['id'] for q in queries)}"
        )
    return [query for query in queries if query["id"] in selected]


def target_path(query):
    return RAW_DIR / f"{query['file']}.csv"


def relative_path(query):
    return f"{RAW_DIR_NAME}/{query['file']}.csv"


def run(setup_statements, queries, query_fn):
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    manifest = new_manifest("vintage", SQL_FILE)
    save_manifest(MANIFEST_FILE, manifest)

    for setup_sql in setup_statements:
        print(f"全局 SET | {setup_sql}")
        try:
            query_fn(setup_sql)
        except Exception as exc:
            print(f"警告 | 全局 SET 执行失败：{exc}")
            print("      请确认 query_to_df 使用同一会话，或执行环境已设置 Australia/Sydney 时区。")

    failed = []
    succeeded = []
    for index, query in enumerate(queries, start=1):
        block = query["id"]
        path = target_path(query)
        print(f"\n[{index}/{len(queries)}] {block}. {query['title']} → {RAW_DIR_NAME}/{path.name}")

        entry = {
            "title": query["title"],
            "file": relative_path(query),
            "sql_sha256": query_digest(query["sql"]),
            "started_at": now().isoformat(timespec="seconds"),
            "status": "running",
        }
        manifest["queries"][block] = entry
        save_manifest(MANIFEST_FILE, manifest)

        try:
            rows, columns = run_query_to_csv(query["sql"], path, query_fn)
            entry.update(
                status="success",
                rows=rows,
                columns=columns,
                file_sha256=file_digest(path),
            )
            succeeded.append((path, relative_path(query)))
            print(f"成功 | {rows} 行 × {len(columns)} 列 | {path}")
        except Exception as exc:
            entry.update(status="failed", error=str(exc))
            failed.append(
                {
                    "block": block,
                    "file": query["file"],
                    "error": str(exc),
                    "run_time": entry["started_at"],
                }
            )
            print(f"失败 | {exc}")
        finally:
            entry["finished_at"] = now().isoformat(timespec="seconds")
            save_manifest(MANIFEST_FILE, manifest)

    write_failures(failed, FAILED_FILE)
    zip_outputs(succeeded, ZIP_FILE)

    print(f"\n成功：{len(succeeded)} / 本次失败：{len(failed)}")
    print(f"输出目录：{RAW_DIR.resolve()}")
    print(f"失败清单：{FAILED_FILE.resolve()}")
    print(f"运行清单：{MANIFEST_FILE.resolve()}")
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="同步 Vintage 监控看板数据。")
    parser.add_argument("--blocks", help="只执行指定块，逗号分隔，如 1,3,5a,5b,6,7")
    parser.add_argument("--dry-run", action="store_true", help="只检查块号和输出文件名，不连接数据库")
    args = parser.parse_args(argv)

    try:
        setup, queries = build_queries()
        queries = select_queries(queries, args.blocks)
    except ValueError as exc:
        parser.error(str(exc))

    print(f"共 {len(queries)} 条查询：{SQL_FILE}")
    if args.dry_run:
        for query in queries:
            print(f"- {query['id']}. {query['title']} → {relative_path(query)}")
        return 0

    query_fn = load_query_fn()
    if query_fn is None:
        return 2
    return run(setup, queries, query_fn)


if __name__ == "__main__":
    raise SystemExit(main())
