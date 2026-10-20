import argparse
import hashlib
import json
import re
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

# 查询直接取自 queries.sql：按分号切出每段查询，执行结果同步到 results/ 目录。
# 末尾输出失败清单 failed_tables.csv；跑完打包成 results.zip，便于留档或发送。
SQL_FILE = Path(__file__).resolve().parent / "queries.sql"
OUTPUT_DIR = Path(__file__).resolve().parent / "results"
FAILED_FILE = OUTPUT_DIR / "failed_tables.csv"
ZIP_FILE = Path(__file__).resolve().parent / "results.zip"
MANIFEST_FILE = OUTPUT_DIR / "sync_manifest.json"
BUSINESS_TZ = timezone(timedelta(hours=8))


def now():
    return datetime.now(BUSINESS_TZ)


# 段号（取 SQL 段首注释「N. 段名」的编号）→ 结果 CSV 文件名。
# 编号与 queries.sql 段首编号一一对应；文件名统一为「序号_英文_中文」。
SEGMENT_NAMES = {
    "1": "01_desc_asset_cmn_listing_资产表结构",
    "2": "02_desc_asset_debt_dtl_snp_债务快照结构",
    "3": "03_desc_credit_application_授信申请表结构",
    "4": "04_desc_credit_decision_授信决策表结构",
    "5": "05_desc_loan_decision_提款决策表结构",
    "6": "06_desc_user_fst_conv_新老客表结构",
    "7": "07_sample_asset_cmn_listing_资产表样例",
    "8": "08_sample_asset_debt_dtl_snp_债务快照样例",
    "9": "09_grain_asset_cmn_listing_资产表粒度",
    "10": "10_grain_asset_debt_dtl_snp_债务快照粒度",
    "11": "11_partitions_asset_debt_dtl_snp_债务快照分区",
    "12": "12_duplicates_asset_cmn_listing_资产表重复检查",
    "13": "13_duplicates_asset_debt_dtl_snp_债务快照重复检查",
    "14": "14_sample_user_fst_conv_新老客表样例",
}


def split_statements(sql_text):
    """切分 SQL 文件：每段以分号结尾，段名取自段首注释里的「N. 段名」编号。

    同段里的后续语句（如多条校验）没有自己的注释块，沿用上一段编号；
    CREATE / DROP 只执行不落 CSV；其余同段语句文件名加 _2、_3。
    """

    statements = []
    last_title = None

    for chunk in sql_text.split(";"):

        blocks = re.findall(r"/\*.*?\*/", chunk, flags=re.S)
        title = (re.search(r"^\s*(\d+(?:\.\d+)?)\.?\s+(.+?)\s*$", blocks[-1], flags=re.M)
                 if blocks else None)
        if title:
            last_title = title

        body = re.sub(r"/\*.*?\*/", " ", chunk, flags=re.S)
        body = re.sub(r"--[^\n]*", " ", body).strip()

        if not body:
            continue

        head = title or last_title
        index = len(statements) + 1
        is_ddl = body.upper().startswith(("CREATE", "DROP", "ALTER", "TRUNCATE"))
        name = SEGMENT_NAMES.get(head.group(1), f"query_{index}") if head else f"query_{index}"

        if not is_ddl:
            base = name
            used = {item[0] for item in statements if not item[3]}
            suffix = 2
            while name in used:
                name = f"{base}_{suffix}"
                suffix += 1

        statements.append((name, head.group(2) if head else "", body, is_ddl))

    return statements


def query_digest(sql):
    """SQL 与结果的版本对应关系；不把 CSV 存在误当作当前查询已执行。"""
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


def save_manifest(manifest):
    temporary = MANIFEST_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(MANIFEST_FILE)


