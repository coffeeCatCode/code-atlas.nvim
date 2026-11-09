-- 表结构探测 + 数据源回退
local project = require("code_atlas.project")
local source = require("code_atlas.source")
local ctx = project.context()
local sqlite = source.get("codegraph")
print("ctx:", ctx and ctx.root)
print("schema rows:", select(2, pcall(function() return sqlite.query(ctx, "PRAGMA table_info(nodes);") end)) ~= nil)
local ok, reason = sqlite.schema_check(ctx)
print("schema_check:", ok, reason or "")
print("available:", sqlite.available(ctx))
print("resolved:", (source.resolve(ctx) or {}).name)
-- 模拟 schema 漂移
sqlite.broken = "simulated: no such column"
print("after broken, resolved:", (source.resolve(ctx) or {}).name)
sqlite.broken = nil
