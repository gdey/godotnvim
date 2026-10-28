## Adds a "Neovim" main screen that edits scripts in an embedded Neovim.
@tool
extends EditorPlugin

const SETTING_PATH := "godot_nvim/nvim_path"
const SETTING_ARGS := "godot_nvim/nvim_args"
const SETTING_LSP := "godot_nvim/connect_lsp"
const SETTING_THEME := "godot_nvim/use_editor_colors"
const SETTING_FORMAT := "godot_nvim/format_on_save"
const SETTING_FORMATTER := "godot_nvim/formatter_command"
const SETTING_SESSION := "godot_nvim/restore_session"
const SETTING_CLEAN := "godot_nvim/start_clean"
const SETTING_SCENE_TABS := "godot_nvim/link_scene_tabs"
## Per project, and kept out of version control with the rest of .godot/.
const _SESSION_FILE := "res://.godot/godot_nvim/session.vim"

## Where GUI-launched editors usually find nvim; macOS apps don't get the
## shell's PATH.
const _NVIM_CANDIDATES := ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/usr/bin/nvim",
	"/snap/bin/nvim", "C:/Program Files/Neovim/bin/nvim.exe"]

const _DebuggerBridge := preload("res://addons/godot_nvim/debugger_bridge.gd")
const _ThemeColors := preload("res://addons/godot_nvim/theme_colors.gd")
const _EditorProfiles := preload("res://addons/godot_nvim/editor_profiles.gd")
const _ExportExcluder := preload("res://addons/godot_nvim/export_excluder.gd")
const _PROFILES_MENU := "Create Neovim Editor Profiles"
## Where GUI-launched editors may find formatters besides PATH.
const _FORMATTER_DIRS := ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "~/.local/bin", "~/.cargo/bin"]
## Settings of GDQuest's GDScript Formatter add-on, whose binary we reuse.
const _GDQUEST_SETTINGS := "gdquest_gdscript_formatter/"
## Editor shortcuts that work while typing in Neovim.
const _PASSTHROUGH_SHORTCUTS := ["editor/run_project", "editor/run_current_scene",
	"editor/run_specific_scene", "editor/pause_running_project", "editor/stop_running_project"]

var view: NvimView
var _current_path := ""
var _debugger: EditorDebuggerPlugin
var _export_excluder: EditorExportPlugin
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
var _unsaved := PackedStringArray()
## Colors last sent to Neovim.
var _sent_theme := {}
## Formatter settings last sent to Neovim.
var _sent_formatter := []
## Scene root instance id -> its key (see _scene_key), as last sent.
var _scene_keys := {}
## Paths of scenes closed since the last _sync_scenes.
var _closed_scenes := PackedStringArray()
## [scenes, current] last sent to Neovim.
var _sent_scenes := []
## The Signals dock's tree and context menus, whose "Go to Method" we follow.
var _signals_tree: Tree
var _signals_menus: Array[PopupMenu] = []


