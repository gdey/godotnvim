## Headless tests. Run with:
##   godot --headless --path . -s tests/run_tests.gd
## Add --editor to also run an EditorScript (:GodotRunFile).
## Set NVIM to the nvim binary if it is not on PATH.
extends SceneTree

var _failures := 0


func _init() -> void:
	await process_frame
	_test_msgpack()
	_test_keys()
	_test_drop_text()
	_test_overrides()
	_test_editor_profiles()
	_test_find_executable()
	_test_run_editor_script()
	await _test_embed()
	await _test_view_drop()
	await _test_session()
	await _test_clean()
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
	check(DropText.build(data, main, holder, false, true)["text"] == "$\"../Player\"", "relative to script node (quoted, like Godot)")
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
	var prop := func(obj: Object, name: String, from: Node, mod: bool) -> String:
		return DropText.build({"type": "obj_property", "object": obj, "property": name}, main, from, mod, true).get("text", "")
	check(prop.call(odd, "modulate", main, false) == "$\"Player/Odd Name\".modulate", "property drop")
	check(prop.call(player, "velocity", holder, false) == "$\"../Player\".velocity", "property relative to script node")
	check(prop.call(hud, "theme_override_colors/font_color", main, false) == "%HUD.get(\"theme_override_colors/font_color\")", "slashed property uses get()")
	check(prop.call(holder, "process_mode", holder, false) == "process_mode", "own property is bare")
	check(prop.call(odd, "modulate", main, true) == "\"Player/Odd Name:modulate\"", "property NodePath with modifier")
	check(prop.call(player, "position", holder, true) == "\"../Player:position\"", "relative NodePath with modifier")
	check(prop.call(holder, "process_mode", holder, true) == "\".:process_mode\"", "own NodePath with modifier")
	check(prop.call(CanvasItemMaterial.new(), "blend_mode", main, false) == "\"blend_mode\"", "non-node property drops its name")
	var stray := Node.new()
	check(prop.call(stray, "name", main, false) == "\"name\"", "node outside the scene drops its name")
	stray.free()
	check(DropText.build({"type": "obj_property"}, main, main, false, true).is_empty(), "ignores property drag without a property")
	check(DropText.build({"type": "resource"}, main, main, false, true).is_empty(), "ignores other drags")
	main.queue_free()


func _test_editor_profiles() -> void:
	print("editor profiles")
	var Profiles = load("res://addons/godot_nvim/editor_profiles.gd")
	var dir := OS.get_cache_dir().path_join("godot_nvim_profiles")
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	var read := func(name: String) -> Dictionary:
		return JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(name + ".profile")))
	check(Profiles.create(dir) == PackedStringArray(["Default-neovim"]), "no profiles: makes Default-neovim")
	check(read.call("Default-neovim").get("disabled_features") == ["script"], "Default-neovim hides the Script screen")
	# Written like Godot's EditorFeatureProfile.save_to_file.
	FileAccess.open(dir.path_join("2D.profile"), FileAccess.WRITE).store_string(JSON.stringify({"type": "feature_profile",
		"disabled_classes": ["Node3D"], "disabled_editors": [], "disabled_properties": [], "disabled_features": ["3d"]}, "\t"))
	FileAccess.open(dir.path_join("Full.profile"), FileAccess.WRITE).store_string(JSON.stringify({"type": "feature_profile"}))
	DirAccess.remove_absolute(dir.path_join("Default-neovim.profile"))
	var made: PackedStringArray = Profiles.create(dir)
	made.sort()
	check(made == PackedStringArray(["2D-neovim", "Full-neovim"]), "one -neovim per profile, none for -neovim ones: %s" % [made])
	var p2d: Dictionary = read.call("2D-neovim")
	check(p2d.get("disabled_features") == ["3d", "script"] and p2d.get("disabled_classes") == ["Node3D"], "2D-neovim keeps 2D's settings: %s" % [p2d])
	check(Profiles.create(dir).is_empty(), "existing -neovim profiles are left alone")


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


func _test_find_executable() -> void:
	print("find executable")
	var find: Callable = load("res://addons/godot_nvim/plugin.gd")._find_executable
	var godot := OS.get_executable_path()
	check(find.call(godot) == godot, "absolute path to an existing file")
	check(find.call(godot + "-missing") == "", "absolute path to a missing file")
	check(find.call(godot.get_file()) == "" or find.call(godot.get_file()).is_absolute_path(), "bare name gives an absolute path or nothing")
	check(find.call("godot-nvim-no-such-tool") == "", "missing bare name")


