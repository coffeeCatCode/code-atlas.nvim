-- ============================================================================
-- code-atlas.nvim: 入口
--
-- 把 codegraph(给 AI 用的代码图谱, 项目根下的 .codegraph/codegraph.db)接到
-- nvim 里:
--   <Leader>gr  搜索符号, 结果用 telescope 展示
--   <Leader>gd  跳转定义或声明, 多个时列表选择
-- 其余键位/命令见 README 与 :h code-atlas
-- ============================================================================

local config = require("code_atlas.config")
local project = require("code_atlas.project")
local util = require("code_atlas.util")
local picker = require("code_atlas.picker")

local M = {}

M.config = config
M.picker = picker

-- ---------------------------------------------------------------------------
-- 高亮
-- ---------------------------------------------------------------------------

local KIND_LINK = {
    ["function"] = "Function",
    method = "Function",
    constructor = "Function",
    class = "Type",
    struct = "Type",
    union = "Type",
    interface = "Type",
    trait = "Type",
    enum = "Type",
    enum_member = "Constant",
    type_alias = "Type",
    typedef = "Type",
    namespace = "Include",
    module = "Include",
    variable = "Identifier",
    constant = "Constant",
    property = "Identifier",
    field = "Identifier",
    macro = "Constant",
    import = "Comment",
    usage = "Comment",
    file = "Directory",
    match = "String",
    unknown = "Comment",
}

function M.setup_highlights()
    for kind, link in pairs(KIND_LINK) do
        vim.api.nvim_set_hl(0, "CodeAtlas" .. kind, { link = link, default = true })
    end
end

-- ---------------------------------------------------------------------------
-- 当前符号
-- ---------------------------------------------------------------------------

-- 光标停在类型/关键字上时 (比如跳转后停在行首, <cWORD> 是 void/int),
-- 退而求其次: 找本行(以及后两行)第一个 "(" 前面的限定名
local TYPE_WORDS = {
    ["void"] = true, ["int"] = true, ["char"] = true, ["short"] = true, ["long"] = true,
    ["float"] = true, ["double"] = true, ["bool"] = true, ["auto"] = true, ["signed"] = true,
    ["unsigned"] = true, ["const"] = true, ["static"] = true, ["virtual"] = true,
    ["volatile"] = true, ["register"] = true, ["restrict"] = true,
    ["inline"] = true, ["explicit"] = true, ["extern"] = true, ["friend"] = true,
    ["struct"] = true, ["class"] = true, ["enum"] = true, ["union"] = true,
    ["namespace"] = true, ["template"] = true, ["typename"] = true, ["typedef"] = true,
    ["using"] = true, ["return"] = true, ["if"] = true, ["else"] = true, ["for"] = true,
    ["while"] = true, ["switch"] = true, ["case"] = true, ["break"] = true, ["continue"] = true,
    ["new"] = true, ["delete"] = true, ["public"] = true, ["private"] = true, ["protected"] = true,
}

--- 找一行里第一个 "xxx(" 的限定名 (跳过类型/关键字)
---@param line string
---@return string|nil
local function name_before_paren(line)
    for seg in line:gmatch("([%w_:~]+)%s*%(") do
        local short = seg:match("([%w_]+)$")
        if short and not TYPE_WORDS[short] then
            return seg
        end
    end
    return nil
end

--- 按扩展名归一化语言家族 (判断"同名符号"是不是同一类工程里的)
local EXT_LANG = {
    c = "c", h = "c",
    cc = "cxx", cpp = "cxx", cxx = "cxx", hpp = "cxx", hh = "cxx", hxx = "cxx",
    inl = "cxx", ipp = "cxx", tpp = "cxx", m = "c", mm = "cxx",
    py = "py", lua = "lua", go = "go", rs = "rs",
    js = "js", ts = "js", jsx = "js", tsx = "js", mjs = "js", cjs = "js",
    java = "java", kt = "kt", rb = "rb", php = "php", cs = "cs", swift = "swift",
}

---@param file string|nil
---@return string|nil
local function lang_of(file)
    local ext = (file or ""):match("%.([%w]+)$")
    return ext and EXT_LANG[ext:lower()] or nil
end

--- 结果里有没有和当前文件同族语言 (或语言未知) 的条目
---@param items table[]
---@param cur_file string
---@return boolean
local function has_related(items, cur_file)
    local cur_lang = lang_of(cur_file)
    if not cur_lang then
        return true
    end
    for _, it in ipairs(items) do
        local lang = lang_of(it.file)
        if lang == nil or lang == cur_lang then
            return true
        end
    end
    return false
end

