"""执行 wagego_04_vintage分析.sql，把各查询块结果写入 原始数据/ 并打包成 vintage_data.zip。

SQL 文件按「块 N」注释组织；脚本按分号拆分语句，开头的 SET 作为全局会话设置，
其余 SELECT 按 QUERY_SPECS 的顺序执行，每个结果写一个 CSV。
另外按 DEFAULT_TABLES（或 --tables 指定）整表拉取底表，输出 table_<表名>.csv，
一并打进 zip，方便本地看明细。
数据库连接由外部 hive_config.query_to_df(sql) 提供，本脚本不负责建连。
"""

import argparse
import hashlib
import json
import re
import sys
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
SQL_FILE = PROJECT_DIR / "wagego_04_vintage分析.sql"

RAW_DIR = PROJECT_DIR / "原始数据"
LOG_DIR = PROJECT_DIR / "同步日志"
MANIFEST_FILE = LOG_DIR / "sync_manifest.json"
FAILED_FILE = LOG_DIR / "failed_tables.csv"
ZIP_FILE = PROJECT_DIR / "vintage_data.zip"

RAW_DIR_NAME = "原始数据"
BUSINESS_TZ = timezone(timedelta(hours=8))

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

# 整表拉取：默认把样本主表拉回本地，输出 table_<表名>.csv
DEFAULT_TABLES = ("model.tmp_eliam_wagego_dwd_loan_apply_label",)

_TABLE_NAME_RE = re.compile(r"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$")
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", flags=re.S)
_LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def now():
    return datetime.now(BUSINESS_TZ)


def query_digest(sql):
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


def file_digest(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
            "请同步更新 sync.py 的块号/文件名"
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


def select_tables(raw, no_tables):
    """解析 --tables；默认拉 DEFAULT_TABLES，--no-tables 时返回空。"""
    if no_tables:
        return []
    names = DEFAULT_TABLES if raw is None else tuple(
        name.strip() for name in raw.split(",") if name.strip()
    )
    invalid = [name for name in names if not _TABLE_NAME_RE.match(name)]
    if invalid:
        raise ValueError(f"表名不合法：{', '.join(invalid)}（只允许字母、数字、下划线、点）")
    return names


def table_file(table):
    """model.tmp_xxx → table_tmp_xxx.csv"""
    return f"table_{table.split('.')[-1]}.csv"


def run_query_to_csv(sql, path, query_fn):
    """执行一条查询并把结果写到 path；返回 (行数, 列名)。失败时抛异常。"""
    # 删掉上一次的文件，失败时目录里不会留下看似成功的旧结果。
    if path.exists():
        path.unlink()

    df = query_fn(sql)
    if not isinstance(df, pd.DataFrame):
        raise ValueError("查询未返回 DataFrame")
    if len(df) == 0:
        print("警告 | 查询返回 0 行，请确认底表是否有数据")

    temporary = path.with_suffix(".csv.tmp")
    try:
        df.to_csv(temporary, index=False, encoding="utf-8-sig")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()
    return int(len(df)), list(df.columns)


def save_manifest(manifest):
    temporary = MANIFEST_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(MANIFEST_FILE)


def run_sync(setup_statements, queries, tables, query_fn, table_limit=0):
    for folder in (RAW_DIR, LOG_DIR):
        folder.mkdir(parents=True, exist_ok=True)

    manifest = {
        "sql_file": SQL_FILE.name,
        "sql_sha256": query_digest(SQL_FILE.read_text(encoding="utf-8")),
        "run_at": now().isoformat(timespec="seconds"),
        "queries": {},
        "tables": {},
    }
    save_manifest(manifest)

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
        save_manifest(manifest)

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
            save_manifest(manifest)

    # 整表拉取：底表明细拉回本地，方便离线看数
    for table in tables:
        filename = table_file(table)
        path = RAW_DIR / filename
        sql = f"SELECT * FROM {table}"
        if table_limit > 0:
            sql += f" LIMIT {table_limit}"
        print(f"\n[表] {table} → {RAW_DIR_NAME}/{filename}")

        entry = {
            "table": table,
            "file": f"{RAW_DIR_NAME}/{filename}",
            "sql": sql,
            "started_at": now().isoformat(timespec="seconds"),
            "status": "running",
        }
        manifest["tables"][table] = entry
        save_manifest(manifest)

        try:
            rows, columns = run_query_to_csv(sql, path, query_fn)

            entry.update(
                status="success",
                rows=rows,
                columns=columns,
                file_sha256=file_digest(path),
            )
            succeeded.append((path, f"{RAW_DIR_NAME}/{filename}"))
            print(f"成功 | {rows} 行 × {len(columns)} 列 | {path}")
        except Exception as exc:
            entry.update(status="failed", error=str(exc))
            failed.append(
                {
                    "block": f"table:{table}",
                    "file": filename,
                    "error": str(exc),
                    "run_time": entry["started_at"],
                }
            )
            print(f"失败 | {exc}")
        finally:
            entry["finished_at"] = now().isoformat(timespec="seconds")
            save_manifest(manifest)

    pd.DataFrame(
        failed,
        columns=["block", "file", "error", "run_time"],
    ).to_csv(FAILED_FILE, index=False, encoding="utf-8-sig")

    if succeeded:
        temporary_zip = ZIP_FILE.with_suffix(".zip.tmp")
        with zipfile.ZipFile(temporary_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{RAW_DIR_NAME}/", "")
            for path, arcname in succeeded:
                archive.write(path, arcname)
        temporary_zip.replace(ZIP_FILE)
        print(f"\n已打包：{ZIP_FILE}（数据表 {len(succeeded)} 个文件）")
    else:
        print(f"\n本次没有可打包的成功结果，未更新 {ZIP_FILE.name}")

    print(f"\n成功：{len(succeeded)} / 本次失败：{len(failed)}")
    print(f"输出目录：{RAW_DIR.resolve()}")
    print(f"失败清单：{FAILED_FILE.resolve()}")
    print(f"运行清单：{MANIFEST_FILE.resolve()}")
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="执行 wagego_04_vintage分析.sql 并打包产出数据。")
    parser.add_argument("--blocks", help="只执行指定块，逗号分隔，如 1,3,5a,5b,6,7")
    parser.add_argument(
        "--tables",
        help=f"整表拉取的表名，逗号分隔；默认拉 {','.join(DEFAULT_TABLES)}；用 --no-tables 关闭",
    )
    parser.add_argument("--no-tables", action="store_true", help="不整表拉取底表")
    parser.add_argument(
        "--table-limit",
        type=int,
        default=0,
        help="整表拉取只取前 N 行（0 = 全量）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只检查块号和输出文件名，不连接数据库")
    args = parser.parse_args(argv)

    try:
        setup, queries = build_queries()
        queries = select_queries(queries, args.blocks)
        tables = select_tables(args.tables, args.no_tables)
    except ValueError as exc:
        parser.error(str(exc))

    print(f"共 {len(queries)} 条查询：{SQL_FILE}")
    if tables:
        print(f"整表拉取：{', '.join(tables)}")
    if args.dry_run:
        for query in queries:
            print(f"- {query['id']}. {query['title']} → {relative_path(query)}")
        for table in tables:
            print(f"- [表] {table} → {RAW_DIR_NAME}/{table_file(table)}")
        return 0

    try:
        from hive_config import query_to_df
    except ImportError:
        print("未找到 hive_config.py：请把提供 query_to_df(sql) 的模块放到本脚本同目录或 PYTHONPATH 中。")
        return 2

    return run_sync(setup, queries, tables, query_to_df, args.table_limit)


if __name__ == "__main__":
    raise SystemExit(main())
