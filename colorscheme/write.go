package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"text/template"
)

// TET renders the ConfigFile Godot reads from text_editor_themes/<name>.tet,
// the same shape Script > File > Theme > Save Theme As writes.
func (t *Theme) TET(source string) string {
	keys := make([]string, 0, len(t.Colors))
	for k := range t.Colors {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	fmt.Fprintf(&b, "; %s, converted from %s by vim2godot\n", t.Name, source)
	b.WriteString("[color_theme]\n\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=\"%s\"\n", k, t.Colors[k])
	}
	return b.String()
}

var applyTmpl = template.Must(template.New("apply").Parse(`## Applies the {{.Name}} theme to the Godot editor: picks {{.Name}}.tet for the
## script editor and sets the interface colors. Copy {{.Name}}.tet into Godot's
## text_editor_themes folder first, then open this file in the Script editor
## and run it with File > Run (Ctrl/Cmd+Shift+X).
##
## Scripts can't make the editor reload its theme, so this saves your scenes and
## restarts the editor to finish.
@tool
extends EditorScript


const SETTINGS := {
	"interface/theme/preset": "Custom",
	"interface/theme/base_color": Color("{{.Base}}"),
	"interface/theme/accent_color": Color("{{.Accent}}"),
	"interface/theme/contrast": 0.2,
	"interface/theme/icon_and_font_color": 0, # Auto
	"text_editor/theme/color_theme": "{{.Name}}",
}


func _run() -> void:
	apply(EditorInterface.get_editor_settings())
	EditorInterface.restart_editor(true)


static func apply(es: EditorSettings) -> void:
	for key: String in SETTINGS:
		es.set_setting(key, SETTINGS[key])
`))

// Apply renders an EditorScript that switches the editor to the theme.
func (t *Theme) Apply() string {
	var b strings.Builder
	if err := applyTmpl.Execute(&b, t); err != nil {
		panic(err)
	}
	return b.String()
}

// Write puts <name>.tet and apply_<name>.gd in dir/<name>/.
func (t *Theme) Write(dir, source string) (string, error) {
	d := filepath.Join(dir, t.Name)
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(d, t.Name+".tet"), []byte(t.TET(source)), 0o644); err != nil {
		return "", err
	}
	return d, os.WriteFile(filepath.Join(d, "apply_"+strings.ReplaceAll(t.Name, "-", "_")+".gd"), []byte(t.Apply()), 0o644)
}

// godotThemesDir is where Godot looks for .tet files.
func godotThemesDir() (string, error) {
	cfg, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	name := "Godot"
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		name = "godot"
	}
	return filepath.Join(cfg, name, "text_editor_themes"), nil
}

// Install copies the .tet into Godot's text_editor_themes folder.
func (t *Theme) Install(source string) (string, error) {
	dir, err := godotThemesDir()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	p := filepath.Join(dir, t.Name+".tet")
	return p, os.WriteFile(p, []byte(t.TET(source)), 0o644)
}
