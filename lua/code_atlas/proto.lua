-- ============================================================================
-- code-atlas.nvim: 头文件原型兜底
--
-- codegraph 对 C/C++ **只给函数定义建节点**, 头文件里的原型
-- (`uint8_t Foo(int);`) 不进 nodes 表。于是"从 .c 跳到 .h 声明"在索引里
-- 根本找不到目标 —— 这里用 rg 在头文件里捞原型, 作为互跳的补充来源。
--
-- 只在"索引里没有声明"时才调用, 正常情况下不产生额外开销。
-- 判定一个行是原型的条件 (宁缺毋滥):
--   - 以 ; 结尾, 含 "name("
--   - 不含 "{" (不是函数体)
--   - 不是 typedef / #define / 注释
--   - "=" 出现在 "(" 之前的不算 (那是初始化/宏), 之后算默认参数, 放过
-- ============================================================================

local util = require("code_atlas.util")

local M = {}

---@param text string
---@param name string
---@return boolean
local function looks_like_prototype(text, name)
    local t = vim.trim(text)
    if t == "" or t:sub(-1) ~= ";" then
        return false
    end
    if t:find("{", 1, true) then
        return false
    end
    if t:find("^typedef") or t:find("^//") or t:find("^/%*") or t:find("^#%s*define") then
        return false
    end
    local par = t:find("(", 1, true)
    if not par then
        return false
    end
    -- name 后面紧跟 ( 才算原型 (允许中间空格)
    local before = t:sub(1, par - 1)
    if not before:find(name .. "%s*$") then
        return false
    end
    local eq = t:find("=", 1, true)
    if eq and eq < par then
        return false
    end
    return true
end

--- 在头文件里找 name 的原型
---@param ctx table
---@param name string
---@param opts table|nil
---@return table[]
function M.find(ctx, name, opts)
    opts = opts or {}
    if not ctx or not ctx.root or not name or name == "" then
        return {}
    end
    if not util.executable("rg") then
        return {}
    end

    local short = name:match("([%w_]+)$") or name
    local limit = opts.limit or 20

    local cmd = {
        "rg",
        "--no-heading",
        "--line-number",
        "--column",
        "--color",
        "never",
        "--with-filename",
        "--max-count",
        tostring(limit),
        "-g", "*.h",
        "-g", "*.hpp",
        "-g", "*.hh",
        "-g", "*.hxx",
        "-g", "*.inl",
        "-F",
        "-e", short,
        ctx.root,
    }

    local res = util.run_sync(cmd, { cwd = ctx.root, timeout = 8000 })
    if res.code ~= 0 and res.code ~= 1 then
        return {}
    end

    local cur_stem = vim.fn.expand("%:t:r") -- 当前文件名 (不含扩展名), 用来优先同名的 .h

-- 当前文件 include 了哪些头文件: 这是判断"哪个原型属于本模块"最可靠的信号
local included = {}
do
    local buf = vim.api.nvim_get_current_buf()
    local total = math.min(160, vim.api.nvim_buf_line_count(buf))
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, total, false)) do
        local inc = line:match('^%s*#%s*include%s*[<"]([^>"]+)[>"]')
        if inc then
            included[inc:match("([^/]+)$")] = true
        end
    end
end
    local items = {}
    local seen = {}

    for _, line in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
        local path, lno, _col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if path and text and looks_like_prototype(text, short) then
            local key = path .. ":" .. lno
            if not seen[key] then
                seen[key] = true
                local rel = util.relpath(ctx.root, path)
                items[#items + 1] = {
                    id = "proto:" .. key,
                    kind = "function",
                    name = short,
                    qualified_name = short,
                    path = rel,
                    file = path,
                    line = tonumber(lno) or 1,
                    start_line = tonumber(lno) or 1,
                    end_line = tonumber(lno) or 1,
                    is_decl = true,
                    is_proto = true,
                    source = "rg",
                    _stem_hit = (cur_stem ~= "" and rel:find("/" .. cur_stem .. "%.") ~= nil),
                }
            end
        end
    end

    -- 先收窄到"本文件 include 的头文件"; 没有就退到同名头文件; 还不行时
    -- 只有在唯一一份原型的情况下才敢用 (否则可能是别的模块的同名函数)
    local by_include = {}
    for _, item in ipairs(items) do
        if included[util.basename(item.path)] then
            by_include[#by_include + 1] = item
        end
    end
    if #by_include > 0 then
        items = by_include
    else
        local by_stem = {}
        for _, item in ipairs(items) do
            if item._stem_hit then
                by_stem[#by_stem + 1] = item
            end
        end
        if #by_stem > 0 then
            items = by_stem
        elseif #items > 1 then
            items = {}
        end
    end

    -- 同名的头文件优先 (Foo.c -> Foo.h), 其次路径短的
    table.sort(items, function(a, b)
        if a._stem_hit ~= b._stem_hit then
            return a._stem_hit
        end
        return #a.path < #b.path
    end)
    for _, item in ipairs(items) do
        item._stem_hit = nil
    end
    return items
end

return M
