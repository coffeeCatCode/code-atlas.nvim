-- ============================================================================
-- code-atlas.nvim: 默认数据源 —— 直读 .codegraph/codegraph.db (SQLite)
--
-- 为什么直读而不是每次跑 `codegraph query`:
--   sqlite3 一条 LIKE 查询在 2 万节点的库上约 10~20ms (含进程启动),
--   而 `codegraph` 是 node 程序, 单次启动就 300ms 上下, 没法边输边查。
--   WAL 模式允许"后台在写, 这边同时在读", 不需要加锁等待。
--
-- 表结构 (codegraph v1.x):
--   nodes(id, kind, name, qualified_name, file_path, start_line, end_line,
--         start_column, end_column, docstring, signature, ...)
--   edges(source, target, kind, line, col)  kind: calls/contains/imports/
--         references/extends/instantiates
--   files(path, language, size, node_count, indexed_at, ...)
--   project_metadata(key, value)
--   file_path 是相对项目根的路径
-- ============================================================================

local config = require("code_atlas.config")
local util = require("code_atlas.util")

local M = {
    name = "codegraph",
    label = "codegraph (SQLite 直读)",
    priority = 100,
}

-- 统一取这些列, 后面的 row -> item 转换只用这一套字段
local COLS = table.concat({
    "id",
    "kind",
    "name",
    "qualified_name",
    "file_path",
    "start_line",
    "end_line",
    "signature",
    "docstring",
}, ", ")

--- 跑一条 SQL, 返回行数组
---@param ctx table
---@param sql string
---@param timeout integer|nil
---@return table[]|nil rows
---@return string|nil err
-- 运行期发现 SQL 已经不兼容 (例如后台重建索引换了 schema): 置位后 available() 立刻变 false
M.broken = nil
M.broken_mtime = nil

---@param msg string
---@return boolean
local function is_schema_error(msg)
    if not msg then
        return false
    end
    for _, pat in ipairs({ "no such column", "no such table", "has no column", "malformed" }) do
        if msg:find(pat, 1, true) then
            return true
        end
    end
    return false
end

local function query(ctx, sql, timeout)
    local cfg = config.get()
    local args = {
        cfg.sqlite.bin,
        "-cmd",
        ".timeout " .. tostring(cfg.sqlite.busy_timeout or 800),
        "-json",
        ctx.db,
    }
    local last_err
    -- 后台刚好在 checkpoint 时可能撞上 locked, 重试一次就够
    for _ = 1, 2 do
        local res = util.run_sync(args, {
            stdin = sql,
            timeout = timeout or cfg.sqlite.timeout,
        })
        if res.code == 0 then
            local rows = util.decode(res.stdout)
            return type(rows) == "table" and rows or {}
        end
        last_err = res.stderr ~= "" and res.stderr or ("sqlite3 退出码 " .. tostring(res.code))
        if is_schema_error(last_err) then
            -- 库结构变了: 这一轮之后让 auto 模式换数据源
            M.broken = last_err
            local st = vim.uv.fs_stat(ctx.db)
            M.broken_mtime = st and st.mtime.sec or nil
            util.notify(
                "codegraph 库结构变了, 直读失效 (" .. util.oneline(last_err) .. "), 改用 MCP/CLI",
                vim.log.levels.WARN
            )
            break
        end
        local uv = vim.uv or vim.loop
        if uv.sleep then
            uv.sleep(60)
        end
    end
    return nil, last_err
end

M.query = query
-- 直读 SQLite 依赖这些列; codegraph 升级把哪一列改名/删掉, 就直接判"不可用",
-- 自动退到 MCP / CLI (它们的接口由 codegraph 自己维护)
local REQUIRED_COLUMNS = {
    "id",
    "kind",
    "name",
    "qualified_name",
    "file_path",
    "start_line",
    "end_line",
}

-- db: mtime -> { ok, reason }
local schema_cache = {}

