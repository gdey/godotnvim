-- Stands in for a user config. With --embed, Neovim sources it only after
-- the UI attaches, so after the plugin's Lua has loaded. Like lazy.nvim's
-- default rtp reset, it drops what was added to 'runtimepath' before it, and
-- it picks its own colorscheme.
vim.opt.runtimepath = { vim.fn.stdpath("config"), vim.env.VIMRUNTIME }
vim.cmd.colorscheme("habamax")
