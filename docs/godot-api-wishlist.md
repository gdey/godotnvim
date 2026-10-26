# Godot editor APIs that would replace our workarounds

godotnvim replaces Godot's script editor, and Godot doesn't expect a plugin to
do that. Some of what the plugin does goes through the editor's internals:
finding unexposed nodes by class name, pressing buttons, reading icons, or
opening scripts in the hidden script editor. This page lists each of those
workarounds, why it is there, and the API that would let us remove it. Each
section is written so it can be the starting point of a
[godot-proposals](https://github.com/godotengine/godot-proposals) issue.

The upstream links were found by searching godotengine/godot and
godot-proposals in October 2026. "Related" means it touches the same code or
need, not that it asks for the same API. Statuses are as of that search.

Each entry ends with **Security concerns** for both today's workaround and
the proposed API. Godot has no plugin sandbox: an enabled plugin, like the
Neovim it starts, already runs with the user's full rights. So the concerns
are mostly about content from an untrusted project (scene names, files in
`.godot/`) reaching code that runs, and about an API making a quiet takeover
easier, rather than about a plugin gaining rights it didn't have.

Godot source references are to `master`. The internals we rely on are the
same from 4.5 to 4.7 unless a section says otherwise.

## Summary

| # | Workaround | Fragile because | Proposed API |
| --- | --- | --- | --- |
| 1 | Hide the Script screen with a feature profile, and follow Godot's script editor wherever it opens a script | Every new "open in script editor" path needs its own hook | `EditorPlugin._edit_script(script, line, column, method)` |
| 2 | Hook the Signals dock's tree and menus for Go to Method | Finds `ConnectionsDock` by class name, hard-codes a menu id | Covered by 1, or a `method_requested` signal |
| 3 | Set breakpoints by opening the script in the hidden script editor | Steals the main screen, needs a `CodeEdit` | `ScriptEditor.set_breakpoint()` and `breakpoint_toggled` |
| 4 | Poll the breakpoint list every 0.5 s | Gutter clicks raise no signal | `breakpoint_toggled` (as in 3) |
| 5 | Read "Skip Breakpoints" off a button's icon | Matches a translated tooltip | `EditorDebuggerPlugin.is_skipping_breakpoints()` |
| 6 | Pause by pressing the run bar's button | Finds `EditorRunBar` by class name | `EditorInterface.set_playing_scene_paused()` |
| 7 | Re-implement File → Run for `EditorScript` | Copies `EditorNode::run_editor_script` | `EditorScript.run()` |
| 8 | Switch to an unsaved scene through the scene tab bar; poll for save-as and reordering | Finds `EditorSceneTabs` by class name | `EditorInterface.set_edited_scene()`, `scenes_changed` |
| 9 | Push saved text into loaded resources and re-grab focus | Script reload steals focus | `EditorInterface.reload_resource_from_disk()` |
| 10 | `_handles` checks the unexposed `TextFile` class; Godot's editors still load text files and shaders | Internal class name | Expose `TextFile`; a file-open hook |
| 11 | Re-implement the script editor's drop text | Behaviour drifts with Godot | `ScriptEditor.get_drop_text()` |
| 12 | Re-implement the override and connection gutter lookups, and poll connections | Behaviour drifts with Godot | `ScriptEditor.get_method_markers()` and a change signal |

Items 1 and 3 are the big ones. With a way to claim script editing, and a
breakpoint API that doesn't live in the script editor's tabs, most of the
rest becomes small.

---

## 1. Claiming script editing

**Where:** `plugin.gd` `_handles` / `_edit`, `_on_debugger_goto_line`,
`_driving_script_editor`; `editor_profiles.gd`; `debugger_bridge.gd`.

**What we do.** A main-screen plugin can say it handles `Script` resources,
and Godot then calls `_edit()`. But Godot's script editor still opens the
script too, and many editor features skip `_edit()` and call the script editor
directly: the Signals dock (see 2), the debugger's Errors, Stack Frames and
Breakpoints lists, and others. So:

- `editor_profiles.gd` writes `-neovim` editor feature profiles with the
  Script feature off, so the Script screen doesn't show, and the plugin offers
  to restart the editor into one. It edits the `.profile` JSON by hand.
- An `EditorDebuggerPlugin` (`debugger_bridge.gd`) hears
  `_goto_script_line` and moves Neovim's cursor after Godot has already
  opened the script in its own editor.
- `_driving_script_editor` guards against our own background use of the
  script editor (see 3) echoing back into Neovim.

**Why it's fragile.** Each new place in the editor that opens a script needs
its own hook, and the script editor keeps a second copy of every file open.

**Prior art in Godot.** Script languages can already do this:
`ScriptLanguage::overrides_external_editor()` and
`open_in_external_editor(script, line, column)` are how C# hands scripts to
Rider or VS Code, and `ScriptEditor::edit()` checks them first
(`editor/script/script_editor_plugin.cpp`). A plugin can't use that for
GDScript, because it doesn't own the language. The `text_editor/external/`
settings only launch a process.

**Proposed API.**

```gdscript
# EditorPlugin: return true to take the request; Godot's script editor then
# does nothing. method is set for "go to method" requests (line is -1).
func _edit_script(script: Script, line: int, column: int, method: StringName) -> bool
```

`ScriptEditor.edit()`, `script_goto_method()` and `focus_script_editor()`
would ask plugins before doing anything, the same way they ask the script
language now. A plugin that claims editing could also ask for the Script
screen to be hidden, which would replace the feature-profile step:

```gdscript
# EditorPlugin: hide this built-in main screen while the plugin is enabled.
func _get_replaced_main_screen() -> String  # e.g. "Script"
```

**Security concerns.**

- *Today:* the feature-profile step writes `.profile` files into the user's
  editor config folder. That folder is shared by every project, so a plugin
  enabled in one project changes the editor everywhere once the user picks
  the profile. We only add new `-neovim` files, never change existing ones,
  and the user has to choose the profile. The profile JSON we read is the
  user's own file; one we can't parse is skipped.
- *Proposed API:* `_edit_script` lets any enabled plugin take every script
  open, quietly. A malicious or buggy plugin could show text that isn't what's
  on disk, or send scripts somewhere else. Plugins already run with the
  editor's full rights, so this isn't a new capability, but it makes a
  takeover easier to miss. Godot should allow only one plugin to claim
  scripts, show which one it is (in Editor Settings or the Script screen's
  place), and give the user a way to turn it off. Built-in scripts (`::` in
  the path) should keep going to the internal editor. Hiding the Script
  screen through `_get_replaced_main_screen` should show up in Manage Editor
  Features, as a profile does today, so it can't be hidden silently.

**Related upstream.**

- [godot-proposals#5759](https://github.com/godotengine/godot-proposals/issues/5759):
  use the embedded and an external editor at the same time (open).
- [godot-proposals#3659](https://github.com/godotengine/godot-proposals/issues/3659):
  a button to force a script into the internal editor.
- [godot-proposals#9806](https://github.com/godotengine/godot-proposals/issues/9806):
  let GDExtension classes provide source editing.
- [godot-proposals#2537](https://github.com/godotengine/godot-proposals/issues/2537):
  refactor the editor API for deep customizations.
- [godot-proposals#14924](https://github.com/godotengine/godot-proposals/issues/14924):
  one external editor configuration for all file types.
- [godot-proposals#8819](https://github.com/godotengine/godot-proposals/issues/8819)
  and [discussion #14541](https://github.com/godotengine/godot-proposals/discussions/14541):
  how `_make_visible`, `_edit` and `_handles` interact with the Script screen.
- [godot#65554](https://github.com/godotengine/godot/issues/65554),
  [godot#19838](https://github.com/godotengine/godot/issues/19838),
  [godot#84294](https://github.com/godotengine/godot/issues/84294): debugger
  lists not opening the external editor. External-editor users hit the same
  gaps we do.

**Possible cleanup today.** `EditorFeatureProfile` and
`EditorInterface.set_current_feature_profile()` are exposed in 4.5. Using them
instead of writing JSON, and switching profiles without a restart, may work.
Not yet tried.

## 2. Signals dock "Go to Method"

**Where:** `plugin.gd` `_hook_signals_dock` (added in
[#26](https://github.com/gdey/godotnvim/pull/26)).

**What we do.** `ConnectionsDock::_go_to_method` calls
`ScriptEditor::script_goto_method()` and `focus_script_editor()` directly, so
no plugin hears it. We find the dock with
`find_children("*", "ConnectionsDock")`, connect to its `Tree.item_activated`
and its `PopupMenu.id_pressed`, match the menu id against a hard-coded
`SLOT_MENU_GO_TO_METHOD` (1), read the connection off the tree item's
metadata, then switch the main screen back to Neovim after Godot has switched
to the Script screen.

**Why it's fragile.** It depends on the dock's class name, its child layout,
an enum value, and the shape of the tree item's metadata. Godot's script
editor still opens the method.

**Proposed API.** 1 covers it. Short of that, an editor-wide signal:

```gdscript
# EditorInterface (or ScriptEditor): emitted before the script editor opens
# a method for the Signals dock, the connect dialog, or "Go to Method".
signal method_requested(script: Script, method: StringName)
```

**Security concerns.**

- *Today:* we read the connection from tree-item metadata and only use the
  target's script path and method name. If a Godot change moved the menu id
  or the metadata, the worst case is opening the wrong method or nothing.
  The method name goes to Neovim as an RPC argument, not spliced into a Vim
  command.
- *Proposed API:* a read-only signal carrying a script and a method name.
  Low risk. Listeners should treat the method name as data, as we do.

**Related upstream.** Connecting a signal with an external editor has the same
root cause: the method stub is written through the script editor
([godot#36459](https://github.com/godotengine/godot/issues/36459),
[godot#39642](https://github.com/godotengine/godot/issues/39642),
[godot#91101](https://github.com/godotengine/godot/issues/91101),
[godot#43546](https://github.com/godotengine/godot/issues/43546)). No upstream
item asks for a Go to Method hook. A workaround for the FileSystem dock in
[godot-proposals#13867](https://github.com/godotengine/godot-proposals/issues/13867)
goes one step further and disconnects Godot's own handler from the dock's
tree. We don't do that yet.

## 3. Setting breakpoints

**Where:** `plugin.gd` `_set_breakpoint`, `_godot_breakpoints`,
`_on_file_saved`.

**What we do.** Godot keeps breakpoints in the gutters of the script editor's
open tabs (`DocumentEditorContainer::get_breakpoints`), and
`ScriptEditor.get_breakpoints()` only lists open scripts. To set one from
Neovim we call `EditorInterface.edit_script()` to open the script in the
hidden script editor, take its `CodeEdit` from `get_current_editor()`, call
`set_line_as_breakpoint()`, then switch the main screen back to Neovim. The
README lists the side effect under Known gaps: scripts with breakpoints stay
open in the background.

`EditorDebuggerSession.set_breakpoint()` exists, but it only tells a running
session and the Breakpoints list. It needs a session, and the script editor's
list, which new runs start from, doesn't change.

**Proposed API.**

```gdscript
# ScriptEditor: the editor's breakpoint list, independent of open tabs.
func set_breakpoint(path: String, line: int, enabled: bool) -> void
func get_breakpoints_for(path: String) -> PackedInt32Array
signal breakpoint_toggled(path: String, line: int, enabled: bool)
```

**Security concerns.**

- *Today:* breakpoint requests come from Neovim. `_set_breakpoint` only
  accepts `res://` paths ending in `.gd`, so Neovim (or a Neovim plugin)
  can't make the editor open arbitrary files this way. Opening the script in
  the background script editor loads it the same way clicking it would.
- *Proposed API:* `set_breakpoint(path, ...)` should only accept scripts
  inside the project and fail on anything else. A breakpoint pauses the
  running game and shows its locals in the debugger; that's the point, and
  it stays within the user's own game. Breakpoints can already be set over
  the Debug Adapter Protocol, which listens on a local port, so the new API
  shouldn't add a way to reach it from the network that DAP doesn't already
  have.

**Related upstream.**
[godot#89039](https://github.com/godotengine/godot/issues/89039) (closed as a
duplicate of [godot#83614](https://github.com/godotengine/godot/issues/83614)):
breakpoints set over DAP failed for scripts not open in the editor, the same
coupling. [godot#100516](https://github.com/godotengine/godot/pull/100516)
(conditional and disabled breakpoints) and
[godot-proposals#10271](https://github.com/godotengine/godot-proposals/issues/10271)
would extend the breakpoint model; an API here should leave room for them.
[godot-proposals#8777](https://github.com/godotengine/godot-proposals/issues/8777)
asks for debugger tooling for GDExtension.

## 4. Watching for breakpoint changes

**Where:** `plugin.gd` `_bp_timer` (0.5 s) → `_sync_breakpoints`.

**What we do.** Clicking Godot's gutter raises nothing a plugin can hear.
`EditorDebuggerNode` emits `breakpoint_toggled`, but that class isn't exposed,
and `EditorDebuggerPlugin` only gets `_breakpoint_set_in_tree` and
`_breakpoints_cleared_in_tree` for the Breakpoints list. So we poll.

**Proposed API.** `ScriptEditor.breakpoint_toggled` from 3, or a virtual on
`EditorDebuggerPlugin`:

```gdscript
func _breakpoint_toggled(path: String, line: int, enabled: bool) -> void
```

**Security concerns.**

- *Today:* none beyond correctness. The poll is cheap and reads the
  editor's own list.
- *Proposed API:* none. A notification carrying a path and line.

**Related upstream.** None found.

## 5. Reading "Skip Breakpoints"

**Where:** `plugin.gd` `_is_skipping_breakpoints`, `_find_skip_buttons`.

**What we do.** We find each `ScriptEditorDebugger` by class name, pick the
`Button` whose tooltip is "Skip Breakpoints", and compare its icon with
`DebugSkipBreakpointsOn`. With several sessions we use the visible one, as
`EditorDebuggerNode::is_skip_breakpoints()` does.

**Why it's fragile.** The tooltip is translated, so this fails in other
editor languages, and it depends on the icon name.

**Proposed API.**

```gdscript
# EditorDebuggerPlugin, or EditorDebuggerSession per session.
func is_skipping_breakpoints() -> bool
func set_skipping_breakpoints(skip: bool) -> void
signal skip_breakpoints_changed(skip: bool)
```

**Security concerns.**

- *Today:* this is a correctness risk rather than a security one, but it
  can mislead. When the tooltip is translated, or the icon changes, we
  report "not skipping" while Godot is skipping, so the user may trust a
  breakpoint that won't stop.
- *Proposed API:* a setter lets a plugin turn breakpoints off. The toggle
  button already shows the state, so the user can see it; keep it that way.

**Related upstream.** The toggle came from
[godot#30982](https://github.com/godotengine/godot/pull/30982). No request to
expose it found.

## 6. Pausing the running project

**Where:** `plugin.gd` `_run` (`"pause"`), `_run_bar_buttons`,
`_find_shortcut_button`.

**What we do.** `EditorInterface` can play and stop but not pause. We find the
run bar's pause button by its `editor/pause_running_project` shortcut, or on
4.5, by its `Pause` icon inside the `EditorRunBar` node, and press it. 4.5
also lacks `EditorSettings.get_shortcut()`, so the shortcuts that work while
typing come from the run bar's buttons too.

**Proposed API.**

```gdscript
# EditorInterface
func set_playing_scene_paused(paused: bool) -> void
func is_playing_scene_paused() -> bool
```

**Security concerns.**

- *Today:* we press a button we found by shortcut or icon. If the 4.5 icon
  fallback ever matched the wrong button, we'd press that one instead; we do
  check it isn't disabled. It only acts on the user's own running game.
- *Proposed API:* low risk. Pausing the user's own game from a plugin.

**Related upstream.**
[godot-proposals#3105](https://github.com/godotengine/godot-proposals/issues/3105)
(pause and frame stepping shortcut),
[godot-proposals#11875](https://github.com/godotengine/godot-proposals/issues/11875)
(pause shortcut from the running game),
[discussion #13794](https://github.com/godotengine/godot-proposals/discussions/13794)
(syncing the run bar and embedded game pause),
[godot-proposals#3504](https://github.com/godotengine/godot-proposals/issues/3504)
(`scene_started` and `scene_stopped` signals).

**Cleanup available now.** Raising the minimum to 4.6 would drop the icon and
run-bar fallbacks; only the button press would remain.

## 7. Running an EditorScript

**Where:** `plugin.gd` `run_editor_script` (`:GodotRunFile`).

**What we do.** `EditorNode::run_editor_script` isn't exposed, so we copy it:
reload the script from disk, check it is a `@tool` `EditorScript`, create it
and call `_run()`.

**Proposed API.** `EditorScript.run()`, or
`EditorInterface.run_editor_script(path)`.

**Security concerns.** This is the item with real exposure.

- *Today:* `:GodotRunFile` runs code with the editor's full rights: it can
  read and write any file the user can, and run programs. Anything that can
  send commands to the embedded Neovim can trigger it: Neovim plugins, and
  any program that can reach Neovim's socket if the user's `nvim_args` add
  `--listen`. Those already run code as the user, so this doesn't raise
  privileges, but it is a new way to run code *inside the editor*. We check
  the script is `@tool` and extends `EditorScript`, and we reload it from
  disk so what runs is what's on disk. Files outside the project need a
  confirmation, on the Neovim side. A Neovim plugin could skip that prompt
  by sending the run notification itself, but that gains it nothing: it can
  already write a script inside the project and run that with no prompt, or
  just run its own code. So the prompt guards against mistakes, not against
  Neovim plugins, and moving it into Godot wouldn't change that.
- *Proposed API:* `EditorScript.run()` adds no new capability: plugins can
  already create the script and call `_run()`. Godot's version should keep
  the `@tool` check and guard against recursion (godot#93274 adds a
  stack-overflow guard). An `EditorInterface.run_editor_script(path)` form
  should refuse paths outside the project unless the caller asks for them
  explicitly.

**Related upstream.**
[godot#93274](https://github.com/godotengine/godot/pull/93274) "Expose run()
method of EditorScript" (KoBeWi; not merged as of the search, with a note that
[godot#99318](https://github.com/godotengine/godot/pull/99318), which adds
named EditorScripts to the command palette, covers part of the need; that one
was also still open). `EditorScript` on `master` still only has `_run`.

## 8. Scene tabs

**Where:** `plugin.gd` `_show_scene`, `_scene_tab_bar`, `_sync_scenes`,
`_bp_timer`.

**What we do.** Switching Godot to a saved scene works with
`EditorInterface.open_scene_from_path()`. A new scene that hasn't been saved
has no path, so we find the `TabBar` inside the `EditorSceneTabs` node and set
`current_tab`. Saving a scene under a new path and reordering tabs raise no
signal that ties the change to the scene, so we poll
`get_open_scene_roots()` on the 0.5 s timer and track roots by instance id.

**Proposed API.**

```gdscript
# EditorInterface
func set_edited_scene(root: Node) -> void  # or by index into get_open_scene_roots()
# EditorPlugin: open scenes were added, removed, reordered or renamed.
signal scenes_changed
signal scene_path_changed(scene_root: Node, old_path: String, new_path: String)
```

**Security concerns.**

- *Today:* scene keys from Neovim are only matched against scenes Godot has
  open; unknown ones are dropped, so Neovim can't make Godot open a scene
  that way. A separate concern the scene links live next to: the Neovim
  session is `res://.godot/godot_nvim/session.vim`, and Neovim *runs* it on
  start (`:source`). Someone who hands over a project with a crafted
  `.godot/` folder can run Vim commands, and through them shell commands,
  when the user opens it. This doesn't add a way in: the addon lives in the
  project's own `addons/` folder, so whoever ships the `.godot/` folder also
  ships the plugin code and any `@tool` scripts, which Godot runs on open.
  An untrusted project is unsafe to open either way. `.godot/` is normally
  kept out of version control, so a cloned project doesn't bring a session.
  Keeping the session in the user's data folder instead would only matter
  if Godot gains a way to open a project without running its code.
- *Proposed API:* `set_edited_scene(root)` only takes scenes that are
  already open. Low risk.

**Related upstream.**
[godot-proposals#9619](https://github.com/godotengine/godot-proposals/issues/9619)
(a signal before a scene change; its author also had to reach into editor
internals),
[godot-proposals#3215](https://github.com/godotengine/godot-proposals/issues/3215)
(tabs control 2D, 3D and scripts).

## 9. Reloading after Neovim saves

**Where:** `plugin.gd` `_on_file_saved`, `_keep_focus`.

**What we do.** After `:w` we call `update_file()`, then put the new text into
the cached resource ourselves (`source_code` and `reload(true)` for scripts,
`code` for shaders, `parse()` for JSON) and call
`ScriptEditor.reload_open_files()`. Reloading hands keyboard focus to the
hidden script editor, so we grab it back on the next frame.

**Proposed API.**

```gdscript
# EditorInterface: reload a file-backed resource that changed on disk, in
# place, and refresh any editor showing it, without moving focus.
func reload_resource_from_disk(path: String) -> Error
```

**Security concerns.**

- *Today:* reloading a `@tool` script runs its new code in the editor right
  away, so every `:w` runs whatever was saved, including text a formatter
  wrote. That matches Godot's own behaviour when it notices a change. We
  only reload `res://` paths.
- *Proposed API:* `reload_resource_from_disk(path)` should be limited to
  project files, and its docs should say that reloading a tool script runs
  it.

**Related upstream.**
[godot-proposals#13741](https://github.com/godotengine/godot-proposals/issues/13741)
"Add a way to update the script editor for external changes" (open; the
workarounds there are hacks too),
[godot#89645](https://github.com/godotengine/godot/issues/89645) (the script
editor overwriting externally edited scripts).

## 10. Text files and shaders

**Where:** `plugin.gd` `_TEXT_CLASSES`, `_handles`; README Known gaps.

**What we do.** Plain text files opened from the FileSystem dock are the
internal `TextFile` class, which scripts can't name, so `_handles` uses
`is_class("TextFile")`. And Godot's own editors load the file before any plugin
sees it: text files get a tab in the script editor, and shaders may open the
shader panel.

**Proposed API.** Expose `TextFile`, and give plugins a say before the
FileSystem dock opens a file:

```gdscript
# EditorPlugin: return true to open the file yourself.
func _open_file(path: String) -> bool
```

**Security concerns.**

- *Today:* `_handles` only takes file-backed resources. The data risk is
  that two editors hold the same file and can overwrite each other's
  changes. That's integrity, not security.
- *Proposed API:* an `_open_file` hook lets a plugin catch every file the
  user opens. Plugins that send files to an outside program should start it
  with an argument list (`OS.create_process(path, args)`), never a shell
  string, so a file name can't become a command. Godot could show which
  plugin handled a file, as with 1.

**Related upstream.**
[godot-proposals#13867](https://github.com/godotengine/godot-proposals/issues/13867)
"Add an API for overriding Open file from the FileSystem dock behavior"
(closed in favour of
[godot-proposals#14924](https://github.com/godotengine/godot-proposals/issues/14924)).

## 11. Drop text

**Where:** `drop_text.gd`, `plugin.gd` `_build_drop`.

**What we do.** Dropping nodes, files and Inspector properties on a `Control`
works, but the text Godot's script editor would insert (`$Path`, `%Unique`,
`@onready var name: Type = $Path`, `preload(...)`, `"Path:property"`) is
built inside `ScriptTextEditor::drop_data_fw`. We rebuild it, including the
quoting rules and the `add_type_hints` setting, and it can drift as Godot
changes the format.

**Proposed API.**

```gdscript
# ScriptEditor, or the ScriptLanguage so C# gets C# text: the text the script
# editor would insert for this drag data, in this script.
func get_drop_text(data: Variant, script: Script, modifier: bool) -> String
```

**Security concerns.**

- *Today:* we turn node names, file paths and property names into code. A
  scene from someone else can have node names with quotes, backslashes or
  newlines. `drop_text.gd` quotes and escapes them (`c_escape`,
  `identifier()`, quoting non-identifier paths), so a name can't break out
  of the string and become code. The text goes to Neovim as an RPC argument
  and is inserted as text, not run as a Vim command. Any change to the
  escaping needs a test with hostile names.
- *Proposed API:* better, because the escaping lives in one place, in
  Godot, and is tested with the script editor. Callers must insert the
  result as text and never evaluate it.

**Related upstream.** Ideas that would change the text we copy:
[godot-proposals#4482](https://github.com/godotengine/godot-proposals/issues/4482)
(Ctrl-drop makes `@onready` vars, implemented),
[godot-proposals#9966](https://github.com/godotengine/godot-proposals/issues/9966)
(a cast option),
[godot-proposals#12394](https://github.com/godotengine/godot-proposals/issues/12394)
(drop as `@export`),
[godot-proposals#12900](https://github.com/godotengine/godot-proposals/issues/12900)
(drop a node to connect its signal),
[godot#91295](https://github.com/godotengine/godot/issues/91295) (C# files get
GDScript text, which this API would fix too).

## 12. Override and connection markers

**Where:** `plugin.gd` `overridable_methods`, `_connections_for`,
`_script_has_method`, `_bp_timer` → `_sync_connections`.

**What we do.** Godot's script editor marks methods that override a base
class and methods that signals connect to. We copy its lookups: walk base
scripts and `ClassDB` for overrides, and walk the edited scene for nodes
using the script and their persistent incoming connections, skipping deleted
nodes kept for undo. Connections made in the Signals dock raise nothing, so
we poll.

**Proposed API.**

```gdscript
# ScriptEditor: what the gutter shows, per method.
func get_method_markers(script: Script) -> Dictionary  # method -> {overrides, connections}
# EditorPlugin: a connection in the edited scene was made or removed.
signal scene_connections_changed
```

**Security concerns.**

- *Today:* we send method, signal and node names from the edited scene to
  Neovim as RPC arguments; the Lua side places signs with them and doesn't
  build Vim commands from them. A crafted scene can't run commands this way.
- *Proposed API:* read-only. Low risk.

**Related upstream.** None found.
