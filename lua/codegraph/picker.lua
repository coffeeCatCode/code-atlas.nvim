-- ============================================================================
-- codegraph.nvim: telescope 展示层
--
-- telescope 的 picker 接受任意"条目来源": finders.new_table (静态表) 或
-- finders.new_dynamic (fn(prompt) 每次输入重新取), 所以 codegraph 的符号、
-- 引用、文件都能直接塞进去, 不需要写新的 UI。
-- ============================================================================

local config = require("codegraph.config")
local util = require("codegraph.util")

local M = {}

-- kind -> 徽标 / 高亮组 (高亮组在 init.setup 里注册)
local BADGE = {
    ["function"] = "fn",
    method = "meth",
    constructor = "ctor",
    class = "class",
    struct = "struct",
    union = "union",
    interface = "iface",
    trait = "trait",
    enum = "enum",
    enum_member = "member",
    type_alias = "type",
    typedef = "typedef",
    namespace = "ns",
    module = "mod",
    variable = "var",
    constant = "const",
    field = "field",
    property = "prop",
    macro = "macro",
    file = "file",
    match = "text",
    import = "imp",
}

---@param item table
---@return string
local function badge(item)
    local kind = item.kind
    if kind == "usage" then
        return item.edge_kind == "references" and "ref" or "call"
    end
    return BADGE[kind] or (kind or "?"):sub(1, 6)
end

---@param kind string
---@return string
local function highlight(kind)
    return "CodeGraph" .. (kind or "unknown")
end

-- ---------------------------------------------------------------------------
-- entry_maker
-- ---------------------------------------------------------------------------

---@param opts table
---@return function
function M.entry_maker(opts)
    local entry_display = require("telescope.pickers.entry_display")

    local name_width = opts.name_width or 34
    local loc_width = opts.loc_width or 44

    local displayer = entry_display.create({
        separator = " ",
        items = {
            { width = 8 }, -- 类型徽标
            { width = name_width }, -- 名字
            { remaining = true }, -- 限定名 / 签名 / 文本
            { width = loc_width }, -- 路径:行号
        },
    })

    return function(item)
        -- 所有要进结果窗口/预览的文本都先压成单行 (signature 里可能带换行)
        local name = util.oneline(item.name)
        local qname = util.oneline(item.qualified_name)
        local text = util.oneline(item.text)
        local sig = util.oneline(item.signature)
        local path = util.oneline(item.path)

        local third = ""
        if item.kind == "usage" then
            -- 调用点: 第二列是被调符号, 第三列显示"在哪个函数里用的"
            third = "← " .. (item.caller or "?")
            if item.caller_kind then
                third = third .. " (" .. item.caller_kind .. ")"
            end
        elseif item.kind == "match" then
            third = util.truncate(text, 70)
        elseif item.kind == "file" then
            third = table.concat({
                item.language and tostring(item.language) or "",
                item.node_count ~= nil and (tostring(item.node_count) .. " 符号") or "",
                item.indexed_at and util.fmt_time(item.indexed_at) or "",
            }, " ")
        elseif qname ~= "" and qname ~= name then
            third = qname
        elseif sig ~= "" then
            third = sig
        end
        third = util.oneline(third)

        local loc = path
        if item.kind ~= "file" then
            loc = loc .. ":" .. tostring(item.line or 1)
        end

        local tag = badge(item)
        if item.is_decl then
            tag = tag .. "·h"
        end

        -- 调用点: 第二列用限定名, 否则只写短名分不清是哪个类的
        local display_name = name
        if item.kind == "usage" and qname ~= "" and qname ~= name then
            display_name = qname
        end

        local function make_display(_)
            return displayer({
                { "[" .. tag .. "]", highlight(item.kind) },
                { util.truncate(display_name, name_width - 1), "TelescopeResultsIdentifier" },
                { third, "TelescopeResultsComment" },
                { util.truncate(loc, loc_width), "TelescopeResultsNumber" },
            })
        end

        return {
            value = item,
            -- ordinal 要包含"能被搜到的所有字段": telescope 的 sorter 会把
            -- ordinal 里匹不上的条目标成 filtered 直接丢掉, 如果只放名字,
            -- 那些"命中签名/文档"的结果就会在 picker 里凭空消失。
            ordinal = util.oneline(table.concat({
                item.name or "",
                item.qualified_name or "",
                item.caller or "",
                item.signature or "",
                item.doc and util.truncate(item.doc, 120) or "",
                item.text or "",
                item.path or "",
                item.kind or "",
            }, " ")),
            display = make_display,
            filename = item.file,
            lnum = item.line or 1,
            col = item.col or 1,
            item = item,
        }
    end