func _enter_tree() -> void:
	_export_excluder = _ExportExcluder.new()
	add_export_plugin(_export_excluder)
	_ensure_settings()
	var es := EditorInterface.get_editor_settings()
	view = NvimView.new()
	view.name = "NeovimView"
	view.nvim_path = es.get_setting(SETTING_PATH)
	view.nvim_args = PackedStringArray(String(es.get_setting(SETTING_ARGS)).split(" ", false))
	view.working_dir = ProjectSettings.globalize_path("res://")
	view.session_file = _session_file()
	view.clean = es.get_setting(SETTING_CLEAN)
	view.link_scene_tabs = es.get_setting(SETTING_SCENE_TABS)
	if es.get_setting(SETTING_LSP):
		view.lsp_host = es.get_setting("network/language_server/remote_host")
		view.lsp_port = es.get_setting("network/language_server/remote_port")
	var theme := EditorInterface.get_editor_theme()
	view.font = theme.get_font("source", "EditorFonts")
	view.font_size = theme.get_font_size("source_size", "EditorFonts")
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.drop_builder = _build_drop
	view.color_picker_setup = _setup_color_picker
	view.resource_picker = _pick_resource
	view.resource_type = func(path: String) -> String:
		return EditorInterface.get_resource_filesystem().get_file_type(path)
	view.resource_icon = _resource_icon
	view.resource_open_requested.connect(_open_resource)
	view.file_saved.connect(_on_file_saved)
	view.buffer_entered.connect(func(p: String) -> void:
		_current_path = p
		_sync_overrides(p)
		_sync_connections(true))
	scene_changed.connect(func(_root: Node) -> void:
		_sync_connections(true)
		_sync_scenes.call_deferred())
	scene_closed.connect(func(path: String) -> void:
		if path != "":
			_closed_scenes.append(path)
		_sync_scenes.call_deferred())
	view.scene_tab_entered.connect(_show_scene)
	view.breakpoint_requested.connect(_set_breakpoint)
	view.modified_changed.connect(func(paths: PackedStringArray) -> void: _unsaved = paths)
	view.run_requested.connect(_run)
	for name in _PASSTHROUGH_SHORTCUTS:
		var sc := _editor_shortcut(name)
		if sc:
			view.passthrough_shortcuts.append(sc)
	if view.passthrough_shortcuts.is_empty():
		# Godot 4.5: take them from the run bar's buttons.
		for b in _run_bar_buttons():
			if b.shortcut:
				view.passthrough_shortcuts.append(b.shortcut)
	view.attached_to_nvim.connect(_sync_breakpoints.bind(true))
	view.attached_to_nvim.connect(_sync_theme.bind(true))
	view.attached_to_nvim.connect(_sync_formatter.bind(true))
	view.attached_to_nvim.connect(_sync_scenes.bind(true))
	es.settings_changed.connect(_sync_theme)
	es.settings_changed.connect(_sync_formatter)
	es.settings_changed.connect(_sync_session)
	es.settings_changed.connect(_sync_clean)
	es.settings_changed.connect(_sync_scene_tabs_setting)
	# Picking a text editor theme sets its colors only when the editor theme
	# is rebuilt, after settings_changed and without another one.
	view.theme_changed.connect(_sync_theme)
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
	# Saving a scene under a new path or reordering tabs raises nothing.
	_bp_timer.timeout.connect(_sync_scenes)
	add_child(_bp_timer)
	_bp_timer.start()

	add_tool_menu_item(_PROFILES_MENU, _create_profiles)
	_hook_signals_dock()

	view.start()


func _exit_tree() -> void:
	if _export_excluder:
		remove_export_plugin(_export_excluder)
		_export_excluder = null
	remove_tool_menu_item(_PROFILES_MENU)
	_unhook_signals_dock()
	var es := EditorInterface.get_editor_settings()
	if es.settings_changed.is_connected(_sync_theme):
		es.settings_changed.disconnect(_sync_theme)
	if es.settings_changed.is_connected(_sync_formatter):
		es.settings_changed.disconnect(_sync_formatter)
	if es.settings_changed.is_connected(_sync_session):
		es.settings_changed.disconnect(_sync_session)
	if es.settings_changed.is_connected(_sync_clean):
		es.settings_changed.disconnect(_sync_clean)
	if es.settings_changed.is_connected(_sync_scene_tabs_setting):
		es.settings_changed.disconnect(_sync_scene_tabs_setting)
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


## Godot asks this when the editor is closing; listing Neovim's unsaved
## buffers makes it offer Save / Don't Save / Cancel.
func _get_unsaved_status(for_scene: String) -> String:
	if for_scene != "" or _unsaved.is_empty():
		return ""
	return "Save changes to the following file(s) in Neovim before closing?\n" + "\n".join(_unsaved)


## Godot calls this when saving (Ctrl+S on a scene), before running the
## project, and from the closing dialog above, like it does for its own
## script editor.
func _save_external_data() -> void:
	if view:
		view.save_all()


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
	# The editor passes null when it clears what's being edited.
	if not is_instance_valid(object) or not _TEXT_CLASSES.any(func(c: String) -> bool: return object.is_class(c)):
		return false
	var path: String = object.resource_path
	return path != "" and not path.contains("::")


func _edit(object: Object) -> void:
	if _handles(object) and not _driving_script_editor:
		# Switching scenes can hand us the scene's script before
		# scene_changed's sync has run; open it in the new scene's tab.
		_sync_scenes()
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


# As the editor sets up its own color pickers: the project's last mode and
# shape, else the Editor Settings defaults.
func _setup_color_picker(picker: ColorPicker) -> void:
	var es := EditorInterface.get_editor_settings()
	picker.color_mode = es.get_project_metadata("color_picker", "color_mode",
		es.get_setting("interface/inspector/default_color_picker_mode"))
	picker.picker_shape = es.get_project_metadata("color_picker", "picker_shape",
		es.get_setting("interface/inspector/default_color_picker_shape"))


