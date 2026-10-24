## Screen state for Neovim's ext_linegrid UI: one grid of cells plus the
## highlight table, default colors, cursor and mode.
##
## Feed it the batches of a "redraw" notification with [method apply]; it
## emits [signal flushed] when Neovim says the screen is consistent.
class_name NvimGrid
extends RefCounted

signal flushed
signal title_changed(title: String)
signal mode_changed(mode: String)

const _UNSET := -1

var width := 0
var height := 0
## Per row: PackedStringArray of cell text ("" for the right half of a wide char).
var text: Array[PackedStringArray] = []
## Per row: PackedInt32Array of highlight ids.
var hl: Array[PackedInt32Array] = []

var default_fg := Color.WHITE
var default_bg := Color.BLACK
var default_sp := Color.RED
## id -> Dictionary of rgb_attr as Neovim sends it.
var attrs := {0: {}}

var cursor_row := 0
var cursor_col := 0
var mode := "normal"
## mode name -> Dictionary from mode_info_set ("cursor_shape", "cell_percentage", ...)
var mode_info := {}
var busy := false


func resize(w: int, h: int) -> void:
	width = w
	height = h
	text.resize(h)
	hl.resize(h)
	for r in h:
		var t := PackedStringArray()
		t.resize(w)
		t.fill(" ")
		var a := PackedInt32Array()
		a.resize(w)
		text[r] = t
		hl[r] = a
	cursor_row = mini(cursor_row, maxi(h - 1, 0))
	cursor_col = mini(cursor_col, maxi(w - 1, 0))


## Applies the params of one "redraw" notification.
func apply(batches: Array) -> void:
	for batch in batches:
		var name: String = batch[0]
		for i in range(1, batch.size()):
			_event(name, batch[i])


func _event(name: String, args: Array) -> void:
	match name:
		"grid_resize":
			resize(args[1], args[2])
		"grid_clear":
			resize(width, height)
		"grid_line":
			_grid_line(args[1], args[2], args[3])
		"grid_scroll":
			_grid_scroll(args[1], args[2], args[3], args[4], args[5])
		"grid_cursor_goto":
			cursor_row = args[1]
			cursor_col = args[2]
		"default_colors_set":
			default_fg = _rgb(args[0], Color.WHITE)
			default_bg = _rgb(args[1], Color.BLACK)
			default_sp = _rgb(args[2], Color.RED)
		"hl_attr_define":
			attrs[args[0]] = args[1]
		"mode_info_set":
			mode_info.clear()
			for info in args[1]:
				mode_info[info.get("name", "")] = info
		"mode_change":
			mode = args[0]
			mode_changed.emit(mode)
		"busy_start":
			busy = true
		"busy_stop":
			busy = false
		"set_title":
			title_changed.emit(args[0])
		"flush":
			flushed.emit()


func _grid_line(row: int, col: int, cells: Array) -> void:
	if row < 0 or row >= height:
		return
	var t := text[row]
	var a := hl[row]
	var cur_hl := 0
	for cell in cells:
		var s: String = cell[0]
		if cell.size() > 1:
			cur_hl = cell[1]
		var rep: int = cell[2] if cell.size() > 2 else 1
		for _r in rep:
			if col >= width:
				break
			t[col] = s
			a[col] = cur_hl
			col += 1
	text[row] = t
	hl[row] = a


func _grid_scroll(top: int, bot: int, left: int, right: int, rows: int) -> void:
	# Rows move up by `rows` (down if negative) inside the region; the
	# vacated rows keep stale content until Neovim redraws them.
	if rows > 0:
		for r in range(top, bot - rows):
			_copy_row(r + rows, r, left, right)
	elif rows < 0:
		for r in range(bot - 1, top - rows - 1, -1):
			_copy_row(r + rows, r, left, right)


func _copy_row(src: int, dst: int, left: int, right: int) -> void:
	var st := text[src]
	var sa := hl[src]
	var dt := text[dst]
	var da := hl[dst]
	for c in range(left, right):
		dt[c] = st[c]
		da[c] = sa[c]
	text[dst] = dt
	hl[dst] = da


## Resolved colors for highlight [param id]: [fg, bg, sp], with reverse applied.
func colors(id: int) -> Array[Color]:
	var a: Dictionary = attrs.get(id, {})
	var fg := _rgb(a.get("foreground", _UNSET), default_fg)
	var bg := _rgb(a.get("background", _UNSET), default_bg)
	var sp := _rgb(a.get("special", _UNSET), default_sp)
	if a.get("reverse", false):
		var t := fg
		fg = bg
		bg = t
	if a.has("blend"):
		bg.a = 1.0 - float(a["blend"]) / 100.0
	return [fg, bg, sp]


func attr(id: int) -> Dictionary:
	return attrs.get(id, {})


## Returns the row's text as a plain string, for tests and debugging.
func row_string(row: int) -> String:
	return "".join(text[row])


static func _rgb(v: Variant, fallback: Color) -> Color:
	if v == null or int(v) < 0:
		return fallback
	return Color.hex((int(v) << 8) | 0xff)
