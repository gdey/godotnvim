-- Loads one colorscheme and writes its resolved highlight groups as JSON.
-- Run by vim2godot: VIM2GODOT_SCHEME names the scheme, VIM2GODOT_OUT the file.
local name = vim.env.VIM2GODOT_SCHEME
local out = vim.env.VIM2GODOT_OUT

local function fail(msg)
  io.stderr:write(msg .. "\n")
  vim.cmd("cquit 1")
end

local ok, err = pcall(vim.cmd.colorscheme, name)
if not ok then
  fail(tostring(err))
end

local function hex(n)
  return n and string.format("%06x", n) or nil
end

local groups = {}
for group in pairs(vim.api.nvim_get_hl(0, {})) do
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  -- A group with nothing set would encode as [] rather than {}.
  if hl.fg or hl.bg or hl.reverse then
    groups[group] = {
      fg = hex(hl.fg),
      bg = hex(hl.bg),
      reverse = hl.reverse or nil,
    }
  end
end

local f = io.open(out, "w")
if not f then
  fail("cannot write " .. out)
end
f:write(vim.json.encode({ background = vim.o.background, groups = groups }))
f:close()
vim.cmd("qall!")
