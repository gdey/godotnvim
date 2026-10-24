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

- Open any text file from the FileSystem dock: scripts, shaders
  (`.gdshader`, `.gdshaderinc`), `.json`, and plain text (`.cfg`, `.txt`,
  `.md`, …). It opens in the Neovim tab. Scenes and `.tres` resources still
  open in their usual editors.
- Drag a node from the Scene dock onto the view to insert `$Path/To/Node`
  (or `%Name` for unique names). Hold Ctrl (Cmd on macOS) while dropping to
  insert `@onready var node_name: Type = $Path/To/Node` above the line under
  the mouse. Type hints follow Editor Settings →
  `text_editor/completion/add_type_hints`.
- Drag files from the FileSystem dock to insert `"res://path"`, or with
  Ctrl/Cmd held, `const Name = preload("res://path")`.
- `:w` saves, and Godot reloads the script, shader or JSON.
- Neovim runs for as long as the editor does. On the last window, `:q` acts
  like `:bd` and `:wq` / `:x` like `:w` + `:bd`: the file closes, the previous
  file (or an empty placeholder) shows, and Neovim keeps running. If Neovim exits anyway
  (`:qa`, a crash), it restarts on the last file.

## Debugger

- Breakpoints show as `●` signs in Neovim's sign column (highlight group
  `GodotBreakpoint`, linked to `DiagnosticError`). They stay in sync with
  Godot's Breakpoints list, whether you set them from Neovim, Godot's own
  editor gutter, or the debugger panel. While the debugger's **Skip
  Breakpoints** is on, the signs turn grey (`GodotBreakpointSkipped`, linked
  to `Comment`).
- `F9` (Godot's key) or `:GodotToggleBreakpoint` toggles a breakpoint on the
  cursor line, and double-clicking the gutter (sign or number column) toggles
  one on the clicked line. If you already map `F9` or `<2-LeftMouse>`, the
  plugin leaves your mapping alone. So there's always a gutter to click,
  GDScript buffers get `signcolumn=yes` when yours is the default `auto`.
- Signs move with your edits. On `:w`, Godot's breakpoints move to match.
- Double-clicking a breakpoint, an error or a stack frame in the debugger
  opens the file in Neovim at that line.

## Signal connections and overrides

Like Godot's script editor, the sign column marks methods:

- `⇠` on a method that a signal in the edited scene is connected to
  (highlight `GodotSignalSlot`, green).
- `↱` on a method that overrides one from a base class, such as `_ready()` or
  a method of a base script (highlight `GodotMethodOverride`, blue).
- `↱⇠` when both apply.

The colors are the ones Godot's own icons use. To restyle them, define the
highlight groups in your config, for example
`vim.api.nvim_set_hl(0, "GodotMethodOverride", { fg = "#ffcc00", bold = true })`.

Change the glyphs with `vim.g.godot_nvim_slot_sign`,
`vim.g.godot_nvim_override_sign` and `vim.g.godot_nvim_override_slot_sign`.
`:GodotConnections` shows the signals connected to the function under the
cursor and the method it overrides. A connection to a method the script
doesn't have shows up as a warning diagnostic. Signal signs follow the scene
you're editing and update when you connect or disconnect signals in the Node
dock; override signs update as you type, and follow `extends` when you save.

## Language server

The plugin connects `.gd` buffers to the GDScript language server that the
Godot editor runs (host and port come from Editor Settings →
`network/language_server/remote_host` / `remote_port`, default
`127.0.0.1:6005`). This gives hover docs (including the engine class
reference), go-to-definition, references, rename and completion.

If your own config already sets up a `gdscript` client (`vim.lsp.enable("gdscript")`
or nvim-lspconfig), the plugin leaves it alone and uses yours. To turn the
plugin's client off entirely, clear Editor Settings → `godot_nvim/connect_lsp`.

On Neovim 0.11+ the default LSP mappings cover most of it: `K` for hover,
`Ctrl-]` for definition, `grr` for references, `grn` for rename, `gra` for
code actions, and `Ctrl-x Ctrl-o` for completion. For completion as you type
and a `gd` mapping, add something like this to your config:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client.name == "gdscript" then
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
      vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = ev.buf })
    end
  end,
})
```

## Known gaps

- Godot's breakpoint API lives in its own script editor, so the plugin keeps
  scripts with breakpoints open there in the background.
- Godot's own editors still load the file in the background: plain text files
  get a tab in the script editor, and shaders may open the shader editor
  panel. The engine does this before any plugin sees the file. Edit in Neovim
  only, or the copies can drift apart.
- Only one grid (no `ext_multigrid`). The popup menu, cmdline and messages
  are drawn by Neovim inside the grid.

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
| `debugger_bridge.gd` | EditorDebuggerPlugin: forwards the debugger's go-to-line and breakpoint events |
| `plugin.gd` | EditorPlugin: the main-screen tab, opening scripts, editor settings |

## Tests

```sh
NVIM=/path/to/nvim godot --headless --path . -s tests/run_tests.gd
```

The first run in a fresh checkout needs `godot --headless --path . --editor --quit`
first, so Godot registers the addon's `class_name`s.
