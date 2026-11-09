-- 搜索结果里应同时有定义和"调用点"
local ctx = require("code_atlas.project").context()
local a = require("code_atlas.source").resolve(ctx)
local items = a.search(ctx, "Connect", {})
local by_kind = {}
for _, it in ipairs(items) do by_kind[it.kind] = (by_kind[it.kind] or 0) + 1 end
print("total:", #items)
for k, v in pairs(by_kind) do print(("  %-10s %d"):format(k, v)) end
for _, it in ipairs(items) do
  if it.kind == "usage" then
    print(("  usage -> %s 被 %s (%s) 用在 %s:%d [%s]"):format(it.name, it.caller, it.caller_kind, it.path, it.line, it.edge_kind))
    break
  end
end
