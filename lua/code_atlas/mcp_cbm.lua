-- ============================================================================
-- code-atlas.nvim: codebase-memory-mcp 的 MCP 客户端 (stdio, 换行 JSON)
--
-- 和 codegraph 的 MCP 客户端分开的原因:
--   - codegraph 每个项目一个 serve 进程, 有 daemon.sock/pid 要清理;
--   - codebase-memory-mcp 是全局一个进程 (项目名作为参数), 冷启动 ~1s,
--     热态 tools/call ~10ms, 由 nvim 负责拉起/杀掉。
--
-- cwd 很重要: 进程的 cwd 决定 codebase-memory 自动 index/watch 哪个项目。
-- 进项目时用 ctx.root 拉起, 它就会自动建索引并在后台增量同步; 切项目时重启。
-- ============================================================================

local M = {}

local config = require("code_atlas.config")
local util = require("code_atlas.util")

local state = {
    proc = nil,
    ready = false,
    initializing = false,
    dead = false,
    cwd = nil,
    buf = "",
    next_id = 1,
    pending = {},
    waiters = {},
}

local function cfg()
    return config.get().codebase_memory or {}
end

local function reset()
    state.proc = nil
    state.ready = false
    state.initializing = false
    state.dead = false
    state.cwd = nil
    state.buf = ""
    state.pending = {}
    state.waiters = {}
end

local function dispatch(msg)
    local id = msg.id
    if id == nil then
        return
    end
    local slot = state.pending[id]
    if not slot then
        return
    end
    slot.result = msg
    slot.done = true
    state.pending[id] = nil
    if slot.on_done then
        vim.schedule(function()
            slot.on_done(msg)
        end)
    end
end

local function on_stdout(_, data)
    if not data or data == "" then
        return
    end
    state.buf = state.buf .. data
    while true do
        local nl = state.buf:find("\n", 1, true)
        if not nl then
            break
        end
        local line = state.buf:sub(1, nl - 1)
        state.buf = state.buf:sub(nl + 1)
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if ok and type(msg) == "table" then
                dispatch(msg)
            end
        end
    end
end

local function on_exit()
    state.ready = false
    state.initializing = false
    state.dead = true
    state.proc = nil
    for id, slot in pairs(state.pending) do
        slot.result = { error = { message = "codebase-memory-mcp 进程退出" } }
        slot.done = true
        state.pending[id] = nil
    end
end

local function write(msg)
    if not state.proc then
        return false
    end
    local ok, encoded = pcall(vim.json.encode, msg)
    if not ok then
        return false
    end
    return pcall(function()
        state.proc:write(encoded .. "\n")
    end)
end

local function request(method, params, timeout)
    if not state.proc then
        return nil, "codebase-memory-mcp 未启动"
    end
    local id = state.next_id
    state.next_id = id + 1
    local slot = { done = false }
    state.pending[id] = slot
    if not write({ jsonrpc = "2.0", id = id, method = method, params = params }) then
        state.pending[id] = nil
        return nil, "写入 MCP 进程失败"
    end
    vim.wait(timeout or cfg().timeout or 2500, function()
        return slot.done
    end, 5)
    state.pending[id] = nil
    if not slot.done then
        return nil, "codebase-memory-mcp 响应超时"
    end
    local msg = slot.result or {}
    if msg.error then
        return nil, msg.error.message or "MCP error"
    end
    return msg.result
end

local function spawn(cwd)
    local c = cfg()
    if c.enabled == false then
        return false, "disabled"
    end
    local cmd = c.cmd or { "codebase-memory-mcp" }
    if not util.executable(cmd[1]) then
        return false, "not installed"
    end
    state.cwd = cwd and vim.fs.normalize(cwd) or vim.fs.normalize(vim.fn.getcwd())
    local ok = pcall(function()
        state.proc = vim.system(cmd, {
            cwd = state.cwd,
            stdin = true,
            stdout = on_stdout,
            stderr = function() end,
            text = true,
        }, on_exit)
    end)
    if not ok or not state.proc then
        reset()
        return false, "spawn failed"
    end
    return true
end

local function fail_waiters()
    local finished = state.waiters
    state.waiters = {}
    for _, w in ipairs(finished) do
        pcall(w, false)
    end
