## Adds a "Neovim" main screen that edits scripts in an embedded Neovim.
@tool
extends EditorPlugin

const SETTING_PATH := "godot_nvim/nvim_path"
const SETTING_ARGS := "godot_nvim/nvim_args"
const SETTING_LSP := "godot_nvim/connect_lsp"
const SETTING_THEME := "godot_nvim/use_editor_colors"

## Where GUI-launched editors usually find nvim; macOS apps don't get the
## shell's PATH.
const _NVIM_CANDIDATES := ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/usr/bin/nvim",
	"/snap/bin/nvim", "C:/Program Files/Neovim/bin/nvim.exe"]

const _DebuggerBridge := preload("res://addons/godot_nvim/debugger_bridge.gd")
const _ThemeColors := preload("res://addons/godot_nvim/theme_colors.gd")

var view: NvimView
var _current_path := ""
var _debugger: EditorDebuggerPlugin
## res:// path -> sorted 1-based breakpoint lines, as last sent to Neovim.
var _breakpoints := {}
var _bp_timer: Timer
## Set while we drive Godot's script editor ourselves, so its "go to line"
## echoes don't move the Neovim cursor.
var _driving_script_editor := false
var _skip_breakpoints := false
## Connections last sent to Neovim, for _current_path.
var _sent_connections := []
var _sent_connections_path := ""
var _skip_buttons: Array[Button] = []
## Colors last sent to Neovim.
var _sent_theme := {}


func _enter_tree() -> void:
	_ensure_settings()
	var es := EditorInterface.get_editor_settings()
	view = NvimView.new()
	view.name = "NeovimView"
	view.nvim_path = es.get_setting(SETTING_PATH)
	view.nvim_args = PackedStringArray(String(es.get_setting(SETTING_ARGS)).split(" ", false))
	view.working_dir = ProjectSettings.globalize_path("res://")
	if es.get_setting(SETTING_LSP):
		view.lsp_host = es.get_setting("network/language_server/remote_host")
		view.lsp_port = es.get_setting("network/language_server/remote_port")
	var theme := EditorInterface.get_editor_theme()
	view.font = theme.get_font("source", "EditorFonts")
	view.font_size = theme.get_font_size("source_size", "EditorFonts")
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.drop_builder = _build_drop
	view.file_saved.connect(_on_file_saved)
	view.buffer_entered.connect(func(p: String) -> void:
		_current_path = p
		_sync_overrides(p)
		_sync_connections(true))
	scene_changed.connect(func(_root: Node) -> void: _sync_connections(true))
	view.breakpoint_requested.connect(_set_breakpoint)
	view.attached_to_nvim.connect(_sync_breakpoints.bind(true))
	view.attached_to_nvim.connect(_sync_theme.bind(true))
	es.settings_changed.connect(_sync_theme)
	EditorInterface.get_editor_main_screen().add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.hide()

	_debugger = _DebuggerBridge.new()
	_debugger.goto_line.connect(_on_debugger_goto_line)
	_debugger.breakpoints_changed.connect(_sync_breakpoints)
	add_debugger_plugin(_debugger)
	# Breakpoints toggled in Godot's own gutter raise no signal we can hear,
	# so poll the (cheap) list as well.
	_bp_timer = Timer.new()
	_bp_timer.wait_time = 0.5
	_bp_timer.timeout.connect(_sync_breakpoints)
	_bp_timer.timeout.connect(_sync_connections)
	add_child(_bp_timer)
	_bp_timer.start()

	view.start()


func _exit_tree() -> void:
	var es := EditorInterface.get_editor_settings()
	if es.settings_changed.is_connected(_sync_theme):
		es.settings_changed.disconnect(_sync_theme)
	if _debugger:
		remove_debugger_plugin(_debugger)
		_debugger = null
	if _bp_timer:
		_bp_timer.queue_free()
		_bp_timer = null
	if view:
		view.stop()
		view.queue_free()
		view = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Neovim"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Script", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if view:
		view.visible = visible
		if visible:
			view.grab_focus()


## Resources whose file is plain source text. TextFile is Godot's internal
## class for .cfg, .txt, .md, ... opened from the FileSystem dock.
## Scenes and .tres resources are text too but stay with their editors.
const _TEXT_CLASSES := ["Script", "Shader", "ShaderInclude", "JSON", "TextFile"]


## File-backed text resources. Built-in ones (path contains "::") stay in
## Godot's editors since Neovim can't open them.
func _handles(object: Object) -> bool:
	if not _TEXT_CLASSES.any(func(c: String) -> bool: return object.is_class(c)):
		return false
	var path: String = object.resource_path
	return path != "" and not path.contains("::")


func _edit(object: Object) -> void:
	if _handles(object) and not _driving_script_editor:
		view.open_file(object.resource_path)


func _build_drop(data: Variant, modifier: bool) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var script_node: Node = null
	if _current_path != "" and ResourceLoader.exists(_current_path):
		var script := load(_current_path) as Script
		if script:
			script_node = DropText.find_script_node(root, script)
	var hints: bool = EditorInterface.get_editor_settings().get_setting("text_editor/completion/add_type_hints")
	return DropText.build(data, root, script_node, modifier, hints)


