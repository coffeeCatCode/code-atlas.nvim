-- ============================================================================
-- code-atlas.nvim: 备用数据源 —— 调 `codegraph` 命令行 (JSON 输出)
--
-- 什么时候用: 机器上没有 sqlite3, 但有 codegraph; 或者想跟 CLI 的排序/语义
-- 完全一致。代价是每次查询都要起一个 node 进程 (约 300ms), 所以 picker 里
-- 查询本身要 300ms 上下, 大库上建议把 search.debounce 调大。
-- ============================================================================

local config = require("code_atlas.config")
local util = require("code_atlas.util")

local M = {
    name = "codegraph_cli",
    label = "codegraph (CLI)",
    priority = 50,
    -- CLI 没有 references 命令 (只有 callers/callees/impact)
    supports = { references = false },
}

---@param ctx table|nil
---@return boolean
function M.available(ctx)
    if not ctx then
        return false
    end
    return util.executable(config.get().cli.bin)
end

---@param ctx table
---@return string[]
local function base_args(ctx)
    return { config.get().cli.bin, "-p", ctx.root }
end

--- 把 CLI 的 node 对象转成统一 item
---@param ctx table
---@param node table
---@return table
local function to_item(ctx, node)
    local path = node.filePath or node.path or ""
    local file = path
    if path ~= "" and path:sub(1, 1) ~= "/" then
        file = ctx.root:gsub("/$", "") .. "/" .. path
    end
    return {
        id = node.id,
        kind = node.kind,
        name = node.name,
        qualified_name = node.qualifiedName or node.qualified_name,
        path = path,
        file = file,
        line = node.startLine or node.line or 1,
        start_line = node.startLine or node.line or 1,
        end_line = node.endLine or node.startLine or 1,
        signature = node.signature,
        doc = node.docstring,
        source = M.name,
    }
end

---@param ctx table
---@param args string[]
---@param opts table|nil
---@return any
local function run_json(ctx, args, opts)
    opts = opts or {}
    local cmd = base_args(ctx)
    vim.list_extend(cmd, args)
    local res = util.run_sync(cmd, {
        cwd = ctx.root,
        timeout = opts.timeout or config.get().cli.timeout,
    })
    if res.code ~= 0 then
        util.notify("codegraph 执行失败: " .. (res.stderr ~= "" and res.stderr or tostring(res.code)), vim.log.levels.WARN)
        return nil
    end
    return util.decode(res.stdout)
end

