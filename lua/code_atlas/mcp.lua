-- ============================================================================
-- code-atlas.nvim: MCP 客户端 (stdio, 换行分隔的 JSON-RPC)
--
-- 为什么要有这个:
--   1) 直读 SQLite 最快 (20~40ms), 但绑定表结构 —— codegraph 升级改了列就失效;
--   2) 每次调 `codegraph query` CLI 要 300ms (node 启动), 太慢;
--   3) `codegraph serve --mcp` 是常驻进程, 走它自己的工具接口, 冷启动慢
--      (首次 4~6s), 热态 1ms 量级, 且**数据库怎么改都跟它没关系**。
--
-- 所以 MCP 在这里是"兼容层/兜底", 默认数据源仍是直读 SQLite。
--
-- 协议要点 (2025-11 MCP stdio transport):
--   - 每条消息一行 JSON, 以 \n 结尾, 里面不能有换行
--   - initialize -> notifications/initialized -> tools/list / tools/call
--   - 工具面按仓库大小动态裁剪; 用环境变量 CODEGRAPH_MCP_TOOLS 指定想要的子集
-- ============================================================================

local M = {}

local config = require("code_atlas.config")
local util = require("code_atlas.util")

---@type table<string, table> root -> Client
local clients = {}

local Client = {}
Client.__index = Client

