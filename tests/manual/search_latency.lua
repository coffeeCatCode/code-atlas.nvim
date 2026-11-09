-- 搜索首屏耗时 (含父索引合并)
local cg = require("codegraph")
local telescope_state = require("telescope.state")

local function st_of()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    local ok, st = pcall(telescope_state.get_status, b)
    if ok and st and st.picker and st.picker.manager then return st end
  end
end

local query = vim.env.CG_QUERY or "Connect"
local t0 = vim.uv.hrtime()
cg.search({ query = query })
vim.wait(3000, function()
  local st = st_of()
  return st and st.picker.manager and st.picker.manager:num_results() > 0
end, 10)
local ms = (vim.uv.hrtime() - t0) / 1e6
local st = st_of()
print(("query=%-12s results=%-4d 首屏=%.0fms"):format(
  query, st and st.picker.manager:num_results() or -1, ms))