# Godot's Quick Open dialog, on files of [param type].
func _pick_resource(_current: String, type: String, done: Callable) -> void:
	EditorInterface.popup_quick_open(func(path: String) -> void:
		if path != "":
			done.call(ResourceUID.ensure_path(path)), [StringName(type)])


# The file type's icon, as the FileSystem dock shows it, then a preview for
# the types that have one (images, materials, meshes, ...). Missing files
# get the broken-file icon.
func _resource_icon(path: String, set_icon: Callable) -> void:
	var theme := EditorInterface.get_editor_theme()
	if not FileAccess.file_exists(path):
		set_icon.call(theme.get_icon(&"FileBroken", &"EditorIcons"))
		return
	var type := EditorInterface.get_resource_filesystem().get_file_type(path)
	var name := StringName(type if type != "" else ResourceLiteral.guess_type(path))
	set_icon.call(theme.get_icon(name, &"EditorIcons") if theme.has_icon(name, &"EditorIcons") else theme.get_icon(&"File", &"EditorIcons"))
	if ClassDB.is_parent_class(name, &"Texture2D"):
		EditorInterface.get_resource_previewer().queue_resource_preview(path, self, &"_on_icon_preview", set_icon)


func _on_icon_preview(_path: String, preview: Texture2D, small: Texture2D, set_icon: Callable) -> void:
	if preview:
		set_icon.call(preview)
	elif small:
		set_icon.call(small)


# Opens a scene in the 2D or 3D editor, as its root is, and anything else as
# the FileSystem dock does: scripts and text in Neovim, other resources in
# the Inspector.
func _open_resource(path: String) -> void:
	if EditorInterface.get_resource_filesystem().get_file_type(path) == "PackedScene":
		EditorInterface.open_scene_from_path(path)
		var root := EditorInterface.get_edited_scene_root()
		if root and root.scene_file_path == path:
			EditorInterface.set_main_screen_editor("3D" if root is Node3D else "2D")
		return
	EditorInterface.get_file_system_dock().navigate_to_path(path)
	if ResourceLoader.exists(path):
		EditorInterface.edit_resource(load(path))
	else:
		# Plain text the editor doesn't load, such as .txt or .md.
		view.open_file(path)


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
	_sync_scenes()
	view.open_file(script.resource_path, line + 1)
	EditorInterface.set_main_screen_editor(_get_plugin_name())


# --- Signals dock ----------------------------------------------------------------

## ConnectionsDock::SLOT_MENU_GO_TO_METHOD, the same in 4.5 to 4.7.
const _GO_TO_METHOD := 1


## The Signals dock's "Go to Method" (its right-click menu, or double-clicking
## a connection) opens the method in Godot's script editor directly, without
## _edit. Watch the dock's tree and menus and follow it into Neovim.
func _hook_signals_dock() -> void:
	var docks := EditorInterface.get_base_control().get_tree().root.find_children("*", "ConnectionsDock", true, false)
	if docks.is_empty():
		return
	var dock: Node = docks[0]
	# Skip the trees and menus of the dock's Connect dialog, a window of its own.
	for t in dock.find_children("*", "Tree", true, false):
		if t.get_window() == dock.get_window():
			_signals_tree = t
			break
	if _signals_tree == null:
		return
	_signals_tree.item_activated.connect(_on_signals_activated)
	for m in dock.find_children("*", "PopupMenu", true, false):
		if m.get_parent().get_window() == dock.get_window():
			m.id_pressed.connect(_on_signals_menu)
			_signals_menus.append(m)


func _unhook_signals_dock() -> void:
	if is_instance_valid(_signals_tree) and _signals_tree.item_activated.is_connected(_on_signals_activated):
		_signals_tree.item_activated.disconnect(_on_signals_activated)
	for m in _signals_menus:
		if is_instance_valid(m) and m.id_pressed.is_connected(_on_signals_menu):
			m.id_pressed.disconnect(_on_signals_menu)
	_signals_tree = null
	_signals_menus.clear()


func _on_signals_activated() -> void:
	_go_to_connected_method(_signals_tree.get_selected())


## The dock's class and signal menus have an id 1 too, but then the
## selected item isn't a connection.
func _on_signals_menu(id: int) -> void:
	if id == _GO_TO_METHOD:
		_go_to_connected_method(_signals_tree.get_selected())


