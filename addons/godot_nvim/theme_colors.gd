## Reads the script editor's colors (Editor Settings →
## text_editor/theme/highlighting) for Neovim's "godot" colorscheme.
@tool
extends RefCounted

const _PREFIX := "text_editor/theme/highlighting/"


## Setting name below text_editor/theme/highlighting/ (such as "keyword_color"
## or "gdscript/annotation_color") -> "#rrggbb". Godot's colors can be
## translucent; Neovim's can't, so each is blended over the background.
## Adds "dark": whether the background is dark.
static func from_settings(es: EditorSettings) -> Dictionary:
	var bg: Color = es.get_setting(_PREFIX + "background_color")
	bg = _over(bg, Color.BLACK)
	var out := {}
	for p in es.get_property_list():
		var name: String = p["name"]
		if not name.begins_with(_PREFIX):
			continue
		var c: Variant = es.get_setting(name)
		if c is Color:
			out[name.trim_prefix(_PREFIX)] = "#" + _over(c, bg).to_html(false)
	# The completion popup draws its own background; blend its overlays on it.
	var popup := _over(es.get_setting(_PREFIX + "completion_background_color"), bg)
	for key in ["completion_selected_color", "completion_scroll_color", "completion_font_color"]:
		if es.has_setting(_PREFIX + key):
			out[key] = "#" + _over(es.get_setting(_PREFIX + key), popup).to_html(false)
	out["dark"] = bg.get_luminance() < 0.5
	return out


static func _over(c: Color, bg: Color) -> Color:
	var a := clampf(c.a, 0.0, 1.0)
	return Color(
		clampf(lerpf(bg.r, c.r, a), 0.0, 1.0),
		clampf(lerpf(bg.g, c.g, a), 0.0, 1.0),
		clampf(lerpf(bg.b, c.b, a), 0.0, 1.0))
