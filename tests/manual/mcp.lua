-- MCP 数据源实测: 强制走 codegraph_mcp (需要机器上有 codegraph, 项目已建索引)
-- 用法:
--   cd <项目根>
--   CG_SYMBOL=<符号> nvim --headless -u tests/minimal_init.lua \
--       -c "luafile tests/manual/mcp.lua" -c "qa!"
local cg = require("code_atlas")
cg.config.setup({ source = "codegraph_mcp" })

local project = require("code_atlas.project")
local source = require("code_atlas.source")
local ctx = project.context()
local a = source.resolve(ctx)
print("adapter:", a and a.name)
if not a then
    return
end

local sym = vim.env.CG_SYMBOL or "main"

local t0 = vim.uv.hrtime()
local st = a.status(ctx)
print(("status: %s nodes, %s files, %.0fms"):format(
    tostring(st.nodes), tostring(st.files_count), (vim.uv.hrtime() - t0) / 1e6))

t0 = vim.uv.hrtime()
local items = a.search(ctx, sym, { limit = 10 })
print(("search(%s): %d 条, %.0fms"):format(sym, #items, (vim.uv.hrtime() - t0) / 1e6))
for i = 1, math.min(3, #items) do
    print(("  [%s] %s %s:%d"):format(items[i].kind, items[i].name, items[i].path, items[i].line))
end

local defs = a.definition(ctx, sym, {})
print(("definition(%s): %d 条"):format(sym, #defs))
local files = a.files(ctx, { limit = 5 })
print("files:", #files)
