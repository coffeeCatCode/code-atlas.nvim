-- ============================================================================
-- code-atlas.nvim: 数据源注册表 (可插拔适配层)
--
-- 想接别的数据源 (LSP / ctags / tree-sitter / grep 服务...), 只要实现下面的
-- 契约再 require("code_atlas.source").register() 一下即可, 上层 (telescope
-- picker / 键位 / 命令) 完全不用改。
--
-- 适配器契约 (除 name 外都可选, 缺哪个能力就返回空表):
--   name        string   唯一名字
--   label       string   给用户看的名字
--   priority    number   数字越大越优先 (auto 模式下先试)
--   available(ctx)        -> boolean         当前项目能不能用
--   search(ctx, query, opts)               -> item[]   符号搜索
--   definition(ctx, name, opts)             -> item[]   定义/声明
--   references(ctx, name, opts)             -> item[]   谁引用了它
--   callers(ctx, name, opts)                -> item[]   谁调用它
--   callees(ctx, name, opts)                -> item[]   它调用了谁
--   files(ctx, opts)                        -> item[]   文件列表
--   status(ctx, cb)                        -> table    索引状态 (cb 形式也可)
--   sync(ctx, opts, cb)                              触发索引同步
--
-- item 是各适配器统一后的"符号条目":
--   { id, kind, name, qualified_name, path(相对 root), file(绝对路径),
--     line, end_line, signature, doc, source(适配器名) }
-- ============================================================================

local config = require("code_atlas.config")

local M = {}

--- 已注册的适配器
---@type table<string, table>
M.registry = {}

--- 内置适配器 (按 auto 模式下的探测顺序)
M.builtin = { "codegraph", "codegraph_mcp", "codegraph_cli", "codebase_memory", "ripgrep" }

M.loaded = false

--- 注册一个数据源
---@param adapter table
---@return table
function M.register(adapter)
    assert(type(adapter) == "table", "adapter 必须是 table")
    assert(type(adapter.name) == "string" and adapter.name ~= "", "adapter.name 必须是非空字符串")
    M.registry[adapter.name] = adapter
    return adapter
end

---@param name string
---@return table|nil
function M.get(name)
    return M.registry[name]
end

--- 加载内置适配器 (只加载一次)
function M.load()
    if M.loaded then
        return
    end
    M.loaded = true
    local loaded_any = false
    for _, name in ipairs(M.builtin) do
        local ok, mod = pcall(require, "code_atlas.source." .. name)
        if ok and type(mod) == "table" then
            M.register(mod)
            loaded_any = true
        end
    end
    -- 一个都没加载成功 (例如插件更新到一半), 下次 resolve 再试
    if not loaded_any then
        M.loaded = false
    end
end

--- 按配置挑一个能用数据源
---@param ctx table|nil
---@return table|nil adapter
---@return table|nil ctx
function M.resolve(ctx)
    M.load()
    local cfg = config.get()

    -- 写死某个源
    if cfg.source ~= "auto" then
        local adapter = M.registry[cfg.source]
        if adapter then
            local ok, avail = pcall(adapter.available, ctx)
            if ok and avail then
                return adapter, ctx
            end
        end
        return nil, ctx
    end

    -- 按配置顺序探测
    for _, name in ipairs(cfg.sources or {}) do
        local adapter = M.registry[name]
        if adapter then
            local ok, avail = pcall(adapter.available, ctx)
            if ok and avail then
                return adapter, ctx
            end
        end
    end
    return nil, ctx
end

--- 列出所有数据源及可用性 (状态面板 / health 用)
---@param ctx table|nil
---@return table[]
function M.list(ctx)
    M.load()
    local out = {}
    for _, name in ipairs(M.builtin) do
        local adapter = M.registry[name]
        if adapter then
            local ok, avail = pcall(adapter.available, ctx)
            out[#out + 1] = {
                name = name,
                label = adapter.label or name,
                available = ok and avail == true,
                reason = (not ok) and tostring(avail) or nil,
            }
        end
    end
    return out
end

return M