end

-- ---------------------------------------------------------------------------
-- 取数据
-- ---------------------------------------------------------------------------

--- 一次性取数 (定义/引用/文件这类不需要边输边查)
---@param kind string
---@param ctx table|nil
---@param adapter table
---@param opts table
---@return table[]
function M.fetch(kind, ctx, adapter, opts)
    local name = opts.name or opts.query or ""
    if kind == "search" then
        return adapter.search(ctx, opts.query or "", opts) or {}
    elseif kind == "definition" then
        return adapter.definition(ctx, name, opts) or {}
    elseif kind == "references" then
        return adapter.references(ctx, name, opts) or {}
    elseif kind == "callers" then
        return adapter.callers(ctx, name, opts) or {}
    elseif kind == "callees" then
        return adapter.callees(ctx, name, opts) or {}
    elseif kind == "files" then
        return adapter.files(ctx, opts) or {}
    end
    return {}
end

--- 条目标识 (跨索引去重): 同一个文件/行/符号在两个索引里只留一份
---@param it table
---@return string
local function item_key(it)
    return table.concat({ it.file or "", tostring(it.line or 0), it.name or "", it.kind or "" }, ":")
end

--- 把上级 .codegraph 的搜索结果并进来 (多级索引, 只向上)
---@param ctx table
---@param items table[]
---@param prompt string
---@param opts table
---@return table[]
local function merge_parent_results(ctx, items, prompt, opts)
    local cfg = config.get()
    if cfg.search.search_parents == false or prompt == "" or not ctx then
        return items
    end

    local project = require("codegraph.project")
    local source = require("codegraph.source")
    local seen = {}
    for _, it in ipairs(items) do
        seen[item_key(it)] = true
    end

    local used = 0
    local max_parents = cfg.search.max_parents or 2
    local parent_limit = cfg.search.max_parent_results or 150

    for _, pctx in ipairs(project.find_all(ctx.root)) do
        if pctx.root ~= ctx.root and used < max_parents then
            used = used + 1
            local pa = source.resolve(pctx)
            if pa and pa.search then
                local popts = vim.tbl_extend("force", opts, { limit = parent_limit })
                local ok, more = pcall(pa.search, pctx, prompt, popts)
                if ok and type(more) == "table" then
                    for _, it in ipairs(more) do
                        local key = item_key(it)
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
    end
    return items
end

--- 异步 finder: 给 MCP 这种"请求-响应"型数据源用, 不阻塞 UI
--- telescope 的 finder 是可调用对象, 结果由 process_result/process_complete 回填
---@param adapter table
---@param ctx table
---@param opts table
---@param entry_maker function
---@return table
local function async_finder(adapter, ctx, opts, entry_maker)
    local finder = {
        close = function() end,
    }

    function finder:_find(prompt, process_result, process_complete)
        if prompt == "" then
            process_complete()
            return
        end
        adapter.search_async(ctx, prompt, opts, function(items)
            items = merge_parent_results(ctx, items or {}, prompt, opts)
            for _, item in ipairs(items) do
                local entry = entry_maker(item)
                if entry and process_result(entry) then
                    return
                end
            end
            process_complete()
        end)
    end

    return setmetatable(finder, {
        __call = function(self, ...)
            return self:_find(...)
        end,
    })
