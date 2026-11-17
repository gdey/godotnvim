## Attach, Extend and Detach Script for the Scene dock while the editor
## profile has the Script screen turned off. Godot hides its own buttons,
## menu items and shortcuts for these then (SceneTreeDock follows
## EditorFeatureProfile.FEATURE_SCRIPT), so this puts them back.
@tool
extends Node

const _EditorProfiles := preload("res://addons/godot_nvim/editor_profiles.gd")

## Called with the new script after Attach or Extend.
var script_opened: Callable
var _plugin: EditorPlugin
var _menu: EditorContextMenuPlugin
var _buttons := {}
## [profile file, modified time] last read, and whether it had scripts off.
var _profile_key := []
var _scripts_off := false
## Our script_created handler while the Attach Script dialog is open.
var _created: Callable


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func _ready() -> void:
	_menu = Menu.new(self)
	_plugin.add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _menu)
	_add_buttons()
	EditorInterface.get_selection().selection_changed.connect(refresh)
	# Attaching and detaching (history_changed), and undo (version_changed).
	var ur := EditorInterface.get_editor_undo_redo()
	ur.history_changed.connect(refresh)
	ur.version_changed.connect(refresh)
	# Godot reads the current profile at startup and on Manage Editor
	# Features' "Make Current", without a signal plugins can hear.
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start()
	refresh()


func _exit_tree() -> void:
	_dialog_closed()
	if _menu:
		_plugin.remove_context_menu_plugin(_menu)
		_menu = null
	var sel := EditorInterface.get_selection()
	if sel.selection_changed.is_connected(refresh):
		sel.selection_changed.disconnect(refresh)
	var ur := EditorInterface.get_editor_undo_redo()
	for sig in [ur.history_changed, ur.version_changed]:
		if sig.is_connected(refresh):
			sig.disconnect(refresh)
	for b in _buttons.values():
		if is_instance_valid(b):
			b.queue_free()
	_buttons.clear()


## Whether the current editor profile turns the Script screen off.
func scripts_off() -> bool:
	var es := EditorInterface.get_editor_settings()
	var name: String = es.get_setting("_default_feature_profile") if es.has_setting("_default_feature_profile") else ""
	var path := _EditorProfiles.profiles_dir().path_join(name + ".profile") if name != "" else ""
	var key := [path, FileAccess.get_modified_time(path) if path != "" and FileAccess.file_exists(path) else 0]
	if key != _profile_key:
		_profile_key = key
		_scripts_off = _EditorProfiles.disables_scripts(path)
	return _scripts_off


## What can be done to [param nodes]: {"attach", "extend", "detach"}, as
## Godot's SceneTreeDock decides it.
static func actions(nodes: Array) -> Dictionary:
	var out := {"attach": false, "extend": false, "detach": false}
	for n in nodes:
		var s: Script = n.get_script()
		var custom := custom_type_script(n)
		if nodes.size() == 1:
			if s == null:
				out["attach"] = true
			elif not s.resource_path.contains("::"):
				out["extend"] = true
		if s != null and s != custom:
			out["detach"] = true
	return out


## The script of the custom type (EditorPlugin.add_custom_type) [param n]
## was made from, or null.
static func custom_type_script(n: Node) -> Script:
	if not n.has_meta(&"_custom_type_script"):
		return null
	var v: Variant = n.get_meta(&"_custom_type_script")
	if v is Script:
		return v
	if v is String and ResourceLoader.exists(v):
		return load(v) as Script
	return null


func refresh() -> void:
	var on := scripts_off()
	var can := actions(EditorInterface.get_selection().get_selected_nodes()) if on else {}
	for k in _buttons:
		if is_instance_valid(_buttons[k]):
			_buttons[k].visible = can.get(k, false)


func attach(extend := false) -> void:
	var nodes := EditorInterface.get_selection().get_top_selected_nodes()
	var root := EditorInterface.get_edited_scene_root()
	if nodes.is_empty() or root == null:
		return
	var node: Node = nodes[0]
	var path := node.scene_file_path
	if path == "":
		path = ("res://" if root.scene_file_path == "" else root.scene_file_path.get_base_dir()).path_join(node.name)
	var inherits := node.get_class()
	var existing: Script = node.get_script()
	if extend:
		if existing == null or existing.resource_path.contains("::"):
			return
		var global := existing.get_global_name()
		if global != "" and EditorInterface.get_editor_settings().get_setting("docks/scene_tree/derive_script_globals_by_name"):
			inherits = global
		else:
			inherits = "\"%s\"" % existing.resource_path
	var dialog := _plugin.get_script_create_dialog()
	# Built-in scripts can't be opened in Neovim, and with the Script screen
	# off nothing else can edit them.
	dialog.config(inherits, path, false, true)
	# As SceneTreeDock does: listen until the dialog closes. script_created
	# comes before confirmed.
	_dialog_closed()
	_created = _on_script_created.bind(nodes)
	dialog.script_created.connect(_created)
	dialog.confirmed.connect(_dialog_closed)
	dialog.canceled.connect(_dialog_closed)
	dialog.popup_centered()


