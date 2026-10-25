# Changelog

All notable changes to this plugin are listed here. Versions follow
[Semantic Versioning](https://semver.org/); the version lives in
`addons/godot_nvim/plugin.cfg`.

## [Unreleased]

### Added

- `:GodotFunc <name>` opens a GDScript function by name from anywhere in the
  project, with name completion. Several matches, or partial ones, go to the
  quickfix list. Godot's language server has no workspace symbol search.

## [0.1.0] - 2026-10-25

First release.

### Added

- Neovim embedded in a main-screen tab through the UI protocol (ext_linegrid).
  GDScript, shaders and other text files open there instead of Godot's script
  editor.
- Drag-and-drop of scene nodes and files from the Scene and FileSystem docks.
  The inserted text matches Godot's script editor (`$Node`, `$"../Path"`,
  `%Unique`, `preload(...)`, `@onready var` with Ctrl/Cmd).
- The GDScript language server, connected automatically.
- Debugger breakpoints as signs. Toggle them with F9 or a double-click on the
  gutter. They sync both ways with Godot's debugger, follow its go-to-line,
  and grey out while Skip Breakpoints is on.
- Signs for methods connected to signals (`⇠`) and for overridden virtual or
  inherited methods (`↱`). `:GodotConnections` lists both for the method
  under the cursor.
- A `godot` colorscheme built from the editor's text editor colors, updated
  when the editor theme changes (setting `godot_nvim/use_editor_colors`).
- The editor's run shortcuts work inside Neovim (Run Project, Run Current
  Scene, Run Specific Scene, Pause, Stop), plus `:GodotRun`,
  `:GodotRunCurrent`, `:GodotRunScene`, `:GodotPause` and `:GodotStop`.
- `:w` saves without moving focus out of Neovim. `:q` closes the buffer
  instead of Neovim, and `:wq` saves then closes it.
- Asset Library packaging, and a release workflow that publishes the addon
  zip when a version tag is pushed.

[0.1.0]: https://github.com/gdey/godotnvim/releases/tag/v0.1.0