## [param item] is a connection when its metadata is the Dictionary of
## Object.get_signal_connection_list(); signals and classes have other data.
func _go_to_connected_method(item: TreeItem) -> void:
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary and meta.has("callable")):
		return
	var callable: Callable = meta["callable"]
	var target := callable.get_object()
	if target == null:
		return
	var script := target.get_script() as Script
	if script == null or not _handles(script):
		return
	# After the dock has switched to the Script screen.
	_open_method.call_deferred(script.resource_path, String(callable.get_method()))


func _open_method(path: String, method: String) -> void:
	_sync_scenes()
	view.open_file(path, 0, 0, method)
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


# --- Running -----------------------------------------------------------------

## Handles :GodotRun, :GodotRunCurrent, :GodotRunScene, :GodotRunFile,
## :GodotPause and :GodotStop.
func _run(action: String, arg: String) -> void:
	match action:
		"project":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		"scene":
			if arg == "":
				EditorInterface.popup_quick_open(func(path: String) -> void:
					if path != "":
						EditorInterface.play_custom_scene(path), ["PackedScene"])
			elif ResourceLoader.exists(arg, "PackedScene"):
				EditorInterface.play_custom_scene(arg)
			else:
				push_warning("godot_nvim: not a scene: " + arg)
		"file":
			var err := run_editor_script(arg)
			if err != "":
				push_warning("godot_nvim: " + err)
				view.notify("GodotRunFile: " + err, 3)
		"stop":
			EditorInterface.stop_playing_scene()
		"pause":
			# No API for this; press the run bar's pause button, as its
			# shortcut does.
			var sc := _editor_shortcut("editor/pause_running_project")
			var b: BaseButton = null
			if sc:
				b = _find_shortcut_button(EditorInterface.get_base_control(), sc)
			else:
				var icon := EditorInterface.get_editor_theme().get_icon("Pause", "EditorIcons")
				for rb in _run_bar_buttons():
					if rb is Button and rb.icon == icon:
						b = rb
			if b and not b.disabled:
				b.button_pressed = not b.button_pressed
				b.pressed.emit()


## Runs the script at [param path] as the script editor's File > Run does
## (EditorNode::run_editor_script, which is not exposed): reload it from
## disk, check it is a @tool script extending EditorScript, and call _run().
## [param path] is a res:// path, or absolute for a file outside the project.
## Returns why it could not run, or "".
static func run_editor_script(path: String) -> String:
	if not ResourceLoader.exists(path, "Script"):
		return "not a script: " + path
	var scr: Script = ResourceLoader.load(path)
	if not scr:
		return "not a script: " + path
	# The cached copy may be older than the file (written outside Neovim).
	scr.source_code = FileAccess.get_file_as_string(path)
	if scr.reload(true) != OK:
		return "%s has errors, see the Output panel" % path
	if not ClassDB.is_parent_class(scr.get_instance_base_type(), "EditorScript"):
		return "%s does not extend EditorScript" % path
	if not scr.is_tool():
		return "%s is not a tool script (add @tool at the top)" % path
	var es: Object = scr.new()
	es.call("_run")
	return ""


## The editor shortcut [param name], or null before Godot 4.6, which lacks
## EditorSettings.get_shortcut().
static func _editor_shortcut(name: String) -> Shortcut:
	var es := EditorInterface.get_editor_settings()
	if es.has_method("get_shortcut"):
		return es.call("get_shortcut", name)
	return null


static func _run_bar_buttons() -> Array[BaseButton]:
	var out: Array[BaseButton] = []
	for bar in EditorInterface.get_base_control().find_children("*", "EditorRunBar", true, false):
		for b in bar.find_children("*", "BaseButton", true, false):
			out.append(b)
	return out


static func _find_shortcut_button(n: Node, sc: Shortcut) -> BaseButton:
	if n is BaseButton and n.shortcut == sc:
		return n
	for c in n.get_children():
		var r := _find_shortcut_button(c, sc)
		if r:
			return r
	return null


# --- Session -----------------------------------------------------------------

## The session file, or "" when godot_nvim/restore_session is off.
func _session_file() -> String:
	if not EditorInterface.get_editor_settings().get_setting(SETTING_SESSION):
		return ""
	return ProjectSettings.globalize_path(_SESSION_FILE)


func _sync_session() -> void:
	if view and _session_file() != view.session_file:
		view.set_session_file(_session_file())


