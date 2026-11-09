-- ============================================================================
-- 数据源: codebase-memory-mcp
--
-- 提供 codegraph 没有的能力:
--   - Macro  (所有宏, 含对象式宏)
--   - Field  (结构体/类成员, 带 parent_class / return_type)
--   - Function/Method/Class/Struct/... (作为 codegraph 查不到时的兜底)
--   - BM25 / 语义搜索 (search_graph)
--
-- 项目名通过 list_projects 的 root_path 最长前缀匹配得到.
-- 索引不存在/过期时 available() 返回 false, 上层自动退回 codegraph.
-- ============================================================================

local M = {
    name = "codebase_memory",
    label = "codebase-memory",
    priority = 120,
}

local config = require("code_atlas.config")
local util = require("code_atlas.util")
local mcp = require("code_atlas.mcp_cbm")

---@type table<string, string|false>
local project_cache = {}

local function cfg()
    return config.get().codebase_memory or {}
end

---@param s string
---@return string
local function escape_regex(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?%{%}%|\\])", "\\%1"))
end

---@return boolean
function M.ready()
    return mcp.ready()
end

--- 预热: 拉起 MCP + 解析项目名 (后台/首次 gd 时调用)
---@param ctx table
function M.warmup(ctx)
    if not ctx or cfg().enabled == false then
        return
    end
    local cmd = cfg().cmd or { "codebase-memory-mcp" }
    if not util.executable(cmd[1]) then
        return
    end
    mcp.start(function(ok)
        if ok then
            M.project(ctx)
        end
    end)
end

