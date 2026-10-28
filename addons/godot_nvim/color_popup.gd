## The color picker that :GodotColor opens on a Color literal in Neovim,
## like the one Godot's script editor opens from a color swatch: a
## ColorPicker and a list of the ways to write the color. Each pick replaces
## the literal in the buffer.
@tool
class_name NvimColorPopup
extends PopupPanel

## Emitted with the literal's new text, to write over [param old_text].
signal picked(old_text: String, new_text: String)

var picker := ColorPicker.new()
var forms := OptionButton.new()
## The literal's text in the buffer now.
var text := ""


func _init() -> void:
	picker.deferred_mode = true
	picker.hex_visible = false
	picker.color_changed.connect(func(_c: Color) -> void: _update_forms(); _write())
	var box := VBoxContainer.new()
	box.add_child(picker)
	add_child(box)
	forms.size_flags_horizontal = Control.SIZE_FILL
	forms.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	forms.fit_to_longest_item = false
	forms.item_selected.connect(func(_i: int) -> void: _write())
	# Below the picker; ColorPicker has no public slot for it.
	box.add_child(forms)


## Shows the picker on [param lit] (from [method ColorLiteral.at]), whose
## text is [param lit_text], at [param rect] (screen coordinates of the
## literal's first cell): below it, or above it when there is no room.
func open(lit: Dictionary, lit_text: String, rect: Rect2) -> void:
	text = lit_text
	picker.color = lit["color"]
	_update_forms()
	forms.select(lit["mode"])
	reset_size()
	var h := get_contents_minimum_size().y
	var pos := Vector2(rect.position.x, rect.end.y)
	var usable := Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	if not get_tree().root.gui_embed_subwindows and pos.y + h > usable.end.y:
		pos.y = rect.position.y - h
	elif get_tree().root.gui_embed_subwindows and pos.y + h > get_tree().root.get_visible_rect().size.y:
		pos.y = rect.position.y - h
	popup(Rect2i(Vector2i(pos), Vector2i.ZERO))


func _update_forms() -> void:
	var options := ColorLiteral.forms(picker.color)
	for i in options.size():
		if i < forms.item_count:
			forms.set_item_text(i, options[i])
		else:
			forms.add_item(options[i], i)


func _write() -> void:
	var new_text := forms.get_item_text(forms.selected)
	if new_text == text:
		return
	var old := text
	text = new_text
	picked.emit(old, new_text)
