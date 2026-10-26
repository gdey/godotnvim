-- Neovim-side helpers for the godot_nvim plugin. Loaded with nvim_exec_lua,
-- which passes the Godot channel id and an options table:
--   root: project folder
--   project: the Godot project's folder (res://)
--   lsp:  { host = ..., port = ... } to attach Godot's GDScript language
--         server to gdscript buffers, or nil to leave LSP to the user's config
--   runtime: folder with this plugin's runtime files (colors/godot.lua)
--   session: file to save open files and layout to when Neovim exits, and
--         to restore them from when it starts; nil for neither
--   clean: Neovim was started with --clean, so say so once it has started
--   scene_tabs: give each scene open in Godot its own tab page
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
-- The window QuitPre opened, until the quit is over. :qa also fires QuitPre,
-- so it is still there when Neovim exits.
local quit_spare

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
    quit_spare = spare
    vim.schedule(function()
      quit_spare = nil
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

-- Scene tabs -------------------------------------------------------------------
-- With godot_nvim/link_scene_tabs on, each scene open in Godot gets its own
-- tab page, marked with t:godot_scene: the scene's res:// path, or
-- "new:<id>" while it is unsaved. Godot sends its open scenes with
-- sync_scenes whenever its scene tabs change, and we show the current one's
-- tab; entering a marked tab here asks Godot to switch to its scene. Tabs
-- without a mark are the user's own and left alone.

M.scene_tabs = opts.scene_tabs or false
-- The scene Godot edits, as last sent or asked for.
M.current_scene = nil
-- Set while we change tabs ourselves, so TabEnter doesn't echo it to Godot.
local switching = false
-- Whether we set 'tabline' (to M.tabline()), so turning off can undo it.
local own_tabline = false

local function scene_of(tab)
  local ok, key = pcall(vim.api.nvim_tabpage_get_var, tab, "godot_scene")
  return ok and key or nil
end

local function scene_tab(key)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if scene_of(tab) == key then
      return tab
    end
  end
end

local function quietly(fn, ...)
  switching = true
  local ok, err = pcall(fn, ...)
  switching = false
  if not ok then
    vim.notify("godot_nvim: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function any_scene_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if scene_of(tab) then
      return true
    end
  end
  return false
end

-- Closes a closed scene's tab. Its buffers stay listed, hidden when they
-- have unsaved changes. The last tab page can't close, so it only loses
-- its mark.
local function close_scene_tab(tab)
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.api.nvim_tabpage_del_var(tab, "godot_scene")
    return
  end
  quietly(vim.cmd, "tabclose! " .. vim.api.nvim_tabpage_get_number(tab))
end

-- Where a new tab for [key] goes so scene tabs keep Godot's order: after
-- the tab of the nearest scene before it in [order], else before the tab of
-- the nearest one after it, else last. As a count for :tabnew.
local function new_tab_position(key, order)
  local at
  for i, k in ipairs(order) do
    if k == key then
      at = i
      break
    end
  end
  if at then
    for i = at - 1, 1, -1 do
      local tab = scene_tab(order[i])
      if tab then
        return vim.api.nvim_tabpage_get_number(tab)
      end
    end
    for i = at + 1, #order do
      local tab = scene_tab(order[i])
      if tab then
        return vim.api.nvim_tabpage_get_number(tab) - 1
      end
    end
  end
  return "$"
end

local function show_scene(key, order)
  local tab = scene_tab(key)
  if not tab then
    if any_scene_tab() then
      local pos = new_tab_position(key, order)
      quietly(function()
        vim.cmd(pos .. "tabnew")
        -- The empty buffer goes away once a file replaces it.
        vim.bo.bufhidden = "wipe"
      end)
      tab = vim.api.nvim_get_current_tabpage()
    else
      -- The first scene takes the tab that's already there.
      tab = vim.api.nvim_get_current_tabpage()
    end
    vim.api.nvim_tabpage_set_var(tab, "godot_scene", key)
  end
  if tab ~= vim.api.nvim_get_current_tabpage() then
    quietly(vim.api.nvim_set_current_tabpage, tab)
  end
  vim.cmd.redrawtabline()
end

-- [scenes]: Godot's open scenes in tab order, as { key = ..., prev = ... };
-- prev is the key the scene had before, when it was saved to a new path.
-- [closed]: keys of scenes Godot closed since the last call. [current]: the
-- key of the scene Godot edits, or nil.
--
-- Only scenes Godot says it closed lose their tab (and unsaved ones, which
-- can't come back): at startup Godot reopens its scenes one by one, and a
-- restored tab must not close before its scene is back.
function M.sync_scenes(scenes, closed, current)
  if not M.scene_tabs then
    return
  end
  local open, order = {}, {}
  for _, s in ipairs(scenes) do
    table.insert(order, s.key)
    if s.prev then
      local tab = scene_tab(s.prev)
      if tab and not scene_tab(s.key) then
        vim.api.nvim_tabpage_set_var(tab, "godot_scene", s.key)
      end
    end
    open[s.key] = true
  end
  local gone = {}
  for _, k in ipairs(closed or {}) do
    gone[k] = true
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local key = scene_of(tab)
    if key and not open[key] and (gone[key] or vim.startswith(key, "new:")) then
      close_scene_tab(tab)
    end
  end
  M.current_scene = current ~= vim.NIL and current or nil
  if M.current_scene then
    show_scene(M.current_scene, order)
  end
end

-- Godot has no scene [key] open (any more): unmark its tab.
function M.unlink_scene(key)
  local tab = scene_tab(key)
  if tab then
    vim.api.nvim_tabpage_del_var(tab, "godot_scene")
    vim.cmd.redrawtabline()
  end
end

vim.api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = function()
    if switching or not M.scene_tabs then
      return
    end
    local key = scene_of(0)
    if key and key ~= M.current_scene then
      M.current_scene = key
      vim.rpcnotify(chan, "godot_nvim_scene_tab", key)
    end
  end,
})

-- Tab labels: the scene's file name, then the current window's file.
function M.tabline()
  local out = {}
  local cur = vim.api.nvim_get_current_tabpage()
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    if name == "" then
      name = vim.bo[buf].buftype == "" and "[No Name]" or vim.bo[buf].filetype
    end
    local modified = false
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      modified = modified or vim.bo[vim.api.nvim_win_get_buf(w)].modified
    end
    local key = scene_of(tab)
    local label = name .. (modified and " +" or "")
    if key then
      local scene = vim.startswith(key, "new:") and "[unsaved]" or vim.fn.fnamemodify(key, ":t")
      label = scene .. " │ " .. label
    end
    table.insert(out, (tab == cur and "%#TabLineSel#" or "%#TabLine#") .. "%" .. i .. "T "
      .. label:gsub("%%", "%%%%") .. " ")
  end
  return table.concat(out) .. "%#TabLineFill#%T"
end

local function update_tabline()
  if M.scene_tabs and vim.o.tabline == "" then
    vim.o.tabline = "%!v:lua.godot_nvim.tabline()"
    own_tabline = true
  elseif not M.scene_tabs and own_tabline then
    vim.o.tabline = ""
    own_tabline = false
  end
end
-- After the user's config, which may set its own.
vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = update_tabline })

