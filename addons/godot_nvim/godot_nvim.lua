-- Neovim-side helpers for the godot_nvim plugin. Loaded with nvim_exec_lua,
-- which passes the Godot channel id and an options table:
--   root: project folder
--   lsp:  { host = ..., port = ... } to attach Godot's GDScript language
--         server to gdscript buffers, or nil to leave LSP to the user's config
local chan, opts = ...
opts = opts or {}
local M = {}
_G.godot_nvim = M

local group = vim.api.nvim_create_augroup("godot_nvim", { clear = true })

-- Buffer names with forward slashes, as Godot writes paths (matters on Windows).
local function bufname(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name == "" and name or vim.fs.normalize(name)
end

-- Unsaved buffers, so Godot can offer to save them when it closes.
local function modified_files()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = bufname(buf)
    if name ~= "" and vim.bo[buf].buflisted and vim.bo[buf].modified then
      table.insert(out, name)
    end
  end
  return out
end

vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost", "BufDelete" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      vim.rpcnotify(chan, "godot_nvim_modified", modified_files())
    end)
  end,
})

-- Quitting -----------------------------------------------------------------
-- Neovim lives as long as the Godot editor, so on the last window :q acts
-- like :bd and :wq / :x like :w + :bd. QuitPre runs before Neovim decides
-- whether the window is the last one: we open a second window showing
-- another buffer (or one reusable empty placeholder), let the quit close the
-- original, then delete the quit buffer.

local placeholder

local function normal_wins()
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
end

-- The buffer to show once [buf] is gone: the alternate file, any other
-- listed buffer, or the placeholder.
local function next_buffer(buf)
  local alt = vim.fn.bufnr("#")
  if alt > 0 and alt ~= buf and vim.bo[alt].buflisted then
    return alt
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.bo[b].buflisted and vim.api.nvim_buf_is_loaded(b) then
      return b
    end
  end
  if not (placeholder and vim.api.nvim_buf_is_valid(placeholder)) then
    placeholder = vim.api.nvim_create_buf(false, true)
  end
  return placeholder
end

vim.api.nvim_create_autocmd("QuitPre", {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return
    end
    if #vim.api.nvim_list_tabpages() > 1 or #normal_wins() > 1 then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    local nb = next_buffer(buf)
    vim.cmd("rightbelow vsplit")
    local spare = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(spare, nb)
    vim.api.nvim_set_current_win(win)
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        -- Quit refused (E37, unsaved changes): undo.
        if vim.api.nvim_win_is_valid(spare) then
          vim.api.nvim_win_close(spare, true)
        end
        return
      end
      if buf ~= placeholder and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
        vim.api.nvim_buf_delete(buf, {})
      end
    end)
  end,
})

-- Breakpoints --------------------------------------------------------------
-- Godot owns the breakpoint list; it pushes it here with set_breakpoints and
-- we draw it as signs. Signs are extmarks, so they follow edits; on save we
-- send their new lines back so Godot's list matches the file on disk.

local bp_ns = vim.api.nvim_create_namespace("godot_nvim_breakpoints")
vim.api.nvim_set_hl(0, "GodotBreakpoint", { default = true, link = "DiagnosticError" })
-- Used while the debugger's "Skip Breakpoints" is on.
vim.api.nvim_set_hl(0, "GodotBreakpointSkipped", { default = true, link = "Comment" })

-- absolute path -> sorted 1-based line numbers
M.breakpoints = {}
M.skip_breakpoints = false

local function apply_breakpoints(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, bp_ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  for _, l in ipairs(M.breakpoints[bufname(buf)] or {}) do
    if l >= 1 and l <= count then
      vim.api.nvim_buf_set_extmark(buf, bp_ns, l - 1, 0, {
        sign_text = "●",
        sign_hl_group = M.skip_breakpoints and "GodotBreakpointSkipped" or "GodotBreakpoint",
      })
    end
  end
end

function M.set_breakpoints(path, lines)
  path = vim.fs.normalize(path)
  M.breakpoints[path] = lines
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if bufname(buf) == path then
      apply_breakpoints(buf)
    end
  end
end

function M.set_skip_breakpoints(skip)
  M.skip_breakpoints = skip
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    apply_breakpoints(buf)
  end
end

-- Current 1-based breakpoint lines of [buf], as moved by edits.
function M.buf_breakpoints(buf)
  local lines, seen = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, bp_ns, 0, -1, {})) do
    local l = m[2] + 1
    if not seen[l] then
      seen[l] = true
      table.insert(lines, l)
    end
  end
  table.sort(lines)
  return lines
end

function M.toggle_breakpoint()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local enabled = not vim.tbl_contains(M.buf_breakpoints(buf), line)
  vim.rpcnotify(chan, "godot_nvim_set_breakpoint", bufname(buf), line, enabled)
