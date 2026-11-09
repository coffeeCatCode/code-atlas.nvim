-- ============================================================================
-- codegraph.nvim: 兼容数据源 —— 走 codegraph 自己的 MCP 工具接口
--
-- 定位: 直读 SQLite (source/codegraph.lua) 是默认快路径, 但它绑定了表结构;
--       一旦 codegraph 升级改了 nodes/edges 的列, 直读就失效。这时自动退到
--       这个数据源: 常驻 `codegraph serve --mcp`, 用它的 codegraph_search /
--       codegraph_callers / codegraph_status 等工具拿数据, 数据库怎么改都
--       跟这边无关 (由 codegraph 自己负责)。
--
-- 代价 (实测, 详见 README "MCP 实测"):
--   - 首次调用要开项目, 4~6s; 热态 p50 0.7ms, 但偶发几秒的抖动
--   - 返回的是给 LLM 看的 markdown 文本, 需要解析; 拿不到 qualified_name
--   - 结果上限 100 条 (工具的硬限制)
-- 所以 picker 用异步 finder 调它, 卡住也不冻结 UI。
-- ============================================================================

local config = require("codegraph.config")
local mcp = require("codegraph.mcp")
local util = require("codegraph.util")

local M = {
    name = "codegraph_mcp",
    label = "codegraph (MCP)",
    priority = 75,
    -- MCP 没有 references 工具 (只有 callers/callees/impact)
    supports = { references = false },
}

---@param ctx table|nil
---@return boolean
function M.available(ctx)
    local cfg = config.get()
    return cfg.mcp.enabled ~= false and ctx ~= nil and util.executable(cfg.cli.bin)
end

---@param ctx table
---@return table
local function client(ctx)
    return mcp.client(ctx.root)
end

---@param ctx table
---@param path string
---@return string
local function abs(ctx, path)
    if path:sub(1, 1) == "/" then
        return path
    end
    return ctx.root:gsub("/$", "") .. "/" .. path
end

-- ---------------------------------------------------------------------------
-- markdown 解析 (工具返回的都是这种给人看的文本)
-- ---------------------------------------------------------------------------

-- **Connect** (method)
-- src/foo.c:17
---@param ctx table
---@param text string|nil
---@return table[]
function M.parse_search(ctx, text)
    local items = {}
    if not text or text == "" then
        return items
    end
    local lines = vim.split(text, "\n", { plain = true })
    local i = 1
    while i <= #lines do
        local name, kind = lines[i]:match("^%*%*(.-)%*%* %(([%w_]+)%)%s*$")
        if name and name ~= "" then
            local j = i + 1
            while j <= #lines and vim.trim(lines[j]) == "" do
                j = j + 1
            end
            local loc = lines[j] or ""
            local path, line = loc:match("^(.-):(%d+)%s*$")
            if path and path ~= "" then
                items[#items + 1] = {
                    id = path .. ":" .. tostring(line) .. ":" .. name,
                    kind = kind,
                    name = name,
                    qualified_name = name,
                    path = path,
                    file = abs(ctx, path),
                    line = tonumber(line) or 1,
                    start_line = tonumber(line) or 1,
                    end_line = tonumber(line) or 1,
                    is_decl = util.is_header(path, config.get().definition.header_exts),
                    source = M.name,
                }
                i = j + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return items
end

-- - HandleFirstLine (method) - src/proxy/HttpConnectHandler.cpp:42
---@param ctx table
---@param text string|nil
---@return table[]
function M.parse_relations(ctx, text)
    local items = {}
    for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
        local name, kind, path, line_no = line:match("^%- (.-) %(([%w_]+)%) %- (.-):(%d+)%s*$")
        if name and path then
            items[#items + 1] = {
                id = path .. ":" .. tostring(line_no) .. ":" .. name,
                kind = kind,
                name = name,
                qualified_name = name,
                path = path,
                file = abs(ctx, path),
                line = tonumber(line_no) or 1,
                start_line = tonumber(line_no) or 1,
                end_line = tonumber(line_no) or 1,
                source = M.name,
            }
        end
    end
    return items
end

-- - src/api/Foo.cpp (cpp, 7 symbols)
---@param ctx table
---@param text string|nil
---@return table[]
function M.parse_files(ctx, text)
    local items = {}
    local limit = config.get().files.limit or 1000
    for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
        local path, lang, count = line:match("^%- (.-) %(([%w_]+),%s*(%d+) symbols?%)%s*$")
        if path and path ~= "" then
            items[#items + 1] = {
                id = path,
                kind = "file",
                name = util.basename(path),
                qualified_name = path,
                path = path,
                file = abs(ctx, path),
                line = 1,
                language = lang,
                node_count = tonumber(count) or 0,
                source = M.name,
            }
            if #items >= limit then
                break
            end
        end
    end
    return items
end

