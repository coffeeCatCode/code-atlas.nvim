-- ============================================================================
-- code-atlas.nvim: 可选数据源 —— ripgrep 文本搜索
--
-- 默认**不启用** (config.sources 里没有它): 没有 .codegraph 的项目按需求
-- 就是"不使用"。想在没有索引的项目里也能用 <Leader>gr, 把 "ripgrep" 加进
-- config.sources 即可 —— 它是纯文本匹配, 没有符号语义, 条目类型是 "match"。
-- ============================================================================

local util = require("code_atlas.util")

local M = {
    name = "ripgrep",
    label = "ripgrep (文本匹配)",
    priority = 10,
    supports = { references = false, callers = false, callees = false },
}

---@param ctx table|nil
---@return boolean
function M.available(_)
    return util.executable("rg")
end

---@param ctx table|nil
---@return string
local function root_of(ctx)
    if ctx and ctx.root then
        return ctx.root
    end
    return vim.fs.normalize(vim.fn.getcwd())
end

--- 解析 rg --json 的匹配行
---@param ctx table|nil
---@param stdout string
---@return table[]
local function parse_json_matches(ctx, stdout)
    local root = root_of(ctx)
    local out = {}
    for _, line in ipairs(vim.split(stdout, "\n", { trimempty = true })) do
        local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
        if ok and type(ev) == "table" and ev.type == "match" then
            local data = ev.data or {}
            local path = data.path and data.path.text or ""
            local line_no = data.line_number or 1
            local text = (data.lines and data.lines.text or ""):gsub("[\r\n]+$", "")
            if path ~= "" then
                out[#out + 1] = {
                    id = path .. ":" .. line_no,
                    kind = "match",
                    name = util.basename(path) .. ":" .. line_no,
                    qualified_name = text,
                    path = util.relpath(root, path),
                    file = path,
                    line = line_no,
                    start_line = line_no,
                    end_line = line_no,
                    text = text,
                    source = M.name,
                }
            end
        end
    end
    return out
end

---@param ctx table|nil
---@param patterns string[]
---@param limit integer
---@return table[]
local function rg(ctx, patterns, limit)
    local root = root_of(ctx)
    local cmd = { "rg", "--json", "--smart-case", "--no-messages", "--max-count", tostring(limit) }
    for _, p in ipairs(patterns) do
        cmd[#cmd + 1] = "-e"
        cmd[#cmd + 1] = p
    end
    cmd[#cmd + 1] = root

    local res = util.run_sync(cmd, { cwd = root, timeout = 8000 })
    if res.code ~= 0 and res.code ~= 1 then
        return {}
    end
    return parse_json_matches(ctx, res.stdout)
end

---@param ctx table|nil
---@param prompt string|nil
---@param opts table|nil
---@return table[]
function M.search(ctx, prompt, opts)
    opts = opts or {}
    if not prompt or prompt == "" then
        return {}
    end
    return rg(ctx, { vim.pesc(prompt) }, opts.limit or 200)
end

---@param ctx table|nil
---@param name string
---@param opts table|nil
---@return table[]
function M.definition(ctx, name, opts)
    opts = opts or {}
    if not name or name == "" then
        return {}
    end
    local n = vim.pesc(name)
    -- 只看长得像定义/声明的行
    local patterns = {
        "\\b(class|struct|union|enum|namespace|interface)\\s+" .. n .. "\\b",
        "\\b" .. n .. "\\s*[\\(<]",
        "^\\s*#\\s*define\\s+" .. n .. "\\b",
    }
    return rg(ctx, patterns, opts.limit or 60)
end

function M.references()
    return {}
end

function M.callers()
    return {}
end

function M.callees()
    return {}
end

---@param ctx table|nil
---@param opts table|nil
---@return table[]
function M.files(ctx, opts)
    opts = opts or {}
    local root = root_of(ctx)
    local res = util.run_sync({ "rg", "--files", root }, { cwd = root, timeout = 8000 })
    if res.code ~= 0 then
        return {}
    end
    local out = {}
    for _, path in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
        out[#out + 1] = {
            id = path,
            kind = "file",
            name = util.basename(path),
            qualified_name = util.relpath(root, path),
            path = util.relpath(root, path),
            file = path,
            line = 1,
            source = M.name,
        }
        if #out >= (opts.limit or 3000) then
            break
        end
    end
    return out
end

return M
