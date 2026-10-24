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
	_test_overrides()
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


func _test_overrides() -> void:
	var base_path := "user://godot_nvim_test_base.gd"
	FileAccess.open(base_path, FileAccess.WRITE).store_string("extends CharacterBody2D\nfunc hit():\n\tpass\n")
	var s := GDScript.new()
	s.source_code = "extends \"%s\"\nfunc own():\n\tpass\n" % [base_path]
	s.reload()
	var methods: Dictionary = load("res://addons/godot_nvim/plugin.gd").overridable_methods(s)
	check(methods.get("_ready") == "Node", "_ready comes from Node: %s" % [methods.get("_ready")])
	check(methods.get("_physics_process") == "Node", "_physics_process from Node")
	check(methods.get("move_and_slide") == "CharacterBody2D", "move_and_slide from CharacterBody2D")
	check(methods.get("hit") == base_path, "hit from the base script: %s" % [methods.get("hit")])
	check(not methods.has("own"), "the script's own methods aren't overrides")


func _wait(cond: Callable, ms := 3000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()


## Sends a request and waits for its [error, result].
func _req(view: NvimView, method: String, params: Array) -> Array:
	var out := []
	view.rpc.request(method, params, func(e, r): out.append_array([e, r]))
	await _wait(func(): return out.size() == 2)
	return out if out.size() == 2 else ["timeout", null]


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
	check(await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node")), "file shown in grid")
	# Signal connections: a sign on the connected func, a warning for a missing one.
	view.set_connections(path, [
		{"method": "_ready", "signal": "pressed", "source": "Button", "target": "Main", "missing": false},
		{"method": "_gone", "signal": "toggled", "source": "Button", "target": "Main", "missing": true}])
	var marks: Array = await _req(view, "nvim_exec_lua", ["local ns = vim.api.nvim_get_namespaces() local r = {} for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns.godot_nvim_slots, 0, -1, {})) do table.insert(r, m[2] + 1) end return {r, #vim.diagnostic.get(0, {namespace = ns.godot_nvim_missing_methods})}", []])
	check(marks[1] == [[3], 1], "slot sign on func _ready, one missing-method warning: %s" % [marks])
	# Double-clicking the gutter on row 2 ("func _ready():") asks Godot to set
	# a breakpoint on line 3; a double-click in the text doesn't.
	var bp_reqs := []
	view.breakpoint_requested.connect(func(p, l, on): bp_reqs.append([l, on]))
	for i in 2:
		view.rpc.request("nvim_input_mouse", ["left", "press", "", 0, 2, 0])
		view.rpc.request("nvim_input_mouse", ["left", "release", "", 0, 2, 0])
	check(await _wait(func(): return bp_reqs.size() > 0), "gutter double-click requests a breakpoint")
	check(bp_reqs == [[3, true]], "breakpoint on line 3: %s" % [bp_reqs])
	await create_timer(0.6).timeout
	for i in 2:
		view.rpc.request("nvim_input_mouse", ["left", "press", "", 0, 2, 8])
		view.rpc.request("nvim_input_mouse", ["left", "release", "", 0, 2, 8])
	await create_timer(0.5).timeout
	check(bp_reqs.size() == 1, "double-click in the text doesn't toggle: %s" % [bp_reqs])
	view.rpc.request("nvim_input", ["<Esc>"])
	# The rest of the test counts cells from the left edge.
	view.rpc.request("nvim_command", ["setlocal signcolumn=no"])
	# Overrides: their own sign, and a combined one on a connected override.
	var signs_lua := "local ns = vim.api.nvim_get_namespaces() local r = {} for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns.godot_nvim_slots, 0, -1, {details = true})) do table.insert(r, {m[2] + 1, vim.trim(m[4].sign_text), m[4].sign_hl_group}) end return r"
	view.set_overrides(path, {"_ready": "Node", "_process": "Node"})
	marks = await _req(view, "nvim_exec_lua", [signs_lua, []])
	check(marks[1] == [[3, "↱⇠", "GodotSignalSlot"]], "combined sign on connected override: %s" % [marks])
	view.set_connections(path, [])
	marks = await _req(view, "nvim_exec_lua", [signs_lua, []])
	check(marks[1] == [[3, "↱", "GodotMethodOverride"]], "override sign on func _ready: %s" % [marks])
	# A newly typed override gets its sign on the next edit.
	view.rpc.request("nvim_buf_set_lines", [0, -1, -1, false, ["", "func _process(delta):", "    pass"]])
	view.rpc.request("nvim_exec_autocmds", ["TextChanged", {"buffer": 0}])
	marks = await _req(view, "nvim_exec_lua", [signs_lua, []])
	check(marks[1].size() == 2 and marks[1][1][0] == 6, "sign follows a new override: %s" % [marks])
	view.rpc.request("nvim_buf_set_lines", [0, -4, -1, false, []])
	view.set_overrides(path, {})
	# The "godot" colorscheme from the editor's colors.
	view.set_colorscheme({"background_color": "#1a1a1a", "text_color": "#c0c0c0", "keyword_color": "#ff7085",
		"breakpoint_color": "#ff7869", "gdscript/annotation_color": "#ffb373", "dark": true})
	var hl: Array = await _req(view, "nvim_exec_lua", ["local h = function(n) return vim.api.nvim_get_hl(0, {name = n, link = false}) end return {vim.g.colors_name, h('Normal').bg, h('Keyword').fg, h('PreProc').fg, h('GodotBreakpoint').fg, h('GodotMethodOverride').fg ~= nil, vim.o.background}", []])
	check(hl[1] == ["godot", 0x1a1a1a, 0xff7085, 0xffb373, 0xff7869, true, "dark"], "godot colorscheme applied: %s" % [hl])
	check(await _wait(func(): return view.grid.default_bg == Color("#1a1a1a")), "view background follows the theme: %s" % [view.grid.default_bg])
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
	# :q / :wq on the last window act like :bd / :w + :bd: Neovim stays,
	# the buffer goes, and no new buffers pile up.
	var pid := view.rpc.pid
	var path2 := OS.get_cache_dir().path_join("godot_nvim_test2.gd")
	FileAccess.open(path2, FileAccess.WRITE).store_string("extends Node2D\n")
	view.open_file(path2)
	await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node2D"))
	view.rpc.request("nvim_input", [":q<CR>"])
	check(await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node ")), ":q shows the previous file")
	var bufs: Array = await _req(view, "nvim_exec_lua", ["return {#vim.fn.getbufinfo({buflisted = 1}), #vim.api.nvim_list_bufs(), vim.fn.bufexists(...) == 1 and vim.fn.buflisted(vim.fn.bufnr(...)) == 1}", [path2]])
	check(view.rpc.pid == pid and view.rpc.is_running(), ":q keeps nvim running")
	check(bufs[1][2] == false, ":q removed the quit buffer from the list: %s" % [bufs])
	for i in 3:
		view.rpc.request("nvim_input", [":wq<CR>" if i == 0 else ":q<CR>"])
		await create_timer(0.3).timeout
	var after: Array = await _req(view, "nvim_exec_lua", ["return {#vim.fn.getbufinfo({buflisted = 1}), #vim.api.nvim_list_bufs(), #vim.api.nvim_tabpage_list_wins(0)}", []])
	check(view.rpc.pid == pid and view.rpc.is_running(), ":wq and repeated :q keep nvim running")
	check(after[1][0] == 0 and after[1][2] == 1, "no listed buffers left, one window: %s" % [after])
	check(after[1][1] <= bufs[1][1], "no buffers piled up (%s -> %s)" % [bufs[1][1], after[1][1]])
	view.open_file(path)
	check(await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node")), "file reopens after :wq")
	# :qa! really exits; the view restarts Neovim on the last file.
	view.open_file(path)
	await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node"))
	view.rpc.request("nvim_input", [":qa!<CR>"])
	check(await _wait(func(): return view.rpc.pid != pid and view.attached), "restarts after :qa!")
	check(await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node")), "last file reopened after restart")
	view.stop()
	view.queue_free()
