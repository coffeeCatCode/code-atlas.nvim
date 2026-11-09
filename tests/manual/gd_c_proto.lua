-- C 头文件原型兜底: codegraph 不索引 C 函数原型, gd 仍应能从 .c 跳到 .h 的声明
-- 用法:
--   cd <项目根>
--   CG_SRC=src/foo.c CG_SYM=Foo nvim --headless -u tests/minimal_init.lua \
--       -c "luafile tests/manual/gd_c_proto.lua" -c "qa!"
local cg = require("code_atlas")

local src = vim.env.CG_SRC
local sym = vim.env.CG_SYM
if not src or src == "" or not sym or sym == "" then
    print("需要 CG_SRC=<实现文件> CG_SYM=<符号名>")
    return
end

local function put_on(name)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        local s = line:find(name, 1, true)
        if s then
            vim.api.nvim_win_set_cursor(0, { i, s - 1 })
            return
        end
    end
end

local function where()
    local p = vim.api.nvim_win_get_cursor(0)
    return ("%s:%d:%d"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), p[1], p[2])
end

vim.cmd("edit " .. vim.fn.fnameescape(src))
put_on(sym)
print("起点:      " .. where())
cg.definition()
print("第一次 gd: " .. where())
cg.definition()
print("第二次 gd: " .. where())