function M.set_scene_tabs(on)
  M.scene_tabs = on
  if not on then
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      pcall(vim.api.nvim_tabpage_del_var, tab, "godot_scene")
    end
    M.current_scene = nil
  end
  if vim.v.vim_did_enter == 1 then
    update_tabline()
  end
end

-- Opens [path] for Godot, at [line] (1-based) when > 0. Like :drop, but with
-- scene tabs on a window showing the file is only looked for in this tab:
-- going to another scene's tab would switch Godot's scene.
function M.open(path, line, col)
  local name = vim.fn.fnameescape(vim.fn.fnamemodify(path, ":~:."))
  if not M.scene_tabs then
    vim.cmd.drop(name)
  else
    local target = vim.fs.normalize(path)
    local found
    for _, w in ipairs(normal_wins()) do
      if bufname(vim.api.nvim_win_get_buf(w)) == target then
        found = w
        break
      end
    end
    if found then
      vim.api.nvim_set_current_win(found)
    else
      -- As :drop does, split when the current buffer can't be abandoned.
      local cur = vim.api.nvim_get_current_buf()
      local keep = vim.bo[cur].modified and not vim.o.hidden and vim.bo[cur].bufhidden == ""
        and #vim.fn.win_findbuf(cur) == 1
      vim.cmd((keep and "split " or "edit ") .. name)
    end
  end
  if line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
    vim.cmd("normal! zz")
  end
end

-- Session --------------------------------------------------------------------
-- Open files, cursors, splits and tabs are saved with :mksession when Neovim
-- exits (Godot closing, or :qa) and restored once the user's config has run.
-- Options and mappings aren't saved: the config owns those. Paths are stored
-- absolute, and windows on scratch buffers (file trees, the placeholder) are
-- left out.