---@param data string|nil
---@return table[]
local function split_lines(self, data)
    if data and data ~= "" then
        self.buf = self.buf .. data
    end
    local out = {}
    while true do
        local nl = self.buf:find("\n", 1, true)
        if not nl then
            break
        end
        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if ok and type(msg) == "table" then
                out[#out + 1] = msg
            end
        end
    end
    return out
end

function Client:_fail_all(reason)
    for _, pending in pairs(self.pending) do
        if pending.timer then
            pcall(pending.timer.stop, pending.timer)
            pcall(pending.timer.close, pending.timer)
        end
        if pending.cb then
            pcall(pending.cb, nil, reason)
        end
    end
    self.pending = {}
end

function Client:_on_exit(res)
    self.dead = true
    self.ready = false
    self:_fail_all("MCP 进程退出 (code=" .. tostring(res and res.code) .. ")")
    -- 让下一次 ensure 重新拉起来
    self.initializing = false
end

function Client:_dispatch(msg)
    -- 响应
    if msg.id ~= nil then
        local pending = self.pending[msg.id]
        if pending then
            self.pending[msg.id] = nil
            if pending.timer then
                pcall(pending.timer.stop, pending.timer)
                pcall(pending.timer.close, pending.timer)
            end
            if pending.cb then
                if msg.error then
                    pcall(pending.cb, nil, msg.error.message or vim.inspect(msg.error))
                else
                    pcall(pending.cb, msg.result, nil)
                end
            end
        end
        return
    end
    -- 通知 (例如窗口日志) 一律忽略
end

function Client:_on_stdout(data)
    for _, msg in ipairs(split_lines(self, data)) do
        self:_dispatch(msg)
    end
end

function Client:_send(obj)
    if self.dead or not self.handle then
        return false
    end
    local ok = pcall(function()
        self.handle:write(vim.json.encode(obj) .. "\n")
    end)
    if not ok then
        self.dead = true
    end
    return ok
end

---@param method string
---@param params table|nil
---@param cb fun(result: table|nil, err: string|nil)
---@param timeout integer|nil
function Client:request(method, params, cb, timeout)
    if self.dead then
        if cb then
            cb(nil, "MCP 未连接")
        end
        return
    end
    self.id = self.id + 1
    local id = self.id
    local ms = timeout or config.get().mcp.timeout or 8000

    local timer
    timer = vim.defer_fn(function()
        local pending = self.pending[id]
        if not pending then
            return
        end
        self.pending[id] = nil
        pcall(function()
            timer:close()
        end)
        if pending.cb then
            pending.cb(nil, "MCP 请求超时 (" .. method .. ", " .. ms .. "ms)")
        end
    end, ms)
    self.pending[id] = { cb = cb, timer = timer }

    self:_send({ jsonrpc = "2.0", id = id, method = method, params = params or {} })
end

--- 起进程 + initialize (幂等, 并发调用会排队)
---@param cb fun(ok: boolean, err: string|nil)
function Client:ensure(cb)
    if self.ready then
        cb(true)
        return
    end
    if self.waiters then
        self.waiters[#self.waiters + 1] = cb
        return
    end
    self.waiters = { cb }

    local function flush(ok, err)
        local waiters = self.waiters or {}
        self.waiters = nil
        for _, fn in ipairs(waiters) do
            pcall(fn, ok, err)
        end
    end

    if self.dead or not self.handle then
        self:_spawn()
        if self.dead then
            flush(false, "拉不起 codegraph serve --mcp")
            return
        end
    end

    self:request("initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "code-atlas.nvim", version = "0.1.0" },
    }, function(result, err)
        if not result then
            flush(false, err)
            return
        end
        self.server = result.serverInfo
        self.ready = true
        self:_send({ jsonrpc = "2.0", method = "notifications/initialized", params = {} })
        flush(true)
    end, 15000)
end

--- 读出 .codegraph/daemon.pid 里的 pid (没有/坏了返回 nil)
---@return number|nil
function Client:_daemon_pid()
    local project = require("code_atlas.project")
    local ctx = project.check_dir(self.root, config.get())
    if not ctx then
        return nil
    end
    local f = io.open(ctx.index_dir .. "/daemon.pid", "r")
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    local data = util.decode(raw)
    return data and tonumber(data.pid) or nil
end

function Client:_spawn()
    local cfg = config.get()
    local cmd = vim.deepcopy(cfg.mcp.cmd or { "codegraph", "serve", "--mcp" })
    if cmd[#cmd] ~= "-p" then
        cmd[#cmd + 1] = "-p"
        cmd[#cmd + 1] = self.root
    end

    local env = vim.tbl_extend("force", vim.fn.environ(), {
        CODEGRAPH_MCP_TOOLS = cfg.mcp.tools or "search,callers,callees,files,status,node",
    })

    self.buf = ""
    self.dead = false
    self.ready = false
    -- 记录启动前是否已经有别人的后台: 有的话退出时不能杀 (可能是 AI 客户端的)
    self.had_daemon = self:_daemon_pid() ~= nil

    local ok, handle = pcall(vim.system, cmd, {
        cwd = self.root,
        env = env,
        stdin = true,
        stdout = function(_, data)
            self:_on_stdout(data)
        end,
        stderr = function(_, data)
            if data and cfg.mcp.debug then
                vim.schedule(function()
                    vim.notify("[codegraph mcp] " .. util.oneline(data), vim.log.levels.DEBUG)
                end)
            end
        end,
    }, function(res)
        vim.schedule(function()
            self:_on_exit(res)
        end)
    end)

    if not ok then
        self.dead = true
        return
    end
    self.handle = handle
end

--- 同步调用 (只在必须同步的地方用: 定义跳转这种一次性查询)
---@param method string
---@param params table|nil
---@param timeout integer|nil
---@return table|nil result
---@return string|nil err
function Client:request_sync(method, params, timeout)
    if not self.ready then
        -- 冷启动要开项目, 实测 4~6s; 提前说一声, 别让人以为卡死了
        vim.schedule(function()
            util.notify("codegraph MCP 首次启动 (约 4~6s), 之后是毫秒级", vim.log.levels.INFO)
        end)
    end
    if not self.ready then
        local done, ok, err = false, false, nil
        self:ensure(function(ok2, err2)
            ok, err, done = ok2, err2, true
        end)
        vim.wait(timeout or 15000, function()
            return done
        end, 10)
        if not ok then
            return nil, err or "MCP 初始化超时"
        end
    end

    local done, result, failure = false, nil, nil
    self:request(method, params, function(res, err)
        result, failure, done = res, err, true
    end, timeout)
    vim.wait((timeout or config.get().mcp.timeout or 8000) + 100, function()
        return done
    end, 5)
    if not done then
        return nil, "MCP 超时"
    end
    return result, failure
end

---@param name string
---@param args table
---@param timeout integer|nil
---@return string|nil text
---@return table|nil raw
---@return string|nil err
function Client:call_tool_sync(name, args, timeout)
    local res, err = self:request_sync("tools/call", { name = name, arguments = args }, timeout)
    if not res then
        return nil, nil, err
    end
    if res.isError then
        return nil, nil, (res.content and res.content[1] and res.content[1].text) or "MCP tool error"
    end
    local content = res.content or {}
    local texts = {}
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and block.text then
            texts[#texts + 1] = block.text
        end
    end
    return table.concat(texts, "\n"), res
end

---@param name string
---@param args table
---@param cb fun(text: string|nil, err: string|nil)
---@param timeout integer|nil
function Client:call_tool(name, args, cb, timeout)
    self:ensure(function(ok, err)
        if not ok then
            cb(nil, err)
            return
        end
        self:request("tools/call", { name = name, arguments = args }, function(res, err2)
            if not res then
                cb(nil, err2)
                return
            end
            if res.isError then
                cb(nil, (res.content and res.content[1] and res.content[1].text) or "MCP tool error")
                return
            end
            local texts = {}
            for _, block in ipairs(res.content or {}) do
                if type(block) == "table" and block.type == "text" and block.text then
                    texts[#texts + 1] = block.text
                end
            end
            cb(table.concat(texts, "\n"))
        end, timeout)
    end)
end

-- ---------------------------------------------------------------------------
-- 对外
-- ---------------------------------------------------------------------------

--- 取项目的 MCP 客户端 (同一个 root 复用)
---@param root string
---@return table
function M.client(root)
    root = vim.fs.normalize(root)
    local client = clients[root]
    if not client then
        client = setmetatable({
            root = root,
            id = 0,
            pending = {},
            buf = "",
            ready = false,
            dead = false,
        }, Client)
        clients[root] = client
    end
    return client
end

--- 关掉所有 MCP 进程 (VimLeavePre)
function M.stop_all()
    local pending = {}
    for root, client in pairs(clients) do
        pending[#pending + 1] = { root = root, client = client }
        if client.handle then
            pcall(function()
                client.handle:kill("sigterm")
            end)
            client.dead = true
        end
    end
    clients = {}

    -- `codegraph serve --mcp` 会自己 daemonize: 我们 kill 掉的只是那个马上退出的
    -- 父进程, 真正干活的是 daemon.pid 里的进程。自己拉起来的要负责收掉,
    -- 但启动前就已经存在的后台 (比如 AI 客户端那只) 不能动。
    local project = require("code_atlas.project")
    local cfg = require("code_atlas.config").get()
    local watcher = require("code_atlas.watcher")
    local uv = vim.uv or vim.loop

    for _, item in ipairs(pending) do
        local root, client = item.root, item.client
        local ctx = project.check_dir(vim.fs.normalize(root), cfg)
        if ctx then
            local owned = client and not client.had_daemon
            if owned and cfg.mcp.kill_on_exit ~= false then
                local pid = (client and client:_daemon_pid()) or nil
                if pid then
                    pcall(uv.kill, pid, "sigterm")
                end
            end
            vim.wait(200, function()
                return not watcher.daemon_state(ctx)
            end, 20)
            if not watcher.daemon_state(ctx) then
                watcher.cleanup_daemon_files(ctx)
            end
        end
    end
end

--- 已连上的服务端信息 (status/health 用)
---@param root string
---@return table|nil
function M.server_info(root)
    local client = clients[vim.fs.normalize(root)]
    if client and client.ready then
        return client.server
    end
    return nil
end

return M
