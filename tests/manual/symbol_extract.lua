local cg = require("code_atlas")
local cases = {
  { line = "int main() {", at = "main", want = "main" },
  { line = "    Foo::Bar(cb);", at = "Bar", want = "Bar" },
  { line = "    if (bar) {", at = "bar", want = "bar" },
  { line = "std::vector<int> v;", at = "vector", want = "vector" },
  { line = "    obj->method();", at = "method", want = "method" },
  { line = "    foo(a, b);", at = "foo", want = "foo" },
  { line = "#define MAX_SIZE 10", at = "MAX_SIZE", want = "MAX_SIZE" },
  { line = "    ::globalFn();", at = "globalFn", want = "globalFn" },
  { line = "    ns::Type t;", at = "Type", want = "Type" },
}
local pass, fail = 0, 0
for _, c in ipairs(cases) do
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { c.line })
  local col = assert(c.line:find(c.at, 1, true))
  vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
  local sym = cg.symbol()
  local ok = sym.name == c.want
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(("%-40s -> name=%-12s qualified=%-28s %s"):format(c.line, sym.name, sym.qualified, ok and "OK" or ("FAIL want " .. c.want)))
end
print(("pass=%d fail=%d"):format(pass, fail))
if fail > 0 then vim.cmd("cq") end
