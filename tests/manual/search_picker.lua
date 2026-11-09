-- 搜索 picker 实测: 打开 -> 等待 -> 模拟输入 -> 看结果数变化
local cg = require("code_atlas")
local telescope_state = require("telescope.state")

local function status()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    local ok, st = pcall(telescope_state.get_status, b)
    if ok and st and st.picker and st.picker.manager then
      return st
    end
  end
end

local t0 = vim.uv.hrtime()
cg.search({ query = "msg" })
vim.wait(500)
print("open ms =", (vim.uv.hrtime() - t0) / 1e6)

local st = status()
print("initial:", st and st.picker.manager:num_results())

if st then
  local pb = st.prompt_bufnr
  for _, q in ipairs({ "con", "connect", "zzz_nothing" }) do
    local t = vim.uv.hrtime()
    vim.api.nvim_buf_set_lines(pb, 0, -1, false, { q })
    vim.wait(400)
    print(("prompt %-12s results=%-5s %.1fms"):format(
      q, tostring(st.picker.manager:num_results()), (vim.uv.hrtime() - t) / 1e6))
  end
end