func _test_run_editor_script() -> void:
	print("run editor script")
	var run: Callable = load("res://addons/godot_nvim/plugin.gd").run_editor_script
	var dir := "res://tests/run_tmp"
	DirAccess.make_dir_recursive_absolute(dir)
	var scripts := {
		"ok.gd": "@tool\nextends EditorScript\nfunc _run():\n\tEngine.set_meta(\"godot_nvim_ran\", Engine.get_meta(\"godot_nvim_ran\", 0) + 1)\n",
		"not_tool.gd": "extends EditorScript\nfunc _run():\n\tpass\n",
		"node.gd": "@tool\nextends Node\n",
		"broken.gd": "@tool\nextends EditorScript\nfunc _run(:\n",
	}
	for name in scripts:
		var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		f.store_string(scripts[name])
		f.close()
	# Only the editor can make an EditorScript.
	if Engine.is_editor_hint():
		check(run.call(dir.path_join("ok.gd")) == "" and Engine.get_meta("godot_nvim_ran", 0) == 1, "runs _run()")
		# Edits on disk are picked up, as after :w.
		var f := FileAccess.open(dir.path_join("ok.gd"), FileAccess.WRITE)
		f.store_string(scripts["ok.gd"].replace("+ 1", "+ 10"))
		f.close()
		check(run.call(dir.path_join("ok.gd")) == "" and Engine.get_meta("godot_nvim_ran", 0) == 11, "reloads from disk: %s" % Engine.get_meta("godot_nvim_ran", 0))
		# Files outside the project run too, as in Godot's script editor.
		var outside := OS.get_cache_dir().path_join("godot_nvim_outside.gd")
		f = FileAccess.open(outside, FileAccess.WRITE)
		f.store_string(scripts["ok.gd"].replace("+ 1", "+ 100"))
		f.close()
		check(run.call(outside) == "" and Engine.get_meta("godot_nvim_ran", 0) == 111, "runs a file outside the project: %s" % Engine.get_meta("godot_nvim_ran", 0))
		DirAccess.remove_absolute(outside)
	else:
		print("  skip running an EditorScript (needs --editor)")
	check("not a tool script" in run.call(dir.path_join("not_tool.gd")), "refuses non-tool script")
	check("does not extend EditorScript" in run.call(dir.path_join("node.gd")), "refuses non-EditorScript")
	check("has errors" in run.call(dir.path_join("broken.gd")), "refuses script with errors")
	check("not a script" in run.call("res://project.godot"), "refuses non-script")
	check("not a script" in run.call(OS.get_cache_dir().path_join("godot_nvim_missing.gd")), "refuses a missing file")
	for name in scripts:
		DirAccess.remove_absolute(dir.path_join(name))
	DirAccess.remove_absolute(dir)
	Engine.remove_meta("godot_nvim_ran")


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
	view.nvim_args = PackedStringArray(["--clean", "-u", ProjectSettings.globalize_path("res://tests/fixtures/init.lua"), "-n"])
	var cwd := OS.get_cache_dir().path_join("godot nvim cwd")
	DirAccess.make_dir_recursive_absolute(cwd)
	view.working_dir = cwd
	view.size = Vector2(800, 400)
	root.add_child(view)
	# Like the plugin, send colors on attach: before the user's config runs
	# (fixtures/init.lua, which resets 'runtimepath' and sets a colorscheme).
	view.attached_to_nvim.connect(func(): view.set_colorscheme({"background_color": "#202830", "dark": true}))
	check(view.start() == OK, "view starts nvim")
	check(await _wait(func(): return view.attached and view.grid.height > 0), "view attached")
	var got_cwd: Array = view.rpc.request_sync("nvim_call_function", ["getcwd", []])
	check(got_cwd[1] == cwd, "working dir with a space: %s" % [got_cwd])
	var first: Array = await _req(view, "nvim_exec_lua", ["return {vim.g.colors_name, vim.api.nvim_get_hl(0, {name = 'Normal'}).bg}", []])
	check(first[1] == ["godot", 0x202830], "colors sent on attach win over the user's config: %s" % [first])
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
	# Editor shortcuts pass through; other keys still reach Neovim.
	# Wait for the mapping: nvim_input is handled ahead of queued requests.
	await _req(view, "nvim_command", ["nnoremap <F5> <Cmd>let g:f5 = get(g:, 'f5', 0) + 1<CR>"])
	var f5 := Shortcut.new()
	var f5_event := InputEventKey.new()
	f5_event.keycode = KEY_F5
	f5.events = [f5_event]
	view.passthrough_shortcuts = [f5]
	var press := InputEventKey.new()
	press.keycode = KEY_F5
	press.pressed = true
	view._gui_input(press)
	view.passthrough_shortcuts = []
	view._gui_input(press)
	# Wait for the mapping to run, then give a stray second F5 time to arrive.
	var f5_count: Array = [null, 0]
	for i in 30:
		f5_count = await _req(view, "nvim_eval", ["get(g:, 'f5', 0)"])
		if f5_count[1] >= 1:
			break
		await create_timer(0.1).timeout
	await create_timer(0.3).timeout
	f5_count = await _req(view, "nvim_eval", ["get(g:, 'f5', 0)"])
	check(f5_count[1] == 1, "passthrough shortcut skips Neovim: %s" % [f5_count])
	# :Godot run commands.
	var runs := []
	view.run_requested.connect(func(a, arg): runs.append([a, arg]))
	view.rpc.request("nvim_command", ["GodotRun"])
	view.rpc.request("nvim_command", ["GodotRunScene " + ProjectSettings.globalize_path("res://main.tscn")])
	await _req(view, "nvim_command", ["GodotRunFile " + ProjectSettings.globalize_path("res://tools/gen.gd")])
	# No file: the current buffer's, written first when modified. It is
	# outside the project, so Neovim asks first: cancel, then run.
	await _req(view, "nvim_command", ["set modified"])
	for key in ["c", "r"]:
		view.rpc.request("nvim_command", ["GodotRunFile"])
		var asking := await _wait(func():
			var m := view.rpc.request_sync("nvim_get_mode")
			# Neovim 0.12 reports the prompt as mode "r?"; older ones as blocking.
			return m[1] is Dictionary and (m[1].get("blocking", false) or m[1].get("mode") == "r?"))
		check(asking, ":GodotRunFile asks before running a file outside the project")
		view.rpc.request("nvim_input", [key])
		var mod: Array = await _req(view, "nvim_eval", ["&modified"])
		check(mod[1] == (1 if key == "c" else 0), "%s: buffer modified = %s" % [key, mod])
	view.rpc.request("nvim_command", ["GodotStop"])
	await _wait(func(): return runs.size() >= 5)
	check(runs == [["project", ""], ["scene", "res://main.tscn"], ["file", "res://tools/gen.gd"], ["file", path], ["stop", ""]], "run commands: %s" % [runs])
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
	# :GodotFunc opens a func by name from the project's .gd files.
	DirAccess.make_dir_recursive_absolute(cwd.path_join("scripts"))
	FileAccess.open(cwd.path_join("scripts/stats.gd"), FileAccess.WRITE).store_string("extends Node\n\nfunc _ready():\n\tpass\n\nstatic func _get_stat(n):\n\treturn n\n")
	FileAccess.open(cwd.path_join("scripts/other.gd"), FileAccess.WRITE).store_string("extends Node\n\nfunc _get_stat_name():\n\tpass\n")
	# The project folder, not Neovim's working directory, is searched.
	view.rpc.request("nvim_command", ["cd /"])
	var names: Array = await _req(view, "nvim_call_function", ["getcompletion", ["GodotFunc _get", "cmdline"]])
	check(names[1] == ["_get_stat", "_get_stat_name"], ":GodotFunc completes func names: %s" % [names])
	view.rpc.request("nvim_command", ["GodotFunc _get_stat"])
	var at: Array = await _req(view, "nvim_exec_lua", ["return {vim.fn.expand('%:t'), vim.fn.line('.')}", []])
	check(at[1] == ["stats.gd", 6], ":GodotFunc jumps to the func: %s" % [at])
	view.rpc.request("nvim_command", ["GodotFunc stat"])
	var qf: Array = await _req(view, "nvim_exec_lua", ["return vim.tbl_map(function(i) return vim.fn.fnamemodify(vim.fn.bufname(i.bufnr), ':t') .. ':' .. i.lnum end, vim.fn.getqflist())", []])
	qf[1].sort()
	check(qf[1] == ["other.gd:3", "stats.gd:6"], ":GodotFunc lists partial matches: %s" % [qf])
	view.rpc.request("nvim_command", ["cclose"])
	view.rpc.request("nvim_command", ["cd " + cwd.replace(" ", "\\ ")])
	await _test_format(view, cwd)
	view.open_file(path)
	await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node"))
	# Unsaved buffers are reported, and save_all writes them.
	var modified := []
	view.modified_changed.connect(func(paths): modified.append(paths))
	view.rpc.request("nvim_buf_set_lines", [0, 0, 0, false, ["# edited"]])
	check(await _wait(func(): return modified.size() > 0 and modified[-1].size() == 1), "modified buffer reported")
	view.save_all()
	check(FileAccess.get_file_as_string(path).begins_with("# edited"), "save_all wrote the buffer")
	check(await _wait(func(): return modified.size() > 0 and modified[-1].is_empty()), "no unsaved buffers after save")
	# A clean stop removes Neovim's swap file.
	view.rpc.request("nvim_buf_set_lines", [0, 0, 0, false, ["# unsaved"]])
	var swap: Array = view.rpc.request_sync("nvim_eval", ["swapname('%')"])
	var had_swap: bool = swap[0] == null and swap[1] != "" and FileAccess.file_exists(swap[1])
	view.stop()
	if had_swap:
		check(not FileAccess.file_exists(swap[1]), "swap file removed on stop")
	view.queue_free()