--- 光标在标识符上, 后面是不是跟 '(' (函数调用/定义)
---@return boolean
local function cursor_followed_by_paren()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local rest = line:sub(col + 1)
    local word = rest:match("^[%w_]+") or ""
    local tail = rest:sub(#word + 1):gsub("^%s+", "")
    return tail:sub(1, 1) == "("
end

--- 从当前 buffer 的声明里推断变量的类型:
---   Foo *p = ...      -> "Foo"
---   const Foo *p;     -> "Foo"
---   Foo cfg;          -> "Foo"
---@param name string
---@return string|nil
local function infer_type(name)
    if not name or name == "" then
        return nil
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local esc = vim.pesc(name)
    local patterns = {
        "struct%s+([%w_]+)%s*%*+%s*" .. esc .. "%f[%W]",
        "union%s+([%w_]+)%s*%*+%s*" .. esc .. "%f[%W]",
        "([%w_]+)%s*%*+%s*" .. esc .. "%f[%W]",
        "struct%s+([%w_]+)%s+" .. esc .. "%f[%W]",
        "union%s+([%w_]+)%s+" .. esc .. "%f[%W]",
        "([%w_]+)%s+" .. esc .. "%f[%W]",
    }
    for _, pat in ipairs(patterns) do
        for _, line in ipairs(lines) do
            local ty = line:match(pat)
            if ty and ty ~= name and not TYPE_WORDS[ty] then
                return ty
            end
        end
    end
    return nil
end

--- cursor 下的符号: <cWORD> 拿去清理成 "限定名" 和 "短名"
--- 例: "ns::Foo(" -> { qualified = "ns::Foo", name = "Foo" }
---     "main()" / "(bar)" / "baz);" / "std::vector<int>" 也都要能收拾干净
---@return table { name, qualified }
--- 光标所在/紧挨着的标识符 (不把整行非空白串当成一个词)
---@return table|nil
local function symbol_at_cursor()
    local line = vim.api.nvim_get_current_line()
    local len = #line
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-based byte

    local function is_word(i)
        return line:sub(i, i):match("[%w_]") ~= nil
    end

    local s, e
    if col <= len and is_word(col) then
        s, e = col, col
    elseif col > 1 and is_word(col - 1) then
        s, e = col - 1, col - 1
    else
        return nil
    end
    while s > 1 and is_word(s - 1) do
        s = s - 1
    end
    while e < len and is_word(e + 1) do
        e = e + 1
    end

    local name = line:sub(s, e)

    -- 向左收 :: 限定名 (Foo::Bar)
    local qualified = name
    local qs = s
    while qs > 1 do
        local left = line:sub(1, qs - 1):gsub("%s+$", "")
        local sep = left:match("::%s*$")
        if not sep then
            break
        end
        local head = left:sub(1, #left - #sep)
        local ps, pe = head:find("([%w_]+)$")
        if not ps then
            break
        end
        qualified = head:sub(ps, pe) .. "::" .. qualified
        qs = ps
    end
    qualified = qualified:gsub("^::", "")

    -- 成员访问: 前面紧挨着 -> 或 . (只认光标这个标识符)
    local before = line:sub(1, qs - 1):gsub("%s+$", "")
    local base, member
    local prefix
    if before:sub(-2) == "->" then
        prefix = before:sub(1, -3)
    elseif before:sub(-1) == "." then
        prefix = before:sub(1, -2)
    end
    if prefix then
        prefix = prefix:gsub("%s+$", "")
        local ps, pe = prefix:find("([%w_]+)$")
        if ps then
            base = prefix:sub(ps, pe)
            member = name
        end
    end

    local tail = line:sub(e + 1):gsub("^%s+", "")
    local is_call = tail:sub(1, 1) == "("

    return {
        name = name,
        qualified = qualified,
        base = base,
        member = member,
        is_call = is_call,
    }
end

function M.symbol()
    local sym = symbol_at_cursor()

    if not sym then
        -- 光标停在标点上: 退回 <cWORD>, 只取末段标识符
        local word = vim.fn.expand("<cWORD>") or ""
        local w = word:gsub("%s+", ""):gsub("^[%(%[%{<\"'&%*]+", "")
        w = w:match("^([^(<]*)") or w
        w = w:gsub("[%)%]%}%(%[%{%)%]\"',;:%.]+$", "")
        local short = w:match("([%w_]+)$") or ""
        if short == "" then
            return { name = "", qualified = "" }
        end
        sym = { name = short, qualified = w, is_call = false }
    end

    -- 光标在 void/int/static 这类词上: 换成本行的函数名再试
    if sym.name == "" or TYPE_WORDS[sym.name] then
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local last = vim.api.nvim_buf_line_count(0)
        for i = row, math.min(row + 2, last) do
            local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1] or ""
            local seg = name_before_paren(line)
            if seg then
                sym.name = seg:match("([%w_]+)$") or sym.name
                sym.qualified = seg
                sym.base, sym.member, sym.is_call = nil, nil, false
                break
            end
        end
    end

    return sym
end

-- ---------------------------------------------------------------------------
-- 视图
-- ---------------------------------------------------------------------------

--- 解析当前项目的 ctx + 数据源, 失败时给出可操作的提示
--- 只要项目上下文 (状态/同步这类不需要数据源也能说清楚)
---@return table|nil
local function ctx_or_warn()
    local ctx = project.context()
    if not ctx then
        util.notify(
            "没找到 .codegraph/codegraph.db (已从 " .. project.start_dir() .. " 逐级向上找), 这个项目不使用 codegraph",
            vim.log.levels.WARN
        )
    end
    return ctx
end

---@return table|nil ctx
---@return table|nil adapter
local function resolve_or_warn()
    local ctx = project.context()
    local adapter = require("code_atlas.source").resolve(ctx)
    if not adapter then
        if ctx == nil then
            util.notify(
                "没找到 .codegraph/codegraph.db (已从 "
                    .. project.start_dir()
                    .. " 逐级向上找), 这个项目不使用 codegraph",
                vim.log.levels.WARN
            )
        else
            local cfg = config.get()
            local loaded = {}
            for name in pairs(require("code_atlas.source").registry) do
                loaded[#loaded + 1] = name
            end
            table.sort(loaded)
            util.notify(
                ("没有可用数据源: sqlite3=%s, codegraph=%s, 已加载=%s"):format(
                    util.executable(cfg.sqlite.bin) and "有" or "无",
                    util.executable(cfg.cli.bin) and "有" or "无",
                    #loaded > 0 and table.concat(loaded, ",") or "(空)"
                ),
                vim.log.levels.WARN
            )
        end
        return nil, nil
    end
    return ctx, adapter
end

-- ---------------------------------------------------------------------------
-- 对外动作
-- ---------------------------------------------------------------------------

--- 搜索符号, 结果显示在 telescope
---@param opts table|nil { query, debounce, prompt_title }
---@return table|nil picker
function M.search(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return nil
    end

    -- 默认把光标下的词填进 prompt: 打开就看到"我正在看的这个符号"的匹配,
    -- 而不是一堆跟当前上下文无关的"最近符号"
    if (not opts.query or opts.query == "") and config.get().search.prefill ~= "none" then
        local sym = M.symbol()
        if sym.name and sym.name ~= "" then
            opts.query = sym.name
        end
    end
    return picker.open("search", vim.tbl_extend("force", {
        ctx = ctx,
        adapter = adapter,
    }, opts))
end

--- 跳转定义/声明: 唯一结果直接跳, 多个结果开 picker
---@param opts table|nil { name, jump_single }
--- 把上级 .codegraph 里查到的定义并进 items (多级索引)
---@param ctx table 本层索引
---@param items table[]
---@param sym table { name, qualified }
---@param opts table
---@return table[] items
local function merge_parent_definitions(ctx, items, sym, opts)
    local cfg = config.get()
    if cfg.definition.search_parents == false then
        return items
    end

    local source = require("code_atlas.source")
    local function key_of(it)
        return (it.file or "") .. ":" .. tostring(it.line or 0) .. ":" .. tostring(it.name or "")
    end

    local seen = {}
    for _, it in ipairs(items) do
        seen[key_of(it)] = true
    end

    local used = 0
    local max_parents = cfg.definition.max_parents or 3
    for _, pctx in ipairs(project.find_all(project.start_dir())) do
        if pctx.root ~= ctx.root and used < max_parents then
            used = used + 1
            local pa = source.resolve(pctx)
            if pa and pa.definition then
                local more = pa.definition(pctx, sym.qualified, opts) or {}
                if #more == 0 and sym.qualified ~= sym.name then
                    more = pa.definition(pctx, sym.name, opts) or {}
                end
                for _, it in ipairs(more) do
                    local key = key_of(it)
                    if not seen[key] then
                        seen[key] = true
                        it.ctx_root = pctx.root
                        it.path = util.display_path(ctx.root, pctx.root, it.file, it.path)
                        items[#items + 1] = it
                    end
                end
            end
        end
    end
    return items
end

---@param items table[]
---@param want_decl boolean
---@return table[]
local function pick_wanted(items, want_decl)
    local out = {}
    for _, item in ipairs(items) do
        if (item.is_decl == true) == want_decl then
            out[#out + 1] = item
        end
    end
    return out
end

--- 把跳转交回 coc (clangd 认识结构体成员/局部变量)
---@param reason string|nil
---@return boolean
local function feed_coc_definition(reason)
    local cfg = config.get()
    if cfg.definition.fallback ~= "coc" or vim.fn.exists("*CocAction") ~= 1 then
        return false
    end
    if reason then
        util.notify(reason .. ", 交给 coc", vim.log.levels.INFO)
    end
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Plug>(coc-definition)", true, false, true),
        "m",
        false
    )
    return true
end

--- codebase-memory 适配器 (装了且有当前项目索引才返回)
---@param ctx table
---@return table|nil
local function cbm_adapter(ctx)
    local cfg = config.get()
    if not cfg.codebase_memory or cfg.codebase_memory.enabled == false then
        return nil
    end
    local ok, source = pcall(require, "code_atlas.source")
    if not ok then
        return nil
    end
    source.load()
    local adapter = source.get("codebase_memory")
    if adapter and adapter.available(ctx) then
        return adapter
    end
    return nil
end

--- 一个就跳, 多个弹列表
---@param items table[]
---@param ctx table
---@param adapter table
---@param title string
local function show_items(items, ctx, adapter, title, prefer_same_file)
    if #items == 0 then
        return
    end
    if #items == 1 then
        picker.jump(items[1])
        return
    end
    if prefer_same_file then
        local cur = vim.api.nvim_buf_get_name(0)
        if items[1].file == cur then
            picker.jump(items[1])
            return
        end
    end
    picker.open("definition", {
        ctx = ctx,
        adapter = adapter,
        name = title,
        items = items,
    })
end

function M.definition(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end

    local sym = opts.name and { name = opts.name, qualified = opts.name } or M.symbol()
    if not sym.name or sym.name == "" then
        util.notify("光标下没有符号", vim.log.levels.WARN)
        return
    end

    local cfg = config.get()

    -- 成员访问 (p->field / obj.field, 非函数调用):
    -- codegraph 只索引 struct 类型, 不索引成员; 先按 base 的声明推断类型,
    -- 直接跳到结构体定义, 而不是拿成员名去撞同名的函数
    -- C 没有成员函数, p->x 一定是结构体字段 (x 可能撞上同名函数),
    -- 一律按 base 的类型跳 struct; C++ 的 p->Method() 是真方法, 照旧按名字查
    local c_family = { c = true, objc = true }
    local cxx_family = { cpp = true, objcpp = true, cuda = true }
    local ft = vim.bo.filetype
    local member_mode = sym.member
        and (c_family[ft] == true or (cxx_family[ft] == true and not sym.is_call))
    if not opts.name and member_mode then
        -- 结构体成员: codegraph 不索引, codebase-memory 有 Field 节点
        local cbm = cbm_adapter(ctx)
        if cbm then
            local fields = cbm.definition(ctx, sym.member, { labels = { "Field" }, limit = 20 }) or {}
            if #fields > 0 then
                local want = infer_type(sym.base)
                if want and #fields > 1 then
                    local filtered = {}
                    for _, it in ipairs(fields) do
                        local pc = it.parent_class or ""
                        if pc == want or pc:sub(-(#want + 1)) == "." .. want then
                            filtered[#filtered + 1] = it
                        end
                    end
                    if #filtered > 0 then
                        fields = filtered
                    end
                end
                show_items(fields, ctx, adapter, sym.member, true)
                return
            end
        end

        local type_name = infer_type(sym.base)
        local type_items = {}
        if type_name then
            type_items = adapter.definition(ctx, type_name, {
                kinds = cfg.definition.type_kinds,
                limit = 20,
            }) or {}
        end
        if #type_items > 0 then
            if #type_items == 1 then
                picker.jump(type_items[1])
            else
                picker.open("definition", {
                    ctx = ctx,
                    adapter = adapter,
                    name = type_name,
                    items = type_items,
                })
            end
            return
        end
        if feed_coc_definition(("codegraph 不索引结构体成员 %s"):format(sym.member)) then
            return
        end
        util.notify(
            ("没找到 %s 的结构体定义 (成员本身不在图谱里)"):format(sym.base or sym.member),
            vim.log.levels.WARN
        )
        return
    end

    -- C++ 的 p->Method(): 方法名可能和别的类/自由函数重名;
    -- 能推出 base 类型时只认 Type::Method, 推不出来才退回按名字查
    if not opts.name and sym.member and sym.is_call and cxx_family[ft] then
        local type_name = infer_type(sym.base)
        if type_name then
            local prefix = type_name .. "::"
            local all = adapter.definition(ctx, sym.member, {
                kinds = { "method", "function" },
                limit = 50,
            }) or {}
            local typed = {}
            for _, it in ipairs(all) do
                local q = it.qualified_name or ""
                if q:sub(1, #prefix) == prefix then
                    typed[#typed + 1] = it
                end
            end
            if #typed > 0 then
                if #typed == 1 then
                    picker.jump(typed[1])
                else
                    picker.open("definition", {
                        ctx = ctx,
                        adapter = adapter,
                        name = sym.member,
                        items = typed,
                    })
                end
                return
            end
            if feed_coc_definition(("codegraph 里没有 %s::%s"):format(type_name, sym.member)) then
                return
            end
            util.notify(
                ("%s::%s 不在图谱里 (只有同名符号), 装 coc/clangd 才能精确跳"):format(
                    type_name, sym.member),
                vim.log.levels.WARN
            )
            return
        end
    end

    local items = adapter.definition(ctx, sym.qualified, opts) or {}
    if #items == 0 and sym.qualified ~= sym.name then
        items = adapter.definition(ctx, sym.name, opts) or {}
    end

    -- 限定名查询会漏掉"声明" (同一个函数的声明往往带不同的类/命名空间前缀,
    -- 比如实现是 impl::Foo, 声明却是 api::Foo)。
    -- 做声明/实现互跳时必须再按短名补一次, 否则永远只能看到实现。
    if cfg.definition.toggle and sym.qualified ~= sym.name then
        local more = adapter.definition(ctx, sym.name, opts) or {}
        if #more > 0 then
            local seen = {}
            for _, item in ipairs(items) do
                seen[item.id] = true
            end
            for _, item in ipairs(more) do
                if not seen[item.id] then
                    seen[item.id] = true
                    items[#items + 1] = item
                end
            end
        end
    end

    -- 名字撞上别的语言里的同名符号 (C 工程里的 base 撞 Python 的 base):
    -- 按 buffer 里的声明推断类型, 走结构体定义, 而不是跳去 Python
    local cur_file = vim.api.nvim_buf_get_name(0)
    if #items > 0 and not sym.member and not cursor_followed_by_paren()
        and not has_related(items, cur_file) then
        local type_name = infer_type(sym.name)
        if type_name then
            local type_items = adapter.definition(ctx, type_name, {
                kinds = cfg.definition.type_kinds,
                limit = 20,
            }) or {}
            if #type_items > 0 then
                if #type_items == 1 then
                    picker.jump(type_items[1])
                else
                    picker.open("definition", {
                        ctx = ctx,
                        adapter = adapter,
                        name = type_name,
                        items = type_items,
                    })
                end
                return
            end
        end
    end

    -- 本层索引里没有: 再看上级 .codegraph (多级索引)
    local parents_merged = false
    if #items == 0 then
        items = merge_parent_definitions(ctx, items, sym, opts)
        parents_merged = true
    end

    if #items == 0 then
        local cbm = cbm_adapter(ctx)

        -- 对象式宏: codebase-memory 有 Macro 节点 (codegraph 完全不索引)
        if cbm and not sym.member then
            local macros = cbm.definition(ctx, sym.name, { labels = { "Macro" }, limit = 20 }) or {}
            if #macros > 0 then
                show_items(macros, ctx, adapter, sym.name, true)
                return
            end
        end

        -- 普通变量/参数: 按 buffer 里的声明推断类型, 跳到 struct/class 定义
        local type_name = (not sym.member) and infer_type(sym.name) or nil
        if type_name then
            local type_items = adapter.definition(ctx, type_name, {
                kinds = cfg.definition.type_kinds,
                limit = 20,
            }) or {}
            if #type_items > 0 then
                if #type_items == 1 then
                    picker.jump(type_items[1])
                else
                    picker.open("definition", {
                        ctx = ctx,
                        adapter = adapter,
                        name = type_name,
                        items = type_items,
                    })
                end
                return
            end
        end

        -- 函数/类/枚举: codegraph 没有时用 codebase-memory 兜底
        if cbm and not sym.member then
            local hits = cbm.definition(ctx, sym.name, { limit = 20 }) or {}
            if #hits > 0 then
                show_items(hits, ctx, adapter, sym.name)
                return
            end
        end

        -- 对象式宏 (#define NAME ...) 不进图谱: 用 rg 补找定义行
        if not sym.member and cfg.definition.macro_fallback ~= false then
            local ok, macro = pcall(require, "code_atlas.macro")
            if ok then
                local defs = macro.find(ctx, sym.name) or {}
                if #defs > 0 then
                    if #defs == 1 then
                        picker.jump(defs[1])
                    else
                        picker.open("definition", {
                            ctx = ctx,
                            adapter = adapter,
                            name = sym.name,
                            items = defs,
                        })
                    end
                    return
                end
            end
        end

        -- 各级索引都没有: 按配置交给 coc/lsp 兜底
        if feed_coc_definition(("codegraph 里没有 %s"):format(sym.name)) then
            return
        end
        util.notify(
            ("没有找到定义: %s (索引可能过期, 试 :CodeAtlas sync)"):format(sym.name),
            vim.log.levels.WARN
        )
        return
    end

    local jump_single = opts.jump_single
    if jump_single == nil then
        jump_single = cfg.definition.jump_single
    end

    -- 声明/实现互跳: 在 .c/.cpp 里按 gd 找的是头文件里的声明, 反过来同理。
    -- 只要"想要的那一类"恰好只有一个, 就直接跳过去, 不再弹列表。
    local pool = items
    local cur_file = vim.api.nvim_buf_get_name(0)
    if cfg.definition.toggle and cur_file ~= "" then
        local cur_is_header = util.is_header(cur_file, cfg.definition.header_exts)
        local want_decl = not cur_is_header
        local wanted = pick_wanted(items, want_decl)

        -- 本层没有"想要的那一类"(比如本模块索引里只有实现): 先去上级索引找
        if #wanted == 0 and not parents_merged then
            local before = #items
            items = merge_parent_definitions(ctx, items, sym, opts)
            parents_merged = true
            if #items > before then
                wanted = pick_wanted(items, want_decl)
            end
        end

        -- codegraph 不给 C/C++ 头文件里的函数原型建节点, 索引里"没有声明"时
        -- 在头文件里用 rg 捞一下原型, 否则从 .c 按 gd 永远只能停在 .c
        if #wanted == 0 and not cur_is_header then
            local ok, proto = pcall(require, "code_atlas.proto")
            if ok then
                local decls = proto.find(ctx, sym.name, { limit = 20 }) or {}
                if #decls > 0 then
                    local seen = {}
                    for _, it in ipairs(items) do
                        seen[it.id] = true
                    end
                    for _, p in ipairs(decls) do
                        if not seen[p.id] then
                            seen[p.id] = true
                            items[#items + 1] = p
                            wanted[#wanted + 1] = p
                        end
                    end
                end
            end
        end

        if #wanted == 1 then
            if jump_single then
                picker.jump(wanted[1])
                return
            end
            pool = wanted
        elseif #wanted > 1 then
            pool = wanted
        end
        -- #wanted == 0: 没有声明/实现对手, 退回全部候选
    end

    if #pool == 1 and jump_single then
        picker.jump(pool[1])
        return
    end

    picker.open("definition", {
        ctx = ctx,
        adapter = adapter,
        name = sym.name,
        items = pool,
    })
end

---@param kind string
---@param opts table
---@return string|nil name
local function relation_name(kind, opts)
    if opts and opts.name and opts.name ~= "" then
        return opts.name
    end
    local sym = M.symbol()
    if not sym.name or sym.name == "" then
        util.notify("光标下没有符号", vim.log.levels.WARN)
        return nil
    end
    return sym.name
end

--- 谁引用了它
---@param opts table|nil
function M.references(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end
    local name = relation_name("references", opts)
    if not name then
        return
    end
    picker.open("references", vim.tbl_extend("force", { ctx = ctx, adapter = adapter, name = name }, opts))
end

--- 谁调用了它
---@param opts table|nil
function M.callers(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end
    local name = relation_name("callers", opts)
    if not name then
        return
    end
    picker.open("callers", vim.tbl_extend("force", { ctx = ctx, adapter = adapter, name = name }, opts))
end

--- 它调用了谁
---@param opts table|nil
function M.callees(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end
    local name = relation_name("callees", opts)
    if not name then
        return
    end
    picker.open("callees", vim.tbl_extend("force", { ctx = ctx, adapter = adapter, name = name }, opts))
end

--- 索引里的文件
---@param opts table|nil
function M.files(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end
    picker.open("files", vim.tbl_extend("force", { ctx = ctx, adapter = adapter }, opts))
end

-- ---------------------------------------------------------------------------
-- 状态 / 同步
-- ---------------------------------------------------------------------------

---@param ctx table|nil
---@return table
function M.status_info(ctx)
    ctx = ctx or project.context()
    local out = {
        ctx = ctx,
        watcher = require("code_atlas.watcher").status(ctx),
    }
    if ctx then
        local adapter = require("code_atlas.source").resolve(ctx)
        out.adapter = adapter and (adapter.label or adapter.name) or nil
        if adapter then
            local ok, st = pcall(adapter.status, ctx)
            out.index = ok and st or nil
        end
    end
    return out
end

--- :CodeAtlas status / <Leader>gs
function M.status()
    local ctx = ctx_or_warn()
    if not ctx then
        return
    end
    local info = M.status_info(ctx)
    local st = info.index or {}
    local w = info.watcher or {}

    local lines = {
        { "codegraph", "Title" },
        { ("  项目      %s"):format(ctx.root) },
        { ("  数据源    %s%s"):format(
            info.adapter or "无",
            (st.schema_ok == false) and ("  (直读失效: " .. tostring(st.schema_reason) .. ")") or ""
        ) },
        { ("  索引库    %s (%s)"):format(ctx.db, util.fmt_size(st.db_size or ctx.db_size)) },
        { ("  符号/关系 %s / %s, 文件 %s"):format(
            util.fmt_count(st.nodes),
            util.fmt_count(st.edges),
            util.fmt_count(st.files_count)
        ) },
        { ("  最近索引  %s"):format(util.fmt_time(st.indexed_at or ctx.db_mtime)) },
        { ("  后台守护  %s"):format(tostring(w.daemon)) },
        { ("  同步模式  %s (生效: %s)"):format(tostring(w.mode), tostring(w.effective)) },
    }

    if st.pending then
        local pending = (st.pending.added or 0) + (st.pending.modified or 0) + (st.pending.removed or 0)
        lines[#lines + 1] = {
            ("  待同步    %d 个文件%s"):format(pending, pending > 0 and " (:CodeAtlas sync)" or ""),
            pending > 0 and "DiagnosticWarn" or "DiagnosticOk",
        }
    end
    if st.index_version then
        lines[#lines + 1] = { ("  索引版本  %s"):format(tostring(st.index_version)) }
    end

    vim.api.nvim_echo(lines, true, {})
end

--- 立即同步索引
---@param opts table|nil
function M.sync(opts)
    opts = opts or {}
    local ctx = ctx_or_warn()
    if not ctx then
        return
    end
    require("code_atlas.watcher").sync_now(ctx, { quiet = false })
end

--- 全量重建索引 (codegraph index)
---@param opts table|nil
function M.reindex(opts)
    opts = opts or {}
    local ctx, adapter = resolve_or_warn()
    if not adapter then
        return
    end
    if not adapter.reindex then
        util.notify("当前数据源不支持重建", vim.log.levels.WARN)
        return
    end
    if not opts.force then
        local ok = vim.fn.confirm(("重建 %s 的索引?"):format(ctx.root), "&Yes\n&No", 2)
        if ok ~= 1 then
            return
        end
    end
    util.notify("开始重建索引: " .. ctx.root)
    adapter.reindex(ctx, { force = opts.force }, function(ok, msg)
        if ok then
            util.notify("索引重建完成")
            project.clear()
        else
            util.notify("索引重建失败: " .. tostring(msg), vim.log.levels.ERROR)
        end
    end)
end

--- 管理后台守护进程
---@param action string|nil "status"|"start"|"stop"
function M.daemon(action)
    action = action or "status"
    local ctx = ctx_or_warn()
    if not ctx then
        return
    end
    local watcher = require("code_atlas.watcher")
    if action == "start" then
        local ok = watcher.start_daemon(ctx)
        util.notify(ok and "已请求拉起 codegraph 后台" or "拉起失败 (检查 codegraph 命令)", ok and vim.log.levels.INFO or vim.log.levels.WARN)
    elseif action == "stop" then
        local ok = watcher.stop_daemon(ctx)
        util.notify(ok and "已停止 codegraph 后台" or "没有在运行的后台", vim.log.levels.INFO)
    else
        local running, pid = watcher.daemon_state(ctx)
        util.notify(
            running and ("后台运行中 (pid " .. tostring(pid) .. ")") or "后台未运行",
            vim.log.levels.INFO
        )
    end
end

--- 指定/清除项目根
---@param path string|nil
function M.root(path)
    project.set_override(path)
    local ctx = project.context()
    if ctx then
        util.notify("codegraph 项目根: " .. ctx.root)
    else
        util.notify("这个目录(及上层)没有 .codegraph/codegraph.db", vim.log.levels.WARN)
    end
end

-- ---------------------------------------------------------------------------
-- 状态栏组件
-- ---------------------------------------------------------------------------

local st_cache = { t = 0, text = "", root = "" }

--- lualine 组件用: 有索引显示 cg:N
---@return string
function M.statusline()
    if not config.get().statusline then
        return ""
    end

    local ctx = project.context()
    local root = ctx and ctx.root or ""
    local now = (vim.uv or vim.loop).now()
    -- 30s 缓存, 但换项目立刻失效
    if st_cache.root == root and now - st_cache.t < 30000 then
        return st_cache.text
    end
    st_cache.t = now
    st_cache.root = root

    if not ctx then
        st_cache.text = ""
        return ""
    end
    local text = "cg"
    local adapter = require("code_atlas.source").resolve(ctx)
    if adapter and adapter.status then
        local ok, st = pcall(adapter.status, ctx)
        if ok and type(st) == "table" and st.nodes then
            text = "atlas:" .. util.fmt_count(st.nodes)
        end
    end
    st_cache.text = text
    return text
end

-- ---------------------------------------------------------------------------
-- 键位 / 命令
-- ---------------------------------------------------------------------------

local KEY_DESC = {
    search = "code-atlas 搜索符号",
    definition = "code-atlas 跳转定义/声明",
    references = "codegraph 引用",
    callers = "codegraph 调用者",
    callees = "codegraph 被调用",
    files = "codegraph 文件列表",
    status = "codegraph 索引状态",
    sync = "codegraph 同步索引",
}

---@param cfg table
local function setup_keymaps(cfg)
    for name, lhs in pairs(cfg.keymaps or {}) do
        if lhs and lhs ~= false and type(lhs) == "string" and KEY_DESC[name] and M[name] then
            -- 顶掉同名的旧映射 (coc 的 <Leader>gr 引用列表就让位给 code-atlas 搜索)
            pcall(vim.keymap.del, "n", lhs)
            vim.keymap.set("n", lhs, function()
                M[name]()
            end, { silent = true, desc = KEY_DESC[name] })
        end
    end
end

local SUBCOMMANDS = {
    "search",
    "definition",
    "references",
    "callers",
    "callees",
    "files",
    "status",
    "sync",
    "index",
    "daemon",
    "root",
    "doctor",
    "health",
}

---@param args string
local function run_command(args)
    local parts = vim.split(args or "", "%s+", { trimempty = true })
    local sub = parts[1] or "status"
    local rest = table.concat(vim.list_slice(parts, 2), " ")

    if sub == "search" then
        M.search({ query = rest ~= "" and rest or nil })
    elseif sub == "definition" or sub == "def" then
        M.definition({ name = rest ~= "" and rest or nil })
    elseif sub == "references" or sub == "refs" then
        M.references({ name = rest ~= "" and rest or nil })
    elseif sub == "callers" then
        M.callers({ name = rest ~= "" and rest or nil })
    elseif sub == "callees" then
        M.callees({ name = rest ~= "" and rest or nil })
    elseif sub == "files" then
        M.files()
    elseif sub == "status" or sub == "info" then
        M.status()
    elseif sub == "sync" then
        M.sync()
    elseif sub == "index" or sub == "reindex" then
        M.reindex({ force = rest:find("--force") ~= nil })
    elseif sub == "daemon" then
        M.daemon(rest ~= "" and rest or "status")
    elseif sub == "root" then
        M.root(rest ~= "" and rest or nil)
    elseif sub == "doctor" or sub == "health" then
        pcall(vim.cmd, "checkhealth code_atlas")
    else
        util.notify("未知子命令: " .. sub .. " (可用: " .. table.concat(SUBCOMMANDS, ", ") .. ")", vim.log.levels.WARN)
    end
end

local function setup_commands()
    pcall(vim.api.nvim_del_user_command, "CodeAtlas")
    vim.api.nvim_create_user_command("CodeAtlas", function(info)
        run_command(info.args)
    end, {
        nargs = "*",
        desc = "code-atlas: search/definition/references/callers/callees/files/status/sync/index/daemon/root/doctor",
        complete = function(arglead, cmdline, _)
            local parts = vim.split(cmdline, "%s+", { trimempty = true })
            if #parts <= 2 then
                return vim.tbl_filter(function(v)
                    return vim.startswith(v, arglead)
                end, SUBCOMMANDS)
            end
            if parts[2] == "daemon" then
                return vim.tbl_filter(function(v)
                    return vim.startswith(v, arglead)
                end, { "status", "start", "stop" })
            end
            return {}
        end,
    })
end

-- ---------------------------------------------------------------------------

---@param opts table|nil
function M.setup(opts)
    local cfg = config.setup(opts)
    M.setup_highlights()
    setup_keymaps(cfg)
    setup_commands()
    require("code_atlas.watcher").setup()
    require("code_atlas.source").load()

    -- 如果这个项目最终落到 MCP 数据源 (直读失效/用户指定), 进 buffer 时在后台
    -- 先把 `codegraph serve --mcp` 暖起来, 这样第一次 gd/gr 不用等 4~6s
    vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("codegraph_mcp_warm", { clear = true }),
        callback = function()
            local ctx = project.context()
            if not ctx then
                return
            end
            local adapter = require("code_atlas.source").resolve(ctx)
            if adapter and adapter.name == "codegraph_mcp" then
                require("code_atlas.mcp").client(ctx.root):ensure(function() end)
            end
        end,
    })

    -- codebase-memory: 进项目后后台拉起 MCP + 解析项目名 (不阻塞 UI)
    local cbm_warmed = {}
    vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("codegraph_cbm_warm", { clear = true }),
        callback = function()
            local c = config.get().codebase_memory
            if not c or c.enabled == false then
                return
            end
            vim.schedule(function()
                local ctx = project.context()
                if not ctx or not ctx.root or cbm_warmed[ctx.root] then
                    return
                end
                cbm_warmed[ctx.root] = true
                local ok, cbm = pcall(require, "code_atlas.source.codebase_memory")
                if ok and cbm and cbm.warmup then
                    cbm.warmup(ctx)
                end
            end)
        end,
    })

    -- 退出时把 MCP 常驻进程收掉 (它同时也是文件监视的那只 daemon)
    vim.api.nvim_create_autocmd("VimLeavePre", {
        once = true,
        callback = function()
            require("code_atlas.mcp").stop_all()
            require("code_atlas.mcp_cbm").stop()
        end,
    })

    -- 保险: 如果某个插件(例如 coc)在 VimEnter 前又把键抢回去了, 这里再顶一次
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
            for name, lhs in pairs(cfg.keymaps or {}) do
                if lhs and lhs ~= false and type(lhs) == "string" and M[name] then
                    local map = vim.fn.maparg(lhs, "n", false, true)
                    local rhs = type(map) == "table" and (map.rhs or "") or ""
                    if rhs:find("coc", 1, true) then
                        setup_keymaps(cfg)
                        return
                    end
                end
            end
        end,
    })
    return cfg
end

return M
