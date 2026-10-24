## Forwards the debugger's "go to line" and breakpoint-tree events to the
## plugin. The debugger emits goto_script_line for double-clicks in the
## Breakpoints list, the Errors tab and stack frames.
@tool
extends EditorDebuggerPlugin

signal goto_line(script: Script, line: int)
signal breakpoints_changed


## [param line] is 0-based.
func _goto_script_line(script: Script, line: int) -> void:
	goto_line.emit(script, line)


func _breakpoint_set_in_tree(_script: Script, _line: int, _enabled: bool) -> void:
	breakpoints_changed.emit()


func _breakpoints_cleared_in_tree() -> void:
	breakpoints_changed.emit()