## Format on save, with sed standing in for gdformat (spaces to tabs).
func _test_format(view: NvimView, cwd: String) -> void:
	var fmt_path := cwd.path_join("scripts/fmt.gd")
	FileAccess.open(fmt_path, FileAccess.WRITE).store_string("extends Node\n\nfunc a():\n    pass\n\nfunc b():\n    pass\n")
	view.set_formatter(PackedStringArray(["sed", "s/^    /\t/"]), true)
	view.open_file(fmt_path)
	await _wait(func(): return view.grid.row_string(0).strip_edges(true, false).begins_with("extends Node"))
	view.set_breakpoints(fmt_path, [6])
	view.rpc.request("nvim_command", ["write"])
	var bps: Array = await _req(view, "nvim_exec_lua", ["return godot_nvim.buf_breakpoints(0)", []])
	check(FileAccess.get_file_as_string(fmt_path) == "extends Node\n\nfunc a():\n\tpass\n\nfunc b():\n\tpass\n",
		"formatted on save: %s" % [FileAccess.get_file_as_string(fmt_path).c_escape()])
	check(bps[1] == [6], "breakpoint stays on its line: %s" % [bps])
	# Formatting off: written as is. :GodotFormat still formats.
	view.set_formatter(PackedStringArray(["sed", "s/^    /\t/"]), false)
	view.rpc.request("nvim_buf_set_lines", [0, 3, 4, false, ["    print(1)"]])
	view.rpc.request("nvim_command", ["write"])
	await _req(view, "nvim_eval", ["1"])
	check(FileAccess.get_file_as_string(fmt_path).contains("\n    print(1)\n"), "format_on_save off writes as is")
	await _req(view, "nvim_command", ["GodotFormat"])
	var line: Array = await _req(view, "nvim_buf_get_lines", [0, 3, 4, false])
	check(line[1] == ["\tprint(1)"], ":GodotFormat formats: %s" % [line])
	# A failing or missing formatter still saves, unformatted.
	for cmd in [["sed", "-e", "bogus{"], ["godot-nvim-no-such-formatter"]]:
		view.set_formatter(PackedStringArray(cmd), true)
		view.rpc.request("nvim_buf_set_lines", [0, 3, 4, false, ["    print(%d)" % cmd.size()]])
		view.rpc.request("nvim_command", ["write"])
		await _req(view, "nvim_eval", ["1"])
		check(FileAccess.get_file_as_string(fmt_path).contains("\n    print(%d)\n" % cmd.size()), "%s: saved unformatted" % cmd[0])
	# No formatter installed: saved as is, with no warning to dismiss.
	view.set_formatter(PackedStringArray(), true)
	view.rpc.request("nvim_buf_set_lines", [0, 3, 4, false, ["    print(0)"]])
	view.rpc.request("nvim_command", ["write"])
	await _req(view, "nvim_eval", ["1"])
	check(FileAccess.get_file_as_string(fmt_path).contains("\n    print(0)\n"), "no formatter: saved as is")
	# The real thing, when installed: GDQuest's formatter indents with tabs.
	var gdquest: String = load("res://addons/godot_nvim/plugin.gd")._find_executable.call("gdscript-formatter")
	if gdquest != "":
		view.set_formatter(PackedStringArray([gdquest]), true)
		view.rpc.request("nvim_buf_set_lines", [0, 0, -1, false, ["extends Node", "func a( ):", "    pass"]])
		view.rpc.request("nvim_command", ["write"])
		await _req(view, "nvim_eval", ["1"])
		check(FileAccess.get_file_as_string(fmt_path) == "extends Node\n\n\nfunc a():\n\tpass\n",
			"gdscript-formatter on save: %s" % FileAccess.get_file_as_string(fmt_path).c_escape())
	view.set_formatter(PackedStringArray(), false)