func _dialog_closed() -> void:
	var dialog := _plugin.get_script_create_dialog()
	if _created.is_valid() and dialog.script_created.is_connected(_created):
		dialog.script_created.disconnect(_created)
	_created = Callable()
	if dialog.confirmed.is_connected(_dialog_closed):
		dialog.confirmed.disconnect(_dialog_closed)
	if dialog.canceled.is_connected(_dialog_closed):
		dialog.canceled.disconnect(_dialog_closed)


func _on_script_created(script: Script, nodes: Array) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Attach Script", UndoRedo.MERGE_DISABLE, nodes[0])
	for n in nodes:
		if not is_instance_valid(n):
			continue
		ur.add_do_method(n, &"set_script", script)
		ur.add_undo_method(n, &"set_script", n.get_script())
	ur.commit_action()
	if script_opened.is_valid():
		script_opened.call(script)


func detach() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.is_empty():
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Detach Script", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	for n in nodes:
		var existing: Script = n.get_script()
		var empty := custom_type_script(n)
		if existing == empty:
			continue
		ur.add_do_method(n, &"set_script", empty)
		ur.add_undo_method(n, &"set_script", existing)
		# Detaching drops the script's property values; undo brings them back.
		for p in n.get_property_list():
			if p["usage"] & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR):
				ur.add_undo_property(n, p["name"], n.get(p["name"]))
	ur.commit_action()


# --- Scene dock buttons --------------------------------------------------------

const _BUTTONS := [
	["attach", "ScriptCreate", "Attach a new or existing script to the selected node."],
	["extend", "ScriptExtend", "Extend the script of the selected node."],
	["detach", "ScriptRemove", "Detach the script from the selected node."],
]


## Adds our buttons beside Godot's (hidden) Attach Script button in the
## Scene dock's toolbar, taking its shortcut. Godot's Ctrl+A goes to the
## dock first, which does nothing with scripts off; a button inside the dock
## sees it before the dock does.
func _add_buttons() -> void:
	var docks := EditorInterface.get_base_control().find_children("*", "SceneTreeDock", true, false)
	if docks.is_empty():
		return
	var theme := EditorInterface.get_editor_theme()
	var anchor: Button = null
	var shortcuts := {}
	for b in docks[0].find_children("*", "Button", true, false):
		for spec in _BUTTONS:
			if b.icon == theme.get_icon(spec[1], &"EditorIcons") and b.get_window() == docks[0].get_window():
				shortcuts[spec[0]] = b.shortcut
				if spec[0] == "attach":
					anchor = b
	if anchor == null:
		push_warning("godot_nvim: can't find the Scene dock's Attach Script button")
		return
	var at := anchor.get_index()
	for spec in _BUTTONS:
		var b := Button.new()
		b.name = "NeovimScript" + String(spec[0]).capitalize()
		b.theme_type_variation = anchor.theme_type_variation
		b.icon = theme.get_icon(spec[1], &"EditorIcons")
		b.tooltip_text = spec[2]
		b.shortcut = shortcuts.get(spec[0])
		b.shortcut_in_tooltip = true
		b.visible = false
		b.pressed.connect(detach if spec[0] == "detach" else attach.bind(spec[0] == "extend"))
		at += 1
		anchor.add_sibling(b)
		anchor.get_parent().move_child(b, at)
		_buttons[spec[0]] = b
	# Follow editor theme changes, like Godot's own buttons.
	anchor.get_parent().theme_changed.connect(func() -> void:
		for spec in _BUTTONS:
			if is_instance_valid(_buttons.get(spec[0])):
				_buttons[spec[0]].icon = EditorInterface.get_editor_theme().get_icon(spec[1], &"EditorIcons"))


## The Scene dock's right-click menu.
class Menu extends EditorContextMenuPlugin:
	var _actions: Node

	func _init(actions: Node) -> void:
		_actions = actions

	func _popup_menu(_paths: PackedStringArray) -> void:
		if not _actions.scripts_off():
			return
		var can: Dictionary = _actions.actions(EditorInterface.get_selection().get_selected_nodes())
		var theme := EditorInterface.get_editor_theme()
		if can["attach"]:
			add_context_menu_item("Attach Script", func(_n: Array) -> void: _actions.attach(false), theme.get_icon(&"ScriptCreate", &"EditorIcons"))
		if can["extend"]:
			add_context_menu_item("Extend Script", func(_n: Array) -> void: _actions.attach(true), theme.get_icon(&"ScriptExtend", &"EditorIcons"))
		if can["detach"]:
			add_context_menu_item("Detach Script", func(_n: Array) -> void: _actions.detach(), theme.get_icon(&"ScriptRemove", &"EditorIcons"))
