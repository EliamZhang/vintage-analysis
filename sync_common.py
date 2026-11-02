#!/usr/bin/env python3
"""同步脚本共用层：路径、Hive 查询执行、CSV 落盘、manifest 与打包。

两个同步入口各自负责一条链路的查询/表清单，共用这里的落盘与记录逻辑：
    sync_vintage.py        监控看板的 8 个 vintage 聚合查询
    sync_model_compare.py  模型比对的主表与两张分数表
数据库连接由外部 hive_config.query_to_df(sql) 提供，本模块不负责建连。
"""

from __future__ import annotations

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
RAW_DIR = PROJECT_DIR / "原始数据"
LOG_DIR = PROJECT_DIR / "同步日志"
RAW_DIR_NAME = "原始数据"
BUSINESS_TZ = timezone(timedelta(hours=8))

TABLE_NAME_RE = re.compile(r"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$")


def now():
    return datetime.now(BUSINESS_TZ)


def query_digest(sql):
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


def file_digest(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def new_manifest(job, sql_file=None):
    manifest = {
        "job": job,
        "run_at": now().isoformat(timespec="seconds"),
        "queries": {},
        "tables": {},
    }
    if sql_file is not None:
        manifest["sql_file"] = Path(sql_file).name
        manifest["sql_sha256"] = query_digest(Path(sql_file).read_text(encoding="utf-8"))
    return manifest


def save_manifest(path, manifest):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def parse_tables(raw, default_tables):
    """解析 --tables；raw 为 None 时用默认表清单。"""
    names = default_tables if raw is None else tuple(
        name.strip() for name in raw.split(",") if name.strip()
    )
    invalid = [name for name in names if not TABLE_NAME_RE.match(name)]
    if invalid:
        raise ValueError(f"表名不合法：{', '.join(invalid)}（只允许字母、数字、下划线、点）")
    return names


def table_file(table, exports=None):
    """model.tmp_xxx → table_tmp_xxx.csv；exports 可覆盖指定表的文件名。"""
    if exports and table in exports:
        return exports[table]
    return f"table_{table.split('.')[-1]}.csv"


def write_failures(failed, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(failed, columns=["block", "file", "error", "run_time"]).to_csv(
        path, index=False, encoding="utf-8-sig"
    )


def export_tables(tables, query_fn, *, table_limit, manifest, manifest_path,
                  failed_path, zip_path, exports=None):
    """整表拉取并逐表记录 manifest；返回 (成功列表, 失败列表)。"""
    succeeded = []
    failed = []
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    for table in tables:
        filename = table_file(table, exports)
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
        save_manifest(manifest_path, manifest)

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
            save_manifest(manifest_path, manifest)

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