func _on_file_saved(path: String, breakpoints: Array) -> void:
	if not path.begins_with("res://"):
		return
	# Reloading hands focus to Godot's (hidden) script editor; keep typing
	# in Neovim after :w.
	if view.has_focus():
		_keep_focus.call_deferred()
	EditorInterface.get_resource_filesystem().update_file(path)
	if ResourceLoader.has_cached(path):
		# Push the new text into the copy Godot already has loaded, so open
		# scenes and editors see it without a restart.
		var res := ResourceLoader.load(path)
		var text := FileAccess.get_file_as_string(path)
		if res is Script:
			res.source_code = text
			res.reload(true)
		elif res is Shader or res is ShaderInclude:
			res.code = text
		elif res is JSON:
			res.parse(text)
	if path.get_extension() != "gd":
		return
	var se := EditorInterface.get_script_editor()
	se.reload_open_files()
	# The script's extends line may have changed.
	_sync_overrides(path)
	# Edits move Neovim's signs; make Godot's list follow them.
	var have: Array = _godot_breakpoints().get(path, [])
	for line in have:
		if not breakpoints.has(line):
			_set_breakpoint(path, line, false)
	for line in breakpoints:
		if not have.has(line):
			_set_breakpoint(path, line, true)


func _keep_focus() -> void:
	if view and view.is_visible_in_tree():
		view.grab_focus()


# --- Debugger ------------------------------------------------------------------

## Double-clicks in the debugger (breakpoints, errors, stack frames). Godot's
## script editor has already handled this and handed us the script through
## _edit without a line, so only the cursor needs moving.
func _on_debugger_goto_line(script: Script, line: int) -> void:
	if _driving_script_editor or script == null or not _handles(script):
		return
	view.open_file(script.resource_path, line + 1)
	EditorInterface.set_main_screen_editor(_get_plugin_name())


## res:// path -> sorted 1-based lines, from Godot's script editor.
func _godot_breakpoints() -> Dictionary:
	var out := {}
	for entry in EditorInterface.get_script_editor().get_breakpoints():
		var i := String(entry).rfind(":")
		if i < 0:
			continue
		var path := String(entry).left(i)
		if not out.has(path):
			out[path] = []
		out[path].append(int(String(entry).substr(i + 1)))
	for p in out:
		out[p].sort()
	return out


# --- Colors ------------------------------------------------------------------

## Gives Neovim the script editor's colors, when they changed or [param force].
func _sync_theme(force := false) -> void:
	if view == null or not view.attached:
		return
	var es := EditorInterface.get_editor_settings()
	if not es.get_setting(SETTING_THEME):
		_sent_theme = {}
		return
	var colors := _ThemeColors.from_settings(es)
	if force or colors != _sent_theme:
		_sent_theme = colors
		view.set_colorscheme(colors)


# --- Signal connections ------------------------------------------------------

## Sends the edited scene's signal connections into the current script's
## methods, as Godot's script editor shows them in its gutter.
func _sync_connections(force := false) -> void:
	if view == null or not view.attached or not _current_path.ends_with(".gd"):
		return
	var conns := _connections_for(_current_path)
	if force or _current_path != _sent_connections_path or conns != _sent_connections:
		_sent_connections = conns
		_sent_connections_path = _current_path
		view.set_connections(_current_path, conns)


func _connections_for(path: String) -> Array:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not ResourceLoader.exists(path):
		return []
	var script := load(path) as Script
	if script == null:
		return []
	var out := []
	for node in _nodes_with_script(root, script):
		for c in node.get_incoming_connections():
			if not (c["flags"] & CONNECT_PERSIST):
				continue
			var source := (c["signal"] as Signal).get_object() as Node
			# Deleted nodes linger for undo; Godot skips them too.
			if source == null or not source.is_inside_tree():
				continue
			var method := String((c["callable"] as Callable).get_method())
			out.append({
				"method": method,
				"signal": String((c["signal"] as Signal).get_name()),
				"source": _scene_path(root, source),
				"target": _scene_path(root, node),
				"missing": not _script_has_method(script, method),
			})
	return out


## Sends the methods [param path]'s base classes define, so Neovim can mark
## the ones the script overrides, as Godot's script editor does.
func _sync_overrides(path: String) -> void:
	if view == null or not view.attached or not path.ends_with(".gd") or not ResourceLoader.exists(path):
		return
	var script := load(path) as Script
	# A script that doesn't parse has no base type; keep the last signs.
	if script == null or script.get_instance_base_type() == &"":
		return
	view.set_overrides(path, overridable_methods(script))


## Method name -> where it's defined: the nearest base script's path, or the
## engine class name. Mirrors ScriptTextEditor's override lookup.
static func overridable_methods(script: Script) -> Dictionary:
	var out := {}
	var s := script.get_base_script()
	while s != null:
		for m in s.get_script_method_list():
			if not out.has(m["name"]):
				out[m["name"]] = s.resource_path
		s = s.get_base_script()
	var cls := script.get_instance_base_type()
	while cls != &"":
		for m in ClassDB.class_get_method_list(cls, true):
			if not out.has(m["name"]):
				out[m["name"]] = String(cls)
		cls = ClassDB.get_parent_class(cls)
	return out


