-- 最小启动: 只为了在 headless 下测插件本体, 不加载用户的整套配置
-- 用法: cd <某个建过索引的项目> && nvim --headless -u <本文件> -c "luafile <selftest>" -c "qa!"

local this = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this, ":p:h:h")

vim.opt.rtp:prepend(plugin_root)
vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"
vim.o.termguicolors = true

-- 测试 picker 需要 telescope + plenary; 用户配置里它们是 lazy.nvim 管理的
for _, name in ipairs({ "plenary.nvim", "telescope.nvim" }) do
    local dir = vim.fn.stdpath("data") .. "/lazy/" .. name
    if vim.uv.fs_stat(dir) then
        vim.opt.rtp:append(dir)
    end
end

require("codegraph").setup({
    notify = true,
})
