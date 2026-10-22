"""执行 queries.sql，把《放款申请样本表及Y标签.sql》依赖的原始表和产出表打包成 vintage_data.zip。

queries.sql 按「N. 段名」注释分段，段号从 1 连续排列。每段可以包含多条以分号结尾的
语句：前面的语句是建表等准备工作，最后一条语句的结果写入 原始数据/ 下的 CSV。本脚本：
1. 按段号顺序执行，每段结果写入 原始数据/ 下的 CSV；
2. 打包成 vintage_data.zip，压缩包根目录只有 原始数据/ 文件夹；
3. 运行日志、失败清单和 manifest 放在 同步日志/，不进入压缩包。

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
SQL_FILE = PROJECT_DIR / "queries.sql"

RAW_DIR = PROJECT_DIR / "原始数据"
LOG_DIR = PROJECT_DIR / "同步日志"
MANIFEST_FILE = LOG_DIR / "sync_manifest.json"
FAILED_FILE = LOG_DIR / "failed_tables.csv"
ZIP_FILE = PROJECT_DIR / "vintage_data.zip"

RAW_DIR_NAME = "原始数据"

BUSINESS_TZ = timezone(timedelta(hours=8))

# 段号 → 输出文件。段号必须和 queries.sql 段首注释一一对应，且从 1 连续排列。
SEGMENT_SPECS = {
    "1": {"file": "01_aus_ewa_loan_biz_t_loan_application"},
    "2": {"file": "02_dwb_asset_cmn_listing"},
    "3": {"file": "03_dwb_asset_debt_dtl_snp"},
    "4": {"file": "04_aus_ewa_risk_risk_event_task"},
    "5": {"file": "05_aus_listing_tb_loan_limit_apply"},
    "6": {"file": "06_tmp_eliam_wagego_param_obs_date"},
    "7": {"file": "07_tmp_eliam_wagego_stg_debt_snp"},
    "8": {"file": "08_tmp_eliam_wagego_dwd_loan_apply_label"},
}

_HEADER_RE = re.compile(r"/\*\s*\r?\n\s*=+\s*\r?\n\s*(\d+)\.\s+([^\r\n]+)")
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
    """按段首「N. 段名」注释分块，每块再按分号拆成多条语句。

    只有以「/* + 等号行 + 标题行」开头的注释块才算段首。段内最后一条语句视为查询，
    其余语句作为建表等准备语句依次执行。
    """
    headers = []
    for block in _BLOCK_COMMENT_RE.finditer(sql_text):
        match = _HEADER_RE.match(block.group(0))
        if match:
            headers.append((block.start(), block.end(), match.group(1), match.group(2).strip()))
    if not headers:
        raise ValueError("queries.sql 中没有找到「N. 段名」注释")

    statements = []
    seen = set()
    for index, (_, header_end, number, title) in enumerate(headers):
        end = headers[index + 1][0] if index + 1 < len(headers) else len(sql_text)
        chunk = sql_text[header_end:end]

        body = _BLOCK_COMMENT_RE.sub(" ", chunk)
        body = _LINE_COMMENT_RE.sub(" ", body)
        parts = [part.strip() for part in body.split(";") if part.strip()]

        if not parts:
            raise ValueError(f"段 {number} 没有可执行语句")
        if number in seen:
            raise ValueError(f"段号重复：{number}")
        seen.add(number)
        statements.append(
            {
                "number": number,
                "title": title,
                "setup": parts[:-1],
                "sql": parts[-1],
            }
        )
    return statements


def load_statements():
    statements = split_statements(SQL_FILE.read_text(encoding="utf-8"))
    actual = [item["number"] for item in statements]
    expected = [str(index) for index in range(1, len(statements) + 1)]
    if actual != expected:
        raise ValueError(f"段号必须从 1 连续排列，实际为：{', '.join(actual)}")
    missing = sorted(set(actual) - set(SEGMENT_SPECS), key=int)
    extra = sorted(set(SEGMENT_SPECS) - set(actual), key=int)
    if missing or extra:
        raise ValueError(
            f"段号与脚本注册表不一致：SQL 多出 {missing or '无'}，注册表多出 {extra or '无'}"
        )
    return statements


def target_path(spec):
    return RAW_DIR / f"{spec['file']}.csv"


def relative_path(spec):
    return f"{RAW_DIR_NAME}/{spec['file']}.csv"


def load_manifest():
    if MANIFEST_FILE.exists():
        try:
            return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {"schema_version": 1, "segments": {}}


def save_manifest(manifest):
    temporary = MANIFEST_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(MANIFEST_FILE)


def run_sync(statements, query_fn):
    for folder in (RAW_DIR, LOG_DIR):
        folder.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest()
    manifest["schema_version"] = 1
    entries = manifest.setdefault("segments", {})
    current_digests = {
        item["number"]: query_digest(";\n".join([*item["setup"], item["sql"]]))
        for item in statements
    }
    success_tables = []
    failed_tables = []

    for index, statement in enumerate(statements, start=1):
        number = statement["number"]
        spec = SEGMENT_SPECS[number]
        path = target_path(spec)
        print(f"\n[{index}/{len(statements)}] {number}. {statement['title']} → {RAW_DIR_NAME}/{path.name}")

        entry = {
            "number": number,
            "title": statement["title"],
            "file": relative_path(spec),
            "sql_sha256": current_digests[number],
            "started_at": now().isoformat(timespec="seconds"),
            "status": "running",
        }
        entries[number] = entry
        save_manifest(manifest)

        # 删掉上一次的文件，失败时目录里不会留下看似成功的旧结果。
        if path.exists():
            path.unlink()

        try:
            if statement["setup"]:
                print(f"准备 | 先执行 {len(statement['setup'])} 条建表/准备语句")
            for setup_sql in statement["setup"]:
                query_fn(setup_sql)

            df = query_fn(statement["sql"])

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

            entry.update(
                status="success",
                rows=int(len(df)),
                columns=list(df.columns),
                file_sha256=file_digest(path),
            )
            success_tables.append(number)
            print(f"成功 | {len(df)} 行 × {len(df.columns)} 列 | {path}")
        except Exception as exc:
            entry.update(status="failed", error=str(exc))
            failed_tables.append(
                {
                    "segment": number,
                    "table_name": spec["file"],
                    "error": str(exc),
                    "run_time": entry["started_at"],
                }
            )
            print(f"失败 | {exc}")
        finally:
            entry["finished_at"] = now().isoformat(timespec="seconds")
            save_manifest(manifest)

    pd.DataFrame(
        failed_tables,
        columns=["segment", "table_name", "error", "run_time"],
    ).to_csv(FAILED_FILE, index=False, encoding="utf-8-sig")

    packaged = []
    for statement in statements:
        number = statement["number"]
        spec = SEGMENT_SPECS[number]
        entry = entries.get(number, {})
        path = target_path(spec)
        if (
            entry.get("status") == "success"
            and entry.get("sql_sha256") == current_digests[number]
            and path.exists()
            and entry.get("file_sha256") == file_digest(path)
        ):
            packaged.append((path, relative_path(spec)))

    if packaged:
        temporary_zip = ZIP_FILE.with_suffix(".zip.tmp")
        with zipfile.ZipFile(temporary_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{RAW_DIR_NAME}/", "")
            for path, arcname in packaged:
                archive.write(path, arcname)
        temporary_zip.replace(ZIP_FILE)
        print(f"\n已打包：{ZIP_FILE}（原始数据 {len(packaged)} 个文件）")
    else:
        print(f"\n本次没有可打包的成功结果，未更新 {ZIP_FILE.name}")

    print(f"\n成功：{len(success_tables)} / 本次失败：{len(failed_tables)}")
    print(f"原始数据：{RAW_DIR.resolve()}")
    print(f"失败清单：{FAILED_FILE.resolve()}")
    print(f"运行清单：{MANIFEST_FILE.resolve()}")
    return 1 if failed_tables else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="执行 queries.sql 并打包原始数据。")
    parser.add_argument("--segments", help="只执行指定段，逗号分隔，如 3,4")
    parser.add_argument("--dry-run", action="store_true", help="只检查段号和输出文件名，不连接数据库")
    args = parser.parse_args(argv)

    try:
        statements = load_statements()
    except ValueError as exc:
        parser.error(str(exc))

    if args.segments:
        selected = [item.strip() for item in args.segments.split(",") if item.strip()]
        unknown = sorted(set(selected) - set(SEGMENT_SPECS))
        if unknown:
            parser.error(f"未知段号：{', '.join(unknown)}")
        statements = [item for item in statements if item["number"] in selected]
        if not statements:
            parser.error("没有匹配的段")
        statements.sort(key=lambda item: int(item["number"]))

    print(f"共 {len(statements)} 条查询：{SQL_FILE}")
    if args.dry_run:
        for statement in statements:
            spec = SEGMENT_SPECS[statement["number"]]
            setup_note = f"（前置 {len(statement['setup'])} 条）" if statement["setup"] else ""
            print(f"- {statement['number']}. {statement['title']}{setup_note} → {relative_path(spec)}")
        return 0

    try:
        from hive_config import query_to_df
    except ImportError:
        print("未找到 hive_config.py：请把提供 query_to_df(sql) 的模块放到本脚本同目录或 PYTHONPATH 中。")
        return 2

    return run_sync(statements, query_to_df)


if __name__ == "__main__":
    raise SystemExit(main())
