#!/usr/bin/env python3
"""同步脚本共用层：路径、SQL 文件解析、Hive 查询执行、CSV 落盘与打包。

两个同步入口各自负责一条链路的 SQL 文件与输出清单，共用这里的执行与落盘逻辑：
    sync_vintage.py                   监控看板的 8 个 vintage 聚合查询
    sync_new_user_credit_analysis.py  新客戳额模型分分析的底表
查询语句只写在对应的 .sql 文件里，本模块和入口脚本都不拼接业务 SQL。
数据库连接由外部 hive_config.query_to_df(sql) 提供，本模块不负责建连。
"""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

import pandas as pd


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PROJECT_DIR = Path(__file__).resolve().parent
RAW_DIR = PROJECT_DIR / "同步数据"
RAW_DIR_NAME = "同步数据"

_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", flags=re.S)
_LINE_COMMENT_RE = re.compile(r"--[^\n]*")
_FROM_RE = re.compile(r"\bFROM\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)", re.IGNORECASE)


def load_query_fn():
    try:
        from hive_config import query_to_df
    except ImportError:
        print("未找到 hive_config.py：请把提供 query_to_df(sql) 的模块放到本脚本同目录或 PYTHONPATH 中。")
        return None
    return query_to_df


def run_query_to_csv(sql, path, query_fn):
    """执行一条查询并写入 path；返回 (行数, 列名)。失败时抛异常。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
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


def split_statements(sql_text):
    """去掉注释后按分号拆分；返回 SQL 语句列表。"""
    body = _BLOCK_COMMENT_RE.sub(" ", sql_text)
    body = _LINE_COMMENT_RE.sub(" ", body)
    return [part.strip() for part in body.split(";") if part.strip()]


def table_name_from_sql(sql):
    """从查询语句的 FROM 子句取表名，用于 --tables 过滤。"""
    match = _FROM_RE.search(sql)
    if not match:
        raise ValueError("无法从 SQL 中解析表名；请确认语句包含 FROM <库.表>")
    return match.group(1)


def write_failures(failed, path):
    """有失败时在项目根目录写失败清单；没有失败则清掉上一次的清单。"""
    path = Path(path)
    if not failed:
        if path.exists():
            path.unlink()
        return
    pd.DataFrame(failed, columns=["block", "file", "error"]).to_csv(
        path, index=False, encoding="utf-8-sig"
    )
    print(f"\n失败清单：{path.resolve()}")


def export_sql_blocks(blocks, query_fn, *, zip_path, failed_path):
    """执行 SQL 块并逐块落盘；blocks 需含 id/title/table/file/sql。返回 (成功, 失败)。"""
    succeeded = []
    failed = []
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    for block in blocks:
        path = RAW_DIR / block["file"]
        print(f"\n[{block['id']}] {block['title']} | {block['table']} → {RAW_DIR_NAME}/{block['file']}")
        try:
            rows, columns = run_query_to_csv(block["sql"], path, query_fn)
            succeeded.append((path, f"{RAW_DIR_NAME}/{block['file']}"))
            print(f"成功 | {rows} 行 × {len(columns)} 列 | {path}")
        except Exception as exc:
            failed.append(
                {"block": block["table"], "file": block["file"], "error": str(exc)}
            )
            print(f"失败 | {exc}")

    write_failures(failed, failed_path)
    zip_outputs(succeeded, zip_path)
    return succeeded, failed


def zip_outputs(outputs, zip_path):
    """outputs: [(本地路径, zip 内路径)]；没有成功结果时不更新 zip。"""
    if not outputs:
        print(f"\n本次没有可打包的成功结果，未更新 {Path(zip_path).name}")
        return

    zip_path = Path(zip_path)
    temporary = zip_path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{RAW_DIR_NAME}/", "")
        for path, arcname in outputs:
            archive.write(path, arcname)
    temporary.replace(zip_path)
    print(f"\n已打包：{zip_path}（{len(outputs)} 个文件）")
