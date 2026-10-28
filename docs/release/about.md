godotnvim replaces Godot's script editor with an embedded Neovim, drawn
inside the editor. Your Neovim config, plugins and keymaps load as usual, and
the parts of Godot's script editor that matter keep working.

![Neovim tab with breakpoint, override and signal signs in the editor's colors](../screenshots/overview.png)

- **Drag and drop:** nodes, files and Inspector properties drop in as the
  same text Godot inserts, with Ctrl/Cmd for `@onready var`, `preload` and
  NodePath forms.
- **Language server:** hover docs, go-to-definition, references, rename and
  completion from Godot's GDScript language server, plus `:GodotFunc` to jump
  to any function in the project and `:GodotErrors` to list script errors
  across it.
- **Colors and resources:** a swatch before each `Color` literal opens
  Godot's color picker, and an icon before each `preload` or `load` path
  opens the file or picks another.
- **Debugger:** breakpoints show in the gutter and stay in sync with Godot's
  debugger both ways.
- **Signs:** methods that signals connect to, and methods that override a base
  class, are marked as in Godot's script editor.
- **Running:** Godot's run, pause and stop shortcuts work while you type, and
  `:GodotRunFile` runs an `EditorScript`.
- **Format on save** with `gdscript-formatter` or `gdformat`.
- **Sessions and scene tabs:** open files, splits and tabs come back when the
  project reopens, and each open scene gets its own Neovim tab page.
- **Colors:** Neovim takes the script editor's colors, and vim2godot (in this
  release's assets) turns any Vim colorscheme into a Godot theme.

![Hover docs from Godot's language server](../screenshots/lsp-hover.png)

![Ctrl-dropping two nodes inserts @onready vars](../screenshots/drag-and-drop.png)

Needs Godot 4.5+ and Neovim, installed separately. To install, copy
`addons/godot_nvim` from `godot_nvim-<version>.zip` into your project's
`addons/` folder and enable **Neovim Script Editor** under Project → Project
Settings → Plugins. See the
[README](https://github.com/gdey/godotnvim#readme) for the details.
