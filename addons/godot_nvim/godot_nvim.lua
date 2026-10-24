-- Neovim-side helpers for the godot_nvim plugin. Loaded with nvim_exec_lua,
-- which passes the Godot channel id and an options table:
--   root: project folder
--   lsp:  { host = ..., port = ... } to attach Godot's GDScript language
--         server to gdscript buffers, or nil to leave LSP to the user's config
--   runtime: folder with this plugin's runtime files (colors/godot.lua)
local chan, opts = ...
opts = opts or {}
local M = {}
_G.godot_nvim = M

local group = vim.api.nvim_create_augroup("godot_nvim", { clear = true })

-- With --embed, Neovim sources the user's config only once the UI attaches,
-- which is after this script runs. Configs that reset 'runtimepath' (lazy.nvim
-- does by default) would drop our folder, so add it again on VimEnter.
local function add_runtime()
  if opts.runtime and not vim.tbl_contains(vim.opt.runtimepath:get(), opts.runtime) then
    vim.opt.runtimepath:append(opts.runtime)
  end
end
add_runtime()
vim.api.nvim_create_autocmd("VimEnter", { group = group, callback = add_runtime })

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
local function define_breakpoint_highlights()
  vim.api.nvim_set_hl(0, "GodotBreakpoint", { default = true, link = "DiagnosticError" })
  -- Used while the debugger's "Skip Breakpoints" is on.
  vim.api.nvim_set_hl(0, "GodotBreakpointSkipped", { default = true, link = "Comment" })
end
define_breakpoint_highlights()
-- A colorscheme clears highlights; bring ours back.
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_breakpoint_highlights })

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

-- Toggles the breakpoint on [line] of [buf], by default the cursor line.
function M.toggle_breakpoint(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local enabled = not vim.tbl_contains(M.buf_breakpoints(buf), line)
  vim.rpcnotify(chan, "godot_nvim_set_breakpoint", vim.api.nvim_buf_get_name(buf), line, enabled)
end

-- Expr mapping for <2-LeftMouse>: a double-click in the gutter (sign,
-- number and fold columns) toggles the breakpoint on that line; anywhere
-- else keeps the usual double-click.
function M.gutter_double_click()
  local pos = vim.fn.getmousepos()
  local info = pos.winid ~= 0 and vim.fn.getwininfo(pos.winid)[1]
  if info and pos.line > 0 and pos.wincol <= info.textoff then
    M.toggle_breakpoint(vim.api.nvim_win_get_buf(pos.winid), pos.line)
    return ""
  end
  return "<2-LeftMouse>"
end

vim.api.nvim_create_user_command("GodotToggleBreakpoint", function() M.toggle_breakpoint() end,
  { desc = "Toggle a Godot debugger breakpoint on the cursor line" })

-- Running -------------------------------------------------------------------
-- The editor's run bar, from Neovim. Godot's own shortcuts for these (F5..F8,
-- or Cmd+B, Cmd+R, ... on macOS) pass through the view to the editor too.

local function run(action, arg)
  vim.rpcnotify(chan, "godot_nvim_run", action, arg or "")
end

vim.api.nvim_create_user_command("GodotRun", function() run("project") end,
  { desc = "Run the Godot project" })
vim.api.nvim_create_user_command("GodotRunCurrent", function() run("current") end,
  { desc = "Run the scene being edited in Godot" })
vim.api.nvim_create_user_command("GodotRunScene", function(o)
  run("scene", o.args ~= "" and vim.fn.fnamemodify(o.args, ":p") or nil)
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(f)
      return f:match("/$") or f:match("%.t?scn$")
    end, vim.fn.getcompletion(lead, "file"))
  end,
  desc = "Run a Godot scene (pick one when no file is given)",
})
vim.api.nvim_create_user_command("GodotPause", function() run("pause") end,
  { desc = "Pause or resume the running Godot project" })
vim.api.nvim_create_user_command("GodotStop", function() run("stop") end,
  { desc = "Stop the running Godot project" })

-- Godot theme ---------------------------------------------------------------
-- The "godot" colorscheme (colors/godot.lua) is built from the script
-- editor's colors, which Godot pushes with set_theme: keys are the settings
-- below text_editor/theme/highlighting/, values "#rrggbb".

M.theme = nil