M.session = opts.session
local session_options = "buffers,folds,help,tabpages,winsize"
local restored_options = { "showtabline", "hlsearch", "winheight", "winwidth", "winminheight", "winminwidth" }

-- :mksession doesn't keep tab variables, so the scene of each tab page
-- (t:godot_scene, see Scene tabs) goes in a file next to the session.
local function scenes_file(file)
  return vim.fn.fnamemodify(file, ":r") .. ".scenes.json"
end

local function save_scene_tabs(file)
  local scenes = {}
  local any = false
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local key = scene_of(tab)
    -- Unsaved scenes don't outlive the editor.
    if key and not vim.startswith(key, "new:") then
      scenes[i] = key
      any = true
    else
      scenes[i] = vim.NIL
    end
  end
  if not (any and M.scene_tabs) then
    os.remove(scenes_file(file))
    return
  end
  local f = io.open(scenes_file(file), "w")
  if f then
    f:write(vim.json.encode(scenes))
    f:close()
  end
end

local function restore_scene_tabs(file)
  local f = io.open(scenes_file(file), "r")
  if not f then
    return
  end
  local ok, scenes = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or type(scenes) ~= "table" then
    return
  end
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if type(scenes[i]) == "string" then
      vim.api.nvim_tabpage_set_var(tab, "godot_scene", scenes[i])
    end
  end
end

-- Writes the session, or removes it when no file is open.
function M.save_session()
  local file = M.session
  if not file then
    return
  end
  local any = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and bufname(buf) ~= "" then
      any = true
      break
    end
  end
  if not any then
    os.remove(file)
    os.remove(scenes_file(file))
    return
  end
  -- Leave out the window QuitPre opened for :qa.
  if quit_spare and vim.api.nvim_win_is_valid(quit_spare) and #normal_wins() > 1 then
    pcall(vim.api.nvim_win_close, quit_spare, true)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local saved = vim.o.sessionoptions
  vim.o.sessionoptions = session_options
  local ok, err = pcall(vim.cmd, "mksession! " .. vim.fn.fnameescape(file))
  vim.o.sessionoptions = saved
  if not ok then
    vim.notify("godot_nvim: could not save the session: " .. err, vim.log.levels.WARN)
  end
  save_scene_tabs(file)
end

-- Restores the session.
function M.restore_session()
  local file = M.session
  if not file or vim.fn.filereadable(file) == 0 then
    return
  end
  -- The session script resets these to Vim's defaults; keep the user's.
  local keep = {}
  for _, o in ipairs(restored_options) do
    keep[o] = vim.o[o]
  end
  local ok, err = pcall(vim.cmd, "silent source " .. vim.fn.fnameescape(file))
  for o, v in pairs(keep) do
    vim.o[o] = v
  end
  if not ok then
    vim.notify("godot_nvim: could not restore the session: " .. err, vim.log.levels.WARN)
  end
  -- Before closing deleted files' windows, which can close their tabs.
  restore_scene_tabs(file)
  -- Show the absolute paths relative to the working directory again.
  vim.cmd("noautocmd silent cd .")
  -- Files deleted since would come back as empty new files.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = bufname(buf)
    if name ~= "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
        and vim.fn.filereadable(name) == 0 then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if vim.v.dying == 0 then
      M.save_session()
    end
  end,
})
-- Godot holds back the files it opens until Neovim has started (startup
-- would move their cursors) and the session is restored, so that its file
-- lands on top of the session. Nested, so the restored buffers get their
-- FileType, signs and LSP.
vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  nested = true,
  callback = function()
    M.restore_session()
    if opts.clean then
      vim.notify("godot_nvim: started clean, without your config and plugins")
    end
    vim.rpcnotify(chan, "godot_nvim_entered")
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

