-- 多级 .codegraph: 本层索引里没有的符号, gd 应该继续去上级索引找
-- 用法:
--   cd <子模块/子项目目录>
--   CG_SYM=<只存在于上级索引的符号> nvim --headless -u tests/minimal_init.lua \
--       -c "luafile tests/manual/multi_index.lua" -c "qa!"
local cg = require("code_atlas")
local project = require("code_atlas.project")

local sym = vim.env.CG_SYM
if not sym or sym == "" then
    print("需要 CG_SYM=<只存在于上级索引的符号>")
    return
end

local ctx = project.context()
print("主索引: " .. tostring(ctx and ctx.root))
for _, c in ipairs(project.find_all()) do
    print("  - " .. c.root)
end

cg.definition({ name = sym })
local p = vim.api.nvim_win_get_cursor(0)
print(("gd -> %s:%d:%d"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p"), p[1], p[2]))
