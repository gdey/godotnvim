## A Control that runs an embedded Neovim and draws its ext_linegrid UI.
##
## Keyboard and mouse input go to Neovim. Nodes and files dragged from the
## editor's docks are inserted the way Godot's own script editor does it,
## via [member drop_builder].
@tool
class_name NvimView
extends Control

signal attached_to_nvim
## [param breakpoints]: the buffer's 1-based breakpoint lines at save time.
signal file_saved(path: String, breakpoints: Array)
signal buffer_entered(path: String)
## The user toggled a breakpoint in Neovim; [param line] is 1-based.
signal breakpoint_requested(path: String, line: int, enabled: bool)
signal nvim_exited

@export var nvim_path := "nvim"
@export var nvim_args := PackedStringArray()
@export var font: Font
@export var font_size := 14
## Optional working directory for Neovim (":cd" on startup).
@export var working_dir := ""
## Godot's GDScript language server; port 0 leaves LSP to the user's config.
@export var lsp_host := "127.0.0.1"
@export var lsp_port := 0

## Callable(data: Variant, modifier: bool) -> Dictionary returning what
## [method DropText.build] returns. Unset means drops are refused.
var drop_builder := Callable()

var rpc := NvimRpc.new()
var grid := NvimGrid.new()
var attached := false

var _cell := Vector2(8, 16)
var _ascent := 12.0
var _fonts := {}  # "b"/"i"/"bi" -> Font
var _mouse_button := ""
var _last_mouse_cell := Vector2i(-1, -1)


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_IBEAM


func _ready() -> void:
	rpc.notification.connect(_on_notification)
	rpc.exited.connect(_on_exited)
	grid.flushed.connect(queue_redraw)
	resized.connect(_on_resized)
	_update_metrics()


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	rpc.poll()


func start() -> Error:
	if rpc.is_running():
		return OK
	var args := PackedStringArray()
	if working_dir != "":
		args.append_array(["--cmd", "cd " + _fnameescape(working_dir)])
	args.append_array(nvim_args)
	var err := rpc.start(nvim_path, args)
	if err != OK:
		push_error("godot_nvim: could not start %s (%s)" % [nvim_path, error_string(err)])
		return err
	rpc.request("nvim_get_api_info", [], _on_api_info)
	return OK


func stop() -> void:
	attached = false
	rpc.stop()


## Opens [param path] (res:// or absolute) in Neovim, at [param line] if > 0.
func open_file(path: String, line := 0, column := 0) -> void:
	if not rpc.is_running():
		start()
	var abs_path := ProjectSettings.globalize_path(path)
	rpc.request("nvim_exec_lua", [
		"local p, l, c = ... vim.cmd.drop(vim.fn.fnameescape(p))" +
		" if l > 0 then pcall(vim.api.nvim_win_set_cursor, 0, {l, math.max(c - 1, 0)}) vim.cmd('normal! zz') end",
		[abs_path, line, column]])
	grab_focus()


## Shows [param lines] (1-based) as breakpoint signs in [param path]'s buffer.
func set_breakpoints(path: String, lines: Array) -> void:
	if attached:
		rpc.request("nvim_exec_lua", ["godot_nvim.set_breakpoints(...)",
			[ProjectSettings.globalize_path(path), lines]])


func cell_size() -> Vector2:
	return _cell


func _on_api_info(err: Variant, res: Variant) -> void:
	if err != null:
		push_error("godot_nvim: %s" % [err])
		return
	var chan: int = res[0]
	var src := FileAccess.get_file_as_string(get_script().resource_path.get_base_dir().path_join("godot_nvim.lua"))
	var opts := {"root": working_dir if working_dir != "" else ProjectSettings.globalize_path("res://")}
	if lsp_port > 0:
		opts["lsp"] = {"host": lsp_host, "port": lsp_port}
	rpc.request("nvim_exec_lua", [src, [chan, opts]])
	var dims := _grid_dims()
	rpc.request("nvim_ui_attach", [dims.x, dims.y, {"ext_linegrid": true, "rgb": true}])
	attached = true
	attached_to_nvim.emit()


func _on_notification(method: String, params: Array) -> void:
	match method:
		"redraw":
			grid.apply(params)
		"godot_nvim_saved":
			file_saved.emit(ProjectSettings.localize_path(params[0]), params[1] if params.size() > 1 else [])
		"godot_nvim_set_breakpoint":
			breakpoint_requested.emit(ProjectSettings.localize_path(params[0]), params[1], params[2])
		"godot_nvim_buf_enter":
			buffer_entered.emit(ProjectSettings.localize_path(params[0]))


