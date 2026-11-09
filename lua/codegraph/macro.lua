-- codegraph 只给"函数式宏" (#define F(x) ...) 建 constant 节点,
-- 对象式宏 (#define F ...) 完全不进索引; gd 用 rg 在项目里补找定义行。
local M = {}

local config = require("codegraph.config")
local util = require("codegraph.util")

local GLOBS = {
    "*.h", "*.hpp", "*.hh", "*.hxx", "*.inc",
    "*.c", "*.cc", "*.cpp", "*.cxx", "*.m", "*.mm",
}

--- 在项目里找 "#define <name>" 的定义行
---@param ctx table 项目上下文
---@param name string 宏名 (纯标识符)
---@return table[]
function M.find(ctx, name)
    if not ctx or not name or name == "" or not util.executable("rg") then
        return {}
    end

    local pattern = "^\\s*#\\s*define\\s+" .. name .. "\\b"
    local cmd = {
        "rg", "--no-heading", "--line-number", "--column", "--with-filename",
        "--color=never", "--max-count", "20", "--no-messages",
    }
    for _, glob in ipairs(GLOBS) do
        cmd[#cmd + 1] = "-g"
        cmd[#cmd + 1] = glob
    end
    cmd[#cmd + 1] = "-e"
    cmd[#cmd + 1] = pattern
    cmd[#cmd + 1] = ctx.root

    local ok, res = pcall(function()
        return vim.system(cmd, { text = true, timeout = 8000 }):wait()
    end)
    if not ok or not res or res.code ~= 0 then
        return {}
    end

    local items, seen = {}, {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
        local file, lnum, _col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if file then
            local abs = file
            if abs:sub(1, 1) ~= "/" then
                abs = ctx.root:gsub("/$", "") .. "/" .. abs
            end
            local key = abs .. ":" .. lnum
            if not seen[key] then
                seen[key] = true
                items[#items + 1] = {
                    id = "macro:" .. key,
                    kind = "macro",
                    name = name,
                    path = util.relpath(ctx.root, abs),
                    file = abs,
                    line = tonumber(lnum),
                    start_line = tonumber(lnum),
                    signature = vim.trim(text),
                    is_decl = true,
                    is_macro = true,
                }
            end
        end
    end

    -- 头文件优先, 其次路径短的
    local header_exts = config.get().definition.header_exts
    table.sort(items, function(a, b)
        local ah = util.is_header(a.file, header_exts)
        local bh = util.is_header(b.file, header_exts)
        if ah ~= bh then
            return ah
        end
        return #a.path < #b.path
    end)
    return items
end

return M
