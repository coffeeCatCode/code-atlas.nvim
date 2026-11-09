-- ============================================================================
-- codegraph.nvim: 索引新鲜度 (后台守护 / 保存后同步 / 轮询)
--
-- codegraph 自己的后台是 `codegraph serve --mcp -p <root>`: 它会监听
-- .codegraph/daemon.sock、监视工程文件、有变化就自动 sync, 空闲 300s 后退出。
-- 这里不重复造监听器, 只做三件事:
--   1) daemon 模式: 需要时把它拉起来 (它是自己 daemonize 的, 不会挂住 nvim)
--   2) 保存后: 直接跑 `codegraph sync -q` (防抖 + 最小间隔)
--   3) poll 模式: 定时 `codegraph status -j` 看 pendingChanges, 有变化才 sync
--
-- 模式: auto(默认) | daemon | on_save | poll | off
--   auto = 别人(比如 AI 客户端)已经起了后台就白嫖它, 没有就保存时自己同步
-- ============================================================================

local config = require("codegraph.config")
local project = require("codegraph.project")
local util = require("codegraph.util")

local M = {}

local state = {
    timer = nil, -- 保存防抖
    poll_timer = nil, -- 轮询
    syncing = false,
    queued = nil, -- 同步期间又攒下的请求
    last_sync = 0,
    daemon_started = {}, -- root -> true
    daemon_attempt = {}, -- root -> 上次尝试时间
    stopping = {}, -- root -> 主动停止中 (别把 SIGTERM 当异常报)
}

local function now_ms()
    return (vim.uv or vim.loop).now()
end

---@return table
local function cfg()
    return config.get().watcher
end

---@param file string
---@return boolean
local function ignored(file)
    for _, pat in ipairs(cfg().ignore or {}) do
        if file:find(pat) then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 同步
-- ---------------------------------------------------------------------------

--- 真正执行一次 sync
---@param ctx table
---@param opts table|nil { reason, quiet }
function M.sync_now(ctx, opts)
    opts = opts or {}
    if not ctx then
        if not opts.quiet then
            util.notify("没有可同步的项目", vim.log.levels.WARN)
        end
        return
    end

    local src = require("codegraph.source")
    local a = src.resolve(ctx)
    if not a or not a.sync then
        if not opts.quiet then
            util.notify("当前数据源不支持同步", vim.log.levels.WARN)
        end
        return
    end

    if state.syncing then
        state.queued = ctx
        return
    end
    state.syncing = true
    state.last_sync = now_ms()

    a.sync(ctx, { quiet = true }, function(ok, msg)
        state.syncing = false
        if ok then
            if not opts.quiet then
                util.notify(("索引已同步 (%s)"):format(ctx.root))
            end
            -- db 变了, 文件头缓存不用动, 但状态栏/状态信息要重新取
            project.clear()
        else
            util.notify("索引同步失败: " .. tostring(msg), vim.log.levels.WARN)
        end
        local queued = state.queued
        state.queued = nil
        if queued then
            M.sync_now(queued, { quiet = true })
        end
    end)
end

--- 防抖后的同步 (自动触发, 静默)
---@param ctx table
local function schedule_sync(ctx)
    local w = cfg().on_save
    local interval = (w.min_interval or 5000)
    if state.last_sync ~= 0 and now_ms() - state.last_sync < interval then
        -- 太近了, 过一个最小间隔再来
        local wait = interval - (now_ms() - state.last_sync)
        if state.timer then
            state.timer:stop()
            state.timer:start(wait, 0, vim.schedule_wrap(function()
                schedule_sync(ctx)
            end))
        end
        return
    end

    if not state.timer then
        state.timer = (vim.uv or vim.loop).new_timer()
    end
    state.timer:stop()
    state.timer:start(w.debounce or 1500, 0, vim.schedule_wrap(function()
        M.sync_now(ctx, { quiet = true })
    end))
end

-- ---------------------------------------------------------------------------
-- 后台守护进程
-- ---------------------------------------------------------------------------

--- /proc/<pid>/cmdline 里是不是 codegraph (防止 pid 被别的进程复用)
---@param pid number
---@return boolean|nil true/false, nil = 判断不了 (非 Linux / 无权限)
local function pid_is_codegraph(pid)
    local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
    if not f then
        return nil
    end
    local raw = f:read("*a") or ""
    f:close()
    return raw:find("codegraph", 1, true) ~= nil
end