## Restarts Neovim when godot_nvim/start_clean changes, unless that would
## lose unsaved changes; then it applies on the next restart.
func _sync_clean() -> void:
	var clean: bool = EditorInterface.get_editor_settings().get_setting(SETTING_CLEAN)
	if view == null or clean == view.clean:
		return
	view.clean = clean
	if _unsaved.is_empty():
		view.restart()
	else:
		view.notify("godot_nvim: Start Clean applies when Neovim restarts. Save, then :qa", 3)
# --- Scene tabs --------------------------------------------------------------

## How Neovim knows a scene: its path, or its root's id while it has none.
static func _scene_key(root: Node) -> String:
	return root.scene_file_path if root.scene_file_path != "" else "new:%d" % root.get_instance_id()


## Sends the open scenes to Neovim when they changed, a scene closed, or
## [param force]; Neovim shows the edited scene's tab page.
func _sync_scenes(force := false) -> void:
	if view == null or not view.link_scene_tabs:
		_closed_scenes = PackedStringArray()
		return
	if not view.attached:
		return
	var scenes := []
	var keys := {}
	for root in EditorInterface.get_open_scene_roots():
		var key := _scene_key(root)
		var entry := {"key": key}
		var prev: String = _scene_keys.get(root.get_instance_id(), key)
		if prev != key:
			entry["prev"] = prev
		scenes.append(entry)
		keys[root.get_instance_id()] = key
	_scene_keys = keys
	var edited := EditorInterface.get_edited_scene_root()
	var current: Variant = _scene_key(edited) if edited else null
	if force or not _closed_scenes.is_empty() or [scenes, current] != _sent_scenes:
		_sent_scenes = [scenes, current]
		view.sync_scenes(scenes, _closed_scenes, current)
		_closed_scenes = PackedStringArray()


## The user entered scene [param key]'s tab page in Neovim: switch to it.
func _show_scene(key: String) -> void:
	var roots := EditorInterface.get_open_scene_roots()
	for i in roots.size():
		if _scene_key(roots[i]) != key:
			continue
		if roots[i] == EditorInterface.get_edited_scene_root():
			return
		if roots[i].scene_file_path != "":
			# Switches to the scene's tab when it is open.
			EditorInterface.open_scene_from_path(roots[i].scene_file_path)
		else:
			var tabs := _scene_tab_bar()
			if tabs and i < tabs.tab_count:
				tabs.current_tab = i
		return
	# Closed while Neovim wasn't looking, e.g. before a restart.
	view.unlink_scene(key)


## The tab bar above the main screen, with one tab per open scene.
static func _scene_tab_bar() -> TabBar:
	for st in EditorInterface.get_base_control().find_children("*", "EditorSceneTabs", true, false):
		for tb in st.find_children("*", "TabBar", true, false):
			return tb
	return null


func _sync_scene_tabs_setting() -> void:
	var on: bool = EditorInterface.get_editor_settings().get_setting(SETTING_SCENE_TABS)
	if view and on != view.link_scene_tabs:
		view.set_link_scene_tabs(on)
		_sync_scenes(true)


# --- Colors ------------------------------------------------------------------

## Gives Neovim the script editor's colors, when they changed or [param force].
## Sends the formatter settings to Neovim when they change, or when Neovim
## (re)starts.
func _sync_formatter(force := false) -> void:
	if view == null or not view.attached:
		return
	var es := EditorInterface.get_editor_settings()
	var cmd := PackedStringArray(String(es.get_setting(SETTING_FORMATTER)).split(" ", false))
	if cmd.is_empty():
		cmd = _detect_formatter()
	var on_save: bool = es.get_setting(SETTING_FORMAT) and not cmd.is_empty()
	if force or [cmd, on_save] != _sent_formatter:
		_sent_formatter = [cmd, on_save]
		view.set_formatter(cmd, on_save)


## The formatter to use when godot_nvim/formatter_command is empty: GDQuest's
## gdscript-formatter (the one its add-on installed, or one on PATH), else
## gdtoolkit's gdformat. Empty when neither is installed.
func _detect_formatter() -> PackedStringArray:
	var es := EditorInterface.get_editor_settings()
	var gdquest := ""
	var addon_path := _GDQUEST_SETTINGS + "formatter_path"
	if es.has_setting(addon_path) and String(es.get_setting(addon_path)) != "":
		gdquest = _find_executable(es.get_setting(addon_path))
	if gdquest == "":
		var cached := EditorInterface.get_editor_paths().get_cache_dir().path_join("gdquest/gdscript-formatter")
		gdquest = _find_executable(cached)
	if gdquest == "":
		gdquest = _find_executable("gdscript-formatter")
	if gdquest != "":
		# It formats stdin when given no files. Follow the add-on's indent
		# settings, as it would.
		var cmd := PackedStringArray([gdquest])
		if es.has_setting(_GDQUEST_SETTINGS + "use_spaces") and es.get_setting(_GDQUEST_SETTINGS + "use_spaces"):
			cmd.append("--use-spaces")
			if es.has_setting(_GDQUEST_SETTINGS + "indent_size"):
				cmd.append("--indent-size=%d" % es.get_setting(_GDQUEST_SETTINGS + "indent_size"))
		return cmd
	var gdformat := _find_executable("gdformat")
	if gdformat != "":
		return PackedStringArray([gdformat, "-"])
	return PackedStringArray()


