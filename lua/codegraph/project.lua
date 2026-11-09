-- ============================================================================
-- codegraph.nvim: 项目定位
-- 规则: 从当前文件所在目录开始, 逐级向上找 <dir>/.codegraph/codegraph.db,
--       找到就用它; 一直找到 / 都没有, 就说明这个项目没建过索引 (不启用)。
-- 注: 家目录下的 ~/.codegraph 往往只有守护进程的 state 而没有 db,
--     这里以"db 是不是真的 SQLite 文件"为准, 空壳目录会被跳过继续向上。
-- ============================================================================

local config = require("codegraph.config")

local M = {}

-- sqlite 文件头: "SQLite format 3\0"
local SQLITE_MAGIC = "SQLite format 3\0"

-- 文件头缓存: key = path:mtime:size, 避免每次找根都读 16 字节
local header_cache = {}

---@param path string
---@param st table
---@return boolean
local function is_sqlite_db(path, st)
    local mtime = st.mtime and st.mtime.sec or 0
    local key = string.format("%s:%d:%d", path, mtime, st.size or 0)
    local cached = header_cache[key]
    if cached ~= nil then
        return cached
    end
    local ok = false
    local f = io.open(path, "rb")
    if f then
        local magic = f:read(16)
        f:close()
        ok = magic == SQLITE_MAGIC
    end
    header_cache[key] = ok
    return ok
end

--- 当前上下文应该从哪个目录开始向上找:
--- 有文件就用文件所在目录 (在子目录里开 nvim / 用绝对路径开文件都适用), 否则用 cwd
---@param path string|nil
---@return string
function M.start_dir(path)
    local name = path
    if not name or name == "" then
        name = vim.api.nvim_buf_get_name(0)
    end
    -- URI 类 buffer (health://, fugitive://, ...) 不是文件路径, 按 cwd 处理
    if name and name:match("^%a[%w+.-]*://") then
        name = nil
    end
    if name and name ~= "" then
        local abs = vim.fs.normalize(name)
        local st = vim.uv.fs_stat(abs)
        if st and st.type == "file" then
            return vim.fs.normalize(vim.fn.fnamemodify(abs, ":p:h"))
        end
        -- 新文件还没落盘: 只要父目录存在就从父目录找
        local dir = vim.fs.dirname(abs)
        if dir and dir ~= "" and vim.uv.fs_stat(dir) then
            return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
        end
    end
    return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))
end

--- 检查某一层目录是不是索引根
---@param dir string
---@param cfg table
---@return table|nil
function M.check_dir(dir, cfg)
    for _, skip in ipairs(cfg.project.skip_roots or {}) do
        if skip ~= "" and vim.fs.normalize(skip) == dir then
            return nil
        end
    end

    local index_dir = vim.fs.joinpath(dir, cfg.project.index_dir)
    local db = vim.fs.joinpath(index_dir, cfg.project.db_file)
    local st = vim.uv.fs_stat(db)
    if not st or st.type ~= "file" or st.size < 512 then
        return nil
    end
    if not is_sqlite_db(db, st) then
        return nil
    end

    return {
        root = dir,
        index_dir = index_dir,
        db = db,
        db_size = st.size,
        db_mtime = st.mtime and (st.mtime.sec * 1000) or 0,
    }
end

--- 从 path 所在目录向上找索引根
---@param start string|nil
---@return table|nil ctx { root, index_dir, db, db_size, db_mtime }
function M.find(start)
    local cfg = config.get()
    local dir = vim.fs.normalize(start or M.start_dir())
    local depth = 0
    local max_depth = cfg.project.max_depth or 0

    while dir and dir ~= "" do
        local ctx = M.check_dir(dir, cfg)
        if ctx then
            return ctx
        end
        local parent = vim.fs.dirname(dir)
        if not parent or parent == dir then
            break
        end
        dir = parent
        depth = depth + 1
        if max_depth > 0 and depth >= max_depth then
            break
        end
    end
    return nil
end

--- 从 start 向上收集"所有"索引 (最近的在前), 用于多级 .codegraph:
--- 本层索引里没有的符号, 还可以去上级索引里找
---@param start string|nil
---@return table[]
function M.find_all(start)
    local cfg = config.get()
    local out = {}

    if M.override then
        local ctx = M.check_dir(vim.fs.normalize(M.override), cfg)
        if ctx then
            ctx.override = true
            out[1] = ctx
        end
        return out
    end

    local dir = vim.fs.normalize(start or M.start_dir())
    local depth = 0
    local max_depth = cfg.project.max_depth or 0

    while dir and dir ~= "" do
        local ctx = M.check_dir(dir, cfg)
        if ctx then
            out[#out + 1] = ctx
        end
        local parent = vim.fs.dirname(dir)
        if not parent or parent == dir then
            break
        end
        dir = parent
        depth = depth + 1
        if max_depth > 0 and depth >= max_depth then
            break
        end
    end
    return out
end

-- 手动指定的项目根 (:CodeGraph root /path)
M.override = nil

---@param path string|nil
function M.set_override(path)
    if not path or path == "" then
        M.override = nil
        return
    end
    M.override = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---@param path string|nil
---@return table|nil
function M.context(path)
    local cfg = config.get()
    if M.override then
        local ctx = M.check_dir(vim.fs.normalize(M.override), cfg)
        if ctx then
            ctx.override = true
            return ctx
        end
    end
    return M.find(path and M.start_dir(path) or nil)
end

--- 给 watcher 用: 这个文件属于哪个索引
---@param file string
---@return table|nil
function M.context_for_file(file)
    if not file or file == "" then
        return nil
    end
    local ctx = M.context(file)
    if ctx and require("codegraph.util").under(ctx.root, file) then
        return ctx
    end
    return nil
end

--- 索引里是否包含这个文件 (存的是相对路径)
---@param ctx table
---@param file string
---@return string|nil rel
function M.rel_in_index(ctx, file)
    local rel = require("codegraph.util").relpath(ctx.root, file)
    if rel == file then
        return nil
    end
    return rel
end

--- 清缓存 (重建索引 / 切换项目后调用)
function M.clear()
    header_cache = {}
end

return M