-- Toggles the breakpoint on [line] of [buf], by default the cursor line.
function M.toggle_breakpoint(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local enabled = not vim.tbl_contains(M.buf_breakpoints(buf), line)
  vim.rpcnotify(chan, "godot_nvim_set_breakpoint", bufname(buf), line, enabled)
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
-- The script editor's File > Run: runs a @tool script that extends
-- EditorScript. Godot runs the text on disk, so write the file's buffer first
-- if it has unsaved changes, as File > Run applies the editor's text. Files
-- outside the project run too, as in Godot, after asking.
function M.run_file(file)
  local path = file and file ~= "" and vim.fs.normalize(vim.fn.fnamemodify(file, ":p")) or bufname(0)
  if path == "" then
    vim.notify("GodotRunFile: the buffer has no file", vim.log.levels.WARN)
    return
  end
  local root = opts.project and vim.fs.normalize(opts.project):gsub("/$", "") .. "/"
  if root and path:sub(1, #root) ~= root
    and vim.fn.confirm(path .. " is outside the project. Run it in the editor?", "&Run\n&Cancel", 2) ~= 1 then
    return
  end
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent update") end)
  end
  run("file", path)
end

vim.api.nvim_create_user_command("GodotRunFile", function(o) M.run_file(o.args) end, {
  nargs = "?",
  complete = "file",
  desc = "Run an EditorScript, as File > Run does (the current file when none is given)",
})
vim.api.nvim_create_user_command("GodotPause", function() run("pause") end,
  { desc = "Pause or resume the running Godot project" })
vim.api.nvim_create_user_command("GodotStop", function() run("stop") end,
  { desc = "Stop the running Godot project" })

-- Formatting ----------------------------------------------------------------
-- Godot has no GDScript formatter, so an external one (GDQuest's
-- gdscript-formatter or gdformat, whichever Godot finds) formats .gd buffers
-- before they are written. Godot pushes the command with set_formatter: an
-- argv list that reads the code on stdin and writes the formatted code to
-- stdout, or nil when none is installed. b:godot_nvim_format = v:false
-- skips a buffer.

M.formatter = nil
M.format_on_save = false
-- Commands already reported missing, so each save doesn't warn again.
local format_warned = {}

local text_diff = (vim.text and vim.text.diff) or vim.diff

function M.set_formatter(cmd, on_save)
  M.formatter = (cmd and #cmd > 0) and cmd or nil
  M.format_on_save = on_save and M.formatter ~= nil
end

-- Reports a formatting problem after the write. On save it is cut to one
-- line, so a hit-enter prompt can't hold up the write or Godot's requests.
local function format_warn(msg, full)
  if not full then
    msg = msg:gsub("\n.*", "")
    if #msg > vim.v.echospace then
      msg = msg:sub(1, math.max(vim.v.echospace - 3, 1)) .. "..."
    end
  end
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
  end)
end

-- Runs [cmd] on [buf]'s text and applies the changes as diff hunks, so
-- breakpoints, signs and the cursor stay on lines the formatter left alone.
-- [full] shows whole error messages (for :GodotFormat). Returns true when
-- the buffer is formatted (changed or not).
function M.format(buf, cmd, full)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  cmd = cmd or M.formatter
  if not cmd then
    format_warn("godot_nvim: no formatter found; install gdscript-formatter or gdformat", full)
    return false
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    if full or not format_warned[cmd[1]] then
      format_warned[cmd[1]] = true
      format_warn(string.format("godot_nvim: formatter %s not found, set godot_nvim/formatter_command", cmd[1]), full)
    end
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n") .. "\n"
  local out, err = {}, {}
  local job = vim.fn.jobstart(cmd, {
    cwd = opts.root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) out = data end,
    on_stderr = function(_, data) err = data end,
  })
  if job <= 0 then
    format_warn("godot_nvim: could not run " .. table.concat(cmd, " "), full)
    return false
  end
  vim.fn.chansend(job, text)
  vim.fn.chanclose(job, "stdin")
  local code = vim.fn.jobwait({ job }, 5000)[1]
  if code == -1 then
    vim.fn.jobstop(job)
    format_warn("godot_nvim: " .. cmd[1] .. " timed out", full)
    return false
  elseif code ~= 0 then
    local msg = vim.trim(table.concat(err, "\n"))
    format_warn("godot_nvim: " .. cmd[1] .. " failed" .. (msg ~= "" and (": " .. msg) or ""), full)
    return false
  end
  -- Buffered output ends with "" after the last newline.
  if out[#out] == "" then
    table.remove(out)
  end
  local formatted = table.concat(out, "\n") .. "\n"
  if formatted == text then
    return true
  end
  local hunks = text_diff(text, formatted, { result_type = "indices" })
  -- Join the formatting with the last change, so one undo reverts both.
  pcall(vim.cmd.undojoin)
  for i = #hunks, 1, -1 do
    local a, na, b, nb = unpack(hunks[i])
    local repl = vim.list_slice(out, b, b + nb - 1)
    if na == 0 then
      vim.api.nvim_buf_set_lines(buf, a, a, false, repl)
    else
      vim.api.nvim_buf_set_lines(buf, a - 1, a - 1 + na, false, repl)
    end
  end
  return true
end

vim.api.nvim_create_autocmd("BufWritePre", {
  group = group,
  pattern = "*.gd",
  callback = function(ev)
    if M.format_on_save and vim.b[ev.buf].godot_nvim_format ~= false then
      M.format(ev.buf)
    end
  end,
})

vim.api.nvim_create_user_command("GodotFormat", function() M.format(0, nil, true) end,
  { desc = "Format the GDScript buffer with gdscript-formatter or gdformat" })

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
  local name = bufname(buf)
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
    if bufname(buf) == path then
      apply_method_signs(buf)
    end
  end
end

-- Opens [path] at the func called [name], for the Signals dock's "Go to
-- Method". The buffer is searched rather than Godot's copy, so unsaved
-- edits count.
function M.open_method(path, name)
  M.open(path, 0, 0)
  local l = func_lines(0)[name]
  if l then
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    vim.cmd("normal! ^zz")
  else
    vim.notify("No func " .. name .. "() in " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.WARN)
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
  local base = top and (M.overrides[bufname(buf)] or {})[name]
  if base then
    table.insert(out, string.format("Overrides %s.%s()", base, name))
  end
  for _, c in ipairs(M.connections[bufname(buf)] or {}) do
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

-- Finding functions -----------------------------------------------------------
-- Godot's language server has no workspace/symbol, so :GodotFunc scans the
-- project's .gd files itself. Loaded buffers are read as they are in Neovim.
-- The project is the folder Godot passed in, not the working directory, which
-- :cd (or a plugin) can move.

-- Returns { file, lnum, name, text } for every func in the project.
function M.project_funcs()
  local loaded = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and bufname(b):match("%.gd$") then
      loaded[bufname(b)] = b
    end
  end
  local out = {}
  for _, f in ipairs(vim.fn.globpath((opts.root or vim.fn.getcwd()):gsub(",", "\\,"), "**/*.gd", false, true)) do
    f = vim.fs.normalize(f)
    if not f:match("/%.godot/") then
      local lines = loaded[f] and vim.api.nvim_buf_get_lines(loaded[f], 0, -1, false) or vim.fn.readfile(f)
      for i, l in ipairs(lines) do
        local name = l:match("^%s*func%s+([%w_]+)%s*%(") or l:match("^%s*static%s+func%s+([%w_]+)%s*%(")
        if name then
          table.insert(out, { file = f, lnum = i, name = name, text = vim.trim(l) })
        end
      end
    end
  end
  return out
end

-- Opens the func called [name]. With several, or with no exact match but
-- some funcs containing [name], fills the quickfix list instead.
function M.find_func(name)
  local exact, partial = {}, {}
  local lname = name:lower()
  for _, f in ipairs(M.project_funcs()) do
    if f.name == name then
      table.insert(exact, f)
    elseif f.name:lower():find(lname, 1, true) then
      table.insert(partial, f)
    end
  end
  local hits = #exact > 0 and exact or partial
  if #hits == 0 then
    vim.notify("No function matching " .. name, vim.log.levels.WARN)
  elseif #hits == 1 and #exact == 1 then
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(hits[1].file))
    vim.api.nvim_win_set_cursor(0, { hits[1].lnum, 0 })
    vim.cmd("normal! ^zz")
  else
    vim.fn.setqflist({}, " ", {
      title = ":GodotFunc " .. name,
      items = vim.tbl_map(function(f)
        return { filename = f.file, lnum = f.lnum, text = f.text }
      end, hits),
    })
    vim.cmd("botright copen")
  end
end

vim.api.nvim_create_user_command("GodotFunc", function(o) M.find_func(o.args) end, {
  nargs = 1,
  complete = function(lead)
    local seen, names = {}, {}
    for _, f in ipairs(M.project_funcs()) do
      if not seen[f.name] and vim.startswith(f.name, lead) then
        seen[f.name] = true
        table.insert(names, f.name)
      end
    end
    table.sort(names)
    return names
  end,
  desc = "Open the GDScript function with this name (several matches go to the quickfix list)",
})

vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = group,
  callback = function(ev)
    local name = bufname(ev.buf)
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
    vim.rpcnotify(chan, "godot_nvim_saved", bufname(ev.buf), M.buf_breakpoints(ev.buf))
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(ev)
    vim.rpcnotify(chan, "godot_nvim_buf_enter", bufname(ev.buf))
  end,
})
-- A file Godot opened before this script loaded entered without us.
if bufname(0) ~= "" then
  vim.rpcnotify(chan, "godot_nvim_buf_enter", bufname(0))
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

