-- 抓取 checkhealth 的调用 (headless 下不依赖 buffer)
local h = vim.health
local out = {}
local orig = { ok = h.ok, warn = h.warn, error = h.error, info = h.info, start = h.start }
h.ok = function(m) out[#out + 1] = "OK   " .. tostring(m) end
h.warn = function(m) out[#out + 1] = "WARN " .. tostring(m) end
h.error = function(m) out[#out + 1] = "ERR  " .. tostring(m) end
h.info = function(m) out[#out + 1] = "info " .. tostring(m) end
h.start = function(m) out[#out + 1] = "\n## " .. tostring(m) end

local ok, err = pcall(require("codegraph.health").check)
for k, v in pairs(orig) do h[k] = v end
print("check ok =", ok, err or "")
for _, l in ipairs(out) do print(l) end