--- 后台守护进程状态
---@param ctx table
---@return boolean running
---@return number|nil pid
function M.daemon_state(ctx)
    if not ctx or not ctx.index_dir then
        return false
    end
    local pid_file = ctx.index_dir .. "/daemon.pid"
    local f = io.open(pid_file, "r")
    if not f then
        return false
    end
    local raw = f:read("*a")
    f:close()

    local data = util.decode(raw)
    local pid = data and tonumber(data.pid)
    if not pid then
        return false
    end
    -- 注意 luv 的语义: 成功返回 0, 失败返回 nil + err (不会抛异常),
    -- 所以这里必须看返回值, 光用 pcall 包着会把 "进程不存在" 当成存活
    local uv = vim.uv or vim.loop
    local ok, ret = pcall(uv.kill, pid, 0)
    if not ok or ret == nil then
        return false
    end

    -- pid 存在还不够: 进程可能已经退出, pid 被系统复用给了别的程序
    if pid_is_codegraph(pid) == false then
        return false
    end
    return true, pid
end

--- 清掉过期/残缺的 daemon 文件 (只在确定没有活进程时调用)
---@param ctx table
function M.cleanup_daemon_files(ctx)
    if not ctx or not ctx.index_dir then
        return
    end
    for _, name in ipairs({ "daemon.sock", "daemon.pid", "writer.pid" }) do
        pcall(vim.uv.fs_unlink, ctx.index_dir .. "/" .. name)
    end
end

---@param ctx table
---@return boolean
function M.daemon_available(ctx)
    return util.executable(config.get().cli.bin) and ctx ~= nil
end