func _session_view(session: String, cwd: String) -> NvimView:
	var view := NvimView.new()
	view.nvim_path = _nvim_path()
	view.nvim_args = PackedStringArray(["--clean", "-u", ProjectSettings.globalize_path("res://tests/fixtures/init.lua"), "-n"])
	view.working_dir = cwd
	view.session_file = session
	# A user option the session script would reset.
	view.nvim_args.append_array(["--cmd", "set winwidth=30"])
	view.auto_restart = false
	view.size = Vector2(800, 400)
	root.add_child(view)
	return view


## Open files, cursors, splits and tabs come back after a restart.
func _test_session() -> void:
	print("session")
	var cwd := OS.get_cache_dir().path_join("godot nvim session")
	DirAccess.make_dir_recursive_absolute(cwd)
	var session := cwd.path_join(".godot/godot_nvim/session.vim")
	DirAccess.remove_absolute(session)
	var a := cwd.path_join("a.gd")
	var b := cwd.path_join("b.gd")
	var c := cwd.path_join("c.gd")
	for p in [a, b, c]:
		FileAccess.open(p, FileAccess.WRITE).store_string("extends Node\n\n# %s\n\nfunc _ready():\n\tpass\n" % p.get_file())
	var layout_lua := "local r = {} for _, t in ipairs(vim.api.nvim_list_tabpages()) do local ws = {} for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do table.insert(ws, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)), ':t') .. ':' .. vim.api.nvim_win_get_cursor(w)[1]) end table.insert(r, ws) end return {r, vim.fn.expand('%:t'), vim.fn.winlayout(1)[1]}"

	var view := _session_view(session, cwd)
	view.start()
	check(await _wait(func(): return view.entered and view.grid.height > 0), "session view started")
	# Nothing open: nothing saved.
	view.stop()
	check(not FileAccess.file_exists(session), "no session without open files")
	view.start()
	await _wait(func(): return view.entered)
	# Tab 1: a and b side by side; tab 2: c. Cursor ends in b.
	view.open_file(a, 3)
	view.rpc.request("nvim_command", ["vsplit " + b.replace(" ", "\\ ")])
	view.rpc.request("nvim_win_set_cursor", [0, [5, 0]])
	view.rpc.request("nvim_command", ["tabedit " + c.replace(" ", "\\ ")])
	view.rpc.request("nvim_win_set_cursor", [0, [6, 0]])
	view.rpc.request("nvim_command", ["tabprevious"])
	var before: Array = await _req(view, "nvim_exec_lua", [layout_lua, []])
	check(before[1] == [[["b.gd:5", "a.gd:3"], ["c.gd:6"]], "b.gd", "row"], "layout to save: %s" % [before])
	view.stop()
	check(FileAccess.file_exists(session), "session saved on stop")
	view.start()
	await _wait(func(): return view.entered)
	var after: Array = []
	await _wait(func():
		after.assign(view.rpc.request_sync("nvim_exec_lua", [layout_lua, []]))
		return after[1] == before[1])
	check(after[1] == before[1], "files, cursors, splits and tabs restored: %s" % [after])
	var names: Array = await _req(view, "nvim_exec_lua", ["return vim.fn.bufname()", []])
	check(names[1] == "b.gd", "names relative to the working directory: %s" % [names])
	# Row 0 is the tabline.
	check(await _wait(func(): return view.grid.row_string(1).contains("extends Node")), "restored files shown")
	var ft: Array = await _req(view, "nvim_eval", ["&filetype"])
	check(ft[1] == "gdscript", "restored buffers get their filetype: %s" % [ft])
	var ww: Array = await _req(view, "nvim_eval", ["&winwidth"])
	check(ww[1] == 30, "user's options kept: winwidth=%s" % [ww[1]])
	view.stop()

	# A file Godot opens at startup keeps the focus; deleted files stay closed.
	DirAccess.remove_absolute(c)
	view.start()
	view.open_file(a, 6)
	await _wait(func():
		after.assign(view.rpc.request_sync("nvim_exec_lua", [layout_lua, []]))
		return after[1] is Array and after[1][1] == "a.gd")
	check(after[1] is Array and after[1][0] == [["b.gd:5", "a.gd:6"]] and after[1][1] == "a.gd", "Godot's file focused at its line, deleted file's tab gone: %s" % [after])
	var listed: Array = await _req(view, "nvim_exec_lua", ["return vim.tbl_map(function(i) return vim.fn.fnamemodify(i.name, ':t') end, vim.fn.getbufinfo({buflisted = 1}))", []])
	check(not listed[1].has("c.gd"), "deleted file not reopened: %s" % [listed])

	# A split closed after restoring stays closed: quitting from a single
	# window must not save the spare window :q handling opens.
	view.rpc.request("nvim_command", ["only"])
	await _req(view, "nvim_eval", ["1"])
	view.stop()
	view.start()
	await _wait(func(): return view.entered)
	await _wait(func():
		after.assign(view.rpc.request_sync("nvim_exec_lua", [layout_lua, []]))
		return after[1] is Array and after[1][1] == "a.gd")
	check(after[1] is Array and after[1][0] == [["a.gd:6"]], "closed split stays closed: %s" % [after])

	# Turned off: not saved, and the old session isn't restored.
	view.set_session_file("")
	view.rpc.request("nvim_command", ["only"])
	view.stop()
	var kept := FileAccess.get_file_as_string(session)
	view.session_file = ""
	view.start()
	await _wait(func(): return view.entered)
	await create_timer(0.3).timeout
	var off: Array = await _req(view, "nvim_exec_lua", [layout_lua, []])
	check(off[1][1] == "", "no restore when off: %s" % [off])
	view.stop()
	check(FileAccess.get_file_as_string(session) == kept, "no save when off")
	view.queue_free()