--- 表结构是否还能被本插件读取
---@param ctx table
---@return boolean ok
---@return string|nil reason
function M.schema_check(ctx)
    if not ctx or not ctx.db then
        return false, "没有索引文件"
    end
    local key = string.format("%s:%d", ctx.db, ctx.db_mtime or 0)
    local cached = schema_cache[key]
    if cached then
        return cached.ok, cached.reason
    end

    local rows = query(ctx, "PRAGMA table_info(nodes);", 3000)
    if not rows then
        local res = { ok = false, reason = "读不到 nodes 表 (库损坏/被锁)" }
        schema_cache[key] = res
        return res.ok, res.reason
    end

    local have = {}
    for _, row in ipairs(rows) do
        have[row.name] = true
    end
    for _, col in ipairs(REQUIRED_COLUMNS) do
        if not have[col] then
            local res = { ok = false, reason = "nodes 缺列 " .. col }
            schema_cache[key] = res
            return res.ok, res.reason
        end
    end

    schema_cache[key] = { ok = true }
    return true
end

---@param ctx table|nil
---@return boolean
function M.available(ctx)
    if not ctx or not ctx.db then
        return false
    end
    if M.broken then
        -- 库被重建过 (mtime 变了) 就重新给直读一次机会
        local st = vim.uv.fs_stat(ctx.db)
        local mtime = st and st.mtime.sec or nil
        -- broken_mtime 为 nil 表示是测试/手动置位, 不去猜
        if M.broken_mtime == nil or M.broken_mtime == mtime then
            return false
        end
        M.broken = nil
        M.broken_mtime = nil
    end
    if not util.executable(config.get().sqlite.bin) then
        return false
    end
    local ok = M.schema_check(ctx)
    return ok == true
end


--- 单行 -> 统一 item
---@param ctx table
---@param row table
---@param line_field string|nil 用哪个字段当跳转行号 (references 用 edge 的行号)
---@return table
local function to_item(ctx, row, line_field)
    local path = row.file_path or ""
    local file = path
    if path ~= "" and path:sub(1, 1) ~= "/" then
        file = ctx.root:gsub("/$", "") .. "/" .. path
    end
    local line = row[line_field or "start_line"] or row.start_line or 1
    return {
        id = row.id,
        kind = row.kind,
        name = row.name,
        qualified_name = row.qualified_name,
        path = path,
        file = file,
        line = line,
        start_line = row.start_line or line,
        end_line = row.end_line or line,
        signature = row.signature,
        doc = row.docstring,
        edge_kind = row.edge_kind,
        source = M.name,
    }
end

---@param kinds string[]|nil
---@param mode "IN"|"NOT IN"
---@return string
local function kind_filter(kinds, mode)
    local list = kinds or {}
    if #list == 0 then
        return "1 = 1"
    end
    return string.format("kind %s %s", mode, util.sql_list(list))
end

-- ---------------------------------------------------------------------------
-- 搜索
-- ---------------------------------------------------------------------------

