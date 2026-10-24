## Headless tests. Run with:
##   godot --headless --path . -s tests/run_tests.gd
## Set NVIM to the nvim binary if it is not on PATH.
extends SceneTree

var _failures := 0


func _init() -> void:
	await process_frame
	_test_msgpack()
	_test_keys()
	_test_drop_text()
	await _test_embed()
	await _test_view_drop()
	print("FAILED: %d" % _failures if _failures else "ALL PASSED")
	quit(1 if _failures else 0)


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _test_msgpack() -> void:
	print("msgpack")
	var values := [null, true, false, 0, 127, 128, 255, 256, 65535, 65536, 1 << 40,
		-1, -32, -33, -128, -129, -40000, -(1 << 40), 1.5, "", "hi",
		"x".repeat(40), "y".repeat(300), "z".repeat(70000), [1, [2, "three"]],
		{"a": 1, "b": [true]}, PackedByteArray([1, 2, 3])]
	for v in values:
		var back: Variant = Msgpack.decode(Msgpack.encode(v))
		check(typeof(back) == typeof(v) and back == v, "roundtrip %s" % str(v).left(30))
	var e := Msgpack.Ext.new(0, Msgpack.encode(7))
	var eb: Variant = Msgpack.decode(Msgpack.encode(e))
	check(eb is Msgpack.Ext and eb.type == 0 and eb.as_int() == 7, "ext roundtrip")
	# Streaming: feed byte by byte.
	var bytes := Msgpack.encode([1, "hello", {"k": [1, 2]}]) + Msgpack.encode(42)
	var d := Msgpack.Decoder.new()
	var got := []
	for b in bytes:
		d.feed(PackedByteArray([b]))
		var r := d.next()
		if r[0]:
			got.append(r[1])
	check(got == [[1, "hello", {"k": [1, 2]}], 42], "streaming decode")


func _nvim_path() -> String:
	var p := OS.get_environment("NVIM")
	return p if p != "" else "nvim"


func _test_embed() -> void:
	print("embed")
	var rpc := NvimRpc.new()
	var grid := NvimGrid.new()
	rpc.notification.connect(func(m, p): if m == "redraw": grid.apply(p))
	check(rpc.start(_nvim_path(), ["--clean", "-n"]) == OK, "start nvim")
	var info := []
	rpc.request("nvim_get_api_info", [], func(err, res): info.append(res))
	rpc.request("nvim_ui_attach", [40, 5, {"ext_linegrid": true, "rgb": true}])
	rpc.request("nvim_input", ["ihello world<Esc>"])
	var flushes := [0]
	grid.flushed.connect(func(): flushes[0] += 1)
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		rpc.poll()
		if flushes[0] > 0 and grid.height > 0 and grid.row_string(0).begins_with("hello world"):
			break
		await process_frame
	check(info.size() == 1 and info[0][0] is int, "api info has channel id")
	check(grid.width == 40 and grid.height == 5, "grid sized 40x5")
	check(grid.row_string(0).begins_with("hello world"), "typed text on row 0: '%s'" % grid.row_string(0).strip_edges())
	check(grid.cursor_row == 0 and grid.cursor_col == 10, "cursor at 0,10 (%d,%d)" % [grid.cursor_row, grid.cursor_col])
	rpc.stop()


func _key(code: Key, unicode := 0, mods := "", label: Key = KEY_NONE) -> String:
	var e := InputEventKey.new()
	e.pressed = true
	e.keycode = code
	e.key_label = label if label != KEY_NONE else code
	e.unicode = unicode
	e.ctrl_pressed = "c" in mods
	e.shift_pressed = "s" in mods
	e.alt_pressed = "a" in mods
	e.meta_pressed = "m" in mods
	return NvimKeys.from_event(e)


func _test_keys() -> void:
	print("keys")
	check(_key(KEY_A, "a".unicode_at(0)) == "a", "a")
	check(_key(KEY_A, "A".unicode_at(0), "s") == "A", "shift-a")
	check(_key(KEY_COMMA, "<".unicode_at(0), "s") == "<lt>", "<")
	check(_key(KEY_ESCAPE) == "<Esc>", "esc")
	check(_key(KEY_ENTER) == "<CR>", "enter")
	check(_key(KEY_TAB, 0, "s") == "<S-Tab>", "shift-tab")
	check(_key(KEY_W, 0, "c") == "<C-w>", "ctrl-w: " + _key(KEY_W, 0, "c"))
	check(_key(KEY_S, 0, "m") == "<D-s>", "cmd-s")
	check(_key(KEY_X, 0, "a") == "<M-x>", "alt-x")
	check(_key(KEY_BACKSLASH, 0, "c") == "<C-Bslash>", "ctrl-backslash")
	check(_key(KEY_SPACE, " ".unicode_at(0)) == " ", "space")
	check(_key(KEY_SPACE, 0, "c") == "<C-Space>", "ctrl-space")
	check(_key(KEY_SHIFT, 0, "s") == "", "bare shift ignored")