function M.set_theme(colors)
  M.theme = colors
  if vim.v.vim_did_enter == 0 then
    -- Apply after the user's config, so its colorscheme doesn't replace ours.
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function()
        M.set_theme(M.theme)
      end,
    })
    return
  end
  add_runtime()
  if not pcall(vim.cmd.colorscheme, "godot") then
    M.apply_theme()
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "godot", modeline = false })
  end
end

-- Called by colors/godot.lua.
function M.apply_theme()
  local c = M.theme
  if not c then
    return
  end
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end
  vim.o.background = c.dark and "dark" or "light"
  vim.g.colors_name = "godot"

  local g = function(k)
    return c["gdscript/" .. k]
  end
  local groups = {
    -- Editor UI
    Normal = { fg = c.text_color, bg = c.background_color },
    NormalNC = { link = "Normal" },
    NormalFloat = { fg = c.completion_font_color, bg = c.completion_background_color },
    FloatBorder = { fg = c.code_folding_color, bg = c.completion_background_color },
    Pmenu = { fg = c.completion_font_color, bg = c.completion_background_color },
    PmenuSel = { fg = c.text_color, bg = c.completion_selected_color },
    PmenuSbar = { bg = c.completion_background_color },
    PmenuThumb = { bg = c.completion_scroll_color },
    PmenuMatch = { fg = c.function_color, bold = true },
    Cursor = { fg = c.caret_background_color, bg = c.caret_color },
    CursorLine = { bg = c.current_line_color },
    CursorColumn = { bg = c.current_line_color },
    ColorColumn = { bg = c.line_length_guideline_color },
    LineNr = { fg = c.line_number_color },
    CursorLineNr = { fg = c.text_color, bold = true },
    SignColumn = { bg = c.background_color },
    FoldColumn = { fg = c.code_folding_color },
    Folded = { fg = c.code_folding_color, bg = c.folded_code_region_color },
    Visual = { bg = c.selection_color },
    Search = { bg = c.search_result_border_color },
    CurSearch = { bg = c.selection_color, bold = true },
    IncSearch = { link = "CurSearch" },
    MatchParen = { bg = c.word_highlighted_color, bold = true },
    NonText = { fg = c.code_folding_color },
    EndOfBuffer = { fg = c.code_folding_color },
    Whitespace = { fg = c.line_length_guideline_color },
    WinSeparator = { fg = c.line_length_guideline_color },
    StatusLine = { fg = c.text_color, bg = c.completion_background_color },
    StatusLineNC = { fg = c.line_number_color, bg = c.completion_background_color },
    TabLine = { fg = c.line_number_color, bg = c.completion_background_color },
    TabLineFill = { bg = c.completion_background_color },
    TabLineSel = { fg = c.text_color, bg = c.background_color, bold = true },
    Title = { fg = c.function_color, bold = true },
    Directory = { fg = c.function_color },
    ErrorMsg = { fg = c.brace_mismatch_color },
    WarningMsg = { fg = c["comment_markers/warning_color"] },
    MoreMsg = { fg = c.base_type_color },
    Question = { fg = c.base_type_color },
    -- Syntax
    Comment = { fg = c.comment_color },
    SpecialComment = { fg = c.doc_comment_color },
    String = { fg = c.string_color },
    Character = { link = "String" },
    Number = { fg = c.number_color },
    Float = { link = "Number" },
    Boolean = { fg = c.keyword_color },
    Constant = { fg = c.text_color },
    Identifier = { fg = c.text_color },
    Function = { fg = c.function_color },
    Statement = { fg = c.keyword_color },
    Keyword = { fg = c.keyword_color },
    StorageClass = { link = "Keyword" },
    Conditional = { fg = c.control_flow_keyword_color },
    Repeat = { link = "Conditional" },
    Label = { link = "Conditional" },
    Exception = { link = "Conditional" },
    Operator = { fg = c.symbol_color },
    Delimiter = { fg = c.symbol_color },
    Special = { fg = c.symbol_color },
    PreProc = { fg = g("annotation_color") },
    Include = { link = "Keyword" },
    Type = { fg = c.engine_type_color },
    Typedef = { fg = c.base_type_color },
    Structure = { link = "Type" },
    Todo = { fg = c["comment_markers/warning_color"], bold = true },
    Error = { fg = c.brace_mismatch_color },
    -- Vim's gdscript syntax
    gdscriptNode = { fg = g("node_reference_color") },
    gdscriptFunctionName = { fg = g("function_definition_color") },
    gdscriptBlockStart = { link = "Delimiter" },
    -- Treesitter
    ["@comment.documentation"] = { link = "SpecialComment" },
    ["@comment.error"] = { fg = c["comment_markers/critical_color"], bold = true },
    ["@comment.warning"] = { fg = c["comment_markers/warning_color"], bold = true },
    ["@comment.todo"] = { fg = c["comment_markers/warning_color"], bold = true },
    ["@comment.note"] = { fg = c["comment_markers/notice_color"], bold = true },
    ["@keyword.conditional"] = { link = "Conditional" },
    ["@keyword.repeat"] = { link = "Conditional" },
    ["@keyword.return"] = { link = "Conditional" },
    ["@type"] = { link = "Type" },
    ["@type.builtin"] = { link = "Typedef" },
    ["@type.definition"] = { fg = c.user_type_color },
    ["@function"] = { fg = g("function_definition_color") },
    ["@function.call"] = { link = "Function" },
    ["@function.method"] = { fg = g("function_definition_color") },
    ["@function.method.call"] = { link = "Function" },
    ["@function.builtin"] = { fg = g("global_function_color") },
    ["@constructor"] = { link = "Type" },
    ["@attribute"] = { link = "PreProc" },
    ["@variable"] = { fg = c.text_color },
    ["@variable.member"] = { fg = c.member_variable_color },
    ["@property"] = { fg = c.member_variable_color },
    ["@variable.parameter"] = { fg = c.text_color },
    ["@constant"] = { fg = c.text_color },
    ["@constant.builtin"] = { link = "Keyword" },
    ["@string.special"] = { fg = g("node_path_color") },
    ["@string.special.symbol"] = { fg = g("string_name_color") },
    ["@string.escape"] = { fg = c.string_placeholder_color },
    ["@punctuation"] = { link = "Delimiter" },
    ["@operator"] = { link = "Operator" },
    -- LSP semantic tokens
    ["@lsp.type.class"] = { link = "Type" },
    ["@lsp.type.function"] = { link = "Function" },
    ["@lsp.type.method"] = { link = "Function" },
    ["@lsp.type.property"] = { link = "@property" },
    ["@lsp.type.parameter"] = { link = "@variable.parameter" },
    -- Diagnostics
    DiagnosticError = { fg = c.brace_mismatch_color },
    DiagnosticUnderlineError = { undercurl = true, sp = c.brace_mismatch_color },
    -- This plugin's signs
    GodotBreakpoint = { fg = c.breakpoint_color },
  }
  for name, spec in pairs(groups) do
    if spec.link or next(spec) ~= nil then
      vim.api.nvim_set_hl(0, name, spec)
    end
  end
