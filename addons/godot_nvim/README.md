# Neovim Script Editor for Godot

Edit GDScript, shaders and other text files in an embedded Neovim, drawn
inside the Godot editor with Neovim's UI protocol.

- Scripts, shaders, JSON and plain text files open in a **Neovim** main-screen tab.
  Your Neovim config, plugins and keymaps load as usual.
- Drag nodes from the Scene dock to insert `$Path` (Ctrl/Cmd: `@onready var`),
  or files from the FileSystem dock to insert paths (Ctrl/Cmd: `preload`).
- Drag an Inspector property to insert `$Path.property`
  (Ctrl/Cmd: the NodePath `"Path:property"`).
- GDScript language server is connected: hover docs, definitions, completion.
  `:GodotFunc <name>` jumps to a function anywhere in the project.
- Debugger breakpoints show as signs and stay in sync with Godot; toggle them
  with `F9` or a double-click in the gutter. Debugger double-clicks jump to
  the line.
- Signs mark methods connected to signals (`⇠`) and methods that override a
  base class (`↱`); `:GodotConnections` lists them.
- GDScript is formatted on save with GDQuest's `gdscript-formatter` or
  gdtoolkit's `gdformat`, whichever is installed (`:GodotFormat` on demand).
- Open files, cursors, splits and tabs are saved when the editor closes and
  restored when the project opens again.
- Each open scene gets its own Neovim tab page. Switching scenes in Godot
  switches tab pages, and `gt` in Neovim switches Godot's scene.
- Neovim uses the script editor's colors and follows theme changes.
- Godot's run, pause and stop shortcuts work while typing, and as
  `:GodotRun`, `:GodotRunCurrent`, `:GodotRunScene`, `:GodotPause`, `:GodotStop`.
- `:GodotRunFile [file]` runs an `EditorScript`, as File → Run does.

## Requirements

Godot 4.5 or newer. Neovim 0.10 or newer, installed separately. The plugin looks in
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and the default Windows
install folder, then your `PATH`. Set another path in Editor Settings →
`godot_nvim/nvim_path`.

## Install

Copy this folder to `res://addons/godot_nvim/` (the Asset Library does this
for you), then enable **Neovim Script Editor** in Project Settings → Plugins.
The addon is editor-only and leaves itself out of exported games.

Full documentation: https://github.com/gdey/godotnvim
