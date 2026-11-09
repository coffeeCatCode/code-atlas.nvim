-- ============================================================================
-- code-atlas.nvim: telescope 扩展入口
-- 用法: :Telescope code_atlas search / definition / references / callers
--       / callees / files
-- (telescope 的 extension 只负责把命令路由到函数, 真正的 picker 在 code_atlas.picker)
-- ============================================================================

local function export(kind)
    return function(opts)
        return require("code_atlas")[kind](opts or {})
    end
end

return require("telescope").register_extension({
    exports = {
        search = export("search"),
        definition = export("definition"),
        references = export("references"),
        callers = export("callers"),
        callees = export("callees"),
        files = export("files"),
    },
})