---@param ctx table
---@param prompt string|nil
---@param opts table|nil
---@return table[]
function M.search(ctx, prompt, opts)
    opts = opts or {}
    if not prompt or prompt == "" then
        return {}
    end
    local limit = opts.limit or config.get().search.limit
    local data = run_json(ctx, { "query", prompt, "-j", "-l", tostring(limit) })
    if type(data) ~= "table" then
        return {}
    end
    local out = {}
    for _, row in ipairs(data) do
        local node = row.node or row
        if node and node.name then
            out[#out + 1] = to_item(ctx, node)
        end
    end
    return out
end

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
    local allowed = {}
    for _, k in ipairs(opts.kinds or cfg.definition.kinds) do
        allowed[k] = true
    end

    local limit = opts.limit or cfg.definition.limit
    local data = run_json(ctx, { "query", name, "-j", "-l", tostring(limit) })
    if type(data) ~= "table" then
        return {}
    end

    local out = {}
    for _, row in ipairs(data) do
        local node = row.node or row
        if node and node.name then
            local n = (node.name or ""):lower()
            local qn = (node.qualifiedName or ""):lower()
            local hit = n == q
                or qn == q
                or (qn:sub(-(#q + 2)) == "::" .. q)
            if hit and allowed[node.kind or ""] then
                local item = to_item(ctx, node)
                item.is_decl = util.is_header(item.path, cfg.definition.header_exts)
                out[#out + 1] = item
            end
        end
    end

    table.sort(out, function(a, b)
        local da = (a.is_decl and 1 or 0) + (#a.path / 100000)
        local db_ = (b.is_decl and 1 or 0) + (#b.path / 100000)
        if da ~= db_ then
            return da < db_
        end
        return a.line < b.line
    end)
    return out
end

---@param ctx table
---@param name string
---@param opts table|nil
---@return table[]
local function relations(ctx, name, opts, direction)
    opts = opts or {}
    local limit = opts.limit or 300
    local cmd = direction == "in" and "callers" or "callees"
    local data = run_json(ctx, { cmd, name, "-j", "-l", tostring(limit) })
    if type(data) ~= "table" then
        return {}
    end
    local out = {}
    for _, def in ipairs(data.definitions or {}) do
        for _, node in ipairs(def[cmd] or {}) do
            if node and node.name then
                local item = to_item(ctx, node)
                item.edge_kind = (node.relationships and node.relationships[1]) or "calls"
                out[#out + 1] = item
            end
        end
    end
    return out
end

function M.callers(ctx, name, opts)
    return relations(ctx, name, opts, "in")
end

function M.callees(ctx, name, opts)
    return relations(ctx, name, opts, "out")
end

--- CLI 没有 references, 用 callers + callees 近似不了, 直接返回空
function M.references()
    return {}
end

---@param ctx table
---@param opts table|nil
---@return table[]
function M.files(ctx, opts)
    opts = opts or {}
    local data = run_json(ctx, { "files", "-j" })
    if type(data) ~= "table" then
        return {}
    end
    local limit = opts.limit or config.get().files.limit
    local out = {}
    for _, row in ipairs(data) do
        if #out >= limit then
            break
        end
        local path = row.path or ""
        if path ~= "" then
            out[#out + 1] = {
                id = path,
                kind = "file",
                name = util.basename(path),
                qualified_name = path,
                path = path,
                file = ctx.root:gsub("/$", "") .. "/" .. path,
                line = 1,
                language = row.language,
                node_count = row.nodeCount,
                size = row.size,
                source = M.name,
            }
        end
    end
    return out
end

--- ISO 时间串转毫秒时间戳
---@param iso string|nil
---@return number|nil
local function iso_to_ms(iso)
    if not iso then
        return nil
    end
    local y, mo, d, hh, mi, ss = tostring(iso):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return nil
    end
    local ok, ts = pcall(os.time, {
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(hh),
        min = tonumber(mi),
        sec = tonumber(ss),
    })
    if not ok or not ts then
        return nil
    end
    return ts * 1000
end

---@param ctx table
---@return table
function M.status(ctx)
    local data = run_json(ctx, { "status", "-j" }, { timeout = 15000 })
    if type(data) ~= "table" then
        return { root = ctx.root, db = ctx.db, source = M.name }
    end
    return {
        root = ctx.root,
        db = ctx.db,
        db_size = data.dbSizeBytes or ctx.db_size,
        nodes = data.nodeCount,
        edges = data.edgeCount,
        files_count = data.fileCount,
        kinds = data.nodesByKind,
        indexed_at = iso_to_ms(data.lastIndexed),
        pending = data.pendingChanges,
        index_version = data.version,
        index_state = data.index and data.index.state,
        source = M.name,
    }
end

---@param ctx table
---@param opts table|nil
---@param cb fun(ok: boolean, msg: string)|nil
function M.sync(ctx, opts, cb)
    local cfg = config.get()
    opts = opts or {}
    local cmd = { cfg.cli.bin, "sync" }
    if opts.quiet ~= false then
        cmd[#cmd + 1] = "-q"
    end
    cmd[#cmd + 1] = ctx.root

    local function done(res)
        local ok = res.code == 0
        local msg = vim.trim(ok and (res.stdout or "") or (res.stderr ~= "" and res.stderr or res.stdout or ""))
        if cb then
            cb(ok, msg)
        end
    end
    if opts.async == false then
        done(util.run_sync(cmd, { cwd = ctx.root, timeout = cfg.cli.timeout }))
    else
        util.run_async(cmd, { cwd = ctx.root, timeout = cfg.cli.timeout }, done)
    end
end

return M