func _on_exited() -> void:
	attached = false
	nvim_exited.emit()
	queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_THEME_CHANGED:
			_update_metrics()
		NOTIFICATION_FOCUS_ENTER:
			if attached:
				rpc.request("nvim_ui_set_focus", [true])
			queue_redraw()
		NOTIFICATION_FOCUS_EXIT:
			if attached:
				rpc.request("nvim_ui_set_focus", [false])
			queue_redraw()


func _on_resized() -> void:
	if attached:
		var d := _grid_dims()
		if d.x != grid.width or d.y != grid.height:
			rpc.request("nvim_ui_try_resize", [d.x, d.y])


func _grid_dims() -> Vector2i:
	return Vector2i(maxi(int(size.x / _cell.x), 1), maxi(int(size.y / _cell.y), 1))


func _base_font() -> Font:
	if font:
		return font
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Menlo", "SF Mono", "DejaVu Sans Mono", "Consolas", "monospace"])
	font = f
	return f


func _update_metrics() -> void:
	var f := _base_font()
	_fonts.clear()
	_cell = Vector2(ceilf(f.get_char_size("M".unicode_at(0), font_size).x), ceilf(f.get_height(font_size)))
	_ascent = f.get_ascent(font_size)
	_on_resized()
	queue_redraw()


func _font_for(a: Dictionary) -> Font:
	var key := ("b" if a.get("bold", false) else "") + ("i" if a.get("italic", false) else "")
	if key == "":
		return _base_font()
	if not _fonts.has(key):
		var v := FontVariation.new()
		v.base_font = _base_font()
		if "b" in key:
			v.variation_embolden = 0.7
		if "i" in key:
			v.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
		_fonts[key] = v
	return _fonts[key]


# --- Drawing -----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), grid.default_bg)
	for r in grid.height:
		_draw_row(r)
	if grid.height > 0:
		_draw_cursor()


func _draw_row(r: int) -> void:
	var t := grid.text[r]
	var ids := grid.hl[r]
	var y := r * _cell.y
	var c := 0
	while c < grid.width:
		var id := ids[c]
		var start := c
		var s := ""
		while c < grid.width and ids[c] == id:
			s += t[c]
			c += 1
		var cols := grid.colors(id)
		var x := start * _cell.x
		var w := (c - start) * _cell.x
		if cols[1] != grid.default_bg:
			draw_rect(Rect2(x, y, w, _cell.y), cols[1])
		var a := grid.attr(id)
		if s.strip_edges() != "":
			draw_string(_font_for(a), Vector2(x, y + _ascent), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, cols[0])
		_draw_decorations(a, cols, x, y, w)


func _draw_decorations(a: Dictionary, cols: Array[Color], x: float, y: float, w: float) -> void:
	var base := y + _cell.y - 1
	var sp: Color = cols[2] if a.has("special") else cols[0]
	if a.get("underline", false):
		draw_line(Vector2(x, base), Vector2(x + w, base), sp)
	if a.get("underdouble", false):
		draw_line(Vector2(x, base), Vector2(x + w, base), sp)
		draw_line(Vector2(x, base - 2), Vector2(x + w, base - 2), sp)
	if a.get("undercurl", false) or a.get("underdashed", false) or a.get("underdotted", false):
		var pts := PackedVector2Array()
		var step := 2.0
		var i := 0
		var px := x
		while px <= x + w:
			pts.append(Vector2(px, base - (i % 2) * 2))
			px += step
			i += 1
		if pts.size() > 1:
			draw_polyline(pts, sp)
	if a.get("strikethrough", false):
		var mid := y + _cell.y / 2
		draw_line(Vector2(x, mid), Vector2(x + w, mid), cols[0])


