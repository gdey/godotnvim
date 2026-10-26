## Keeps the addon out of exported games; it only runs in the editor.
@tool
extends EditorExportPlugin

const _ADDON_DIR := "res://addons/godot_nvim/"


func _get_name() -> String:
	return "godot_nvim_export_excluder"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_DIR):
		skip()
