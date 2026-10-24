## Adds a "Neovim" main screen that edits scripts in an embedded Neovim.
@tool
extends EditorPlugin

const SETTING_PATH := "godot_nvim/nvim_path"
const SETTING_ARGS := "godot_nvim/nvim_args"

## Where GUI-launched editors usually find nvim; macOS apps don't get the
## shell's PATH.
const _NVIM_CANDIDATES := ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/usr/bin/nvim",
	"/snap/bin/nvim", "C:/Program Files/Neovim/bin/nvim.exe"]

var view: NvimView
var _current_path := ""


func _enter_tree() -> void:
	_ensure_settings()
	var es := EditorInterface.get_editor_settings()
	view = NvimView.new()
	view.name = "NeovimView"
	view.nvim_path = es.get_setting(SETTING_PATH)
	view.nvim_args = PackedStringArray(String(es.get_setting(SETTING_ARGS)).split(" ", false))
	view.working_dir = ProjectSettings.globalize_path("res://")
	var theme := EditorInterface.get_editor_theme()
	view.font = theme.get_font("source", "EditorFonts")
	view.font_size = theme.get_font_size("source_size", "EditorFonts")
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.drop_builder = _build_drop
	view.file_saved.connect(_on_file_saved)
	view.buffer_entered.connect(func(p: String) -> void: _current_path = p)
	EditorInterface.get_editor_main_screen().add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.hide()
	view.start()


func _exit_tree() -> void:
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


## File-backed GDScript, plus plain text files (Godot's internal TextFile
## class, which is how the FileSystem dock opens .cfg, .txt, .md, ...).
## Built-in scripts (path contains "::") stay in Godot's editor since
## Neovim can't open them.
func _handles(object: Object) -> bool:
	if not (object is GDScript or object.is_class("TextFile")):
		return false
	var path: String = object.resource_path
	return path != "" and not path.contains("::")


func _edit(object: Object) -> void:
	if _handles(object):
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


func _on_file_saved(path: String) -> void:
	if not path.begins_with("res://"):
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	if ResourceLoader.has_cached(path):
		var script := ResourceLoader.load(path) as Script
		if script:
			script.source_code = FileAccess.get_file_as_string(path)
			script.reload(true)


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