end

---@param kind string
---@param ctx table|nil
---@param adapter table
---@param opts table
---@return table
local function new_finder(kind, ctx, adapter, opts)
    local finders = require("telescope.finders")
    local entry_maker = M.entry_maker(opts)
    local cfg = config.get()

    -- 调用方已经查好了 (比如 <Leader>gd 的多结果), 直接摆出来
    if opts.items then
        return finders.new_table({ results = opts.items, entry_maker = entry_maker })
    end

    -- 搜索: 有异步接口的 (MCP) 先走异步, 避免冷启动/抖动把 UI 卡住
    if kind == "search" and type(adapter.search_async) == "function" then
        return async_finder(adapter, ctx, opts, entry_maker)
    end

    -- 搜索: 每次输入都查 (SQL 直读约 10~20ms; 用 telescope 的 debounce 限流)
    if kind == "search" then
        local min_prompt = cfg.search.min_prompt or 0
        local empty_prompt = cfg.search.empty_prompt
        return finders.new_dynamic({
            entry_maker = entry_maker,
            fn = function(prompt)
                if prompt == "" then
                    -- 空 prompt: 显示最近索引过的符号 (recent) 或什么都不显示
                    if empty_prompt == "none" then
                        return {}
                    end
                    local ok, items = pcall(adapter.search, ctx, "", opts)
                    return ok and items or {}
                end
                if #prompt < min_prompt then
                    return {}
                end
                local ok, items = pcall(adapter.search, ctx, prompt, opts)
                if not ok then
                    return {}
                end
                return merge_parent_results(ctx, items or {}, prompt, opts)
            end,
        })
    end

    local items = M.fetch(kind, ctx, adapter, opts)
    return finders.new_table({ results = items, entry_maker = entry_maker })
end

-- ---------------------------------------------------------------------------
-- picker
-- ---------------------------------------------------------------------------

local TITLES = {
    search = "codegraph 符号",
    definition = "codegraph 定义/声明",
    references = "codegraph 引用",
    callers = "codegraph 调用者",
    callees = "codegraph 被调用",
    files = "codegraph 文件",
}

---@param kind string
---@param opts table
---@return table|nil
function M.open(kind, opts)
    opts = opts or {}
    local ctx = opts.ctx or require("codegraph.project").context()
    local source = require("codegraph.source")
    local adapter = opts.adapter
    if not adapter then
        adapter = source.resolve(ctx)
    end

    if not adapter then
        if ctx == nil then
            util.notify("没找到 .codegraph/codegraph.db (已逐级向上查找), 这个项目不使用 codegraph", vim.log.levels.WARN)
        else
            util.notify("没有可用的数据源 (sqlite3 / codegraph 都不在 PATH 里?)", vim.log.levels.WARN)
        end
        return nil
    end

    if adapter.supports and adapter.supports[kind] == false then
        util.notify(("%s 数据源不支持 %s"):format(adapter.label or adapter.name, kind), vim.log.levels.WARN)
        return nil
    end

    -- 只有定义/引用这些需要名字的操作才有意义; 搜不到就不开空窗
    if kind ~= "search" and kind ~= "files" and (not opts.name or opts.name == "") then
        util.notify("光标下没有符号", vim.log.levels.WARN)
        return nil
    end

    local pickers = require("telescope.pickers")
    local conf = require("telescope.config").values
    local titles = TITLES
    local title = opts.prompt_title or titles[kind] or ("codegraph " .. kind)
    if opts.name and opts.name ~= "" and kind ~= "search" then
        title = title .. " · " .. opts.name
    end

    opts.title = title
    -- 搜索限流: 输入停顿这么久才真正查一次 (telescope 在 finder 前 sleep)
    if kind == "search" and opts.debounce == nil then
        opts.debounce = config.get().search.debounce
    end

    local finder = new_finder(kind, ctx, adapter, opts)

    local previewer
    if config.get().preview.enabled and opts.previewer ~= false then
        previewer = (kind == "files") and conf.file_previewer(opts) or conf.grep_previewer(opts)
    end

    local picker = pickers.new(opts, {
        prompt_title = title,
        finder = finder,
        previewer = previewer,
        sorter = conf.generic_sorter(opts),
        default_text = opts.query and opts.query ~= "" and opts.query or nil,
        attach_mappings = function(prompt_bufnr, map)
            local actions = require("telescope.actions")

            -- <C-q> 全部塞进 quickfix (批量跳转/重构时好用)
            local function to_qflist()
                actions.send_selected_to_qflist(prompt_bufnr)
                actions.open_qflist(prompt_bufnr)
            end
            map("i", "<C-q>", to_qflist)
            map("n", "<C-q>", to_qflist)

            -- <CR> 用自己的跳转: telescope 默认按 entry.lnum/col 放光标,
            -- 而 codegraph 的列号对 C/C++ 没意义, 会停在行首
            local action_state = require("telescope.actions.state")
            local function select_and_jump()
                local entry = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if entry and entry.value then
                    M.jump(entry.value)
                end
            end
            map("i", "<CR>", select_and_jump)
            map("n", "<CR>", select_and_jump)

            if opts.attach_mappings then
                opts.attach_mappings(prompt_bufnr, map)
            end
            return true
        end,
    })
    picker:find()
    return picker
