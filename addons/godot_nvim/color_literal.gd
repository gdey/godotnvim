## Finds Color literals in a line of GDScript, the ones Godot's script editor
## shows a swatch for and opens its inline color picker on: Color(r, g, b[, a]),
## Color("#hex" or "name"), Color(0xRRGGBBAA), Color(), Color.from_hsv(...),
## Color.from_ok_hsl(...), Color.from_rgba8(...) and named constants such as
## Color.RED. Arguments must be number literals; expressions are left alone,
## since a pick would replace them.
class_name ColorLiteral
extends RefCounted

## How a literal is written, and the index of its form in [method forms].
enum Mode { RGB, STRING, HSV, OKHSL, RGB8, HEX }


## Returns one {"start", "end", "color", "mode"} per literal in [param line].
## [code]start[/code] and [code]end[/code] are character indices of its first
## and last character (both inclusive); [code]mode[/code] is a [enum Mode].
static func parse(line: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var from := 0
	while true:
		var i := line.find("Color", from)
		if i == -1:
			break
		from = i + 1
		# Skip identifiers that only contain "Color", like modulate_Color or Colors.
		if i > 0 and _is_ident(line[i - 1]):
			continue
		var after := i + 5
		if after < line.length() and _is_ident(line[after]):
			continue
		var lit := _named(line, i, after)
		if lit.is_empty():
			lit = _call(line, i, after)
		if not lit.is_empty():
			out.append(lit)
			from = lit["end"] + 1
	return out


## The literal in [param line] that the character index [param col] is in,
## or {}.
static func at(line: String, col: int) -> Dictionary:
	for lit in parse(line):
		if col >= lit["start"] and col <= lit["end"]:
			return lit
	return {}


## The ways Godot's color picker offers to write [param c], in [enum Mode]
## order.
static func forms(c: Color) -> PackedStringArray:
	return PackedStringArray([
		"Color(%s)" % _join([c.r, c.g, c.b, c.a]),
		"Color(\"%s\")" % c.to_html(),
		"Color.from_hsv(%s)" % _join([c.h, c.s, c.v, c.a]),
		"Color.from_ok_hsl(%s)" % _join([c.ok_hsl_h, c.ok_hsl_s, c.ok_hsl_l, c.a]),
		"Color.from_rgba8(%d, %d, %d, %d)" % [c.r8, c.g8, c.b8, c.a8],
		"Color(0x%s)" % c.to_html(),
	])


## Byte offset in [param line]'s UTF-8 of the character index [param col].
static func byte_col(line: String, col: int) -> int:
	return line.substr(0, col).to_utf8_buffer().size()


## Character index in [param line] of the UTF-8 byte offset [param col].
static func char_col(line: String, col: int) -> int:
	var bytes := line.to_utf8_buffer()
	return bytes.slice(0, clampi(col, 0, bytes.size())).get_string_from_utf8().length()


static func _join(values: Array) -> String:
	var parts := PackedStringArray()
	for v in values:
		# The shorter 1, not 1.0.
		parts.append(String.num(v, 3).trim_suffix(".0"))
	return ", ".join(parts)


static func _is_ident(ch: String) -> bool:
	return ch == "_" or (ch.unicode_at(0) < 128 and (ch.is_valid_int() or ch.to_upper() != ch.to_lower()))


# Color.NAME, a named color constant.
static func _named(line: String, i: int, after: int) -> Dictionary:
	if after >= line.length() or line[after] != ".":
		return {}
	var j := after + 1
	while j < line.length() and _is_ident(line[j]):
		j += 1
	var name := line.substr(after + 1, j - after - 1)
	# Constants are upper case; from_string would also take hex like "ABC".
	if name == "" or name != name.to_upper() or name[0] == "_" or Color.html_is_valid(name):
		return {}
	var none := Color(-1, -1, -1, -1)
	var c := Color.from_string(name, none)
	if c == none:
		return {}
	# There is no constant form to write back, so picks use Color(r, g, b, a).
	return {"start": i, "end": j - 1, "color": c, "mode": Mode.RGB}


# Color(...) or Color.from_*(...) with literal arguments.
static func _call(line: String, i: int, after: int) -> Dictionary:
	var open := line.find("(", after)
	if open == -1:
		return {}
	var close := line.find(")", open)
	if close == -1:
		return {}
	var fn := line.substr(after, open - after)
	if fn not in ["", ".from_hsv", ".from_ok_hsl", ".from_rgba8"]:
		return {}
	var args := line.substr(open + 1, close - open - 1).strip_edges()
	var lit := {"start": i, "end": close}
	if fn == "":
		if args == "":
			lit["color"] = Color()
			lit["mode"] = Mode.RGB
			return lit
		if args.length() > 1 and (args[0] == "\"" or args[0] == "'") and args[-1] == args[0]:
			var s := args.substr(1, args.length() - 2)
			if s.contains(args[0]):
				return {}
			lit["color"] = Color.from_string(s, Color())
			lit["mode"] = Mode.STRING
			return lit
		if args.length() == 10 and args.begins_with("0x") and args.substr(2).is_valid_hex_number():
			lit["color"] = Color.from_string(args.substr(2), Color())
			lit["mode"] = Mode.HEX
			return lit
	var nums := PackedFloat64Array()
	for a in args.split(",", false):
		if not a.strip_edges().is_valid_float():
			return {}
		nums.append(a.to_float())
	if nums.size() == 3:
		nums.append(255.0 if fn == ".from_rgba8" else 1.0)
	if nums.size() != 4:
		return {}
	match fn:
		"":
			lit["color"] = Color(nums[0], nums[1], nums[2], nums[3])
			lit["mode"] = Mode.RGB
		".from_hsv":
			lit["color"] = Color.from_hsv(nums[0], nums[1], nums[2], nums[3])
			lit["mode"] = Mode.HSV
		".from_ok_hsl":
			lit["color"] = Color.from_ok_hsl(nums[0], nums[1], nums[2], nums[3])
			lit["mode"] = Mode.OKHSL
		".from_rgba8":
			lit["color"] = Color.from_rgba8(int(nums[0]), int(nums[1]), int(nums[2]), int(nums[3]))
			lit["mode"] = Mode.RGB8
	return lit
