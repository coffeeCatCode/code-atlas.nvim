-- ============================================================================
-- codegraph.nvim: 小工具 (通知 / 子进程 / SQL 转义 / 路径)
-- ============================================================================

local M = {}

---@param msg string
---@param level integer|nil
function M.notify(msg, level)
    local cfg = require("codegraph.config").get()
    level = level or vim.log.levels.INFO
    if not cfg.notify and level < vim.log.levels.WARN then
        return
    end
    vim.schedule(function()
        vim.notify("[codegraph] " .. msg, level)
    end)
end

---@param name string
---@return boolean
function M.executable(name)
    return vim.fn.executable(name) == 1
end

--- 把字符串变成 SQL 字面量 (单引号内再双写单引号)
---@param s string|number|nil
---@return string
function M.sql(s)
    local str = tostring(s == nil and "" or s)
    -- NUL 会让 sqlite 命令行解析出错, 直接丢掉
    str = str:gsub("%z", "")
    return "'" .. str:gsub("'", "''") .. "'"
end

--- 转义 LIKE 里的特殊字符 (不负责加引号)
---@param s string
---@return string
function M.escape_like(s)
    return (tostring(s or ""):gsub("[\\%%_]", function(c)
        return "\\" .. c
    end))
end

--- 把用户输入转成 LIKE 的 %...% 模式 (含 SQL 引号)
---@param s string
---@return string
function M.like_contains(s)
    return M.sql("%" .. M.escape_like(s) .. "%")
end

--- 同上, 但是前缀匹配 (用于排序权重)
---@param s string
---@return string
function M.like_prefix(s)
    return M.sql(M.escape_like(s) .. "%")
end

--- 把字符串数组变成 SQL 的 IN 列表: ('a','b')
---@param list string[]
---@return string
function M.sql_list(list)
    local out = {}
    for _, v in ipairs(list or {}) do
        out[#out + 1] = M.sql(v)
    end
    return "(" .. table.concat(out, ",") .. ")"
end

--- 同步跑一个命令
---@param cmd string[]
---@param opts table|nil { cwd, stdin, timeout }
---@return table { code, stdout, stderr }
function M.run_sync(cmd, opts)
    opts = opts or {}
    local ok, obj = pcall(vim.system, cmd, {
        cwd = opts.cwd,
        stdin = opts.stdin,
        text = true,
        timeout = opts.timeout or 5000,
    })
    if not ok then
        return { code = -1, stdout = "", stderr = tostring(obj) }
    end
    local res = obj:wait()
    res.stdout = res.stdout or ""
    res.stderr = res.stderr or ""
    return res
end

--- 异步跑一个命令 (回调已 vim.schedule, 可以安全碰 buffer)
---@param cmd string[]
---@param opts table|nil { cwd, stdin, timeout }
---@param cb fun(res: table)
function M.run_async(cmd, opts, cb)
    opts = opts or {}
    local function done(res)
        res = res or {}
        res.stdout = res.stdout or ""
        res.stderr = res.stderr or ""
        vim.schedule(function()
            cb(res)
        end)
    end
    local ok, err = pcall(vim.system, cmd, {
        cwd = opts.cwd,
        stdin = opts.stdin,
        text = true,
        timeout = opts.timeout or 5000,
    }, done)
    if not ok then
        done({ code = -1, stderr = tostring(err) })
    end
end

--- 安全解码 JSON (空串/坏数据返回 nil)
--- luanil: 把 JSON null 解成 Lua nil —— 默认解成 vim.NIL, 后面稍微一索引就报
--- "attempt to index vim.NIL" (codegraph 的 signature/docstring 大量是 null)
---@param raw string|nil
---@return any
function M.decode(raw)
    if not raw or raw == "" then
        return nil
    end
    local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if not ok then
        return nil
    end
    return data
end

--- 绝对路径转项目内相对路径
---@param root string
---@param path string
---@return string
function M.relpath(root, path)
    if not path or path == "" then
        return ""
    end
    local prefix = root:gsub("/$", "") .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

---@param path string
---@return string
function M.basename(path)
    return (path:gsub("/$", ""):match("([^/]+)$")) or path
end

---@param path string
---@return string
function M.ext(path)
    return (path:match("%.([%w_]+)$") or ""):lower()
end

---@param path string
---@param exts string[]
---@return boolean
function M.is_header(path, exts)
    local e = M.ext(path)
    for _, v in ipairs(exts or {}) do
        if e == v:lower() then
            return true
        end
    end
    return false
end

--- 条目展示路径: 本层索引内的保持相对路径; 上级索引里的加"父目录名/"前缀
---@param primary_root string
---@param parent_root string
---@param file string 绝对路径
---@param fallback string|nil
---@return string
function M.display_path(primary_root, parent_root, file, fallback)
    local rel = M.relpath(primary_root, file)
    if rel ~= file then
        return rel
    end
    local prel = M.relpath(parent_root, file)
    if prel ~= file then
        return M.basename(parent_root) .. "/" .. prel
    end
    return fallback or file
end

--- 判断 path 是否在 root 之下 (都按绝对路径)
---@param root string
---@param path string
---@return boolean
function M.under(root, path)
    if not root or not path then
        return false
    end
    local prefix = root:gsub("/$", "") .. "/"
    return path:sub(1, #prefix) == prefix
end

--- 压成单行: telescope 往结果窗口写行时, 字符串里带 \n 会让 set_lines 失败,
--- 进而把结果 buffer 的行数弄乱 (报 "Invalid cursor line: out of range")。
--- codegraph 的 signature 里真的会有多行内容 (比如 #include 块), 必须洗掉。
---@param s string|nil
---@return string
function M.oneline(s)
    if not s then
        return ""
    end
    return (tostring(s):gsub("[\r\n\t]+", " "))
end

--- 截断长字符串 (按 utf8 字符宽度粗略处理)
---@param s string
---@param width integer
---@return string
function M.truncate(s, width)
    if not s then
        return ""
    end
    if vim.fn.strdisplaywidth(s) <= width then
        return s
    end
    local out = ""
    for _, c in ipairs(vim.fn.split(s, "\\zs")) do
        if vim.fn.strdisplaywidth(out .. c) > width - 1 then
            break
        end
        out = out .. c
    end
    return out .. "…"
end

---@param ts number|nil 毫秒时间戳
---@return string
function M.fmt_time(ts)
    if not ts or ts <= 0 then
        return "-"
    end
    return os.date("%Y-%m-%d %H:%M", math.floor(ts / 1000))
end

---@param bytes number|nil
---@return string
function M.fmt_size(bytes)
    if not bytes then
        return "-"
    end
    if bytes < 1024 then
        return bytes .. "B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1fKB", bytes / 1024)
    end
    return string.format("%.1fMB", bytes / 1024 / 1024)
end

---@param n number
---@return string
function M.fmt_count(n)
    if not n then
        return "-"
    end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 10000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(n)
end

return M
