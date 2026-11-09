-- ============================================================================
-- codegraph.nvim: :checkhealth codegraph
-- ============================================================================

local config = require("codegraph.config")
local project = require("codegraph.project")
local util = require("codegraph.util")

local M = {}

---@return table
local function health()
    return vim.health or require("vim.health")
end

function M.check()
    local h = health()
    h.start("codegraph.nvim")

    -- ------------------------------------------------------------------
    h.start("环境")
    -- ------------------------------------------------------------------
    local v = vim.version()
    if (v.major > 0) or (v.minor >= 10) then
        h.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
    else
        h.error("需要 Neovim >= 0.10 (用到 vim.system)")
    end

    local ok_telescope, telescope = pcall(require, "telescope")
    if ok_telescope and telescope then
        h.ok("telescope.nvim 已安装")
    else
        h.error("telescope.nvim 未安装: 没有它就没法展示结果")
    end

    local cfg = config.get()
    if util.executable(cfg.sqlite.bin) then
        local res = util.run_sync({ cfg.sqlite.bin, "--version" }, { timeout = 3000 })
        h.ok(("%s: %s"):format(cfg.sqlite.bin, vim.trim(res.stdout or "")))
    else
        h.warn(("%s 不在 PATH 里: 会退回 codegraph CLI 数据源, 搜索会慢很多"):format(cfg.sqlite.bin))
    end

    if util.executable(cfg.cli.bin) then
        local res = util.run_sync({ cfg.cli.bin, "--version" }, { timeout = 5000 })
        h.ok(("%s: %s"):format(cfg.cli.bin, vim.trim(res.stdout or "")))
    else
        h.warn(("%s 不在 PATH 里: 无法同步/重建索引"):format(cfg.cli.bin))
    end

    -- ------------------------------------------------------------------
    h.start("项目索引")
    -- ------------------------------------------------------------------
    local ctx = project.context()
    if not ctx then
        h.warn("当前 buffer 逐级向上都没有找到 .codegraph/codegraph.db")
        h.info("按设计此时插件不启用; 需要在项目根执行 codegraph init")
        h.info("查找起点: " .. project.start_dir())
    else
        h.ok("索引根: " .. ctx.root)
        h.info("索引目录: " .. ctx.index_dir)
        h.info(("db: %s (%s)"):format(ctx.db, util.fmt_size(ctx.db_size)))

        local source = require("codegraph.source")
        local adapter = source.resolve(ctx)
        if not adapter then
            h.error("没有可用的数据源 (检查 sqlite3 / codegraph 可执行文件)")
        else
            h.ok("当前数据源: " .. (adapter.label or adapter.name))
            local ok, st = pcall(adapter.status, ctx)
            if ok and type(st) == "table" then
                h.info(("符号 %s / 关系 %s / 文件 %s"):format(
                    util.fmt_count(st.nodes),
                    util.fmt_count(st.edges),
                    util.fmt_count(st.files_count)
                ))
                h.info("最近索引: " .. util.fmt_time(st.indexed_at or ctx.db_mtime))
                if st.pending then
                    local pending = (st.pending.added or 0) + (st.pending.modified or 0) + (st.pending.removed or 0)
                    if pending > 0 then
                        h.warn(("有 %d 个文件还没同步 (:CodeGraph sync)"):format(pending))
                    else
                        h.ok("索引与工作区一致")
                    end
                end
                if st.index_version then
                    h.info("索引版本: " .. tostring(st.index_version))
                end
                if st.schema_ok == false then
                    h.warn("直读 SQLite 不可用: " .. tostring(st.schema_reason))
                    h.info("auto 模式会自动改用 MCP / CLI 数据源")
                elseif st.schema_ok == true then
                    h.ok("表结构与直读 SQL 匹配")
                end
            else
                h.warn("读取索引状态失败: " .. tostring(st))
            end
        end
    end

    -- ------------------------------------------------------------------
    h.start("数据源")
    -- ------------------------------------------------------------------
    local source = require("codegraph.source")
    for _, item in ipairs(source.list(ctx)) do
        if item.available then
            h.ok(("%s: 可用"):format(item.label))
        else
            h.info(("%s: 不可用%s"):format(item.label, item.reason and (" (" .. item.reason .. ")") or ""))
        end
    end
    h.info("配置顺序: " .. table.concat(cfg.sources or {}, " -> "))

    -- ------------------------------------------------------------------
    h.start("MCP")
    -- ------------------------------------------------------------------
    if cfg.mcp.enabled == false then
        h.info("已关闭 (mcp.enabled = false)")
    else
        h.info("工具白名单: " .. tostring(cfg.mcp.tools))
        local mcp = require("codegraph.mcp")
        local server = ctx and mcp.server_info(ctx.root) or nil
        if server then
            h.ok(("已连接: %s %s"):format(tostring(server.name), tostring(server.version)))
        else
            h.info("尚未启动 (首次调用约 4~6s 冷启动; 只在直读失效或指定 source 时才用)")
        end
    end

    -- ------------------------------------------------------------------
    h.start("索引新鲜度")
    -- ------------------------------------------------------------------
    local watcher = require("codegraph.watcher")
    local ws = watcher.status(ctx)
    h.info(("watcher.mode = %s, 实际生效 = %s"):format(tostring(ws.mode), tostring(ws.effective)))
    h.info("后台守护: " .. ws.daemon)
    if ws.mode == "auto" and not cfg.watcher.daemon.autostart then
        h.info("auto 模式不会主动拉起后台; 想常驻把 watcher.daemon.autostart 设为 true")
    end

    -- ------------------------------------------------------------------
    h.start("键位")
    -- ------------------------------------------------------------------
    for name, lhs in pairs(cfg.keymaps or {}) do
        if lhs and lhs ~= false then
            local mapped = vim.fn.maparg(lhs, "n")
            if mapped ~= "" then
                h.ok(("%s -> %s"):format(lhs, name))
            else
                h.warn(("%s (%s) 没有映射"):format(lhs, name))
            end
        end
    end
end

return M
