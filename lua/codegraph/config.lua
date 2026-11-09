-- ============================================================================
-- codegraph.nvim: 默认配置 / 合并逻辑
-- 所有可调项集中在这里, 说明见 README.md 与 :h codegraph-config
-- ============================================================================

local M = {}

--- 深度合并: table 逐键合并, list 整体替换 (vim.tbl_deep_extend 会按下标合并 list,
--- 用户写 kinds = { "function" } 时不会把默认的一长串清掉, 这里必须自己来)
---@param base table
---@param user table|nil
---@return table
local function merge(base, user)
    if type(user) ~= "table" then
        return base
    end
    local out = {}
    for k, v in pairs(base) do
        out[k] = v
    end
    for k, v in pairs(user) do
        if type(v) == "table" and type(out[k]) == "table" and not vim.islist(v) and not vim.islist(out[k]) then
            out[k] = merge(out[k], v)
        else
            out[k] = v
        end
    end
    return out
end

M.defaults = {
    -- ======================================================================
    -- 数据源 (可插拔): auto = 按 sources 顺序探测第一个可用的
    -- 也可以写死 "codegraph" / "codegraph_cli" / "ripgrep"
    -- 注: ripgrep 默认不在列表里 —— 没有 .codegraph 的项目按需求就是"不使用",
    --     想在没有索引的项目里也能搜, 把 "ripgrep" 加进来即可。
    -- ======================================================================
    source = "auto",
    -- 顺序 = 探测顺序:
    --   codegraph     直读 SQLite (最快, 20~40ms, 但绑表结构)
    --   codegraph_mcp 走 codegraph 自己的 MCP 工具 (表结构改了也能用; 冷启动 4~6s)
    --   codegraph_cli 每次起一个 node 进程 (最慢, 300ms/次, 最后的兜底)
    sources = { "codegraph", "codegraph_mcp", "codegraph_cli" },

    -- ======================================================================
    -- 项目定位: 从当前文件所在目录向上找 .codegraph/codegraph.db
    -- ======================================================================
    project = {
        index_dir = ".codegraph",
        db_file = "codegraph.db",
        -- 向上最多找几层, 0 = 一直找到 / (需求就是"没有就回上一级")
        max_depth = 0,
        -- 这些目录里的索引直接忽略 (默认空; 若 ~/.codegraph 被建成了全 home 索引,
        -- 可以写 vim.env.HOME 把它排除掉)
        skip_roots = {},
    },

    -- ======================================================================
    -- 搜索
    -- ======================================================================
    search = {
        limit = 400,
        -- 这些 kind 不参与搜索: import 每个文件一条, 纯噪声
        exclude_kinds = { "import", "file" },
        match_signature = true,
        match_docstring = true,
        -- 输入至少几个字符才查 (0 = 空 prompt 也查)
        min_prompt = 1,
        -- 空 prompt 时显示什么: "none"(什么都不显示) / "recent"(最近索引过的符号)
        empty_prompt = "none",
        -- 打开搜索时用光标下的词预填 prompt: "cword"(预填) / "none"(空)
        prefill = "cword",
        -- 搜索时合并上级 .codegraph 的结果 (多级索引): 本模块索引里没有的符号也能搜到
        search_parents = true,
        max_parents = 2,
        -- 每个上级索引最多取多少条, 防止父仓库太大把结果刷爆
        max_parent_results = 150,
        -- 搜索结果里要不要带上"调用/引用点" (edges 表里的 calls/references),
        -- 也就是"这个函数在哪些地方被用到了", 点一下直接跳到调用行
        include_usages = true,
        usage_limit = 200,
        usage_kinds = { "calls", "references" },
        -- 输入停顿多少毫秒才真正查一次 (telescope 的 debounce; 大库调大能少查几次)
        debounce = 120,
    },

    -- ======================================================================
    -- 定义跳转 <Leader>gd
    -- ======================================================================
    definition = {
        limit = 80,
        -- 哪些 kind 算"定义/声明"
        kinds = {
            "function",
            "method",
            "constructor",
            "class",
            "struct",
            "union",
            "interface",
            "trait",
            "enum",
            "enum_member",
            "type_alias",
            "typedef",
            "namespace",
            "module",
            "variable",
            "constant",
            "field",
            "property",
            "macro",
        },
        -- 头文件后缀: 判定"声明"而不是"实现" (C/C++ 场景)
        header_exts = { "h", "hh", "hpp", "hxx", "inl", "ipp", "tpp", "inc", "def" },
        -- 声明/实现互跳: 在 .h 里按 gd 找实现, 在 .c/.cpp 里按 gd 找声明
        -- (关掉就永远按 prefer_impl 的规则, 只认实现)
        toggle = true,
        -- 声明让位给实现 (toggle 关闭或当前文件类型判断不出来时生效)
        prefer_impl = true,
        -- 当前 buffer 里的同名节点排最前
        same_file_first = true,
        -- 只有一个结果时直接跳; false = 也开 picker
        jump_single = true,
        -- 本层索引里没有时, 继续查上级 .codegraph (多级索引: 子模块 + 顶层仓库)
        search_parents = true,
        max_parents = 3,
        -- 索引里找不到时怎么兜底: "coc"(喂 <Plug>(coc-definition)) / "lsp" / ""(不管)
        fallback = "coc",
    },

    -- ======================================================================
    -- 引用 / 调用关系 (用 edges 表)
    -- ======================================================================
    references = {
        limit = 500,
        edge_kinds = { "calls", "references", "instantiates", "extends" },
    },

    callers = { limit = 300 },
    callees = { limit = 300 },
    files = { limit = 3000 },

    -- ======================================================================
    -- 界面
    -- ======================================================================
    preview = {
        enabled = true,
    },

    -- ======================================================================
    -- 键位: 设为 false 可关掉对应的键
    -- ======================================================================
    keymaps = {
        search = "<Leader>gr",      -- 搜索符号 / 匹配
        definition = "<Leader>gd",  -- 跳转定义或声明 (多个时列表选择)
        references = "<Leader>gR",  -- 谁引用了它
        callers = "<Leader>gc",     -- 谁调用了它
        callees = "<Leader>gC",     -- 它调用了谁
        files = "<Leader>gf",       -- 索引里的文件
        status = "<Leader>gs",      -- 索引状态
        sync = "<Leader>gy",        -- 立即同步索引
    },

    -- ======================================================================
    -- 后台索引: 要不要维持 codegraph 后台, 让它在文件变化后自动更新数据库
    --
    --   "auto"    已有后台就复用, 没有就在保存时自己 sync (推荐)
    --   "daemon"  主动拉起 `codegraph serve --mcp` 后台 (它自带文件监视)
    --   "on_save" 只在保存时 sync
    --   "poll"    定时检查 pendingChanges, 有变更就 sync (能兜住 git checkout 等)
    --   "off"     完全不管, 只用 :CodeGraph sync 手动同步
    -- ======================================================================
    watcher = {
        mode = "auto",
        daemon = {
            -- auto 模式下是否允许主动拉起后台; false = 只复用别人(如 AI 客户端)起的
            autostart = false,
            -- nvim 退出时是否杀掉自己拉起的后台; 默认 false, 让它按 idle 超时(5min)自己退
            stop_on_exit = false,
            -- 注: --no-watch 关掉它的文件监视, 这里不传, 要的就是监视
            cmd = { "codegraph", "serve", "--mcp" },
            -- 最大文件数: 超大仓库拉起后台性价比低 (node 进程约 150MB)
            max_files = 20000,
        },
        on_save = {
            debounce = 1500,     -- 保存后等多久再同步 (ms)
            min_interval = 5000, -- 两次同步之间至少隔多久 (ms)
            timeout = 120000,
        },
        poll = {
            interval = 120, -- 秒
            timeout = 30000,
        },
        -- 这些路径保存后不同步 (Lua 正则)
        ignore = { "/%.codegraph/", "/%.git/", "/build/", "/node_modules/", "/deps/", "/%.cache/" },
    },

    -- ======================================================================
    -- MCP (codegraph serve --mcp): 兼容层, 直读 SQLite 失效时自动顶上
    -- ======================================================================
    mcp = {
        enabled = true,
        -- 工具面按仓库大小动态裁剪, 用这个变量点名要哪些 (小仓库默认只给 explore)
        tools = "search,callers,callees,files,status,node",
        cmd = { "codegraph", "serve", "--mcp" },
        timeout = 8000,
        -- nvim 退出时是否杀掉自己拉起的 MCP 后台 (别人的后台不会动)
        kill_on_exit = true,
        -- 调试时把 MCP 的 stderr 打出来
        debug = false,
    },

    -- ======================================================================
    -- 外部命令
    -- ======================================================================
    cli = {
        bin = "codegraph",
        timeout = 120000,
    },
    sqlite = {
        bin = "sqlite3",
        timeout = 4000,
        -- 直读 SQLite 时的 busy 超时 (ms), 后台正在写库时等它一会
        busy_timeout = 800,
    },

    -- 通知: false = 静默 (错误除外)
    notify = true,
    -- 状态栏组件: require("codegraph").statusline()
    statusline = true,
}

--- 当前生效的配置 (setup 之后填充)
M.values = M.defaults

---@param user table|nil
---@return table
function M.setup(user)
    M.values = merge(M.defaults, user or {})
    return M.values
end

---@return table
function M.get()
    return M.values
end

return M