--- 当前项目在 codebase-memory 里的名字 (没有索引返回 nil)
---@param ctx table
---@return string|nil
function M.project(ctx)
    if not ctx or not ctx.root then
        return nil
    end
    local root = ctx.root:gsub("/$", "")
    local cached = project_cache[root]
    if cached ~= nil then
        return cached or nil
    end

    local data = mcp.call("list_projects", { limit = 1000, format = "json" }, 8000)
    if not data or type(data.projects) ~= "table" then
        project_cache[root] = false
        return nil
    end

    local best, best_len = nil, -1
    for _, p in ipairs(data.projects) do
        local pr = (p.root_path or ""):gsub("/$", "")
        if pr ~= "" then
            if pr == root then
                best, best_len = p, #pr
                break
            end
            if root:sub(1, #pr + 1) == pr .. "/" and #pr > best_len then
                best, best_len = p, #pr
            end
        end
    end

    project_cache[root] = best and best.name or false
    return best and best.name or nil
end

--- 清掉项目名缓存 (重新索引后用)
function M.refresh()
    project_cache = {}
end

---@param ctx table
---@return boolean
function M.available(ctx)
    if cfg().enabled == false then
        return false
    end
    local cmd = cfg().cmd or { "codebase-memory-mcp" }
    if not util.executable(cmd[1]) then
        return false
    end
    if not M.ready() then
        return false
    end
    return M.project(ctx) ~= nil
end

--- search_graph 的结果 -> item[] (groups 和 rows 两种形态都支持)
---@param data table
---@param ctx table
---@param project string|nil
---@return table[]
local function to_items(data, ctx, project)
    local items = {}
    local seen = {}

    local cols = {}
    for i, c in ipairs(data.cols or {}) do
        cols[c] = i
    end

    local function push(group, row, qn_prefix)
        local qn = group.qn or (cols.qn and row[cols.qn])
        local name = (cols.name and row[cols.name]) or (qn and qn:match("([^%.]+)$")) or nil
        local label = cols.label and row[cols.label]
        if not name or not label then
            return
        end

        local lines = (cols.lines and row[cols.lines]) or ""
        local start_line = tonumber(tostring(lines):match("^(%d+)")) or 1
        local end_line = tonumber(tostring(lines):match("%-(%d+)$")) or start_line
        local file = group.file or (cols.file and row[cols.file])
        if not file or file == "" or file == "{}" then
            return
        end

        local key = file .. ":" .. start_line .. ":" .. name
        if seen[key] then
            return
        end
        seen[key] = true

        -- 展示用的限定名去掉 "项目名." 前缀
        local display_qn = qn or name
        if project and display_qn:sub(1, #project + 1) == project .. "." then
            display_qn = display_qn:sub(#project + 2)
        end

        items[#items + 1] = {
            id = "cbm:" .. key,
            kind = tostring(label):lower(),
            name = name,
            qualified_name = display_qn,
            path = util.relpath(ctx.root, ctx.root .. "/" .. file),
            file = ctx.root .. "/" .. file,
            line = start_line,
            start_line = start_line,
            end_line = end_line,
            parent_class = cols.parent_class and row[cols.parent_class],
            return_type = cols.return_type and row[cols.return_type],
            signature = cols.signature and row[cols.signature],
            is_decl = label == "Macro" or label == "Field",
            source = M.name,
        }
    end

    if type(data.groups) == "table" then
        for _, g in ipairs(data.groups) do
            for _, row in ipairs(g.rows or {}) do
                push(g, row, g.qn_prefix)
            end
        end
    end
    if type(data.rows) == "table" then
        for _, row in ipairs(data.rows) do
            push({}, row, nil)
        end
    end

    -- 当前文件的排前面, 然后按路径/行号
    local cur = vim.api.nvim_buf_get_name(0)
    table.sort(items, function(a, b)
        local ac, bc = a.file == cur, b.file == cur
        if ac ~= bc then
            return ac
        end
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.line < b.line
    end)

    return items
end

--- 精确查一个符号 (name 完全相等; 数组字段 groupKeys[x] 走 query 兜底)
--- 精确查一个符号 (name 完全相等)
---@param ctx table
---@param name string
---@param opts table|nil  { labels = {"Field"} }
---@return table[]
function M.definition(ctx, name, opts)
    opts = opts or {}
    if not name or name == "" then
        return {}
    end
    local project = M.project(ctx)
    if not project then
        return {}
    end

    local args = {
        project = project,
        name_pattern = "^" .. escape_regex(name) .. "$",
        limit = opts.limit or 50,
        format = "json",
        fields = { "parent_class", "return_type", "signature" },
    }
    if opts.labels and #opts.labels == 1 then
        args.label = opts.labels[1]
    end

    local data = mcp.call("search_graph", args, cfg().timeout or 2500)
    local items = data and to_items(data, ctx, project) or {}
    if #items > 0 then
        return items
    end

    -- 数组字段在索引里叫 "groupKeys[kHSLedGroupMax]", 精确匹配不到;
    -- 再用 BM25 查一次, 只保留同名或以 name+"[" 开头的
    local fuzzy = {
        project = project,
        query = name,
        limit = 50,
        format = "json",
        fields = { "parent_class", "return_type", "signature" },
    }
    if opts.labels and #opts.labels == 1 then
        fuzzy.label = opts.labels[1]
    end
    data = mcp.call("search_graph", fuzzy, cfg().timeout or 2500)
    items = data and to_items(data, ctx, project) or {}
    local filtered = {}
    for _, it in ipairs(items) do
        if it.name == name or it.name:sub(1, #name + 1) == name .. "[" then
            filtered[#filtered + 1] = it
        end
    end
    return filtered
end

--- BM25 搜索 (codegraph 的 FTS 互补)
---@param ctx table
---@param prompt string
---@param opts table|nil
---@return table[]
function M.search(ctx, prompt, opts)
    opts = opts or {}
    if not prompt or prompt == "" then
        return {}
    end
    local project = M.project(ctx)
    if not project then
        return {}
    end
    local data = mcp.call("search_graph", {
        project = project,
        query = prompt,
        limit = opts.limit or cfg().search_limit or 100,
        format = "json",
        fields = { "parent_class", "return_type", "signature" },
    }, cfg().timeout or 2500)
    if not data then
        return {}
    end
    return to_items(data, ctx, project)
end

--- 索引状态
---@param ctx table
---@return table|nil
function M.status(ctx)
    local project = M.project(ctx)
    if not project then
        return nil
    end
    return mcp.call("index_status", { project = project }, cfg().timeout or 2500)
end

return M
