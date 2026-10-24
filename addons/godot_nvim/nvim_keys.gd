## Translates Godot input events to Neovim key notation for nvim_input.
class_name NvimKeys
extends RefCounted

const _SPECIAL := {
	KEY_ENTER: "CR", KEY_KP_ENTER: "CR", KEY_ESCAPE: "Esc", KEY_BACKSPACE: "BS",
	KEY_TAB: "Tab", KEY_DELETE: "Del", KEY_INSERT: "Insert", KEY_HOME: "Home",
	KEY_END: "End", KEY_PAGEUP: "PageUp", KEY_PAGEDOWN: "PageDown",
	KEY_UP: "Up", KEY_DOWN: "Down", KEY_LEFT: "Left", KEY_RIGHT: "Right",
	KEY_SPACE: "Space",
	KEY_F1: "F1", KEY_F2: "F2", KEY_F3: "F3", KEY_F4: "F4", KEY_F5: "F5",
	KEY_F6: "F6", KEY_F7: "F7", KEY_F8: "F8", KEY_F9: "F9", KEY_F10: "F10",
	KEY_F11: "F11", KEY_F12: "F12",
}

const _MODIFIER_KEYS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK]


## Returns the keys for a pressed key event, or "" if it should be ignored.
static func from_event(e: InputEventKey) -> String:
	var code := e.keycode if e.keycode != KEY_NONE else e.physical_keycode
	if code in _MODIFIER_KEYS:
		return ""
	var ctrl := e.ctrl_pressed
	var alt := e.alt_pressed
	var meta := e.meta_pressed
	var shift := e.shift_pressed
	if _SPECIAL.has(code):
		var name: String = _SPECIAL[code]
		if name == "Space" and not (ctrl or alt or meta or shift):
			return " "
		return _wrap(name, ctrl, alt, meta, shift)
	var ch := ""
	if e.unicode != 0 and not (ctrl or alt or meta):
		ch = String.chr(e.unicode)
		return "<lt>" if ch == "<" else ch
	# With a modifier held, unicode is unreliable (0 for Ctrl, composed
	# characters for macOS Option); use the layout-aware key label instead.
	var label := e.key_label if e.key_label != KEY_NONE else code
	if label == KEY_NONE or label > 0x10ffff:
		return ""
	ch = String.chr(label)
	if ch.length() != 1:
		return ""
	if shift and ch.to_upper() != ch.to_lower():
		ch = ch.to_upper()
		shift = false
	else:
		ch = ch.to_lower()
	if ch == "<":
		ch = "lt"
	elif ch == ">":
		ch = "gt"
	elif ch == "\\":
		ch = "Bslash"
	elif ch == "|":
		ch = "Bar"
	if not (ctrl or alt or meta):
		return ch if ch.length() == 1 else "<%s>" % ch
	return _wrap(ch, ctrl, alt, meta, shift and ch.length() > 1)


## Modifier string for nvim_input_mouse ("C", "S", "A", "D").
static func modifiers(e: InputEventWithModifiers) -> String:
	var m := ""
	if e.ctrl_pressed:
		m += "C"
	if e.shift_pressed:
		m += "S"
	if e.alt_pressed:
		m += "A"
	if e.meta_pressed:
		m += "D"
	return m


static func _wrap(name: String, ctrl: bool, alt: bool, meta: bool, shift: bool) -> String:
	var p := ""
	if ctrl:
		p += "C-"
	if shift:
		p += "S-"
	if alt:
		p += "M-"
	if meta:
		p += "D-"
	return "<%s%s>" % [p, name]