end

--- 后台启动 (不阻塞), 初始化完成后回调
---@param cb fun(ok: boolean)|nil
---@param cwd string|nil 进程工作目录 (决定自动 index/watch 的项目)
function M.start(cb, cwd)
    cwd = cwd and vim.fs.normalize(cwd) or nil
    if state.ready then
        if not cwd or cwd == state.cwd then
            if cb then
                cb(true)
            end
            return
        end
        -- 换项目必须重启, 新 cwd 才会触发 auto_index / auto_watch
        M.stop()
    end
    if cb then
        state.waiters[#state.waiters + 1] = cb
    end
    if state.initializing then
        return
    end

    state.initializing = true
    state.dead = false
    local ok = spawn(cwd)
    if not ok then
        state.initializing = false
        fail_waiters()
        return
    end

    local id = state.next_id
    state.next_id = id + 1
    local slot = { done = false }
    slot.on_done = function(msg)
        local finished = state.waiters
        state.waiters = {}
        state.initializing = false
        if msg and msg.result then
            write({ jsonrpc = "2.0", method = "notifications/initialized", params = {} })
            state.ready = true
        else
            pcall(function()
                state.proc:kill(9)
            end)
            reset()
        end
        for _, w in ipairs(finished) do
            pcall(w, state.ready)
        end
    end
    state.pending[id] = slot
    if not write({
        jsonrpc = "2.0",
        id = id,
        method = "initialize",
        params = {
            protocolVersion = "2024-11-05",
            capabilities = {},
            clientInfo = { name = "code-atlas.nvim", version = "0.1.0" },
        },
    }) then
        state.pending[id] = nil
        state.initializing = false
        pcall(function()
            state.proc:kill(9)
        end)
        reset()
    end
end

--- 同步启动/复用 (gd 这类不能异步的路径用)
---@param timeout integer|nil
---@param cwd string|nil
---@return boolean
function M.ensure(timeout, cwd)
    cwd = cwd and vim.fs.normalize(cwd) or nil
    if state.ready then
        if not cwd or cwd == state.cwd then
            return true
        end
        M.stop()
    end
    if state.initializing then
        vim.wait(timeout or 6000, function()
            return state.ready or state.dead
        end, 10)
        return state.ready
    end

    state.initializing = true
    state.dead = false
    local ok = spawn(cwd)
    if not ok then
        state.initializing = false
        return false
    end

    local res = request("initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "code-atlas.nvim", version = "0.1.0" },
    }, timeout or 6000)
    if not res then
        pcall(function()
            state.proc:kill(9)
        end)
        reset()
        return false
    end

    write({ jsonrpc = "2.0", method = "notifications/initialized", params = {} })
    state.ready = true
    state.initializing = false
    return true
end

--- 调用一个 MCP 工具, 返回解析后的结构化结果
---@param tool string
---@param args table
---@param timeout integer|nil
---@param cwd string|nil
---@return table|nil data
---@return string|nil err
function M.call(tool, args, timeout, cwd)
    if not M.ensure(timeout, cwd) then
        return nil, "codebase-memory-mcp 不可用"
    end
    local res, err = request("tools/call", { name = tool, arguments = args }, timeout)
    if not res then
        return nil, err
    end
    return M.parse(res)
end

--- 解析 tools/call 的 result: 优先 structuredContent, 否则解 content[].text
---@param res table
---@return table|nil data
---@return string|nil err
function M.parse(res)
    if type(res) ~= "table" then
        return nil, "空结果"
    end
    if res.structuredContent then
        return res.structuredContent
    end
    local text = nil
    for _, c in ipairs(res.content or {}) do
        if c.type == "text" and c.text then
            text = (text or "") .. c.text
        end
    end
    if not text or text == "" then
        return nil, "空结果"
    end
    local ok, obj = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if ok and type(obj) == "table" then
        return obj
    end
    return { text = text }
end

---@return boolean
function M.ready()
    return state.ready and not state.dead
end

---@return string|nil
function M.cwd()
    return state.cwd
end

function M.stop()
    if state.proc then
        pcall(function()
            state.proc:kill(9)
        end)
    end
    reset()
end

return M
