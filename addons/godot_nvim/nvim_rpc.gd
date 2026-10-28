## Talks msgpack-RPC to an embedded Neovim over its stdio pipe.
##
## Call [method start], then [method poll] every frame. Requests return
## through a callback; notifications (such as "redraw") are emitted as
## [signal notification].
class_name NvimRpc
extends RefCounted

signal notification(method: String, params: Array)
signal exited

const _REQUEST := 0
const _RESPONSE := 1
const _NOTIFY := 2

var pid := -1

var _io: FileAccess
var _err: FileAccess
var _decoder := Msgpack.Decoder.new()
var _next_id := 1
var _pending := {}  # msgid -> Callable(err, result)


## Starts [param nvim_path] with --embed plus [param extra_args].
func start(nvim_path: String, extra_args: PackedStringArray = []) -> Error:
	var args := PackedStringArray(["--embed"])
	args.append_array(extra_args)
	var p := OS.execute_with_pipe(nvim_path, args, false)
	if p.is_empty():
		return ERR_CANT_FORK
	_io = p.stdio
	_err = p.stderr
	pid = p.pid
	return OK


func is_running() -> bool:
	return pid > 0 and OS.is_process_running(pid)


## Quits Neovim, giving it [param grace_ms] to exit cleanly (and remove its
## swap files) before it is killed.
func stop(grace_ms := 1000) -> void:
	if is_running():
		notify("nvim_command", ["qa!"])
		var deadline := Time.get_ticks_msec() + grace_ms
		while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
			_io.get_buffer(1 << 16)  # keep the pipe drained so nvim isn't blocked writing
			OS.delay_msec(10)
		if OS.is_process_running(pid):
			OS.kill(pid)
	pid = -1
	_io = null
	_err = null


## Calls [param method] and waits up to [param timeout_ms] for the result,
## dispatching anything else that arrives meanwhile. Returns [error, result];
## error is "timeout" if Neovim didn't answer in time.
func request_sync(method: String, params: Array = [], timeout_ms := 2000) -> Array:
	var out := []
	request(method, params, func(err: Variant, res: Variant) -> void: out.append_array([err, res]))
	var deadline := Time.get_ticks_msec() + timeout_ms
	while out.is_empty() and is_running() and Time.get_ticks_msec() < deadline:
		poll()
		if out.is_empty():
			OS.delay_msec(5)
	return out if out.size() == 2 else ["timeout", null]


## Calls [param method]; [param callback] gets (error, result) when the
## response arrives. Error is null on success.
func request(method: String, params: Array = [], callback := Callable()) -> void:
	var id := _next_id
	_next_id += 1
	if callback.is_valid():
		_pending[id] = callback
	_send([_REQUEST, id, method, params])


func notify(method: String, params: Array = []) -> void:
	_send([_NOTIFY, method, params])


## Reads whatever Neovim has written and dispatches complete messages.
func poll() -> void:
	if _io == null:
		return
	var chunk := _io.get_buffer(1 << 16)
	while chunk.size() > 0:
		_decoder.feed(chunk)
		chunk = _io.get_buffer(1 << 16)
	while true:
		var r := _decoder.next()
		if not r[0]:
			break
		_dispatch(r[1])
	if _err != null:
		var e := _err.get_buffer(1 << 12)
		if e.size() > 0:
			push_warning("nvim: " + e.get_string_from_utf8())
	if not is_running():
		pid = -1
		_io = null
		exited.emit()


## The pipe is non-blocking, and a write the pipe has no room for fails with
## no way to tell how much of it went through. Writes of at most PIPE_BUF
## bytes (512 on macOS, more elsewhere) go through whole or not at all, so
## big messages, such as godot_nvim.lua, go in pieces of that size, each
## tried again until Neovim has read enough to make room.
const _PIPE_CHUNK := 512


func _send(msg: Array) -> void:
	if _io == null:
		return
	var data := Msgpack.encode(msg)
	var deadline := Time.get_ticks_msec() + 2000
	var i := 0
	while i < data.size():
		var piece := data if data.size() <= _PIPE_CHUNK else data.slice(i, i + _PIPE_CHUNK)
		if _io.store_buffer(piece):
			i += piece.size()
		elif Time.get_ticks_msec() > deadline or not is_running():
			push_error("godot_nvim: could not write to Neovim")
			return
		else:
			OS.delay_usec(200)
	_io.flush()


func _dispatch(msg: Variant) -> void:
	if not (msg is Array) or msg.is_empty():
		return
	match msg[0]:
		_RESPONSE:
			var cb: Callable = _pending.get(msg[1], Callable())
			_pending.erase(msg[1])
			if cb.is_valid():
				cb.call(msg[2], msg[3])
			elif msg[2] != null:
				push_warning("nvim error: %s" % [msg[2]])
		_NOTIFY:
			notification.emit(msg[1], msg[2])
		_REQUEST:
			# Neovim only sends requests if we register handlers via rpcrequest.
			_send([_RESPONSE, msg[1], "unsupported request " + str(msg[2]), null])