## start_clean skips the user's config, but not the plugin's own Lua, and a
## restart applies it on the file that was open.
func _test_clean() -> void:
	print("clean")
	var cwd := OS.get_cache_dir().path_join("godot nvim clean")
	DirAccess.make_dir_recursive_absolute(cwd.path_join("config/nvim"))
	FileAccess.open(cwd.path_join("config/nvim/init.lua"), FileAccess.WRITE).store_string("vim.g.user_config = 1\n")
	var a := cwd.path_join("a.gd")
	FileAccess.open(a, FileAccess.WRITE).store_string("extends Node\n")
	var xdg := OS.get_environment("XDG_CONFIG_HOME")
	OS.set_environment("XDG_CONFIG_HOME", cwd.path_join("config"))
	var state_lua := "return {vim.g.user_config or 0, _G.godot_nvim ~= nil, #vim.api.nvim_get_runtime_file('colors/godot.lua', false), vim.tbl_contains(vim.v.argv, '--clean'), vim.fn.expand('%:t')}"
	var view := NvimView.new()
	view.nvim_path = _nvim_path()
	view.nvim_args = PackedStringArray(["-n"])
	view.working_dir = cwd
	view.auto_restart = false
	view.size = Vector2(800, 400)
	root.add_child(view)
	view.start()
	view.open_file(a)
	var st: Array = []
	await _wait(func():
		st.assign(view.rpc.request_sync("nvim_exec_lua", [state_lua, []]))
		return st[1] is Array and st[1][4] == "a.gd")
	check(st[1] is Array and st[1][0] == 1 and not st[1][3], "user config loads when off: %s" % [st])
	view.clean = true
	view.restart()
	await _wait(func():
		st.assign(view.rpc.request_sync("nvim_exec_lua", [state_lua, []]))
		return view.entered and st[1] is Array and st[1][4] == "a.gd")
	check(st[1] is Array and st[1][3], "started with --clean: %s" % [st])
	check(st[1] is Array and st[1][0] == 0, "user config skipped: %s" % [st])
	check(st[1] is Array and st[1][1] and st[1][2] > 0, "plugin Lua and runtime loaded: %s" % [st])
	check(st[1] is Array and st[1][4] == "a.gd", "restart reopens the last file: %s" % [st])
	var msgs: Array = await _req(view, "nvim_exec2", ["messages", {"output": true}])
	check(msgs[1] is Dictionary and String(msgs[1].get("output", "")).contains("started clean"), "says it started clean: %s" % [msgs])
	view.stop()
	view.queue_free()
	if xdg != "":
		OS.set_environment("XDG_CONFIG_HOME", xdg)
	else:
		OS.unset_environment("XDG_CONFIG_HOME")
