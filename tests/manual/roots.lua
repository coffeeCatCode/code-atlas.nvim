-- 多项目探活: 在任意子目录里看能不能找到索引
local project = require("code_atlas.project")
local ctx = project.find(vim.fn.getcwd())
if not ctx then
  print("cwd:", vim.fn.getcwd(), "-> no index")
  return
end
local a = require("code_atlas.source").resolve(ctx)
local st = a and a.status and a.status(ctx) or {}
print(("%-52s -> %-52s nodes=%s"):format(vim.fn.getcwd(), ctx.root, tostring(st.nodes)))