end

vim.api.nvim_create_user_command("GodotToggleBreakpoint", M.toggle_breakpoint,
  { desc = "Toggle a Godot debugger breakpoint on the cursor line" })

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
  group = group,
  callback = function(ev)
    apply_breakpoints(ev.buf)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "gdscript",
  callback = function(ev)
    -- F9 toggles breakpoints in Godot's editor too; keep the user's own F9.
    if vim.fn.maparg("<F9>", "n") == "" then
      vim.keymap.set("n", "<F9>", M.toggle_breakpoint, { buffer = ev.buf, desc = "Toggle Godot breakpoint" })
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(ev)
    vim.rpcnotify(chan, "godot_nvim_saved", bufname(ev.buf), M.buf_breakpoints(ev.buf))
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(ev)
    vim.rpcnotify(chan, "godot_nvim_buf_enter", bufname(ev.buf))
  end,
})

-- Attaches Godot's language server to [buf], unless the user's own config
-- already handles gdscript. Scheduled so that config's FileType handlers
-- (vim.lsp.enable, lspconfig) run first and we can see their client.
function M.lsp_attach(buf)
  if not opts.lsp then
    return
  end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.lsp.is_enabled and vim.lsp.is_enabled("gdscript") then
      return
    end
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    if #get_clients({ bufnr = buf, name = "gdscript" }) > 0 then
      return
    end
    vim.lsp.start({
      name = "gdscript",
      cmd = vim.lsp.rpc.connect(opts.lsp.host, opts.lsp.port),
      root_dir = opts.root,
      filetypes = { "gdscript" },
    }, { bufnr = buf })
  end)
end

if opts.lsp then
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "gdscript",
    callback = function(ev)
      M.lsp_attach(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "gdscript" then
      M.lsp_attach(buf)
    end
  end
end

M.pending = nil

-- Queues a click at the screen cell and then drop(), so the text lands
-- where the mouse released the drag.
function M.queue_drop(kind, text, row, col)
  M.pending = { kind = kind, text = text }
  vim.api.nvim_input_mouse("left", "press", "", 0, row, col)
  vim.api.nvim_input_mouse("left", "release", "", 0, row, col)
  vim.api.nvim_input("<Cmd>lua godot_nvim.drop()<CR>")
end

-- Inserts M.pending at the last mouse position. kind "lines" inserts whole
-- lines above the line under the mouse; kind "text" inserts at the cell.
function M.drop()
  local p = M.pending
  -- Attaches Godot's language server to [buf], unless the user's own config
-- already handles gdscript. Scheduled so that config's FileType handlers
-- (vim.lsp.enable, lspconfig) run first and we can see their client.
function M.lsp_attach(buf)
  if not opts.lsp then
    return
  end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.lsp.is_enabled and vim.lsp.is_enabled("gdscript") then
      return
    end
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    if #get_clients({ bufnr = buf, name = "gdscript" }) > 0 then
      return
    end
    vim.lsp.start({
      name = "gdscript",
      cmd = vim.lsp.rpc.connect(opts.lsp.host, opts.lsp.port),
      root_dir = opts.root,
      filetypes = { "gdscript" },
    }, { bufnr = buf })
  end)
end

if opts.lsp then
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "gdscript",
    callback = function(ev)
      M.lsp_attach(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "gdscript" then
      M.lsp_attach(buf)
    end
  end
end

M.pending = nil
  if not p then
    return
  end
  local pos = vim.fn.getmousepos()
  local win = pos.winid ~= 0 and pos.winid or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local cur = vim.api.nvim_win_get_cursor(win)
  local line = pos.line > 0 and pos.line or cur[1]
  line = math.min(line, vim.api.nvim_buf_line_count(buf))
  if p.kind == "lines" then
    local lines = vim.split(p.text, "\n", { trimempty = true })
    local indent = vim.fn.indent(line)
    local prefix = string.rep(vim.bo[buf].expandtab and " " or "\t",
      vim.bo[buf].expandtab and indent or math.floor(indent / math.max(vim.bo[buf].tabstop, 1)))
    if vim.trim(vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or "") == "" then
      prefix = ""
    end
    for i, l in ipairs(lines) do
      lines[i] = prefix .. l
    end
    vim.api.nvim_buf_set_lines(buf, line - 1, line - 1, false, lines)
    vim.api.nvim_win_set_cursor(win, { line + #lines - 1, #lines[#lines] })
  else
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    local col = pos.line > 0 and pos.column - 1 or cur[2]
    col = math.max(0, math.min(col, #text))
    vim.api.nvim_buf_set_text(buf, line - 1, col, line - 1, col, { p.text })
    vim.api.nvim_win_set_cursor(win, { line, col + #p.text })
  end
end

