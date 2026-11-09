# 手动测试脚本

这些脚本不随 `selftest.lua` 自动跑，需要你自己的、已经建过 `.codegraph` 索引的项目：

```bash
cd /path/to/indexed/project
CG_SYMBOL=Foo CG_SRC=src/foo.c nvim --headless -u tests/minimal_init.lua \
    -c "luafile tests/manual/<script>.lua" -c "qa!"
```

| 脚本 | 用途 | 需要的环境变量 |
| --- | --- | --- |
| `bench.lua` | 搜索 / 定义 / 状态的耗时 | — |
| `bench2.lua` | 带与不带调用点的搜索耗时对比 | — |
| `daemon.lua` | 后台守护 start/stop/状态 | — |
| `gd_c_proto.lua` | C 头文件原型兜底（.c → .h） | `CG_SRC`、`CG_SYM` |
| `health.lua` | 抓取 `:checkhealth codegraph` 的输出 | — |
| `mcp.lua` | MCP 数据源实测（需要 codegraph 可执行） | `CG_SYMBOL` |
| `multi_index.lua` | 多级索引向上查找 | `CG_SYM` |
| `roots.lua` | 从子目录向上找索引 | — |
| `schema.lua` | 表结构探测与数据源回退 | — |
| `search_latency.lua` | 搜索首屏耗时 | `CG_QUERY` |
| `search_picker.lua` | 搜索 picker 的输入变化 | — |
| `symbol_extract.lua` | 光标符号清理单测（不需要项目） | — |
| `usages.lua` | 搜索结果里的调用点 | `CG_QUERY` |

`selftest.lua` 是主自测（在任意已索引项目里跑）：

```bash
cd /path/to/indexed/project
nvim --headless -u tests/minimal_init.lua -c "luafile tests/selftest.lua" -c "qa!"
```
