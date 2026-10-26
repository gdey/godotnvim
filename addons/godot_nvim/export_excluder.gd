## Keeps the addon out of exported games; it only runs in the editor.
@tool
extends EditorExportPlugin

const _ADDON_DIR := "res://addons/godot_nvim/"
## Export plugins run sorted by name, and the first one that skips or remaps
## a file wins. This must sort before "GDScript", or that plugin compiles
## our scripts first and _export_file is never called for them.
const NAME := "AddonExclude_godot_nvim"


func _get_name() -> String:
	return NAME


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_DIR):
		skip()