end

-- ---------------------------------------------------------------------------
-- 跳转
-- ---------------------------------------------------------------------------

--- 在 line 起往下几行里找符号名, 返回 { 行, 列(0 基) }
--- 目的: codegraph 给的 start_column 对 C/C++ 基本是 0, 直接跳会停在行首,
--- 光标下的 <cWORD> 变成 void/int 这类返回类型, 再按 gd 就找不到东西了。
---@param buf integer
---@param line integer
---@param item table
---@return integer line
---@return integer col
local function locate_symbol(buf, line, item)
    local names = {}
    if item.name and item.name ~= "" then
        names[#names + 1] = item.name
    end
    local short = item.qualified_name and item.qualified_name:match("([%w_]+)$")
    if short and short ~= "" and short ~= item.name then
        names[#names + 1] = short
    end

    local last = vim.api.nvim_buf_line_count(buf)
    for offset = 0, 3 do
        local ln = line + offset
        if ln > last then
            break
        end
        local text = vim.api.nvim_buf_get_lines(buf, ln - 1, ln, false)[1] or ""
        for _, name in ipairs(names) do
            local ok, res = pcall(vim.fn.matchstrpos, text, "\\<" .. vim.pesc(name) .. "\\>")
            if ok and type(res) == "table" and tonumber(res[2]) and tonumber(res[2]) >= 0 then
                return ln, tonumber(res[2])
            end
            -- 名字里带 ~ / operator 之类, 整词匹配不上时退回普通查找
            local s = text:find(name, 1, true)
            if s then
                return ln, s - 1
            end
        end
    end
    return line, math.max(0, (item.col or 1) - 1)
end

---@param item table|nil
---@return boolean
function M.jump(item)
    if not item or not item.file or item.file == "" then
        return false
    end
    vim.cmd("edit " .. vim.fn.fnameescape(item.file))
    local buf = vim.api.nvim_get_current_buf()
    local last = vim.api.nvim_buf_line_count(buf)
    local line = math.max(1, math.min(item.line or 1, last))
    local col = 0

    -- 文件条目 / 用法匹配不到名字时, 老老实实停在行首
    if item.kind ~= "file" and (item.name or item.qualified_name) then
        line, col = locate_symbol(buf, line, item)
    end

    pcall(vim.api.nvim_win_set_cursor, 0, { line, col })
    vim.cmd("normal! zz")
    return true
end

return M
