## Applies the cendre theme to the Godot editor: picks cendre.tet for the
## script editor and sets the interface colors. Copy cendre.tet into Godot's
## text_editor_themes folder first, then open this file in the Script editor
## and run it with File > Run (Ctrl/Cmd+Shift+X).
##
## Scripts can't make the editor reload its theme, so this saves your scenes and
## restarts the editor to finish.
@tool
extends EditorScript


const SETTINGS := {
	"interface/theme/preset": "Custom",
	"interface/theme/base_color": Color("201b19"),
	"interface/theme/accent_color": Color("ea9875"),
	"interface/theme/contrast": 0.2,
	"interface/theme/icon_and_font_color": 0, # Auto
	"text_editor/theme/color_theme": "cendre",
}


func _run() -> void:
	apply(EditorInterface.get_editor_settings())
	EditorInterface.restart_editor(true)


static func apply(es: EditorSettings) -> void:
	for key: String in SETTINGS:
		es.set_setting(key, SETTINGS[key])