func _draw_cursor() -> void:
	var r := clampi(grid.cursor_row, 0, grid.height - 1)
	var c := clampi(grid.cursor_col, 0, grid.width - 1)
	var info: Dictionary = grid.mode_info.get(grid.mode, {})
	var shape: String = info.get("cursor_shape", "block")
	var pct: float = info.get("cell_percentage", 100) / 100.0
	if pct <= 0:
		pct = 1.0
	var id := grid.hl[r][c]
	var cols := grid.colors(id)
	var cur_bg := cols[0]
	var cur_fg := cols[1]
	var cid: int = info.get("attr_id", 0)
	if cid > 0:
		var cc := grid.colors(cid)
		cur_bg = cc[1]
		cur_fg = cc[0]
	var pos := Vector2(c * _cell.x, r * _cell.y)
	var wide := c + 1 < grid.width and grid.text[r][c + 1] == ""
	var cw := _cell.x * (2 if wide else 1)
	if not has_focus():
		draw_rect(Rect2(pos, Vector2(cw, _cell.y)), cur_bg, false, 1.0)
		return
	match shape:
		"vertical":
			draw_rect(Rect2(pos, Vector2(maxf(cw * pct, 1), _cell.y)), cur_bg)
		"horizontal":
			var h := maxf(_cell.y * pct, 1)
			draw_rect(Rect2(pos + Vector2(0, _cell.y - h), Vector2(cw, h)), cur_bg)
		_:
			draw_rect(Rect2(pos, Vector2(cw, _cell.y)), cur_bg)
			var ch := grid.text[r][c]
			if ch.strip_edges() != "":
				draw_string(_font_for(grid.attr(id)), pos + Vector2(0, _ascent), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, cur_fg)


# --- Input -------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if not attached:
		return
	if event is InputEventKey:
		if event.pressed:
			var keys := NvimKeys.from_event(event)
			if keys != "":
				rpc.request("nvim_input", [keys])
		accept_event()
	elif event is InputEventMouseButton:
		_mouse_button_event(event)
		accept_event()
	elif event is InputEventMouseMotion:
		if _mouse_button != "":
			var cell := _cell_at(event.position)
			if cell != _last_mouse_cell:
				_last_mouse_cell = cell
				_send_mouse(_mouse_button, "drag", event, cell)
			accept_event()


func _mouse_button_event(e: InputEventMouseButton) -> void:
	var cell := _cell_at(e.position)
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			if e.pressed:
				var dir: String = {MOUSE_BUTTON_WHEEL_UP: "up", MOUSE_BUTTON_WHEEL_DOWN: "down",
					MOUSE_BUTTON_WHEEL_LEFT: "left", MOUSE_BUTTON_WHEEL_RIGHT: "right"}[e.button_index]
				_send_mouse("wheel", dir, e, cell)
			return
	var button: String = {MOUSE_BUTTON_LEFT: "left", MOUSE_BUTTON_RIGHT: "right",
		MOUSE_BUTTON_MIDDLE: "middle"}.get(e.button_index, "")
	if button == "":
		return
	if e.pressed:
		grab_focus()
		_mouse_button = button
		_last_mouse_cell = cell
		_send_mouse(button, "press", e, cell)
	else:
		_mouse_button = ""
		_send_mouse(button, "release", e, cell)


func _send_mouse(button: String, action: String, e: InputEventWithModifiers, cell: Vector2i) -> void:
	rpc.request("nvim_input_mouse", [button, action, NvimKeys.modifiers(e), 0, cell.y, cell.x])


func _cell_at(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(p.x / _cell.x), 0, maxi(grid.width - 1, 0)),
		clampi(int(p.y / _cell.y), 0, maxi(grid.height - 1, 0)))


# --- Drag and drop -------------------------------------------------------------

func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return attached and drop_builder.is_valid() and not drop_builder.call(data, false).is_empty()


func _drop_data(at: Vector2, data: Variant) -> void:
	var modifier := Input.is_key_pressed(KEY_META if OS.has_feature("macos") else KEY_CTRL)
	var res: Dictionary = drop_builder.call(data, modifier)
	if res.is_empty():
		return
	drop_text_at(_cell_at(at), res)
	grab_focus()


## Inserts [param res] ({"kind", "text"}) at the buffer position under
## [param cell]. A mouse click lets Neovim map the cell to a buffer
## position itself, so folds, wrapping and sign columns are handled.
func drop_text_at(cell: Vector2i, res: Dictionary) -> void:
	# One Lua call: nvim_input is a "fast" API that Neovim acts on before
	# queued requests, so sending the payload separately would race the input.
	rpc.request("nvim_exec_lua", ["godot_nvim.queue_drop(...)", [res["kind"], res["text"], cell.y, cell.x]])


static func _fnameescape(p: String) -> String:
	return p.replace("\\", "\\\\").replace(" ", "\\ ")