## Returns [param name] as an absolute path if it is an executable file, or
## the first match in PATH and _FORMATTER_DIRS when it is a bare name.
static func _find_executable(name: String) -> String:
	var exe := ".exe" if OS.has_feature("windows") else ""
	if name.is_absolute_path():
		for p in [name, name + exe]:
			if FileAccess.file_exists(p):
				return p
		return ""
	var dirs := Array(OS.get_environment("PATH").split(";" if OS.has_feature("windows") else ":", false))
	dirs.append_array(_FORMATTER_DIRS)
	for d: String in dirs:
		if d.begins_with("~"):
			d = OS.get_environment("HOME").path_join(d.trim_prefix("~/"))
		var p := d.path_join(name + exe)
		if FileAccess.file_exists(p):
			return p
	return ""


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


## Project → Tools → Create Neovim Editor Profiles. Makes the "-neovim"
## profiles, then offers to switch to the one for the current profile. The
## profile manager only reads the current profile at startup, so switching
## restarts the editor.
func _create_profiles() -> void:
	var made := _EditorProfiles.create(_EditorProfiles.profiles_dir())
	var es := EditorInterface.get_editor_settings()
	var current: String = es.get_setting("_default_feature_profile") if es.has_setting("_default_feature_profile") else ""
	var target := current if current.ends_with(_EditorProfiles.SUFFIX) else _EditorProfiles.neovim_name(current)
	var text := ("Created: %s." % ", ".join(made)) if not made.is_empty() else "All of your editor profiles already have a \"-neovim\" version."
	text += "\nThey hide the Script screen; Neovim edits scripts instead."
	var dialog: AcceptDialog
	if current == target or not FileAccess.file_exists(_EditorProfiles.profiles_dir().path_join(target + ".profile")):
		dialog = AcceptDialog.new()
		text += "\nPick one under Editor → Manage Editor Features."
	else:
		dialog = ConfirmationDialog.new()
		dialog.ok_button_text = "Switch and Restart"
		dialog.cancel_button_text = "Not Now"
		text += "\n\nSwitch to \"%s\" now? The editor restarts to apply it." % target
		dialog.confirmed.connect(func() -> void:
			es.set_setting("_default_feature_profile", target)
			EditorInterface.restart_editor(true))
	dialog.title = "Neovim Editor Profiles"
	dialog.dialog_text = text
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)


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
	if not es.has_setting(SETTING_FORMAT):
		es.set_setting(SETTING_FORMAT, true)
	es.set_initial_value(SETTING_FORMAT, true, false)
	es.add_property_info({"name": SETTING_FORMAT, "type": TYPE_BOOL})
	if not es.has_setting(SETTING_FORMATTER):
		es.set_setting(SETTING_FORMATTER, "")
	es.set_initial_value(SETTING_FORMATTER, "", false)
	es.add_property_info({"name": SETTING_FORMATTER, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Auto: gdscript-formatter, else gdformat -"})
	if not es.has_setting(SETTING_SESSION):
		es.set_setting(SETTING_SESSION, true)
	es.set_initial_value(SETTING_SESSION, true, false)
	es.add_property_info({"name": SETTING_SESSION, "type": TYPE_BOOL})
	if not es.has_setting(SETTING_CLEAN):
		es.set_setting(SETTING_CLEAN, false)
	es.set_initial_value(SETTING_CLEAN, false, false)
	es.add_property_info({"name": SETTING_CLEAN, "type": TYPE_BOOL})
	if not es.has_setting(SETTING_SCENE_TABS):
		es.set_setting(SETTING_SCENE_TABS, true)
	es.set_initial_value(SETTING_SCENE_TABS, true, false)
	es.add_property_info({"name": SETTING_SCENE_TABS, "type": TYPE_BOOL})
