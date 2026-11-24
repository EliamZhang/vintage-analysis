# 新增一个模型分析的步骤

每个模型分析各自一个目录，互不引用代码，共用的只有根目录的 `sync_common.py`。

## 1. 建目录

```
分析/<slug>/     SQL、sync.py、build.py、报告 HTML 都在这里
数据/<slug>/     sync.py 的落盘目录（已被 .gitignore 忽略）
```

`<slug>` 用中文短名，比如 `新客戳额`、`新老客发标`。

## 2. 写 SQL

在 `分析/<slug>/` 下放一个 `.sql`，每个查询块之间用 `;` 分隔。块顺序就是 `sync.py` 里 `QUERY_SPECS` 的顺序，第 N 块写到第 N 个文件名。

## 3. 写 sync.py

从本目录的 `sync.py` 复制，替换所有 `<slug>` 和 `QUERY_SPECS`。

## 4. 写 build.py

优先从最接近的已有分析复制后改常量（`分析/新客戳额/build.py` 或 `分析/新老客发标/build.py`），或者从本目录的 `build.py` 骨架起手。路径约定：

- `PROJECT_DIR = Path(__file__).resolve().parents[2]`
- 输入：`PROJECT_DIR / "数据" / "<slug>"`
- 输出：`Path(__file__).resolve().parent / "<报告名>.html"`

## 5. 运行

```
python 分析/<slug>/sync.py --dry-run    # 先校验块数和文件名
python 分析/<slug>/sync.py              # 实际同步（需要 hive_config）
python 分析/<slug>/build.py             # 生成报告
```

## 注意

- 根目录不再放入口脚本，只留 `sync_common.py`。
- 不同分析之间不要互相 import；发现要复用的逻辑，先确认是否真的该放进 `sync_common.py`。
- 报告 HTML 是自包含的（数据以 JSON 内嵌），可以直接发出去。