-- **Files indexed:** 54    **Total nodes:** 595    **Changes since index:** 0 added, ...
---@param text string|nil
---@return table
function M.parse_status(text)
    local st = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local key, value = line:match("^%*%*(.-):%*%*%s*(.-)%s*$")
        if key and value then
            if key == "Files indexed" then
                st.files_count = tonumber(value)
            elseif key == "Total nodes" then
                st.nodes = tonumber(value)
            elseif key == "Total edges" then
                st.edges = tonumber(value)
            elseif key == "Latest file indexed" then
                st.indexed_at_raw = value
            elseif key == "Changes since index" then
                local added, modified, removed = value:match("(%d+) added, (%d+) modified, (%d+) removed")
                if added then
                    st.pending = {
                        added = tonumber(added),
                        modified = tonumber(modified),
                        removed = tonumber(removed),
                    }
                end
            end
        end
    end
    return st
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------

--- 搜索 (同步; 只给测试/命令用, picker 走 search_async)
---@param ctx table
---@param prompt string|nil
---@param opts table|nil
---@return table[]
function M.search(ctx, prompt, opts)
    opts = opts or {}
    if not prompt or prompt == "" then
        return {}
    end
    local limit = math.min(opts.limit or 100, 100)
    local text, _, err = client(ctx):call_tool_sync("codegraph_search", { query = prompt, limit = limit })
    if not text then
        util.notify("MCP 查询失败: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end
    return M.parse_search(ctx, text)
end

--- 异步搜索 (picker 用): 不阻塞 UI, 慢了也只是结果晚点出来
---@param ctx table
---@param prompt string|nil
---@param opts table|nil
---@param cb fun(items: table[])
function M.search_async(ctx, prompt, opts, cb)
    opts = opts or {}
    if not prompt or prompt == "" then
        cb({})
        return
    end
    local limit = math.min(opts.limit or 100, 100)
    client(ctx):call_tool("codegraph_search", { query = prompt, limit = limit }, function(text, err)
        if not text then
            util.notify("MCP 查询失败: " .. tostring(err), vim.log.levels.WARN)
            cb({})
            return
        end
        cb(M.parse_search(ctx, text))
    end)
end

--- 定义: 用 search 拿候选再按名字过滤 (MCP 没有 definition 工具)
---@param ctx table
---@param name string
---@param opts table|nil
---@return table[]
function M.definition(ctx, name, opts)
    opts = opts or {}
    if not name or name == "" then
        return {}
    end
    local cfg = config.get()
    local short = name:match("([%w_]+)$") or name
    local q = short:lower()

    local text, _, err = client(ctx):call_tool_sync("codegraph_search", { query = short, limit = 100 })
    if not text then
        util.notify("MCP 查询失败: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end

    local allowed = {}
    for _, k in ipairs(opts.kinds or cfg.definition.kinds) do
        allowed[k] = true
    end

    local items = {}
    for _, item in ipairs(M.parse_search(ctx, text)) do
        if (item.name or ""):lower() == q and allowed[item.kind or ""] then
            items[#items + 1] = item
        end
    end
    return items
end

---@param ctx table
---@param name string
---@param opts table|nil
---@param tool string
---@return table[]
local function relations(ctx, name, opts, tool)
    opts = opts or {}
    if not name or name == "" then
        return {}
    end
    local limit = math.min(opts.limit or 50, 100)
    local text, _, err = client(ctx):call_tool_sync(tool, { symbol = name, limit = limit })
    if not text then
        util.notify("MCP 查询失败: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end
    return M.parse_relations(ctx, text)
end

function M.callers(ctx, name, opts)
    return relations(ctx, name, opts, "codegraph_callers")
end

function M.callees(ctx, name, opts)
    return relations(ctx, name, opts, "codegraph_callees")
end

--- MCP 没有 references
function M.references()
    return {}
end

---@param ctx table
---@param opts table|nil
---@return table[]
function M.files(ctx, opts)
    opts = opts or {}
    local text, _, err = client(ctx):call_tool_sync("codegraph_files", {
        format = "flat",
        includeMetadata = true,
    })
    if not text then
        util.notify("MCP 查询失败: " .. tostring(err), vim.log.levels.WARN)
        return {}
    end
    return M.parse_files(ctx, text)
end

---@param ctx table
---@return table
function M.status(ctx)
    -- 冷启动时 status 会顺带扫一遍工作区, 给宽一点
    local text, _, err = client(ctx):call_tool_sync("codegraph_status", {}, 20000)
    if not text then
        util.notify("MCP status 失败: " .. tostring(err), vim.log.levels.WARN)
        return { root = ctx.root, db = ctx.db, source = M.name }
    end
    local st = M.parse_status(text)
    st.root = ctx.root
    st.db = ctx.db
    st.source = M.name
    st.schema = "mcp"
    local cfg = config.get()
    return st
end

-- ---------------------------------------------------------------------------
-- 写操作还是交给 CLI (MCP 只暴露读工具)
-- ---------------------------------------------------------------------------

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