--- 最近索引过的符号 (空 prompt 时用)
---@param ctx table
---@param limit integer
---@return table[]
local function recent(ctx, limit)
    local cfg = config.get()
    local sql = ([[
SELECT %s FROM nodes
WHERE %s
ORDER BY updated_at DESC, length(name), name
LIMIT %d;
]]):format(COLS, kind_filter(cfg.search.exclude_kinds, "NOT IN"), limit)
    local rows = query(ctx, sql)
    local out = {}
    for _, row in ipairs(rows or {}) do
        out[#out + 1] = to_item(ctx, row)
    end
    return out
end

---@param ctx table
---@param name string
---@param max integer
---@return string[]
local function node_ids_by_name(ctx, name, max)
    local q = util.sql(name:lower())
    local sql = ([[
SELECT id FROM nodes
WHERE lower(name) = %s OR lower(qualified_name) = %s
LIMIT %d;
]]):format(q, q, max or 200)
    local rows = query(ctx, sql) or {}
    local ids = {}
    for _, row in ipairs(rows) do
        ids[#ids + 1] = util.sql(row.id)
    end
    return ids
end

M.node_ids_by_name = node_ids_by_name

--- 查"谁在哪儿用了它": edges 里指向匹配符号的 calls/references 边,
--- 条目的 path/line 是**调用点**的行号 (不是被调函数的定义行)
---@param ctx table
---@param prompt string
---@param opts table|nil
---@return table[]
function M.usages(ctx, prompt, opts)
    local cfg = config.get()
    opts = opts or {}
    local limit = opts.limit or cfg.search.usage_limit or 200
    local q = prompt:lower()
    local contains = util.like_contains(q)
    local kinds = opts.usage_kinds or cfg.search.usage_kinds or { "calls", "references" }

    local sql = ([[
SELECT e.id AS edge_id, e.kind AS edge_kind, e.line AS edge_line, e.col AS edge_col,
       t.name AS target_name, t.qualified_name AS target_qname, t.kind AS target_kind,
       s.name AS src_name, s.qualified_name AS src_qname, s.kind AS src_kind,
       s.file_path AS file_path, s.start_line AS start_line, s.end_line AS end_line
FROM edges e
JOIN nodes t ON t.id = e.target
JOIN nodes s ON s.id = e.source
WHERE e.kind IN %s
  AND t.id IN (
      SELECT id FROM nodes
      WHERE kind NOT IN ('import', 'file')
        AND (lower(name) LIKE %s ESCAPE '\'
             OR lower(qualified_name) LIKE %s ESCAPE '\')
  )
ORDER BY length(t.name), s.file_path, e.line
LIMIT %d;
]]):format(util.sql_list(kinds), contains, contains, limit)

    local rows, err = query(ctx, sql)
    if not rows then
        util.notify("查调用点失败: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end

    local out = {}
    local seen = {}
    for _, row in ipairs(rows) do
        local path = row.file_path or ""
        if path ~= "" then
            local line = row.edge_line or row.start_line or 1
            -- 同一行里对同一个符号的重复边只留一条
            local key = path .. ":" .. tostring(line) .. ":" .. tostring(row.target_name) .. ":" .. tostring(row.edge_kind)
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = {
                    id = "usage:" .. tostring(row.edge_id),
                    kind = "usage",
                    name = row.target_name,
                    qualified_name = row.target_qname,
                    path = path,
                    file = path:sub(1, 1) == "/" and path or (ctx.root:gsub("/$", "") .. "/" .. path),
                    line = line,
                    start_line = line,
                    end_line = line,
                    caller = row.src_name,
                    caller_qualified = row.src_qname,
                    caller_kind = row.src_kind,
                    edge_kind = row.edge_kind,
                    is_usage = true,
                    source = M.name,
                }
            end
        end
    end
    return out
end

--- 符号搜索
---@param ctx table
---@param prompt string|nil
---@param opts table|nil
---@return table[]
function M.search(ctx, prompt, opts)
    local cfg = config.get()
    opts = opts or {}
    local limit = opts.limit or cfg.search.limit

    if not prompt or prompt == "" then
        if cfg.search.empty_prompt == "none" then
            return {}
        end
        return recent(ctx, limit)
    end

    local q = prompt:lower()
    local contains = util.like_contains(q)
    local prefix = util.like_prefix(q)
    local exact = util.sql(q)

    local parts = {
        "lower(name) LIKE " .. contains .. " ESCAPE '\\'",
        "lower(qualified_name) LIKE " .. contains .. " ESCAPE '\\'",
    }
    if cfg.search.match_signature then
        parts[#parts + 1] = "lower(ifnull(signature, '')) LIKE " .. contains .. " ESCAPE '\\'"
    end
    if cfg.search.match_docstring then
        parts[#parts + 1] = "lower(ifnull(docstring, '')) LIKE " .. contains .. " ESCAPE '\\'"
    end

    local exclude = cfg.search.exclude_kinds
    local sql = ([[
SELECT %s FROM nodes
WHERE %s
  AND (%s)
ORDER BY
  CASE
    WHEN lower(name) = %s THEN 0
    WHEN lower(name) LIKE %s ESCAPE '\' THEN 1
    WHEN lower(qualified_name) LIKE %s ESCAPE '\' THEN 2
    ELSE 3
  END,
  length(name), name, file_path
LIMIT %d;
]]):format(COLS, kind_filter(exclude, "NOT IN"), table.concat(parts, "\n     OR "), exact, prefix, prefix, limit)

    local rows, err = query(ctx, sql)
    if not rows then
        util.notify("搜索失败: " .. tostring(err), vim.log.levels.ERROR)
        return {}
    end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = to_item(ctx, row)
    end

    -- 定义在前, "调用/引用点"追加在后 (picker 里按 fuzzy 分数重排)
    if cfg.search.include_usages ~= false then
        local usage_limit = opts.usage_limit or cfg.search.usage_limit or 200
        for _, item in ipairs(M.usages(ctx, prompt, { limit = usage_limit })) do
            out[#out + 1] = item
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 定义 / 声明
-- ---------------------------------------------------------------------------

--- 排序: 名字完全相等的在前, 其次按"声明/实现互跳"的期望排, 再次当前文件优先
---
--- 互跳规则 (definition.toggle = true 时):
---   当前在 .h/.hpp  -> 优先去 .c/.cpp 的实现
---   当前在 .c/.cpp  -> 优先去 .h/.hpp 的声明   <-- 头文件优先, 不再永远跳实现
---   判断不出文件类型 / toggle 关闭 -> 按 prefer_impl (实现优先)
---@param ctx table
---@param items table[]
---@param name string
local function sort_definitions(ctx, items, name)
    local cfg = config.get()
    local q = name:lower()
    local cur_file = vim.api.nvim_buf_get_name(0)
    if cur_file and cur_file ~= "" then
        cur_file = vim.fs.normalize(cur_file)
    end

    local toggle = cfg.definition.toggle
    local cur_is_header = cur_file ~= "" and util.is_header(cur_file, cfg.definition.header_exts)
    -- 当前在实现里 -> 想找声明; 当前在头文件里 -> 想找实现
    local want_decl = toggle and cur_file ~= "" and not cur_is_header

    local function rank(item)
        local exact = (item.name or ""):lower() == q and 0 or 1
        local is_decl = item.is_decl and 1 or 0
        local decl
        if toggle and cur_file ~= "" then
            decl = want_decl and (1 - is_decl) or is_decl
        elseif cfg.definition.prefer_impl then
            decl = is_decl -- 声明(1) 排在实现(0) 后面
        else
            decl = 0
        end
        local same = (cfg.definition.same_file_first and cur_file == item.file) and 0 or 1
        return { exact, decl, same, #item.path, item.line }
    end

    table.sort(items, function(a, b)
        local ra, rb = rank(a), rank(b)
        for i = 1, #ra do
            if ra[i] ~= rb[i] then
                return ra[i] < rb[i]
            end
        end
        return false
    end)
end

--- 定义/声明查询: 名字完全相等, 或限定名完全相等, 或以 ::name 结尾
---@param ctx table
---@param name string
---@param opts table|nil
---@return table[]
function M.definition(ctx, name, opts)
    local cfg = config.get()
    opts = opts or {}
    if not name or name == "" then
        return {}
    end
    local q = name:lower()
    local exact = util.sql(q)
    local suffix = util.sql("%::" .. util.escape_like(q))

    local sql = ([[
SELECT %s FROM nodes
WHERE %s
  AND (
        lower(name) = %s
     OR lower(qualified_name) = %s
     OR lower(qualified_name) LIKE %s ESCAPE '\'
  )
LIMIT %d;
]]):format(COLS, kind_filter(opts.kinds or cfg.definition.kinds, "IN"), exact, exact, suffix, opts.limit or cfg.definition.limit)

    local rows, err = query(ctx, sql)
    if not rows then
        util.notify("查定义失败: " .. tostring(err), vim.log.levels.ERROR)
        return {}
    end
    local out = {}
    for _, row in ipairs(rows) do
        local item = to_item(ctx, row)
        item.is_decl = util.is_header(item.path, cfg.definition.header_exts)
        out[#out + 1] = item
    end
    sort_definitions(ctx, out, name)
    return out
end

-- ---------------------------------------------------------------------------
-- 引用 / 调用关系 (edges 表)
-- ---------------------------------------------------------------------------

---@param ctx table
---@param name string
---@param opts table
---@param edge_kinds string[]
---@param direction "in"|"out"
---@return table[]
local function walk_edges(ctx, name, opts, edge_kinds, direction)
    local limit = opts.limit or 300
    local ids = node_ids_by_name(ctx, name)
    if #ids == 0 then
        return {}
    end
    local ids_sql = "(" .. table.concat(ids, ",") .. ")"
    local sql
    if direction == "in" then
        -- 谁指向 name: 跳转点用调用点的行号
        sql = ([[
SELECT e.kind AS edge_kind, e.line AS edge_line,
       n.id AS id, n.kind AS kind, n.name AS name, n.qualified_name AS qualified_name,
       n.file_path AS file_path, n.start_line AS start_line, n.end_line AS end_line,
       n.signature AS signature, n.docstring AS docstring
FROM edges e JOIN nodes n ON n.id = e.source
WHERE e.kind IN %s AND e.target IN %s
ORDER BY n.file_path, e.line
LIMIT %d;
]]):format(util.sql_list(edge_kinds), ids_sql, limit)
    else
        -- name 指向谁: 跳转点用被调方的起始行
        sql = ([[
SELECT e.kind AS edge_kind, e.line AS edge_line,
       n.id AS id, n.kind AS kind, n.name AS name, n.qualified_name AS qualified_name,
       n.file_path AS file_path, n.start_line AS start_line, n.end_line AS end_line,
       n.signature AS signature, n.docstring AS docstring
FROM edges e JOIN nodes n ON n.id = e.target
WHERE e.kind IN %s AND e.source IN %s
ORDER BY n.file_path, n.start_line
LIMIT %d;
]]):format(util.sql_list(edge_kinds), ids_sql, limit)
    end

    local rows, err = query(ctx, sql)
    if not rows then
        util.notify("查关系失败: " .. tostring(err), vim.log.levels.ERROR)
        return {}
    end
    local out = {}
    for _, row in ipairs(rows) do
        local item = to_item(ctx, row, direction == "in" and "edge_line" or "start_line")
        item.edge_kind = row.edge_kind
        out[#out + 1] = item
    end
    return out
end

--- 谁引用了 name
function M.references(ctx, name, opts)
    opts = opts or {}
    return walk_edges(ctx, name, opts, config.get().references.edge_kinds, "in")
end

--- 谁调用了 name
function M.callers(ctx, name, opts)
    opts = opts or {}
    return walk_edges(ctx, name, opts, { "calls" }, "in")
end

--- name 调用了谁
function M.callees(ctx, name, opts)
    opts = opts or {}
    return walk_edges(ctx, name, opts, { "calls" }, "out")
end

-- ---------------------------------------------------------------------------
-- 文件 / 状态
-- ---------------------------------------------------------------------------

---@param ctx table
---@param opts table|nil
---@return table[]
function M.files(ctx, opts)
    local cfg = config.get()
    opts = opts or {}
    local limit = opts.limit or cfg.files.limit
    local where = ""
    if opts.pattern and opts.pattern ~= "" then
        where = "WHERE lower(path) LIKE " .. util.like_contains(opts.pattern:lower()) .. " ESCAPE '\\'"
    end
    local sql = ([[
SELECT path, language, node_count, size, indexed_at FROM files
%s
ORDER BY path
LIMIT %d;
]]):format(where, limit)

    local rows, err = query(ctx, sql)
    if not rows then
        util.notify("读文件列表失败: " .. tostring(err), vim.log.levels.ERROR)
        return {}
    end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = {
            id = row.path,
            kind = "file",
            name = util.basename(row.path),
            qualified_name = row.path,
            path = row.path,
            file = ctx.root:gsub("/$", "") .. "/" .. row.path,
            line = 1,
            language = row.language,
            node_count = row.node_count,
            size = row.size,
            source = M.name,
        }
    end
    return out
end

--- 索引状态 (几条小查询拼起来, 约 20~30ms)
---@param ctx table
---@return table
function M.status(ctx)
    local schema_ok, schema_reason = M.schema_check(ctx)
    local out = {
        root = ctx.root,
        db = ctx.db,
        db_size = ctx.db_size,
        db_mtime = ctx.db_mtime,
        source = M.name,
        schema_ok = schema_ok,
        schema_reason = schema_reason,
    }

    local counts = query(ctx, [[
SELECT (SELECT COUNT(*) FROM nodes) AS nodes,
       (SELECT COUNT(*) FROM edges) AS edges,
       (SELECT COUNT(*) FROM files) AS files,
       (SELECT MAX(indexed_at) FROM files) AS indexed_at;
]])
    if counts and counts[1] then
        out.nodes = counts[1].nodes
        out.edges = counts[1].edges
        out.files_count = counts[1].files
        out.indexed_at = counts[1].indexed_at
    end

    local meta = query(ctx, "SELECT key, value FROM project_metadata;")
    if meta then
        out.metadata = {}
        for _, row in ipairs(meta) do
            out.metadata[row.key] = row.value
        end
        out.index_version = out.metadata.indexed_with_version
        out.extraction_version = out.metadata.indexed_with_extraction_version
        out.index_state = out.metadata.index_state
    end

    local kinds = query(ctx, "SELECT kind, COUNT(*) AS c FROM nodes GROUP BY kind ORDER BY c DESC;")
    if kinds then
        out.kinds = {}
        for _, row in ipairs(kinds) do
            out.kinds[row.kind] = row.c
        end
    end

    return out
end

---@param ctx table
---@return boolean
function M.ping(ctx)
    local rows = query(ctx, "SELECT 1 AS ok;", 2000)
    return rows ~= nil and rows[1] ~= nil
end

--- 用 CLI 同步索引 (直读模式自己不会更新库)
---@param ctx table
---@param opts table|nil
---@param cb fun(ok: boolean, msg: string)|nil
function M.sync(ctx, opts, cb)
    local cfg = config.get()
    opts = opts or {}
    if not util.executable(cfg.cli.bin) then
        local msg = "找不到 " .. cfg.cli.bin .. " 命令, 无法同步索引"
        if cb then
            cb(false, msg)
        end
        return
    end
    local cmd = { cfg.cli.bin, "sync" }
    if opts.quiet ~= false then
        cmd[#cmd + 1] = "-q"
    end
    cmd[#cmd + 1] = ctx.root

    local function done(res)
        if res.code == 0 then
            if cb then
                cb(true, vim.trim(res.stdout or ""))
            end
        else
            local msg = (res.stderr ~= "" and res.stderr or res.stdout or ""):gsub("\n+$", "")
            if cb then
                cb(false, msg ~= "" and msg or ("codegraph sync 退出码 " .. tostring(res.code)))
            end
        end
    end

    if opts.async == false then
        done(util.run_sync(cmd, { cwd = ctx.root, timeout = cfg.cli.timeout }))
    else
        util.run_async(cmd, { cwd = ctx.root, timeout = cfg.cli.timeout }, done)
    end
end

--- 全量重建 (codegraph index)
---@param ctx table
---@param opts table|nil
---@param cb fun(ok: boolean, msg: string)|nil
function M.reindex(ctx, opts, cb)
    local cfg = config.get()
    opts = opts or {}
    local cmd = { cfg.cli.bin, "index", "-q" }
    if opts.force then
        cmd[#cmd + 1] = "-f"
    end
    cmd[#cmd + 1] = ctx.root
    util.run_async(cmd, { cwd = ctx.root, timeout = cfg.cli.timeout * 5 }, function(res)
        local ok = res.code == 0
        local msg = vim.trim(ok and (res.stdout or "") or (res.stderr ~= "" and res.stderr or res.stdout or ""))
        if cb then
            cb(ok, msg)
        end
    end)
end

return M
