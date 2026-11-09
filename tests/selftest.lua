-- ============================================================================
-- 自测: nvim --headless -u tests/minimal_init.lua -c "luafile tests/selftest.lua" -c "qa!"
-- 在某个建过索引的项目目录里跑 (默认用当前目录), 或者设 CG_ROOT 指定
-- ============================================================================

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print("FAIL: " .. msg)
    end
end

local function info(msg)
    print("  · " .. msg)
end

local function section(name)
    print("\n== " .. name .. " ==")
end

local config = require("codegraph.config")
local project = require("codegraph.project")
local source = require("codegraph.source")

local cfg = config.get()
local root = vim.env.CG_ROOT or vim.fn.getcwd()

-- ---------------------------------------------------------------------------
section("配置")
-- ---------------------------------------------------------------------------
check(cfg.keymaps.search == "<Leader>gr", "默认搜索键位 <Leader>gr")
check(cfg.keymaps.definition == "<Leader>gd", "默认定义键位 <Leader>gd")
check(cfg.watcher.mode == "auto", "默认 watcher auto")
check(#cfg.sources > 0, "sources 非空")
check(cfg.sources[1] == "codegraph", "首选数据源是 sqlite 直读")

local custom = config.setup({ search = { limit = 7 }, keymaps = { search = "<Leader>zz" } })
check(custom.search.limit == 7, "用户配置覆盖 limit")
check(custom.search.exclude_kinds[1] == "import", "list 配置不被下标合并破坏")
config.setup({}) -- 还原

-- ---------------------------------------------------------------------------
section("项目定位: " .. root)
-- ---------------------------------------------------------------------------
local ctx = project.find(root)
check(ctx ~= nil, "找到 .codegraph/codegraph.db")
if ctx then
    info("root = " .. ctx.root)
    info("db   = " .. ctx.db .. " (" .. tostring(ctx.db_size) .. "B)")
    check(vim.uv.fs_stat(ctx.db) ~= nil, "db 文件存在")

    -- 从子目录也要能找到 (向上递归)
    local sub = ctx.root .. "/.codegraph"
    if vim.uv.fs_stat(sub) then
        local from_sub = project.find(sub)
        check(from_sub ~= nil and from_sub.root == ctx.root, "从子目录向上找到同一个根")
    end

    -- 家目录那种只有 state 没有 db 的 .codegraph 要被跳过
    local fake = "/tmp/codegraph-selftest/nested/deep"
    vim.fn.mkdir(fake, "p")
    vim.fn.mkdir("/tmp/codegraph-selftest/.codegraph", "p")
    vim.fn.writefile({}, "/tmp/codegraph-selftest/.codegraph/daemon.pid")
    local none = project.find(fake)
    check(none == nil, "空壳 .codegraph (无 db) 不算索引, 继续向上")
end

-- ---------------------------------------------------------------------------
section("数据源解析")
-- ---------------------------------------------------------------------------
local adapter = source.resolve(ctx)
check(adapter ~= nil, "解析出可用数据源")
if adapter then
    info("adapter = " .. tostring(adapter.label or adapter.name))
    check(adapter.name == "codegraph", "默认用 sqlite 直读")

    local st = adapter.status(ctx)
    check(type(st) == "table", "status 返回 table")
    check((st.nodes or 0) > 0, "status 有节点数: " .. tostring(st.nodes))
    info(("nodes=%s edges=%s files=%s"):format(
        tostring(st.nodes), tostring(st.edges), tostring(st.files_count)))

    -- 搜索
    local items = adapter.search(ctx, "co", { limit = 10 })
    check(#items > 0, "搜索 'co' 有结果")
    if items[1] then
        info(("首条: [%s] %s %s:%d"):format(items[1].kind, items[1].name, items[1].path, items[1].line))
        check(items[1].file and items[1].file:sub(1, 1) == "/", "item.file 是绝对路径")
        check(items[1].path and items[1].path:sub(1, 1) ~= "/", "item.path 是相对路径")
    end

    -- 空 prompt: 默认 "none" 不查; 配成 "recent" 时返回最近符号
    local recent = adapter.search(ctx, "", { limit = 5 })
    if cfg.search.empty_prompt == "recent" then
        check(#recent > 0, "空 prompt 返回最近符号")
    else
        check(#recent == 0, "空 prompt (none) 不返回数据")
    end

    -- 调用点: 搜索结果里应同时有"定义"和"调用位置"
    local usage_items = {}
    for _, it in ipairs(items) do
        if it.kind == "usage" then
            usage_items[#usage_items + 1] = it
        end
    end
    if cfg.search.include_usages ~= false then
        check(#usage_items > 0, "搜索包含调用点 (usage) 条目")
        if usage_items[1] then
            local u = usage_items[1]
            check(u.caller ~= nil and u.caller ~= "", "调用点带调用者名字")
            check((u.line or 0) > 0, "调用点带行号")
            check(u.path ~= nil and u.path ~= "", "调用点带路径")
            info(("调用点: %s <- %s @ %s:%d"):format(u.name, u.caller, u.path, u.line))
        end
    end
    cfg.search.include_usages = false
    local no_usage = adapter.search(ctx, "co", { limit = 20 })
    local has_usage = false
    for _, it in ipairs(no_usage) do
        if it.kind == "usage" then
            has_usage = true
        end
    end
    check(not has_usage, "include_usages=false 时不返回调用点")
    cfg.search.include_usages = true

    -- 定义: 拿搜索到的第一个符号名再查
    if items[1] then
        local defs = adapter.definition(ctx, items[1].name, {})
        check(#defs > 0, "definition('" .. items[1].name .. "') 有结果")
        if defs[1] then
            info(("定义: %s %s:%d decl=%s"):format(
                defs[1].name, defs[1].path, defs[1].line, tostring(defs[1].is_decl)))
        end
    end

    -- 引用 / 调用
    local refs = adapter.references(ctx, items[1] and items[1].name or "main", {})
    info("references = " .. tostring(#refs))
    local callers = adapter.callers(ctx, "main", {})
    info("callers(main) = " .. tostring(#callers))
    local callees = adapter.callees(ctx, "main", {})
    info("callees(main) = " .. tostring(#callees))

    -- 文件
    local files = adapter.files(ctx, { limit = 5 })
    check(#files > 0, "files 有结果")
end

-- ---------------------------------------------------------------------------
section("跳转定位")
-- ---------------------------------------------------------------------------
local jump_item
do
    local probe = adapter and adapter.search(ctx, "Connect", { limit = 5 }) or {}
    for _, it in ipairs(probe) do
        if it.kind ~= "usage" then
            jump_item = it
            break
        end
    end
end
if jump_item then
    local picker_mod = require("codegraph.picker")
    check(picker_mod.jump(jump_item), "jump() 成功")
    local cword = vim.fn.expand("<cword>")
    local short = (jump_item.name or ""):match("([%w_]+)$") or ""
    check(short ~= "" and cword:sub(-#short) == short,
        ("跳转后光标在符号上 (<cword>=%s, 期望含 %s)"):format(cword, short))
    info(("跳转定位: %s:%d 光标列 %d"):format(jump_item.path, jump_item.line, vim.api.nvim_win_get_cursor(0)[2]))
end

-- ---------------------------------------------------------------------------
section("光标符号提取")
-- ---------------------------------------------------------------------------
local symbol_cases = {
    { line = "int main() {", at = "main", want = "main" },
    { line = "    Foo::Bar(cb);", at = "Bar", want = "Bar" },
    { line = "    if (bar) {", at = "bar", want = "bar" },
    { line = "std::vector<int> v;", at = "vector", want = "vector" },
    { line = "    obj->method();", at = "method", want = "method" },
    { line = "#define MAX_SIZE 10", at = "MAX_SIZE", want = "MAX_SIZE" },
    { line = "    ::globalFn();", at = "globalFn", want = "globalFn" },
    { line = "    obj->method();", at = "method", want = "method", base = "obj", member = "method", call = true },
    { line = "    p->len = 0;", at = "len", want = "len", base = "p", member = "len", call = false },
    { line = "    cfg.count = 0;", at = "count", want = "count", base = "cfg", member = "count", call = false },
    { line = "    pFoo->Init();", at = "Init", want = "Init", base = "pFoo", member = "Init", call = true },
}
local cg_mod = require("codegraph")
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
for _, case in ipairs(symbol_cases) do
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { case.line })
    local col = case.line:find(case.at, 1, true)
    vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
    local sym = cg_mod.symbol()
    check(sym.name == case.want, ("%s -> name=%s (want %s)"):format(case.line, sym.name, case.want))
    if case.base then
        check(sym.base == case.base, ("%s -> base=%s (want %s)"):format(case.line, tostring(sym.base), case.base))
    end
    if case.member then
        check(sym.member == case.member,
            ("%s -> member=%s (want %s)"):format(case.line, tostring(sym.member), case.member))
    end
    if case.call ~= nil then
        check(sym.is_call == case.call,
            ("%s -> is_call=%s (want %s)"):format(case.line, tostring(sym.is_call), tostring(case.call)))
    end
end

-- ---------------------------------------------------------------------------
section("表结构探测 / 数据源回退")
-- ---------------------------------------------------------------------------
local sqlite_adapter = source.get("codegraph")
if sqlite_adapter then
    local schema_ok, reason = sqlite_adapter.schema_check(ctx)
    check(schema_ok == true, "直读 schema 检查通过: " .. tostring(reason))
    sqlite_adapter.broken = "simulated"
    check(source.resolve(ctx).name == "codegraph_mcp", "直读失效时自动退到 MCP")
    sqlite_adapter.broken = nil
end

-- ---------------------------------------------------------------------------
section("MCP 文本解析 (离线单测)")
-- ---------------------------------------------------------------------------
local mcp_src = source.get("codegraph_mcp")
if mcp_src then
    local search_text = table.concat({
        "**Search Results (2 found)**",
        "",
        "**Foo** (method)",
        "src/foo.c:17",
        "`void Foo::bar()`",
        "",
        "**FooState** (enum_member)",
        "src/foo.h:29",
        "",
    }, "\n")
    local parsed = mcp_src.parse_search(ctx, search_text)
    check(#parsed == 2, "parse_search 条数")
    check(parsed[1] and parsed[1].name == "Foo", "parse_search 名字不带多余的 *")
    check(parsed[1] and parsed[1].line == 17, "parse_search 行号")
    check(parsed[2] and parsed[2].path == "src/foo.h", "parse_search 路径")

    local rel_text = table.concat({
        "**Callers of Foo (2 found)**",
        "",
        "- Handler (method) - src/foo.c:42",
        "- Worker (method) - src/worker.c:69",
    }, "\n")
    local rel = mcp_src.parse_relations(ctx, rel_text)
    check(#rel == 2, "parse_relations 条数")
    check(rel[1] and rel[1].name == "Handler", "parse_relations 名字")

    local files_text = "- src/main.cpp (cpp, 7 symbols)\n- src/util.h (cpp, 0 symbols)"
    local files = mcp_src.parse_files(ctx, files_text)
    check(#files == 2, "parse_files 条数")
    check(files[1] and files[1].node_count == 7, "parse_files 符号数")

    local status_text = table.concat({
        "**CodeGraph Status**",
        "",
        "**Files indexed:** 54",
        "**Total nodes:** 595",
        "**Total edges:** 1048",
        "**Changes since index:** 1 added, 2 modified, 0 removed",
    }, "\n")
    local st = mcp_src.parse_status(status_text)
    check(st.nodes == 595 and st.files_count == 54, "parse_status 计数")
    check(st.pending and st.pending.modified == 2, "parse_status pending")
else
    check(false, "codegraph_mcp 适配器已注册")
end

-- ---------------------------------------------------------------------------
section("UI 注册")
-- ---------------------------------------------------------------------------
check(vim.fn.maparg("<Leader>gr", "n") ~= "", "<Leader>gr 已映射")
check(vim.fn.maparg("<Leader>gd", "n") ~= "", "<Leader>gd 已映射")
check(vim.fn.maparg("<Leader>gR", "n") ~= "", "<Leader>gR 已映射")
check(vim.fn.exists(":CodeGraph") == 2, ":CodeGraph 命令存在")

local hl = vim.api.nvim_get_hl(0, { name = "CodeGraphfunction", link = false })
check(hl ~= nil, "高亮组已注册")

-- telescope 能懒加载
local ok_t, telescope = pcall(require, "telescope")
check(ok_t and telescope ~= nil, "telescope 可以 require")
if ok_t then
    local ok_ext, err = pcall(require, "telescope._extensions.codegraph")
    check(ok_ext, "telescope 扩展可以加载: " .. tostring(err))
end

-- ---------------------------------------------------------------------------
section("状态栏 / 状态")
-- ---------------------------------------------------------------------------
local cg = require("codegraph")
local sl = cg.statusline()
info("statusline = '" .. sl .. "'")
check(sl ~= "", "statusline 有内容")

local info_tbl = cg.status_info(ctx)
check(type(info_tbl) == "table", "status_info 返回 table")
check(info_tbl.watcher ~= nil, "status_info 带 watcher 状态")

-- ---------------------------------------------------------------------------
print(("\n结果: %d 通过, %d 失败"):format(passed, failed))
if failed > 0 then
    print("失败项:")
    for _, m in ipairs(failures) do
        print("  - " .. m)
    end
    vim.cmd("cq") -- 非零退出码
end
