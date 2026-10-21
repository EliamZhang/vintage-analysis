"""执行 queries.sql，把原始数据和查询结果打包成一个 zip。

queries.sql 按段组织，每段以分号结尾，段首注释写明「N. 段名」。本脚本：
1. 段 1–6 是底表，写入 原始数据/；
2. 段 7–14 是《样本表准备以及Y标签表准备.sql》里的 8 张加工表，
   因为库里没有 model.tmp_eliam_wagego_*，SQL 已把上游逻辑内联，直接把结果写入 查询结果/；
3. 打包成 vintage_data.zip，压缩包根目录只有 原始数据/ 和 查询结果/ 两个文件夹；
4. 运行日志、失败清单和 manifest 放在 同步日志/，不进入压缩包。

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
RESULT_DIR = PROJECT_DIR / "查询结果"
LOG_DIR = PROJECT_DIR / "同步日志"
MANIFEST_FILE = LOG_DIR / "sync_manifest.json"
FAILED_FILE = LOG_DIR / "failed_tables.csv"
ZIP_FILE = PROJECT_DIR / "vintage_data.zip"

RAW_DIR_NAME = "原始数据"
RESULT_DIR_NAME = "查询结果"

BUSINESS_TZ = timezone(timedelta(hours=8))

# FPD 标签列由 3/7/14/30 天四组组成，单独列出来避免注册表里重复抄写。
FPD_FLAGS = {f"is_fpd{n}_{suffix}" for n in (3, 7, 14, 30) for suffix in ("obs", "ovd")}

# 段号 → 输出文件与校验规则。段号必须和 queries.sql 段首注释一一对应。
# unique_keys / required_columns / obs_column 只对结果段生效，用来防止 SQL 写错后仍产出“成功”的空表或放大表。
SEGMENT_SPECS = {
    "1": {"kind": "raw", "file": "01_aus_ewa_loan_biz_t_loan_application"},
    "2": {"kind": "raw", "file": "02_dwb_asset_cmn_listing"},
    "3": {"kind": "raw", "file": "03_dwb_asset_debt_dtl_snp"},
    "4": {"kind": "raw", "file": "04_aus_ewa_risk_risk_event_task"},
    "5": {"kind": "raw", "file": "05_aus_listing_tb_loan_limit_apply"},
    "6": {"kind": "raw", "file": "06_aus_listing_tb_loan_user_limit_log"},
    "7": {
        "kind": "result",
        "file": "07_观察日参数表_param_obs_date",
        "required_columns": {"obs_dt"},
        "expect_rows": 1,
        "obs_source": True,
    },
    "8": {
        "kind": "result",
        "file": "08_债务快照子集_stg_debt_snp",
        "required_columns": {
            "listing_id", "user_id", "stat_date", "init_due_date", "first_repay_time",
            "user_actual_repay_time", "debt_status", "hist_overdue_days",
            "current_overdue_days", "principal", "repay_amount", "owing_amount",
        },
        "unique_keys": ["listing_id", "stat_date"],
    },
    "9": {
        "kind": "result",
        "file": "09_借款申请明细_dwd_loan_apply",
        "required_columns": {
            "loan_no", "user_id", "application_id", "app_id", "listing_id",
            "apply_status", "apply_status_desc", "is_disburse_success", "is_reject",
            "is_expired", "is_disburse_failed", "apply_time", "apply_date", "apply_month",
            "disburse_time", "apply_seq", "is_first_apply_in_window", "strategy_time",
            "retry_count",
        },
        "unique_keys": ["loan_no"],
    },
    "10": {
        "kind": "result",
        "file": "10_借款债务明细_dwd_loan_debt",
        "required_columns": {
            "loan_no", "user_id", "listing_id", "apply_status", "apply_status_desc",
            "is_disburse_success", "apply_time", "disburse_time", "apply_seq",
            "real_amount", "term_quantity", "term_unit", "init_due_date", "obs_dt",
            "label_obs_dt", "is_label_matured", "dpd_at_label_obs",
            "hist_dpd_at_label_obs", "is_current_overdue_at_label_obs",
            "is_5plus_at_label_obs", "is_30plus_at_label_obs",
            "is_ever_30plus_in_window", "loan_term_contract_days",
            "loan_term_actual_days", "is_early_settlement", "is_current_overdue",
            "current_ovd_amt",
        } | FPD_FLAGS,
        "unique_keys": ["loan_no"],
        "obs_column": "obs_dt",
    },
    "11": {
        "kind": "result",
        "file": "11_放款成功表_dwd_disbursed_loan",
        "required_columns": {
            "loan_no", "user_id", "listing_id", "disburse_time", "disburse_date",
            "disburse_month", "real_amount", "term_quantity", "term_unit",
            "init_due_date", "user_type",
        },
        "unique_keys": ["loan_no"],
    },
    "12": {
        "kind": "result",
        "file": "12_戳额表_dwd_loan_stamp",
        "required_columns": {
            "loan_no", "user_id", "apply_time", "stamp_time",
            "stamp_to_apply_days", "stamp_source", "limit_apply_no",
            "stamp_flow_no", "limit_total_before", "limit_total_after",
            "limit_available_after", "limit_occupied_after", "limit_expire_time",
        },
        "unique_keys": ["loan_no"],
    },
    "13": {
        "kind": "result",
        "file": "13_借款级Vintage宽表_dws_vintage_loan",
        "required_columns": {
            "loan_no", "user_id", "listing_id", "disburse_time", "disburse_month",
            "real_amount", "term_unit", "init_due_date", "label_obs_dt",
            "is_label_matured", "data_as_of", "days_on_book", "dpd_at_label_obs",
            "hist_dpd_at_label_obs", "is_current_overdue_at_label_obs",
            "current_ovd_amt_at_label_obs", "is_5plus_at_label_obs",
            "is_30plus_at_label_obs", "is_ever_30plus_in_window",
            "application_rank", "user_type",
        } | FPD_FLAGS
          | {f"mob{n}_{suffix}" for n in range(1, 13) for suffix in ("5plus", "30plus")},
        "unique_keys": ["loan_no"],
        "obs_column": "data_as_of",
    },
}

# 放款样本表字段与借款 / 债务明细完全一致，直接复用同一套字段校验。
SEGMENT_SPECS["14"] = {
    "kind": "result",
    "file": "14_放款样本表_dwd_loan_disburse_sample",
    "required_columns": SEGMENT_SPECS["10"]["required_columns"],
    "unique_keys": ["loan_no"],
    "obs_column": "obs_dt",
}

_TITLE_RE = re.compile(r"^\s*(\d+)\.\s+(.+?)\s*$", flags=re.M)
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
    """按分号切段，从每段最后一个注释块里读「N. 段名」。

    一段一条语句。切分前先去掉注释再判断是否为空，避免只有注释的尾块被当成查询。
    """
    statements = []
    seen = set()
    for chunk in sql_text.split(";"):
        blocks = _BLOCK_COMMENT_RE.findall(chunk)
        number = title = None
        for block in reversed(blocks):
            match = _TITLE_RE.search(block)
            if match:
                number, title = match.group(1), match.group(2).strip()
                break

        body = _BLOCK_COMMENT_RE.sub(" ", chunk)
        body = _LINE_COMMENT_RE.sub(" ", body).strip()
        if not body:
            continue

        if number is None:
            raise ValueError(f"第 {len(statements) + 1} 条语句缺少「N. 段名」注释")
        if number in seen:
            raise ValueError(f"段号重复：{number}")
        seen.add(number)
        statements.append({"number": number, "title": title or "", "sql": body})
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
    folder = RAW_DIR if spec["kind"] == "raw" else RESULT_DIR
    return folder / f"{spec['file']}.csv"


def relative_path(spec):
    folder = RAW_DIR_NAME if spec["kind"] == "raw" else RESULT_DIR_NAME
    return f"{folder}/{spec['file']}.csv"


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


def validate_frame(df, spec, expected_obs):
    if not isinstance(df, pd.DataFrame):
        raise ValueError("查询未返回 DataFrame")

    missing = sorted(set(spec.get("required_columns", set())) - set(df.columns))
    if missing:
        raise ValueError(f"结果缺少必需字段：{'、'.join(missing)}")

    expect_rows = spec.get("expect_rows")
    if expect_rows is not None and len(df) != expect_rows:
        raise ValueError(f"结果应为 {expect_rows} 行，实际 {len(df)} 行")

    keys = spec.get("unique_keys")
    if keys and len(df):
        duplicated = df.duplicated(subset=keys, keep=False)
        if duplicated.any():
            sample = df.loc[duplicated, keys].head(3).to_dict("records")
            raise ValueError(f"唯一键重复 {int(duplicated.sum())} 行，例如：{sample}")

    obs_column = spec.get("obs_column")
    if obs_column and expected_obs is not None and len(df):
        values = pd.to_datetime(df[obs_column], errors="coerce").dropna()
        dates = sorted({value.date() for value in values})
        if not dates:
            raise ValueError(f"{obs_column} 全为空，无法核对观察日")
        if len(dates) != 1 or dates[0] != expected_obs:
            raise ValueError(f"{obs_column} 与观察日参数不一致：{dates} vs {expected_obs}")


def run_sync(statements, query_fn):
    for folder in (RAW_DIR, RESULT_DIR, LOG_DIR):
        folder.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest()
    manifest["schema_version"] = 1
    entries = manifest.setdefault("segments", {})
    current_digests = {item["number"]: query_digest(item["sql"]) for item in statements}
    expected_obs = None
    success_tables = []
    failed_tables = []

    for index, statement in enumerate(statements, start=1):
        number = statement["number"]
        spec = SEGMENT_SPECS[number]
        path = target_path(spec)
        label = "原始数据" if spec["kind"] == "raw" else "查询结果"
        print(f"\n[{index}/{len(statements)}] {number}. {statement['title']} → {label}/{path.name}")

        entry = {
            "number": number,
            "title": statement["title"],
            "kind": spec["kind"],
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
            df = query_fn(statement["sql"])

            if spec.get("obs_source"):
                if not isinstance(df, pd.DataFrame) or len(df) != 1:
                    raise ValueError("观察日参数必须返回 1 行")
                observed = pd.to_datetime(df.iloc[0].get("obs_dt"), errors="coerce")
                if pd.isna(observed):
                    raise ValueError("观察日参数 obs_dt 为空或不可解析")
                expected_obs = observed.date()

            validate_frame(df, spec, expected_obs)

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
                    "kind": spec["kind"],
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
        columns=["segment", "table_name", "kind", "error", "run_time"],
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
            archive.writestr(f"{RESULT_DIR_NAME}/", "")
            for path, arcname in packaged:
                archive.write(path, arcname)
        temporary_zip.replace(ZIP_FILE)
        raw_count = sum(1 for _, name in packaged if name.startswith(f"{RAW_DIR_NAME}/"))
        result_count = len(packaged) - raw_count
        print(f"\n已打包：{ZIP_FILE}")
        print(f"  原始数据：{raw_count} 个文件")
        print(f"  查询结果：{result_count} 个文件")
    else:
        print(f"\n本次没有可打包的成功结果，未更新 {ZIP_FILE.name}")

    print(f"\n成功：{len(success_tables)} / 本次失败：{len(failed_tables)}")
    print(f"原始数据：{RAW_DIR.resolve()}")
    print(f"查询结果：{RESULT_DIR.resolve()}")
    print(f"失败清单：{FAILED_FILE.resolve()}")
    print(f"运行清单：{MANIFEST_FILE.resolve()}")
    return 1 if failed_tables else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="执行 queries.sql 并打包原始数据与查询结果。")
    parser.add_argument("--segments", help="只执行指定段，逗号分隔，如 7,13")
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
            print(f"- {statement['number']}. {statement['title']} → {relative_path(spec)}")
        return 0

    try:
        from hive_config import query_to_df
    except ImportError:
        print("未找到 hive_config.py：请把提供 query_to_df(sql) 的模块放到本脚本同目录或 PYTHONPATH 中。")
        return 2

    return run_sync(statements, query_to_df)


if __name__ == "__main__":
    raise SystemExit(main())