static func _nodes_with_script(n: Node, script: Script) -> Array[Node]:
	var out: Array[Node] = []
	if n.get_script() == script:
		out.append(n)
	for c in n.get_children():
		out.append_array(_nodes_with_script(c, script))
	return out


static func _scene_path(root: Node, n: Node) -> String:
	return String(root.name) if n == root else String(root.get_path_to(n))


static func _script_has_method(script: Script, method: String) -> bool:
	if ClassDB.class_has_method(script.get_instance_base_type(), method):
		return true
	var s := script
	while s != null:
		for m in s.get_script_method_list():
			if m["name"] == method:
				return true
		s = s.get_base_script()
	return false


func _sync_breakpoints(force := false) -> void:
	if view == null or not view.attached:
		return
	var skip := _is_skipping_breakpoints()
	if force or skip != _skip_breakpoints:
		_skip_breakpoints = skip
		view.set_skip_breakpoints(skip)
	var now := _godot_breakpoints()
	var paths := now.keys()
	for p in _breakpoints:
		if not now.has(p):
			paths.append(p)
	for p in paths:
		var lines: Array = now.get(p, [])
		if force or lines != _breakpoints.get(p, []):
			view.set_breakpoints(p, lines)
	_breakpoints = now


## Whether the debugger's "Skip Breakpoints" toggle is on. Godot doesn't
## expose this to plugins, so read it off the toggle button: its icon is
## DebugSkipBreakpointsOn while skipping. With several debugger sessions,
## the visible one wins, as in EditorDebuggerNode.is_skip_breakpoints().
func _is_skipping_breakpoints() -> bool:
	if _skip_buttons.is_empty() or not is_instance_valid(_skip_buttons[0]):
		_skip_buttons = _find_skip_buttons()
	if _skip_buttons.is_empty():
		return false
	var on_icon := EditorInterface.get_editor_theme().get_icon("DebugSkipBreakpointsOn", "EditorIcons")
	var pick: Button = _skip_buttons[0]
	for b in _skip_buttons:
		if is_instance_valid(b) and b.is_visible_in_tree():
			pick = b
			break
	return pick.icon == on_icon


func _find_skip_buttons() -> Array[Button]:
	var out: Array[Button] = []
	var base := EditorInterface.get_base_control()
	for dbg in base.find_children("*", "ScriptEditorDebugger", true, false):
		for b in dbg.find_children("*", "Button", true, false):
			if b.tooltip_text == "Skip Breakpoints":
				out.append(b)
	return out


## Sets a breakpoint the way Godot's gutter does, so the debugger and a
## running game see it. That needs the script open in Godot's script editor,
## which happens in the background while the Neovim tab stays in front.
func _set_breakpoint(path: String, line: int, enabled: bool) -> void:
	if not path.begins_with("res://") or path.get_extension() != "gd":
		return
	var script := load(path) as Script
	if script == null:
		return
	var neovim_in_front := view.is_visible_in_tree()
	_driving_script_editor = true
	EditorInterface.edit_script(script, -1, 0, false)
	var se := EditorInterface.get_script_editor()
	var code := se.get_current_editor().get_base_editor() as CodeEdit if se.get_current_editor() else null
	if se.get_current_script() == script and code and line - 1 < code.get_line_count():
		code.set_line_as_breakpoint(line - 1, enabled)
	else:
		push_warning("godot_nvim: could not set breakpoint at %s:%d" % [path, line])
	_driving_script_editor = false
	if neovim_in_front:
		EditorInterface.set_main_screen_editor(_get_plugin_name())
	_sync_breakpoints()


func _ensure_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTING_PATH):
		var found := "nvim"
		for c in _NVIM_CANDIDATES:
			if FileAccess.file_exists(c):
				found = c
				break
		es.set_setting(SETTING_PATH, found)
	es.set_initial_value(SETTING_PATH, "nvim", false)
	es.add_property_info({"name": SETTING_PATH, "type": TYPE_STRING, "hint": PROPERTY_HINT_GLOBAL_FILE})
	if not es.has_setting(SETTING_ARGS):
		es.set_setting(SETTING_ARGS, "")
	es.set_initial_value(SETTING_ARGS, "", false)
	es.add_property_info({"name": SETTING_ARGS, "type": TYPE_STRING})
	if not es.has_setting(SETTING_LSP):
		es.set_setting(SETTING_LSP, true)
	es.set_initial_value(SETTING_LSP, true, false)
	es.add_property_info({"name": SETTING_LSP, "type": TYPE_BOOL})
	if not es.has_setting(SETTING_THEME):
		es.set_setting(SETTING_THEME, true)
	es.set_initial_value(SETTING_THEME, true, false)
	es.add_property_info({"name": SETTING_THEME, "type": TYPE_BOOL})
