## Finds resource paths in a line of GDScript: the string argument of
## preload("..."), load("...") or ResourceLoader.load("..."), by res://,
## uid:// or a path relative to the script.
class_name ResourceLiteral
extends RefCounted

## The most general type Quick Open offers in place of a resource of a
## given type, so a texture is replaced by any texture. First match wins.
const _PICK_BASES := ["PackedScene", "Script", "Shader", "ShaderInclude", "Texture2D", "Texture",
	"AudioStream", "Font", "Mesh", "Material", "Theme"]

## Types by extension, for when the editor's file system can't tell.
const _TYPES := {
	"tscn": "PackedScene", "scn": "PackedScene",
	"gd": "GDScript", "gdshader": "Shader", "gdshaderinc": "ShaderInclude",
	"png": "Texture2D", "svg": "Texture2D", "jpg": "Texture2D", "jpeg": "Texture2D", "webp": "Texture2D",
	"wav": "AudioStream", "ogg": "AudioStream", "mp3": "AudioStream",
	"ttf": "Font", "otf": "Font", "woff": "Font", "woff2": "Font",
	"tres": "Resource", "res": "Resource", "json": "JSON",
}


## Returns one {"start", "end", "path_start", "path_end", "path"} per
## resource path in [param line]. [code]start[/code] and [code]end[/code]
## are the character indices of the call's first character and of its
## closing parenthesis (both inclusive), [code]path_start[/code] and
## [code]path_end[/code] those of the path inside the quotes (exclusive
## end), and [code]path[/code] the path as written. [param script_path]
## (res://) resolves relative paths; see [method resolve].
static func parse(line: String, script_path := "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var from := 0
	while true:
		var i := line.find("load", from)
		if i == -1:
			break
		from = i + 1
		var start := i
		if line.substr(maxi(i - 3, 0), 3) == "pre":
			start = i - 3
		elif line.substr(maxi(i - 15, 0), 15) == "ResourceLoader.":
			start = i - 15
		if start > 0 and (_is_ident(line[start - 1]) or line[start - 1] == "."):
			continue
		var j := i + 4
		while j < line.length() and line[j] == " ":
			j += 1
		if j >= line.length() or line[j] != "(":
			continue
		j += 1
		while j < line.length() and line[j] == " ":
			j += 1
		if j >= line.length() or (line[j] != "\"" and line[j] != "'"):
			continue
		var q := line[j]
		var close_q := line.find(q, j + 1)
		if close_q == -1:
			continue
		var path := line.substr(j + 1, close_q - j - 1)
		var close := line.find(")", close_q)
		if close == -1 or resolve(path, script_path) == "":
			continue
		out.append({"start": start, "end": close, "path_start": j + 1, "path_end": close_q, "path": path})
		from = close + 1
	return out


## The resource path in [param line] whose call the character index
## [param col] is in, else the first one after [param col], or {}.
static func at(line: String, col: int, script_path := "") -> Dictionary:
	for lit in parse(line, script_path):
		if col <= lit["end"]:
			return lit
	return {}


## The res:// path [param path] names, or "" when it names no file: a
## uid:// path Godot doesn't know, or a path with no extension. Relative
## paths are relative to the folder of [param script_path].
static func resolve(path: String, script_path := "") -> String:
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
			return ""
		path = ResourceUID.get_id_path(id)
	elif not path.begins_with("res://"):
		if not script_path.begins_with("res://") or path.is_absolute_path():
			return ""
		path = script_path.get_base_dir().path_join(path).simplify_path()
	if path.get_extension() == "" or path.ends_with("/"):
		return ""
	return path


## The type of the resource at [param path] going by its extension:
## "Resource" when it is not a known one.
static func guess_type(path: String) -> String:
	return _TYPES.get(path.get_extension().to_lower(), "Resource")


## The type Quick Open lists to replace a resource of type [param type].
static func pick_base(type: String) -> String:
	for base in _PICK_BASES:
		if type == base or (ClassDB.class_exists(type) and ClassDB.is_parent_class(type, base)):
			return base
	return type if type != "" else "Resource"


## How to write [param res_path] in place of [param old]: as a uid:// path
## when [param old] was one and the file has a UID, else as [param res_path].
static func write_as(old: String, res_path: String) -> String:
	if old.begins_with("uid://"):
		var id := ResourceLoader.get_resource_uid(res_path)
		if id != ResourceUID.INVALID_ID:
			return ResourceUID.id_to_text(id)
	return res_path


static func _is_ident(ch: String) -> bool:
	return ch == "_" or (ch.unicode_at(0) < 128 and (ch.is_valid_int() or ch.to_upper() != ch.to_lower()))
