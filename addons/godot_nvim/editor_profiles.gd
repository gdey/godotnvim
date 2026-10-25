## Makes "<name>-neovim" editor feature profiles: copies of the user's
## profiles with the Script screen turned off, so the Neovim tab replaces it.
@tool
extends RefCounted

const SUFFIX := "-neovim"
## The profile made when the user has none of their own.
const DEFAULT_BASE := "Default"
## EditorFeatureProfile.FEATURE_SCRIPT's name in .profile files.
const SCRIPT_FEATURE := "script"


## Godot keeps feature profiles here (EditorPaths' feature_profiles_dir).
static func profiles_dir() -> String:
	return EditorInterface.get_editor_paths().get_config_dir().path_join("feature_profiles")


## The "-neovim" profile name for [param base].
static func neovim_name(base: String) -> String:
	return (base if base != "" else DEFAULT_BASE) + SUFFIX


## For every profile in [param dir] without a "-neovim" twin, saves one with
## the Script screen disabled. Existing "-neovim" profiles are left as they
## are. With no profiles at all, makes "Default-neovim" from a blank profile.
## Returns the names of the profiles it made.
static func create(dir: String) -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(dir)
	var bases := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "profile" and not f.get_basename().ends_with(SUFFIX):
			bases.append(f.get_basename())
	if bases.is_empty():
		bases.append("")
	var made := PackedStringArray()
	for base in bases:
		var name := neovim_name(base)
		var path := dir.path_join(name + ".profile")
		if FileAccess.file_exists(path):
			continue
		# The file is JSON (see EditorFeatureProfile.save_to_file). It's edited
		# directly because EditorFeatureProfile only exists inside the editor.
		var data: Variant = {"type": "feature_profile"}
		if base != "":
			data = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(base + ".profile")))
			if not data is Dictionary or data.get("type") != "feature_profile":
				push_warning("godot_nvim: can't read editor profile '%s'" % base)
				continue
		var features: Array = data.get("disabled_features", [])
		if not features.has(SCRIPT_FEATURE):
			features.append(SCRIPT_FEATURE)
		data["disabled_features"] = features
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(data, "\t"))
			made.append(name)
		else:
			push_warning("godot_nvim: can't write editor profile '%s'" % path)
	return made
