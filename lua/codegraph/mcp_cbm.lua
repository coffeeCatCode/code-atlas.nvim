-- ============================================================================
-- codegraph.nvim: codebase-memory-mcp 的 MCP 客户端 (stdio, 换行 JSON)
--
-- 和 codegraph 的 MCP 客户端分开的原因:
--   - codegraph 每个项目一个 serve 进程, 有 daemon.sock/pid 要清理;
--   - codebase-memory-mcp 是全局一个进程 (项目名作为参数), 冷启动 ~1s,
--     热态 tools/call ~10ms, 由 nvim 负责拉起/杀掉。
-- ============================================================================

local M = {}

local config = require("codegraph.config")
local util = require("codegraph.util")

local state = {
    proc = nil,
    ready = false,
    initializing = false,
    dead = false,
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
    state.buf = ""
    state.pending = {}
    state.waiters = {}
end

local function dispatch(msg)
    local id = msg.id
    if id ~= nil then
        local slot = state.pending[id]
        if slot then
            slot.result = msg
            slot.done = true
            state.pending[id] = nil
            if slot.on_done then
                vim.schedule(function()
                    slot.on_done(msg)
                end)
            end
        end
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

--- 启动并 initialize (幂等)
---@param timeout integer|nil
---@return boolean
--- 后台启动 (不阻塞): 初始化完成后回调
---@param cb fun(ok: boolean)|nil
function M.start(cb)
    if state.ready then
        if cb then
            cb(true)
        end
        return
    end
    if cb then
        state.waiters[#state.waiters + 1] = cb
    end
    if state.initializing then
        return
    end

    local c = cfg()
    local function fail_waiters()
        local finished = state.waiters
        state.waiters = {}
        for _, w in ipairs(finished) do
            pcall(w, false)
        end
    end
    if c.enabled == false then
        fail_waiters()
        return
    end
    local cmd = c.cmd or { "codebase-memory-mcp" }
    if not util.executable(cmd[1]) then
        fail_waiters()
        return
    end

    state.initializing = true
    state.dead = false
    local ok = pcall(function()
        state.proc = vim.system(cmd, {
            stdin = true,
            stdout = on_stdout,
            stderr = function() end,
            text = true,
        }, on_exit)
    end)
    if not ok or not state.proc then
        state.initializing = false
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
            clientInfo = { name = "codegraph.nvim", version = "0.1.0" },
        },
    }) then
        state.pending[id] = nil
        state.initializing = false
        pcall(function()
            state.proc:kill(9)
        end)
        reset()
        return
    end
end

function M.ensure(timeout)
    if state.ready then
        return true
    end
    if state.initializing then
        vim.wait(timeout or 6000, function()
            return state.ready or state.dead
        end, 10)
        return state.ready
    end

    local c = cfg()
    if c.enabled == false then
        return false
    end
    local cmd = c.cmd or { "codebase-memory-mcp" }
    if not util.executable(cmd[1]) then
        return false
    end

    state.initializing = true
    state.dead = false
    local ok = pcall(function()
        state.proc = vim.system(cmd, {
            stdin = true,
            stdout = on_stdout,
            stderr = function() end,
            text = true,
        }, on_exit)
    end)
    if not ok or not state.proc then
        reset()
        return false
    end

    local res = request("initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "codegraph.nvim", version = "0.1.0" },
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
---@return table|nil data
---@return string|nil err
function M.call(tool, args, timeout)
    if not M.ensure(timeout) then
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

function M.stop()
    if state.proc then
        pcall(function()
            state.proc:kill(9)
        end)
    end
    reset()
end

return M
