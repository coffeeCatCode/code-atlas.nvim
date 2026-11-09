local ctx = require("code_atlas.project").context()
local a = require("code_atlas.source").resolve(ctx)
local function bench(label, fn, n)
  local t = vim.uv.hrtime()
  local last
  for _ = 1, n do last = fn() end
  print(("%-26s %6.1fms/次 (%d 条)"):format(label, (vim.uv.hrtime() - t) / 1e6 / n, #(last or {})))
end
bench("search 带调用点", function() return a.search(ctx, "message", {}) end, 10)
bench("search 空", function() return a.search(ctx, "", {}) end, 5)
local cfg = require("code_atlas.config").get()
cfg.search.include_usages = false
bench("search 不带调用点", function() return a.search(ctx, "message", {}) end, 10)
cfg.search.include_usages = true