--- 需要时把后台拉起来 (CLI 自己 daemonize, jobstart 的进程会立刻退出)
---@param ctx table
---@return boolean
function M.start_daemon(ctx)
    if not ctx then
        return false
    end
    if M.daemon_state(ctx) then
        return true
    end
    if not M.daemon_available(ctx) then
        return false
    end
    -- 上一个后台是被 kill -9 之类的, pid/sock 会残留, 先清掉再起
    if vim.uv.fs_stat(ctx.index_dir .. "/daemon.pid") then
        M.cleanup_daemon_files(ctx)
    end

    -- 30s 内不重复尝试, 免得每次 BufEnter 都拉一次
    local last = state.daemon_attempt[ctx.root]
    if last and now_ms() - last < 30000 then
        return false
    end
    state.daemon_attempt[ctx.root] = now_ms()

    local d = cfg().daemon
    local cmd = vim.deepcopy(d.cmd or { "codegraph", "serve", "--mcp" })
    cmd[#cmd + 1] = "-p"
    cmd[#cmd + 1] = ctx.root

    -- jobstart 返回 job id, 0/-1 表示起不来; pcall 只兜参数错误
    local ok, job = pcall(vim.fn.jobstart, cmd, {
        cwd = ctx.root,
        stdout_buffered = false,
        stderr_buffered = false,
        on_exit = function(_, code)
            if state.stopping[ctx.root] then
                state.stopping[ctx.root] = nil
                return
            end
            if code ~= 0 then
                util.notify("codegraph 后台退出 (code=" .. tostring(code) .. ")", vim.log.levels.WARN)
            end
        end,
    })
    if not ok or not job or job <= 0 then
        return false
    end

    state.daemon_started[ctx.root] = true
    -- CLI 起完后台就退出, 这里等一下再确认 pid 文件
    vim.defer_fn(function()
        local running = M.daemon_state(ctx)
        if running then
            project.clear()
        end
    end, 1200)
    return true
end

---@param ctx table
---@return boolean
function M.stop_daemon(ctx)
    local running, pid = M.daemon_state(ctx)
    if not running or not pid then
        -- 清掉可能残留的 socket / pid
        pcall(vim.uv.fs_unlink, ctx.index_dir .. "/daemon.sock")
        pcall(vim.uv.fs_unlink, ctx.index_dir .. "/daemon.pid")
        return false
    end
    state.stopping[ctx.root] = true
    pcall(function()
        return (vim.uv or vim.loop).kill(pid, "sigterm")
    end)
    state.daemon_started[ctx.root] = nil

    -- 等它退出, 再把可能残留的 pid/sock 清掉
    vim.defer_fn(function()
        if not M.daemon_state(ctx) then
            M.cleanup_daemon_files(ctx)
        end
    end, 800)
    return true
end

-- ---------------------------------------------------------------------------
-- 轮询
-- ---------------------------------------------------------------------------

--- 用 CLI 问一次 pendingChanges (直读 SQLite 算不出这个)
---@param ctx table
---@param cb fun(data: table|nil)
local function cli_status_async(ctx, cb)
    local cfg = config.get()
    if not util.executable(cfg.cli.bin) then
        cb(nil)
        return
    end
    util.run_async({
        cfg.cli.bin,
        "status",
        "-j",
        ctx.root,
    }, { cwd = ctx.root, timeout = cfg.watcher.poll.timeout or 30000 }, function(res)
        cb(util.decode(res.stdout))
    end)
end

---@param pending table|nil
---@return integer
local function pending_total(pending)
    if type(pending) ~= "table" then
        return 0
    end
    return (pending.added or 0) + (pending.modified or 0) + (pending.removed or 0)
end

local function poll_once()
    local ctx = project.context()
    if not ctx then
        return
    end
    if M.daemon_state(ctx) then
        return -- 后台自己会 sync
    end

    local a = require("codegraph.source").resolve(ctx)
    local ok, st = pcall(function()
        return a and a.status and a.status(ctx)
    end)
    st = (ok and type(st) == "table") and st or {}

    if type(st.pending) == "table" then
        if pending_total(st.pending) > 0 then
            M.sync_now(ctx, { quiet = true })
        end
        return
    end

    -- sqlite 直读没有 pending 字段, 让 CLI 帮忙判断
    if not a or a.name ~= "codegraph" then
        return
    end
    cli_status_async(ctx, function(data)
        if type(data) == "table" and pending_total(data.pendingChanges) > 0 then
            M.sync_now(ctx, { quiet = true })
        end
    end)
end

M.poll_once = poll_once

local function start_poll_timer()
    local interval = math.max(15, cfg().poll.interval or 120)
    if not state.poll_timer then
        state.poll_timer = (vim.uv or vim.loop).new_timer()
    end
    state.poll_timer:stop()
    state.poll_timer:start(interval * 1000, interval * 1000, vim.schedule_wrap(poll_once))
end

-- ---------------------------------------------------------------------------
-- 事件入口
-- ---------------------------------------------------------------------------

--- 当前实际生效的模式 (auto 会被解析成 daemon 或 on_save)
---@param ctx table|nil
---@return string
function M.effective_mode(ctx)
    local mode = cfg().mode or "auto"
    if mode ~= "auto" then
        return mode
    end
    if ctx and M.daemon_state(ctx) then
        return "daemon"
    end
    return "on_save"
end

---@param ctx table
function M.attach(ctx)
    if not ctx then
        return
    end
    local mode = cfg().mode or "auto"
    if mode == "off" then
        return
    end

    if mode == "daemon" then
        M.start_daemon(ctx)
        return
    end

    if mode == "auto" and cfg().daemon.autostart and not M.daemon_state(ctx) then
        -- 文件数太多就不拉后台 (node 进程常驻约 150MB)
        local d = cfg().daemon
        local a = require("codegraph.source").resolve(ctx)
        local count
        if a and a.status then
            local ok, st = pcall(a.status, ctx)
            if ok and type(st) == "table" then
                count = st.files_count
            end
        end
        if count and d.max_files and count > d.max_files then
            return
        end
        M.start_daemon(ctx)
    end
end

--- BufWritePost 入口
---@param file string
function M.on_write(file)
    if not file or file == "" then
        return
    end
    if ignored(file) then
        return
    end
    local mode = cfg().mode or "auto"
    if mode == "off" then
        return
    end

    local ctx = project.context_for_file(file)
    if not ctx then
        return
    end

    -- 后台已经在跑: 它自己会 sync, 这边不用重复做
    if mode == "daemon" or mode == "auto" then
        if M.daemon_state(ctx) then
            return
        end
    end

    if mode == "poll" then
        -- 轮询模式不按保存触发
        return
    end

    schedule_sync(ctx)
end

--- 注册 autocmd
function M.setup()
    local group = vim.api.nvim_create_augroup("codegraph_watcher", { clear = true })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*",
        callback = function(args)
            M.on_write(args.match)
        end,
    })

    vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
        group = group,
        callback = function()
            local ctx = project.context()
            if ctx then
                M.attach(ctx)
            end
        end,
    })

    if (cfg().mode or "auto") == "poll" then
        start_poll_timer()
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            M.shutdown()
        end,
    })
end

--- 收尾: 停定时器, 按配置停掉自己拉起的后台
function M.shutdown()
    if state.timer then
        state.timer:stop()
        pcall(state.timer.close, state.timer)
        state.timer = nil
    end
    if state.poll_timer then
        state.poll_timer:stop()
        pcall(state.poll_timer.close, state.poll_timer)
        state.poll_timer = nil
    end

    if cfg().daemon.stop_on_exit then
        for root in pairs(state.daemon_started) do
            local ctx = project.check_dir(root, config.get())
            if ctx then
                M.stop_daemon(ctx)
            end
        end
    end
end

--- 状态 (给 :CodeGraph status / health 用)
---@param ctx table|nil
---@return table
function M.status(ctx)
    ctx = ctx or project.context()
    local running, pid = false, nil
    if ctx then
        running, pid = M.daemon_state(ctx)
    end
    return {
        mode = cfg().mode,
        effective = M.effective_mode(ctx),
        daemon = running and ("running (pid " .. tostring(pid) .. ")") or "stopped",
        daemon_pid = pid,
        last_sync = state.last_sync,
        syncing = state.syncing,
    }
end

return M
