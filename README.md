# codegraph.nvim

> 作者：[coffee](https://github.com/coffeeCatCode) · MIT License

把 **codegraph**（给 AI 用的代码图谱）接到 Neovim：搜索符号、跳转定义/声明、看引用和调用关系，
结果用 **telescope** 展示。

- 数据来源：项目根下的 `.codegraph/codegraph.db`（SQLite，WAL 模式）
- 默认**直读 SQLite**：2 万节点的库一次搜索 ~20ms，可以边输边查；`codegraph` CLI 只负责同步索引
- 项目根**逐级向上查找**：没有 `.codegraph` 就回到上一级找，一直找到 `/`；都没有 → 插件不启用
- 数据源是**可插拔**的：`codegraph`（直读 SQLite）/ `codegraph_mcp`（走 codegraph 自己的 MCP 工具，
  库结构变了也能用）/ `codegraph_cli` / `ripgrep`，也可以自己注册
- 表结构变了不会瞎跑：直读前先 `PRAGMA table_info` 校验，缺列就自动退到 MCP / CLI
- 索引新鲜度可配：保存后自动 `sync`、常驻后台、定时轮询，或完全手动

> 本插件直接放在配置目录里：`~/.config/nvim/local/codegraph.nvim/`，
> 由 `lua/plugins.lua` 里的一条 `dir = ...` 规格加载（见下文「接入」）。

---

## 1. 键位

默认键位（全部可在 `keymaps` 里改，设 `false` 关掉）：

| 键 | 作用 |
| --- | --- |
| `<Leader>gr` | 搜索符号 **+ 调用/引用点**，telescope 展示；打开时预填光标下的词（`search.prefill`） |
| `<Leader>gd` | 跳转定义/声明；**声明↔实现互跳**（`.cpp` 里跳 `.h`，反过来同理），唯一候选直接跳，多个才弹列表 |
| `<Leader>gR` | 谁引用了它（`edges` 里的 calls/references/instantiates/extends） |
| `<Leader>gc` | 谁调用了它（callers） |
| `<Leader>gC` | 它调用了谁（callees） |
| `<Leader>gf` | 索引里的文件列表 |
| `<Leader>gs` | 索引状态（节点数、最近索引时间、后台状态、待同步文件） |
| `<Leader>gy` | 立即同步索引 |

picker 内：

| 键 | 作用 |
| --- | --- |
| `<CR>` | 跳到该条目 |
| `<C-q>` | 全部结果丢进 quickfix 并打开（批量跳转） |
| `<Tab>` / `<S-Tab>` | 多选 / 反选 |
| `<C-/>` | 看当前条目的默认映射 |

> **和 coc 的冲突**：本插件默认接管 `<Leader>gr`（原来是 coc 的引用列表）。
> 插件在 setup 时先 `vim.keymap.del` 再重新映射，所以 coc 的 `\gr` 会被顶掉；
> coc 原生的 `gr`（不带 leader）仍然可用，引用也可以用 `<Leader>gR` 看（走图谱，跨文件更全）。
> 想保留 coc 的 `\gr`，把 `keymaps.search` 改成别的键，或者设 `keymaps.search = false`。

---

## 2. 安装

lazy.nvim（从 GitHub 装）：

```lua
{
    "you/codegraph.nvim",      -- 换成你的仓库地址
    lazy = false,              -- 要在 coc 之后注册键位，不能懒加载
    priority = 40,             -- < coc 的 50，保证 setup 在 coc 之后跑
    opts = {},                 -- 见第 8 节
    config = function(_, opts)
        require("codegraph").setup(opts)
    end,
},
```

本地开发（`dir` 直接指向插件目录）：

```lua
{
    "codegraph.nvim",
    dir = vim.fn.expand("~/path/to/codegraph.nvim"),
    lazy = false,
    priority = 40,
    opts = {},
    config = function(_, opts)
        require("codegraph").setup(opts)
    end,
},
```

`lazy = false` 是必须的：键位要在启动时就注册好，否则第一次按 `<Leader>gr` 时
coc 的映射会先命中。telescope 不需要写进 `dependencies`——插件里 `require("telescope...")`
时 lazy.nvim 会自动把它加载起来。

依赖：`telescope.nvim` 必装；`sqlite3` 与 `codegraph` 至少有一个（前者直读索引，后者同步/重建）。

---

## 3. 命令

```
:CodeGraph [子命令] [参数]
```

| 子命令 | 说明 |
| --- | --- |
| `search [词]` | 打开搜索 picker（可带初始词） |
| `definition [名]` | 跳定义；带名字时直接查这个名字 |
| `references [名]` / `refs` | 引用列表 |
| `callers [名]` / `callees [名]` | 调用关系 |
| `files` | 索引里的文件 |
| `status` / `info` | 索引状态（也可以 `<Leader>gs`） |
| `sync` | 跑 `codegraph sync -q` |
| `index [--force]` | 全量重建（会二次确认） |
| `daemon status\|start\|stop` | 管理 codegraph 后台守护进程 |
| `root [路径]` | 手动指定/清除项目根（临时用，不写进配置） |
| `doctor` / `health` | `:checkhealth codegraph` |

telescope 扩展：

```
:Telescope codegraph search
:Telescope codegraph definition
:Telescope codegraph references
:Telescope codegraph callers
:Telescope codegraph callees
:Telescope codegraph files
```

---

## 4. 数据从哪来

codegraph 在项目根建一个 `.codegraph/`：

```
.codegraph/
├── codegraph.db        # SQLite（WAL），真正的图
├── codegraph.db-wal    # 后台写入时的预写日志（读的时候不用管）
├── daemon.sock/.pid    # 后台守护进程的 socket / pid（有后台时才有）
└── daemon.log
```

用得到的表：

| 表 | 字段（节选） | 用途 |
| --- | --- | --- |
| `nodes` | `id, kind, name, qualified_name, file_path, start_line, end_line, signature, docstring` | 符号 |
| `edges` | `source, target, kind, line` （kind: `calls` / `references` / `instantiates` / `extends` / `contains` / `imports`） | 引用与调用 |
| `files` | `path, language, size, node_count, indexed_at` | 文件清单 |
| `project_metadata` | `key, value` | 索引版本、状态 |

`file_path` 是**相对项目根**的路径，跳转时拼回绝对路径。

`kind` 的常见值：`function` `method` `class` `struct` `enum` `enum_member` `type_alias`
`namespace` `variable` `constant` `field` `import` `file` —— 探针/展示都按这套走，
未知 kind 会退化成灰色徽标，不会报错。

**为什么直读而不是每次调 `codegraph query`**：`codegraph` 是 node 程序，启动一次 ~300ms，
而 `sqlite3` 一条 `LIKE` 查询在 2 万节点的库上约 10~20ms（含进程启动）。搜索要"边输边查"，
只能走直读。`codegraph` CLI 负责写（sync/index），SQLite 负责读（WAL 允许读写并发）。

### 4.1 codebase-memory 增强（可选，自动退化）

装了 [`codebase-memory-mcp`](https://github.com/coffeeCatCode) 且当前项目建过它的索引时，
插件会**自动接上它**，补 codegraph 没有的数据；没装 / 没索引 / 索引过期就静默退回
codegraph，原来的用法完全不变。

| 场景 | 实际走哪 | 说明 |
| --- | --- | --- |
| `p->field` / `obj.field` 结构体成员 | **codebase-memory `Field`** → codegraph 类型推断 | codegraph 不索引成员；有 Field 就跳字段定义行，没有才退回"按 base 类型跳 struct" |
| 宏（尤其对象式 `#define X`） | **codebase-memory `Macro`** → rg 兜底 | codegraph 只索引函数式宏 |
| 普通符号（函数/类/枚举） | **codegraph** → codebase-memory → coc | 声明/实现互跳仍由 codegraph 负责（codebase-memory 没有这个概念） |
| `<Leader>gr` 搜索 | codegraph 结果 **+** codebase-memory 结果（BM25） | 按 `文件:行:名` 去重；索引没预热好时跳过，不拖慢输入 |

冷启动约 1s（进项目时后台拉起，不阻塞 UI），之后每次查询 ~10ms；退出 nvim 时把进程清掉。
项目名按 `list_projects` 的 `root_path` 最长前缀匹配，子目录里的 buffer 也能对上。

---

## 5. 项目定位（那条"往上找"的规则）

从**当前文件所在目录**开始，逐级向上找 `<dir>/.codegraph/codegraph.db`：

- 找到真的 SQLite 文件（校验文件头 `SQLite format 3\0`）就用它；
- 某一层只有 `.codegraph/` 目录、里面没有 db（比如 `~/.codegraph` 常常只有后台的
  state 文件）→ **跳过这一层，继续向上**；
- 一直找到 `/` 都没有 → 返回 nil，**插件不启用**：`<Leader>gr` 只给一句提示，
  不会悄悄退化成全项目 grep。

### 多级索引（子模块 + 顶层仓库）

`<Leader>gd` 的查找顺序：

1. **最近的** `.codegraph`（本模块）先查；
2. 本层没有（或互跳时"想要的那一类"没有），**继续查上级 `.codegraph`**
   （`definition.search_parents = true`，最多 `max_parents` 层）；
3. 上级索引里命中的条目，展示路径会写成 `父目录名/相对路径`，跳转用绝对路径。

实测（顶层仓库索引 + 子模块索引）：

```
repo/sub/src/impl.c:120  --(Foo)-->     repo/include/foo.h:36    ← 实现在子索引, 声明在父索引
repo/sub/src/uses.c:8    --(Helper)-->  repo/include/helper.h:12  ← 只有父索引有
```

`<Leader>gr` **搜索也会合并上级索引**（`search.search_parents = true`）：本模块索引里没有的符号
（比如顶层仓库里的公共函数）也能搜到，结果路径同样带 `父目录名/` 前缀。每个上级索引最多取
`search.max_parent_results` 条，最多合并 `search.max_parents` 层。

注意：**只向上找，不向下找**。在父仓库里打开文件时不会去扫子模块的索引（那要把整棵树翻一遍）。

相关配置：

```lua
project = {
    index_dir = ".codegraph",
    db_file = "codegraph.db",
    max_depth = 0,        -- 0 = 不限制，一直找到 /
    skip_roots = {},      -- 想排除某层的索引就写进来，例如 vim.env.HOME
},
definition = {
    search_parents = true,  -- 本层没有时查上级 .codegraph
    max_parents = 3,        -- 最多查几层上级
},
```

手动指定根（不写配置，重启失效）：`:CodeGraph root /path/to/project`，清除：`:CodeGraph root`。

---

## 6. 后台与索引新鲜度

codegraph 自己的后台是：

```bash
codegraph serve --mcp -p <项目根>
```

它会监听 `.codegraph/daemon.sock`、**监视项目文件**、有变化就自动 sync，空闲 300s 后退出
（进程约 150MB，是 node）。插件不重复造监听器，只按配置决定是否维持它：

| `watcher.mode` | 行为 | 适合 |
| --- | --- | --- |
| `"auto"`（默认） | 已有后台（比如 AI 客户端/MCP 起的）→ 白嫖，不重复同步；没有 → 保存时自己 `sync` | 绝大多数情况 |
| `"daemon"` | 进项目就确保后台在跑（挂了会重拉），文件变化由它自己处理 | 想让索引始终最新 |
| `"on_save"` | 只在你保存时 `codegraph sync -q`（防抖 1.5s、两次至少间隔 5s） | 不想多一个常驻进程 |
| `"poll"` | 每 120s 跑一次 `codegraph status -j`，`pendingChanges > 0` 才 sync | 经常用 git 切分支/改文件 |
| `"off"` | 完全不管，只用 `:CodeGraph sync` 手动同步 | 调试 / 老机器 |

```lua
watcher = {
    mode = "auto",
    daemon = {
        autostart = false,   -- auto 模式下是否允许主动拉起后台
        stop_on_exit = false,-- 退出 nvim 是否杀掉自己拉起的后台（默认让它自己 idle 超时）
        cmd = { "codegraph", "serve", "--mcp" },
        max_files = 20000,   -- 文件超过这个数就不自动拉后台
    },
    on_save = { debounce = 1500, min_interval = 5000, timeout = 120000 },
    poll = { interval = 120, timeout = 30000 },
    ignore = { "/%.codegraph/", "/%.git/", "/build/", "/node_modules/", "/deps/", "/%.cache/" },
},
```

手动控制：`:CodeGraph daemon start|stop|status`，状态里会显示 pid（判定存活时会核对
`/proc/<pid>/cmdline`，避免 pid 被别的进程复用导致误判）。

---

## 7. 搜索和"定义/声明"

**搜索**走 `nodes` 的 `name` / `qualified_name` / `signature` / `docstring` 子串匹配
（大小写不敏感），排序：名字完全相等 > 名字前缀 > 限定名前缀 > 其它，再按名字长度。
默认 `search.prefill = "cword"`：打开时把光标下的词预填进 prompt，所以 `<Leader>gr`
一打开就是"我正在看的这个符号"的匹配，而不是一堆无关的"最近符号"
（`empty_prompt = "none"`，空 prompt 什么都不显示；想改回最近符号就设 `recent`）。

结果里**同时有定义和调用点**（`search.include_usages = true`，数据来自 `edges` 表）：

```
[method] Foo          ns::Foo          src/foo.c:17     ← 定义
[call]   ns::Foo      ← main (method)  src/main.c:100   ← 调用点
[ref]    ...
```

调用点条目的 `path:line` 是**调用发生的行**，`<CR>` 直接跳过去；第三列是"在哪个函数里用的"。
嫌多可以 `include_usages = false`，或用 `usage_limit` 控制条数（默认 200）。

**`<Leader>gd`** 的流程：

1. 取**光标所在**的那个标识符（按行列扫描，不是整段 `<cWORD>`）：所以
   `ret += multi_heap_free_size(heap->heap);` 里光标在函数名上就是 `multi_heap_free_size`，
   不会因为同一行有 `->` 被误判成成员访问 —— 两个名字紧挨着也能各认各的；
   再向左收 `::` 限定名，拆成 `qualified`（`ns::Foo`）和 `name`（`Foo`）；
2. **成员访问 / 结构体变量**（`p->field`、`obj.field`，或光标就在 `p` 上）：
   codegraph 只给 `struct/class` 类型建节点、**不索引成员**，所以 `gd` 先在当前 buffer 里
   找 base 的声明（`Foo *p = ...`、`Foo f;`、`void f(Foo *p)`），推出类型后
   直接跳到 `struct/class` 定义 —— 不会拿成员名去撞同名的函数；
   C++ 的 `p->Method()` 只认 `Type::Method` 的候选，方法没进图谱就交给 coc；
   推不出类型（声明在别的文件/`auto`）也交给 coc；
3. 先按限定名精确查，没有再按短名查（`name` 相等，或 `qualified_name` 以 `::name` 结尾）；
4. 排序：名字完全相等 → 按"想要声明还是实现"（见下条）→ **当前文件优先** → 路径/行号；
5. **声明/实现互跳**（`definition.toggle = true`）：在 `.c/.cpp` 里按 `gd` 优先找 `.h/.hpp`
   里的声明，在头文件里则优先找实现；"想要的那一类"恰好只有一个就直接跳，多个才弹列表
   —— 所以从实现能跳回头文件，不再永远停在实现上（条目上 `·h` 表示这是头文件里的声明）；
6. 结果 1 个直接跳；多个 → telescope 列表；
7. **跳过去之后光标落在符号名上**：codegraph 给的 `start_column` 对 C/C++ 基本是 0，
   直接用它只会停在行首（`<cWORD>` 变成 `void`），所以跳转时会在目标行（及后 3 行）里
   找符号名再定位；连续按两次 `gd` 就能在声明/实现之间来回跳；
8. **C/C++ 头文件原型兜底**：codegraph 只给函数**定义**建节点，头文件里的
   `uint8_t Foo(int);` 不进 `nodes` 表 —— 所以从 `.c` 按 `gd` 在索引里找不到声明。
   这时会在头文件里用 `rg` 捞原型（`-g *.h/*.hpp/...`，要求 `;` 结尾、无 `{`、
   非 typedef/#define、`=` 不在 `(` 之前），同名的头文件优先。
9. **对象式宏兜底**：codegraph 只给函数式宏（`#define F(x)`）建 `constant` 节点，
   `#define F 1` 这种对象式宏完全不在索引里。`gd` 找不到时会用 `rg` 在项目里搜
   `^#define <name>`，命中就跳过去（`definition.macro_fallback = false` 可关）。
10. 一个都没有 → 按 `definition.fallback` 交给 coc（喂 `<Plug>(coc-definition)`），
   没有 coc 就提示"索引可能过期，试 `:CodeGraph sync`"。

---

## 8. 配置项

```lua
require("codegraph").setup({
    source = "auto",     -- auto | codegraph | codegraph_mcp | codegraph_cli | ripgrep
    -- auto 的探测顺序: 直读 -> MCP 兼容层 -> CLI 兜底
    sources = { "codegraph", "codegraph_mcp", "codegraph_cli" },

    -- codebase-memory-mcp: 补 codegraph 没有的能力 (字段/宏/BM25), 自动退化
    codebase_memory = {
        enabled = true,
        cmd = { "codebase-memory-mcp" },
        timeout = 2500,      -- 单次 tools/call 超时
        search_limit = 100,  -- 搜索时最多并入多少条
    },

    project = {
        index_dir = ".codegraph",
        db_file = "codegraph.db",
        max_depth = 0,
        skip_roots = {},
    },

    search = {
        limit = 400,
        exclude_kinds = { "import", "file" },     -- import 每文件一条，噪声
        match_signature = true,
        match_docstring = true,
        min_prompt = 1,
        empty_prompt = "none",                    -- none | recent(最近索引过的符号)
        prefill = "cword",                        -- 打开时用光标下的词预填: cword | none
        search_parents = true,                    -- 搜索也合并上级 .codegraph
        max_parents = 2,                          -- 最多合并几层上级索引
        max_parent_results = 150,                 -- 每个上级索引最多取几条
        debounce = 120,                           -- 输入停顿多少毫秒才真查（大库调大）
        include_usages = true,                    -- 结果里带上调用/引用点
        usage_limit = 200,                        -- 调用点最多几条
        usage_kinds = { "calls", "references" },  -- 哪些 edges 算"使用"
    },

    definition = {
        limit = 80,
        kinds = { "function", "method", "class", "struct", "enum", "type_alias", ... },
        header_exts = { "h", "hpp", "hh", "hxx", "inl", "ipp", "tpp", "inc", "def" },
        toggle = true,                            -- .h 里按 gd 找实现, .c/.cpp 里找声明
        type_kinds = { "struct", "class", "union", "enum", "type_alias", "typedef" },
        macro_fallback = true,                    -- 对象式宏用 rg 补找 #define
        search_parents = true,                    -- 本层没有时查上级 .codegraph
        max_parents = 3,
        prefer_impl = true,                       -- toggle 判断不出来时的默认倾向
        same_file_first = true,
        jump_single = true,
        fallback = "coc",                         -- coc | lsp | ""
    },

    references = { limit = 500, edge_kinds = { "calls", "references", "instantiates", "extends" } },
    callers = { limit = 300 },
    callees = { limit = 300 },
    files   = { limit = 3000 },

    preview = { enabled = true },

    keymaps = {
        search = "<Leader>gr",
        definition = "<Leader>gd",
        references = "<Leader>gR",
        callers = "<Leader>gc",
        callees = "<Leader>gC",
        files = "<Leader>gf",
        status = "<Leader>gs",
        sync = "<Leader>gy",
        -- 任意一项设 false 关掉
    },

    watcher = { ... },           -- 见第 6 节

    -- 兼容层: 直读 SQLite 失效时自动顶上
    mcp = {
        enabled = true,
        tools = "search,callers,callees,files,status,node",  -- 工具白名单 (小仓库默认只给 explore)
        cmd = { "codegraph", "serve", "--mcp" },
        timeout = 8000,
        kill_on_exit = true,     -- 退出时收掉自己拉起的 MCP 后台
        debug = false,
    },

    cli = { bin = "codegraph", timeout = 120000 },
    sqlite = { bin = "sqlite3", timeout = 4000, busy_timeout = 800 },

    notify = true,
    statusline = true,
})
```

<!-- 配置项以 lua/codegraph/config.lua 的 defaults 为准，这里只列常改的 -->
完整默认值见 [`lua/codegraph/config.lua`](lua/codegraph/config.lua)。

---

## 9. 数据源适配器（"可适配插件"那一层）

内置四个（`lua/codegraph/source/`）：

| 名字 | 干什么 | 何时用 |
| --- | --- | --- |
| `codegraph` | 直读 `.codegraph/codegraph.db` | 默认；最快、数据最全 |
| `codegraph_mcp` | 常驻 `codegraph serve --mcp`，走 `codegraph_search/callers/status/...` 工具 | 直读失效（表结构变了）或显式指定；冷启动慢，热态极快 |
| `codegraph_cli` | 调 `codegraph query/status/files/callers -j` | 没有 `sqlite3`、MCP 也起不来时的最后兜底（300ms/次） |
| `ripgrep` | `rg --json` 文本匹配 | 想在没有索引的项目也能搜（默认**不启用**，见下） |

`source = "auto"` 时按 `sources` 顺序探测第一个 `available()` 为真的。

### 表结构变了怎么办（schema 漂移）

直读 SQLite 是拿列名说话的，codegraph 升级把 `nodes` 的列改名/删掉就会失效。所以：

1. 每次解析数据源时先 `PRAGMA table_info(nodes)` 校验必需列（`id/kind/name/qualified_name/
   file_path/start_line/end_line`），结果按 db 的 mtime 缓存；
2. 校验不过 → 这个源 `available()` 返回 false，auto 自动换下一个（通常是 `codegraph_mcp`）；
3. 运行中某条 SQL 报 `no such column` 之类，也会把该源标记为 broken，下一次直接换源；
4. `:checkhealth codegraph` 会显示"表结构与直读 SQL 匹配"或具体缺哪一列。

MCP 这条路的兼容性由 codegraph 自己负责（工具接口是它的公开面），但代价见上表。

### 自己加一个数据源

```lua
-- ~/.config/nvim/lua/my_source.lua
local M = { name = "my_source", label = "我的符号库", priority = 200 }

function M.available(ctx) return true end

-- 返回统一的 item 列表；搜索是同步的（picker 的 finder 每输入一次就调一次）
function M.search(ctx, prompt, opts)
    return {
        {
            id = "x1", kind = "function", name = "foo",
            qualified_name = "ns::foo",
            path = "src/foo.c",                    -- 相对项目根，展示用
            file = "/abs/path/src/foo.c",          -- 绝对路径，跳转/预览用
            line = 12, end_line = 20,
            signature = "void foo(void)", doc = nil,
            source = M.name,
        },
    }
end

function M.definition(ctx, name, opts) return {} end
function M.references(ctx, name, opts) return {} end
function M.files(ctx, opts) return {} end
function M.status(ctx) return { nodes = 0 } end

require("codegraph.source").register(M)
```

契约全表（除 `name` 外都可以不实现，缺的能力会提示"数据源不支持"）：

```
name / label / priority
available(ctx)                     -> boolean
search(ctx, prompt, opts)          -> item[]
definition(ctx, name, opts)        -> item[]
references(ctx, name, opts)        -> item[]
callers(ctx, name, opts)           -> item[]
callees(ctx, name, opts)           -> item[]
files(ctx, opts)                   -> item[]
status(ctx)                        -> table { nodes, edges, files_count, indexed_at, pending?, ... }
sync(ctx, opts, cb)                            -- 可选
reindex(ctx, opts, cb)                         -- 可选
supports = { references = false, ... }         -- 明确声明不支持的能力
```

item 字段：`id kind name qualified_name path file line end_line signature doc source`。

### 关于 `ripgrep`

需求里"没有 `.codegraph` 就不使用"，所以 `ripgrep` 默认**不在** `sources` 里。
真想让无索引的项目也能 `<Leader>gr`，把它加进去：

```lua
sources = { "codegraph", "codegraph_cli", "ripgrep" },
```

注意它是纯文本匹配（结果 kind 是 `match`，带匹配行原文），没有符号语义。

---

## 10. 状态栏

```lua
-- lualine
lualine_x = { function() return require("codegraph").statusline() end },
```

有索引时显示 `cg:595`（节点数，30s 缓存），没有索引显示空。不想要就 `statusline = false`。

---

## 11. 性能

在 21k 节点 / 40MB 的库上实测（`sqlite3` 进程 + 查询，单位 ms）：

| 操作 | 耗时 |
| --- | --- |
| 搜索（4 列 LIKE，仅定义） | ~23 |
| 搜索（定义 + 调用点，37k 条边） | ~49 |
| 搜索首屏（含 picker 开销，单层索引） | ~58 |
| 搜索首屏（子索引 + 1 层父索引合并） | ~71 |
| 空 prompt（最近符号） | ~41 |
| 定义查询 | ~12 |
| 状态（3 条小查询） | ~18 |

调优手段（按需）：

- `search.limit` 调小（默认 400）；
- `search.match_docstring = false`（docstring 通常最大，关掉明显快）；
- `search.debounce` 调大（如 300~400），输入更快时合并成一次查询；
- 库特别大（>10 万节点）时 `debounce = 400` + `limit = 200` + 关掉 `match_docstring` 一起用。

### MCP 数据源实测（为什么它是"兜底"而不是默认）

同一台机器、同一个库（约 1 千文件 / 2.8 万节点）：

| 指标 | 直读 SQLite | `codegraph_mcp` |
| --- | --- | --- |
| 搜索延迟（热态） | 23~40ms | **0.7~1ms**（p50） |
| 首次调用 | 无 | **3.8~6.6s**（要开项目） |
| 抖动 | 稳定 | 偶发 5.8s（后台 sync/checkpoint） |
| 返回数据 | 结构化（含 qualified_name/signature） | markdown 文本，要解析，**没有 qualified_name** |
| 结果上限 | 自己定（默认 400） | 工具硬上限 100 |
| 文件列表 | 全量 | 输出被截断（约 15KB / 300 条） |
| 依赖 | `nodes/edges` 表结构 | 只依赖 codegraph 的工具接口 |

结论：**热态 MCP 确实更快，但冷启动和抖动会卡人**，所以默认顺序是
`codegraph` → `codegraph_mcp` → `codegraph_cli`；直读失效（schema 变了 / 没装 sqlite3）
才自动落到 MCP。MCP 的 picker 走**异步 finder**，就算它 5 秒才回，UI 也不会冻结。
想强制用 MCP：`source = "codegraph_mcp"`；进项目时插件会先在后台把 MCP 暖起来。

---

## 12. 排错

```
:checkhealth codegraph
```

会检查：nvim 版本、telescope、`sqlite3`/`codegraph` 可执行文件与版本、索引根与 db 大小、
节点/关系/文件数、最近索引时间、待同步文件数、数据源可用性、watcher 模式与后台状态、键位是否都绑上了。

常见问题：

| 现象 | 原因 / 处理 |
| --- | --- |
| `没找到 .codegraph/codegraph.db (已从 ... 逐级向上找)` | 项目没建索引。在项目根跑 `codegraph init`；或者这个项目就是不想用 |
| `<Leader>gr` 没反应 / 弹 coc 的引用 | 插件没加载或加载顺序不对：确认 `lazy = false`、`priority = 40` |
| 搜索结果是旧的 | `:CodeGraph sync`；或把 `watcher.mode` 改成 `"daemon"` |
| `sqlite3: command not found` | 装 sqlite3；或 `source = "codegraph_cli"`（会慢很多） |
| 预览窗报 `attempt to index vim.NIL` | 老版本 bug，已修（JSON null 统一解成 nil）；升级插件文件即可 |
| 补全时报 `E474: String "<c9><f9>..." contains byte that does not start any UTF-8` | 不是本插件：codeium 会把所有已加载 buffer 原文塞进请求，GBK 源码/telescope 结果里的非 UTF-8 字节让 `json_encode` 失败。已在 `lua/codeium_fix.lua` 打补丁（过滤非法 UTF-8 文档） |
| 后台状态显示 running 但其实是残留 pid | 已核对 `/proc/<pid>/cmdline`；仍不对就 `:CodeGraph daemon stop` 再 start |

---

## 13. 自测

```bash
cd /path/to/一个有索引的项目
nvim --headless -u ~/.config/nvim/local/codegraph.nvim/tests/minimal_init.lua \
     -c "luafile ~/.config/nvim/local/codegraph.nvim/tests/selftest.lua" -c "qa!"
```

`tests/manual/` 下是几个手动用例（picker 实测、多定义、后台守护、保存同步、轮询同步、健康检查），
用同样的命令换 `luafile` 的路径即可。

---

## 14. 已知限制

- **codegraph 的 `start_column` 不可靠**（C/C++ 常年是 0）：跳转定位靠"在目标行里找符号名"，
  名字在目标行出现多次时取第一个；找不到才退回行首。
- **codebase-memory 是可选增强**：它按项目单独建索引（`~/.cache/codebase-memory-mcp/`），
  索引过期/项目搬过家时 `gd` 可能落在旧行号；`<Leader>gd` 优先 codegraph、搜不到才问它，
  所以日常路径不受影响。它也没有"声明/实现"概念，互跳永远由 codegraph 负责。
- **对象式宏不在图谱里**：`#define NAME ...` 不建节点，`gd` 靠 `rg` 补找（第 7 节第 9 条），
  能跳但 `<Leader>gr` 搜不到；`#define NAME(x)` 这类函数式宏是 `constant` 节点，两者都正常。
- **结构体成员不在图谱里**：codegraph 只索引 `struct/class` 类型，没有字段节点。`gd` 靠
  当前 buffer 里的声明推断 base 的类型再跳到类型定义；声明不在当前文件（全局变量、`auto`）
  时只能交给 coc。多个同名结构体（比如仓库里有份 `audit/` 拷贝）会弹列表。
- **多级索引只向上找**：`gd` 和 `gr` 都会合并上级索引，但从父仓库打开文件不会反查子模块索引。
  合并父索引会让每次搜索多花约 15ms/层（只查有索引的祖先）。
- **codegraph 不索引 C/C++ 头文件里的函数原型**：`.h` 里通常只有 `enum/struct/宏` 有节点，
  `uint8_t Foo(int);` 这种原型没有。插件靠 `rg` 在头文件里补找（见第 7 节第 7 条），
  所以"从 .c 跳 .h"能用，但不属于图谱数据，而是文件搜索的结果。
- **"声明 vs 定义"靠文件后缀猜**：`.h/.hpp` 算声明，`.c/.cpp` 算实现。codegraph 的
  `nodes` 表没有 `is_declaration` 字段，跨语言（C++ 之外）这个启发式会不准。
- **references/callers 依赖 `edges` 的质量**：索引里没建出 `calls` 边时结果会是 0，
  不是插件漏查。
- **CLI 数据源没有 references**：`codegraph` 只有 `callers/callees/impact`，没有 references 命令，
  所以 `codegraph_cli` 下 `<Leader>gR` 会提示不支持。
- **每次输入都起一个 `sqlite3` 进程**：简单可靠，但超大库（>50 万节点）会到 100ms 量级，
  届时把 `search.debounce` 调大、`limit` 调小。
- **MCP 源靠解析 markdown 文本**：codegraph 的工具返回是给 LLM 看的格式化文本，不是 JSON，
  所以拿不到 `qualified_name`、结果被工具硬限制在 100 条、`codegraph_files` 的输出还会被截断
  （约 300 个文件）。它是"表结构变了还能用"的兜底，不是全功能替代。
- **MCP 冷启动 4~6s**：插件会在进项目时后台预热，但第一次真的等它时仍可能慢；picker 用异步
  finder 不冻结 UI，`gd` 这种同步跳转会等（会先弹提示）。想避开就保持直读可用。
- **MCP 没有 references 工具**：`<Leader>gR` 在 MCP 源下会提示不支持（只有 callers/callees）；
  它的 `codegraph_search` 也只给定义，没有"调用点"条目（`include_usages` 只在直读/CLI 源生效）。

---

## License

MIT © coffee
