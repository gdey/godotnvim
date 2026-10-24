# godotnvim

A Godot 4 editor plugin that edits GDScript in an embedded Neovim, drawn
inside the editor with Neovim's UI protocol (`ext_linegrid`). Dragging nodes
or files from the editor's docks onto the Neovim view inserts the same text
Godot's own script editor does.

Status: early. Tested headless against Godot 4.7.1 with Neovim 0.12 and 0.9.

## Install

Copy `addons/godot_nvim` into your project's `addons/` folder, then enable
**Neovim Script Editor** under Project → Project Settings → Plugins. A
**Neovim** tab appears next to 2D / 3D / Script.

The plugin looks for `nvim` in `/opt/homebrew/bin`, `/usr/local/bin` and
`/usr/bin` (apps started from the macOS Dock don't see your shell's `PATH`).
To use a different binary, set it in Editor Settings → `godot_nvim/nvim_path`.
You can pass extra arguments, such as `-u NONE`, in `godot_nvim/nvim_args`.
Neovim starts in the project folder and loads your usual config.

## Use

- Open a script from the FileSystem dock (anything that goes through
  `EditorInterface.edit_resource`). It opens in the Neovim tab.
- Drag a node from the Scene dock onto the view to insert `$Path/To/Node`
  (or `%Name` for unique names). Hold Ctrl (Cmd on macOS) while dropping to
  insert `@onready var node_name: Type = $Path/To/Node` above the line under
  the mouse. Type hints follow Editor Settings →
  `text_editor/completion/add_type_hints`.
- Drag files from the FileSystem dock to insert `"res://path"`, or with
  Ctrl/Cmd held, `const Name = preload("res://path")`.
- `:w` saves, and Godot reloads the script.

## Known gaps

- Godot opens some scripts with `EditorInterface.edit_script()`, for
  example when jumping to an error or a debugger breakpoint. Those still open
  in Godot's built-in script editor. The fix is either to route Godot's
  "external editor" setting to the embedded Neovim, or to add an engine hook
  through a local Godot patch.
- Only one grid (no `ext_multigrid`). The popup menu, cmdline and messages
  are drawn by Neovim inside the grid.
- No LSP wiring yet. Godot's language server runs on port 6005, and you can
  point `vim.lsp` at it from your own config.

## Layout

| File | What it does |
| --- | --- |
| `msgpack.gd` | MessagePack encoder and streaming decoder |
| `nvim_rpc.gd` | Starts `nvim --embed` through `OS.execute_with_pipe`, msgpack-RPC requests and notifications |
| `nvim_grid.gd` | `ext_linegrid` screen state (cells, highlights, cursor, mode) |
| `nvim_view.gd` | Control that draws the grid and sends keyboard, mouse and drops to Neovim |
| `nvim_keys.gd` | Turns Godot key events into Neovim key notation |
| `drop_text.gd` | Builds the text for dropped nodes and files, matching Godot's script editor |
| `godot_nvim.lua` | Neovim-side helpers: save and buffer notifications, drop insertion |
| `plugin.gd` | EditorPlugin: the main-screen tab, opening scripts, editor settings |

## Tests

```sh
NVIM=/path/to/nvim godot --headless --path . -s tests/run_tests.gd
```

The first run in a fresh checkout needs `godot --headless --path . --editor --quit`
first, so Godot registers the addon's `class_name`s.