func _test_drop_text() -> void:
	print("drop text")
	var main := Node2D.new()
	main.name = "Main"
	var script := GDScript.new()
	script.source_code = "extends Node\n"
	script.reload()
	var holder := Node.new()
	holder.name = "Holder"
	main.add_child(holder)
	holder.owner = main
	holder.set_script(script)
	var player := CharacterBody2D.new()
	player.name = "Player"
	main.add_child(player)
	player.owner = main
	var odd := Sprite2D.new()
	odd.name = "Odd Name"
	player.add_child(odd)
	odd.owner = main
	var hud := Control.new()
	hud.name = "HUD"
	main.add_child(hud)
	hud.owner = main
	hud.unique_name_in_owner = true
	root.add_child(main)

	var sn := DropText.find_script_node(main, script)
	check(sn == holder, "finds script node")
	var data := {"type": "nodes", "nodes": [player.get_path()]}
	check(DropText.build(data, main, main, false, true) == {"kind": "text", "text": "$Player"}, "plain drop")
	check(DropText.build(data, main, holder, false, true)["text"] == "$../Player", "relative to script node")
	data = {"type": "nodes", "nodes": [odd.get_path(), hud.get_path()]}
	check(DropText.build(data, main, main, false, true)["text"] == "$\"Player/Odd Name\", %HUD", "quoted + unique")
	var r := DropText.build(data, main, main, true, true)
	check(r == {"kind": "lines", "text": "@onready var odd_name: Sprite2D = $\"Player/Odd Name\"\n@onready var hud: Control = %HUD\n"}, "onready lines: " + str(r))
	r = DropText.build({"type": "nodes", "nodes": [player.get_path()]}, main, main, true, false)
	check(r["text"] == "@onready var player = $Player\n", "onready without hints")
	r = DropText.build({"type": "files", "files": ["res://art/my_icon.png"]}, main, main, false, true)
	check(r["text"] == "\"res://art/my_icon.png\"", "file drop")
	r = DropText.build({"type": "files", "files": ["res://art/my_icon.png"]}, main, main, true, true)
	check(r["text"] == "const MyIcon = preload(\"res://art/my_icon.png\")\n", "file preload: " + r["text"])
	check(DropText.build({"type": "obj_property"}, main, main, false, true).is_empty(), "ignores other drags")
	main.queue_free()


func _wait(cond: Callable, ms := 3000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _test_view_drop() -> void:
	print("view drop")
	var view := NvimView.new()
	view.nvim_path = _nvim_path()
	view.nvim_args = PackedStringArray(["--clean", "-n"])
	view.size = Vector2(800, 400)
	root.add_child(view)
	check(view.start() == OK, "view starts nvim")
	check(await _wait(func(): return view.attached and view.grid.height > 0), "view attached")
	var path := OS.get_cache_dir().path_join("godot_nvim_test.gd")
	FileAccess.open(path, FileAccess.WRITE).store_string("extends Node\n\nfunc _ready():\n    pass\n")
	view.open_file(path)
	check(await _wait(func(): return view.grid.row_string(0).begins_with("extends Node")), "file shown in grid")
	# Drop onto row 2 ("func _ready():") inserts the line above it.
	view.drop_text_at(Vector2i(3, 2), {"kind": "lines", "text": "@onready var player: Node = $Player\n"})
	check(await _wait(func(): return view.grid.row_string(2).begins_with("@onready var player")), "onready line inserted at drop row")
	# Drop "$HUD" on the "a" of "    pass" (row 4).
	view.drop_text_at(Vector2i(5, 4), {"kind": "text", "text": "$HUD"})
	await _wait(func(): return "$HUD" in view.grid.row_string(4))
	var lines := []
	view.rpc.request("nvim_buf_get_lines", [0, 0, -1, false], func(e, res): lines.append(res))
	await _wait(func(): return lines.size() > 0)
	check(lines.size() > 0 and lines[0][4] == "    p$HUDass", "text inserted at cell: %s" % [lines[0][4] if lines.size() else lines])
	view.rpc.request("nvim_command", ["write"])
	var saved := []
	view.file_saved.connect(func(p, _bps): saved.append(p))
	check(await _wait(func(): return saved.size() > 0), "save notification")
	view.stop()
	view.queue_free()