end

-- Signal connections and overrides ---------------------------------------
-- Like Godot's script editor, mark methods that signals in the edited scene
-- are connected to, methods that override a base class method, and warn
-- about connections to methods that don't exist. Godot pushes the lists with
-- set_connections and set_overrides.

local slot_ns = vim.api.nvim_create_namespace("godot_nvim_slots")
local missing_ns = vim.api.nvim_create_namespace("godot_nvim_missing_methods")
-- Godot's own icon colors, so the signs stand out whatever the colorscheme.
-- `default` lets a colorscheme or config define the groups instead.
local function define_method_highlights()
  vim.api.nvim_set_hl(0, "GodotSignalSlot", { default = true, fg = "#5fff97", ctermfg = 84, bold = true })
  vim.api.nvim_set_hl(0, "GodotMethodOverride", { default = true, fg = "#5fb2ff", ctermfg = 75, bold = true })
end
define_method_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_method_highlights })

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
      text, hl = vim.g.godot_nvim_override_slot_sign or "↱⇠", "GodotSignalSlot"
    elseif s.slot then
      text, hl = vim.g.godot_nvim_slot_sign or "⇠", "GodotSignalSlot"
    else
      text, hl = vim.g.godot_nvim_override_sign or "↱", "GodotMethodOverride"
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
      vim.keymap.set("n", "<F9>", function() M.toggle_breakpoint() end,
        { buffer = ev.buf, desc = "Toggle Godot breakpoint" })
    end
    if vim.fn.maparg("<2-LeftMouse>", "n") == "" then
      vim.keymap.set("n", "<2-LeftMouse>", M.gutter_double_click,
        { buffer = ev.buf, expr = true, desc = "Toggle Godot breakpoint from the gutter" })
    end
    -- Keep a gutter to click, as Godot's editor does, unless the user chose
    -- otherwise.
    if vim.opt_local.signcolumn:get() == "auto" then
      vim.opt_local.signcolumn = "yes"
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

