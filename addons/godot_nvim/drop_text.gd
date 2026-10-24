## Builds the text Godot's script editor inserts when nodes or files are
## dropped on a script: "$Path" (or "%Unique"), or with the drop modifier
## (Ctrl / Cmd) held, "@onready var name: Type = $Path" lines.
class_name DropText
extends RefCounted


## Returns {"kind": "text"|"lines", "text": String}, or {} if [param data]
## is not something we handle.
## [param script_node] is the node in the edited scene that owns the script
## (or the scene root); [param scene_root] resolves dragged node paths.
static func build(data: Variant, scene_root: Node, script_node: Node, modifier: bool, type_hints: bool) -> Dictionary:
	if not (data is Dictionary):
		return {}
	match data.get("type", ""):
		"nodes":
			if scene_root == null:
				return {}
			var nodes: Array[Node] = []
			for p in data.get("nodes", []):
				var n := _resolve(scene_root, p)
				if n != null:
					nodes.append(n)
			if nodes.is_empty():
				return {}
			return nodes_text(nodes, script_node if script_node else scene_root, modifier, type_hints)
		"files", "files_and_dirs":
			var files: Array = data.get("files", [])
			if files.is_empty():
				return {}
			return files_text(files, modifier)
	return {}


static func nodes_text(nodes: Array[Node], from: Node, modifier: bool, type_hints: bool) -> Dictionary:
	if modifier:
		var out := ""
		for n in nodes:
			var name := identifier(String(n.name).to_snake_case())
			var hint := (": " + type_name(n)) if type_hints else ""
			out += "@onready var %s%s = %s\n" % [name, hint, node_ref(n, from)]
		return {"kind": "lines", "text": out}
	var refs := PackedStringArray()
	for n in nodes:
		refs.append(node_ref(n, from))
	return {"kind": "text", "text": ", ".join(refs)}


static func files_text(files: Array, modifier: bool) -> Dictionary:
	if modifier:
		var out := ""
		for f in files:
			var name := identifier(String(f).get_file().get_basename().to_pascal_case())
			out += "const %s = preload(\"%s\")\n" % [name, f]
		return {"kind": "lines", "text": out}
	var refs := PackedStringArray()
	for f in files:
		refs.append("\"%s\"" % f)
	return {"kind": "text", "text": ", ".join(refs)}


## "$Path/To", "$\"Odd Name\"" or "%Unique".
static func node_ref(n: Node, from: Node) -> String:
	if n.is_unique_name_in_owner() and n.owner == _owner_of(from):
		return "%" + _quote(String(n.name))
	var path := String(from.get_path_to(n))
	return "$" + _quote(path)


## Global class_name of the node's script if it has one, else the engine class.
static func type_name(n: Node) -> String:
	var s: Script = n.get_script()
	while s != null:
		var g := s.get_global_name()
		if g != &"":
			return g
		s = s.get_base_script()
	return n.get_class()


## Finds the node in [param root]'s tree whose script is [param script].
static func find_script_node(root: Node, script: Script) -> Node:
	if root == null:
		return null
	if root.get_script() == script:
		return root
	for c in root.get_children():
		var f := find_script_node(c, script)
		if f:
			return f
	return null


## Replaces characters that can't appear in an identifier with "_".
static func identifier(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s[i]
		var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (i > 0 and c >= "0" and c <= "9")
		out += c if ok else "_"
	if out == "" or (s[0] >= "0" and s[0] <= "9"):
		out = "_" + out
	return out


static func _owner_of(n: Node) -> Node:
	return n.owner if n.owner else n


static func _quote(path: String) -> String:
	for part in path.split("/"):
		if part != ".." and not part.is_valid_ascii_identifier():
			return "\"%s\"" % path
	return path


## Dragged paths are absolute in the editor's tree; get_node_or_null
## resolves those as long as [param scene_root] is inside a tree.
static func _resolve(scene_root: Node, p: Variant) -> Node:
	return scene_root.get_node_or_null(NodePath(p))
