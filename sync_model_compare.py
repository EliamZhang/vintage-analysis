#!/usr/bin/env python3
"""同步模型比对输入：主表 + 新模型分 + 新客戳额样本分。

产出：原始数据/ 下的主表与两张分数表、model_compare_data.zip、
同步日志/model_compare_manifest.json。只服务模型比对；监控看板见 sync_vintage.py。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from sync_common import (
    LOG_DIR,
    RAW_DIR,
    export_tables,
    load_query_fn,
    new_manifest,
    parse_tables,
    table_file,
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
MANIFEST_FILE = LOG_DIR / "model_compare_manifest.json"
FAILED_FILE = LOG_DIR / "model_compare_failed_tables.csv"
ZIP_FILE = PROJECT_DIR / "model_compare_data.zip"

# 模型比对脚本默认读取的三张表
TABLES = (
    "model.tmp_eliam_wagego_dwd_loan_apply_label",
    "model.tmp_eliam_aus_new_wagego_credit_20261028_v1_0_txn_lgb_score",
    "model.tmp_eliam_aus_wagego_new_user_credit_20260801_20261023_score",
)

# build_model_compare.py 按这两个文件名读取，导出时保持同名
TABLE_EXPORTS = {
    "model.tmp_eliam_aus_new_wagego_credit_20261028_v1_0_txn_lgb_score":
        "aus_new_wagego_credit_20261028_v1_0_txn_lgb_score.csv",
    "model.tmp_eliam_aus_wagego_new_user_credit_20260801_20261023_score":
        "wagego_new_user_credit_20260801_20261023_score.csv",
}


def main(argv=None):
    parser = argparse.ArgumentParser(description="同步模型比对输入表。")
    parser.add_argument(
        "--tables",
        help=f"整表拉取的表名，逗号分隔；默认拉 {','.join(TABLES)}",
    )
    parser.add_argument(
        "--table-limit",
        type=int,
        default=0,
        help="整表拉取只取前 N 行（0 = 全量）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只检查表名和输出文件名，不连接数据库")
    args = parser.parse_args(argv)

    try:
        tables = parse_tables(args.tables, TABLES)
    except ValueError as exc:
        parser.error(str(exc))

    print(f"整表拉取：{', '.join(tables)}")
    if args.dry_run:
        for table in tables:
            print(f"- [表] {table} → 原始数据/{table_file(table, TABLE_EXPORTS)}")
        return 0

    query_fn = load_query_fn()
    if query_fn is None:
        return 2

    manifest = new_manifest("model_compare")
    succeeded, failed = export_tables(
        tables,
        query_fn,
        table_limit=args.table_limit,
        manifest=manifest,
        manifest_path=MANIFEST_FILE,
        failed_path=FAILED_FILE,
        zip_path=ZIP_FILE,
        exports=TABLE_EXPORTS,
    )

    print(f"\n成功：{len(succeeded)} / 本次失败：{len(failed)}")
    print(f"输出目录：{RAW_DIR.resolve()}")
    print(f"失败清单：{FAILED_FILE.resolve()}")
    print(f"运行清单：{MANIFEST_FILE.resolve()}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