def run_sync(statements, query_fn):
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {"schema_version": 2, "segments": {}}
    entries = manifest["segments"]
    success_tables, failed_tables = [], []

    for i, (name, title, sql, is_ddl) in enumerate(statements, start=1):
        print(f"\n[{i}/{len(statements)}] {name} — {title}")
        entry = {"sql_sha256": query_digest(sql),
                 "started_at": now().isoformat(timespec="seconds"), "status": "running"}
        entries[name] = entry
        save_manifest(manifest)
        try:
            df = query_fn(sql)
            if is_ddl:
                entry["status"] = "success"
                success_tables.append(name)
                print("成功 | 已执行 DDL（无结果集，不落 CSV）")
            else:
                if not isinstance(df, pd.DataFrame):
                    raise ValueError("查询未返回 DataFrame")
                output_path = OUTPUT_DIR / f"{name}.csv"
                temporary = output_path.with_suffix(".csv.tmp")
                df.to_csv(temporary, index=False, encoding="utf-8-sig")
                temporary.replace(output_path)
                entry.update(status="success", rows=len(df), columns=list(df.columns),
                             file_sha256=hashlib.sha256(output_path.read_bytes()).hexdigest())
                success_tables.append(name)
                print(f"成功 | {df.shape[0]} 行 × {df.shape[1]} 列 | {output_path}")
        except Exception as e:
            error_text = " ".join(str(e).split())
            if len(error_text) > 2000:
                error_text = error_text[:2000] + "...(truncated)"
            entry.update(status="failed", error=error_text)
            failed_tables.append({"table_name": name, "error": error_text, "run_time": entry["started_at"]})
            print(f"失败 | {error_text}")
        finally:
            entry["finished_at"] = now().isoformat(timespec="seconds")
            save_manifest(manifest)

    failures = [{"table_name": name, "error": e.get("error", "执行未完成"),
                 "run_time": e.get("started_at", "")}
                for name, e in entries.items() if e.get("status") != "success"]
    pd.DataFrame(failures, columns=["table_name", "error", "run_time"]).to_csv(
        FAILED_FILE, index=False, encoding="utf-8-sig")

    # 只打包当前代码可验证的成功结果；没有元数据的旧段不混入新结果包。
    current = {name: query_digest(sql) for name, _, sql, ddl in
               split_statements(SQL_FILE.read_text(encoding="utf-8")) if not ddl}
    with zipfile.ZipFile(ZIP_FILE, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, e in entries.items():
            path = OUTPUT_DIR / f"{name}.csv"
            if (e.get("status") == "success" and e.get("sql_sha256") == current.get(name)
                    and path.exists() and e.get("file_sha256") == hashlib.sha256(path.read_bytes()).hexdigest()):
                archive.write(path, f"results/{path.name}")
        archive.write(MANIFEST_FILE, "results/sync_manifest.json")
        archive.write(FAILED_FILE, "results/failed_tables.csv")
    print(f"\n已打包：{ZIP_FILE}（仅含版本校验通过的结果及元数据）")
    print(f"\n成功：{len(success_tables)} / 本次失败：{len(failed_tables)}")
    print(f"数据目录：{OUTPUT_DIR.resolve()}\n失败清单：{FAILED_FILE.resolve()}")
    return 1 if failed_tables else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="执行 queries.sql 并同步结果到 results/。")
    parser.add_argument("--segments", help="只执行指定段，逗号分隔，如 1,2,11")
    parser.add_argument("--dry-run", action="store_true", help="只检查段号与查询清单，不连接数据库")
    args = parser.parse_args(argv)

    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    if args.segments:
        selected = {item.strip() for item in args.segments.split(",")}
        unknown = selected - SEGMENT_NAMES.keys()
        if unknown:
            parser.error(f"未知段号：{', '.join(sorted(unknown))}")
        bases = [SEGMENT_NAMES[key] for key in selected]
        statements = [s for s in statements
                      if any(s[0] == base or s[0].startswith(base + "_") for base in bases)]

    print(f"共 {len(statements)} 条查询：{SQL_FILE}")
    if args.dry_run:
        for name, title, _, _ in statements:
            print(f"- {name} — {title}")
        return 0

    try:
        from hive_config import query_to_df
    except ImportError:
        raise SystemExit(
            "缺少 hive_config.py：请把原项目的 hive_config.py 放到本目录，"
            "或按你的连接方式实现 query_to_df(sql) -> DataFrame。"
        )
    return run_sync(statements, query_to_df)


if __name__ == "__main__":
    raise SystemExit(main())
