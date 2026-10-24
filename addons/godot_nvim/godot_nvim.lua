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
  for _, l in ipairs(M.breakpoints[vim.api.nvim_buf_get_name(buf)] or {}) do
    if l >= 1 and l <= count then
      vim.api.nvim_buf_set_extmark(buf, bp_ns, l - 1, 0, {
        sign_text = "●",
        sign_hl_group = M.skip_breakpoints and "GodotBreakpointSkipped" or "GodotBreakpoint",
      })
    end
  end
end

function M.set_breakpoints(path, lines)
  M.breakpoints[path] = lines
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == path then
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
  vim.rpcnotify(chan, "godot_nvim_set_breakpoint", vim.api.nvim_buf_get_name(buf), line, enabled)
end

vim.api.nvim_create_user_command("GodotToggleBreakpoint", M.toggle_breakpoint,
  { desc = "Toggle a Godot debugger breakpoint on the cursor line" })

-- Signal connections and overrides ---------------------------------------
-- Like Godot's script editor, mark methods that signals in the edited scene
-- are connected to, methods that override a base class method, and warn
-- about connections to methods that don't exist. Godot pushes the lists with
-- set_connections and set_overrides.

local slot_ns = vim.api.nvim_create_namespace("godot_nvim_slots")
local missing_ns = vim.api.nvim_create_namespace("godot_nvim_missing_methods")
vim.api.nvim_set_hl(0, "GodotSignalSlot", { default = true, link = "DiagnosticOk" })
vim.api.nvim_set_hl(0, "GodotMethodOverride", { default = true, link = "DiagnosticInfo" })

-- absolute path -> list of { method, signal, source, target, missing }
M.connections = {}
-- absolute path -> { method name -> base script path or engine class }
M.overrides = {}

-- Returns method name -> 1-based line of its first "func" in [buf], and the
-- same for top-level, non-static funcs (the only ones that can override).
local function func_lines(buf)
  local any, top = {}, {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local name = l:match("^%s*func%s+([%w_]+)%s*%(") or l:match("^%s*static%s+func%s+([%w_]+)%s*%(")
    if name and not any[name] then
      any[name] = i
    end
    name = l:match("^func%s+([%w_]+)%s*%(")
    if name and not top[name] then
      top[name] = i
    end
  end
  return any, top
end

local function apply_method_signs(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, slot_ns, 0, -1)
  local name = vim.api.nvim_buf_get_name(buf)
  local conns = M.connections[name] or {}
  local overrides = M.overrides[name] or {}
  local any, top = func_lines(buf)
  local signs, diags = {}, {} -- line -> { slot = bool, override = bool }
  for _, c in ipairs(conns) do
    local l = any[c.method]
    if l then
      signs[l] = signs[l] or {}
      signs[l].slot = true
    elseif c.missing then
      table.insert(diags, {
        lnum = 0,
        col = 0,
        severity = vim.diagnostic.severity.WARN,
        source = "godot",
        message = string.format("Missing connected method '%s' for signal '%s' from node '%s' to node '%s'.",
          c.method, c.signal, c.source, c.target),
      })
    end
  end
  for method, l in pairs(top) do
    if overrides[method] then
      signs[l] = signs[l] or {}
      signs[l].override = true
    end
  end
  for l, s in pairs(signs) do
    local text, hl
    if s.slot and s.override then
      text, hl = vim.g.godot_nvim_override_slot_sign or "⇡⇠", "GodotSignalSlot"
    elseif s.slot then
      text, hl = vim.g.godot_nvim_slot_sign or "⇠", "GodotSignalSlot"
    else
      text, hl = vim.g.godot_nvim_override_sign or "⇡", "GodotMethodOverride"
    end
    vim.api.nvim_buf_set_extmark(buf, slot_ns, l - 1, 0, {
      sign_text = text,
      sign_hl_group = hl,
      priority = 100, -- below breakpoints, which win the sign column
    })
  end
  vim.diagnostic.set(missing_ns, buf, diags)
end

local function apply_to_path(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == path then
      apply_method_signs(buf)
    end
  end
end

function M.set_connections(path, conns)
  M.connections[path] = conns
  apply_to_path(path)
end

function M.set_overrides(path, methods)
  M.overrides[path] = methods
  apply_to_path(path)
end

-- Lists the signals connected to the function the cursor is in, and the
-- base class method it overrides.
function M.show_connections()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local name, top
  for i = row, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    name = l:match("^%s*func%s+([%w_]+)") or l:match("^%s*static%s+func%s+([%w_]+)")
    if name then
      top = l:match("^func%s") ~= nil
      break
    end
  end
  local out = {}
  local base = top and (M.overrides[vim.api.nvim_buf_get_name(buf)] or {})[name]
  if base then
    table.insert(out, string.format("Overrides %s.%s()", base, name))
  end
  for _, c in ipairs(M.connections[vim.api.nvim_buf_get_name(buf)] or {}) do
    if c.method == name then
      table.insert(out, string.format("%s.%s -> %s.%s()", c.source, c.signal, c.target, c.method))
    end
  end
  if #out == 0 then
    vim.notify(name and ("No signals connected to " .. name .. "()") or "Not inside a function")
  else
    vim.notify(table.concat(out, "\n"))
  end
end

vim.api.nvim_create_user_command("GodotConnections", M.show_connections,
  { desc = "Show the Godot signals connected to, and the method overridden by, the function under the cursor" })

vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = group,
  callback = function(ev)
    local name = vim.api.nvim_buf_get_name(ev.buf)
    if M.connections[name] or M.overrides[name] then
      apply_method_signs(ev.buf)
    end
  end,
})

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
  group = group,
  callback = function(ev)
    apply_breakpoints(ev.buf)
    apply_method_signs(ev.buf)
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
    vim.rpcnotify(chan, "godot_nvim_saved", vim.api.nvim_buf_get_name(ev.buf), M.buf_breakpoints(ev.buf))
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(ev)
    vim.rpcnotify(chan, "godot_nvim_buf_enter", vim.api.nvim_buf_get_name(ev.buf))
  end,
})
-- A file Godot opened before this script loaded entered without us.
if vim.api.nvim_buf_get_name(0) ~= "" then
  vim.rpcnotify(chan, "godot_nvim_buf_enter", vim.api.nvim_buf_get_name(0))
end

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

