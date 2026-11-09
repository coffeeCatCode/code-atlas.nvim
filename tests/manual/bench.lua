local ctx = require("code_atlas.project").context()
local a = require("code_atlas.source").resolve(ctx)
local function bench(label, fn, n)
  local t = vim.uv.hrtime()
  local last
  for _ = 1, n do last = fn() end
  print(("%-22s %6.1fms/次 (%s 条)"):format(label, (vim.uv.hrtime() - t) / 1e6 / n, #(last or {})))
end
bench("search con", function() return a.search(ctx, "con", {}) end, 10)
bench("search connect", function() return a.search(ctx, "connect", {}) end, 10)
bench("search 空", function() return a.search(ctx, "", {}) end, 5)
bench("definition main", function() return a.definition(ctx, "main", {}) end, 10)
bench("status", function() return { a.status(ctx) } end, 5)
