# Changelog

All notable changes to this plugin are listed here. Versions follow
[Semantic Versioning](https://semver.org/); the version lives in
`addons/godot_nvim/plugin.cfg`.

## [Unreleased]

### Added

- `colorscheme/`: vim2godot, a Go tool that converts a Vim or Neovim
  colorscheme (any on vimcolorschemes.com) into a Godot editor theme, a `.tet`
  for the script editor plus an EditorScript for the interface colors. It is
  not part of the addon download. cendre is included as an example.
- `:GodotRunFile [file]` runs a `@tool` script that extends `EditorScript`,
  as the script editor's File → Run does. Without a file it runs the current
  buffer, writing it first if it has unsaved changes. Files outside the
  project run after a confirmation.
- Dragging a property from the Inspector into Neovim inserts it with its
  node path, `$Path/To/Node.property`, or with Ctrl/Cmd held, the NodePath
  string `"Path/To/Node:property"`.
- Open files, cursor positions, splits and tabs are saved when the editor
  closes (or Neovim quits) and restored when the project opens again. The
  session lives in `.godot/godot_nvim/session.vim`. Editor Settings →
  `godot_nvim/restore_session` turns it off.

### Fixed

- A file opened from Godot while Neovim was still starting lost its line:
  Godot now holds files back until Neovim has started.
- The plugin failed to load on Godot 4.5, which lacks
  `EditorSettings.get_shortcut()`. There, the run shortcuts that work while
  typing are taken from the editor's run bar.

## [0.2.0] - 2026-10-25

### Added

- `:GodotFunc <name>` opens a GDScript function by name from anywhere in the
  project, with name completion. Several matches, or partial ones, go to the
  quickfix list. Godot's language server has no workspace symbol search.
- Project → Tools → Create Neovim Editor Profiles: copies each editor feature
  profile to `<name>-neovim` with the Script screen hidden, and offers to
  switch to one. The README now recommends hiding the Script screen.
- GDScript formatting on save, on by default. It uses GDQuest's
  `gdscript-formatter` (including the copy its Godot add-on installs) or
  gdtoolkit's `gdformat`, whichever is found, and does nothing if neither is
  installed. Editor Settings → `godot_nvim/format_on_save` turns it off and
  `godot_nvim/formatter_command` picks another command. `:GodotFormat`
  formats on demand.

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

[0.2.0]: https://github.com/gdey/godotnvim/releases/tag/v0.2.0
[0.1.0]: https://github.com/gdey/godotnvim/releases/tag/v0.1.0
