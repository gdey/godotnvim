## Minimal MessagePack encoder and streaming decoder for Neovim's RPC.
##
## Strings decode to String, bin to PackedByteArray, maps to Dictionary,
## arrays to Array. Ext types (Neovim's Buffer, Window, Tabpage handles)
## decode to an [Msgpack.Ext] and encode back unchanged.
class_name Msgpack
extends RefCounted


## An opaque ext value such as a Neovim buffer handle.
class Ext:
	extends RefCounted
	var type: int
	var data: PackedByteArray

	func _init(p_type: int, p_data: PackedByteArray) -> void:
		type = p_type
		data = p_data

	## Decodes the payload as the integer Neovim stores in it.
	func as_int() -> int:
		return Msgpack.decode(data)

	func _to_string() -> String:
		return "Ext(%d, %s)" % [type, as_int()]


static func encode(value: Variant) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.big_endian = true
	_encode(out, value)
	return out.data_array


## Decodes one complete value from [param bytes].
static func decode(bytes: PackedByteArray) -> Variant:
	var d := Decoder.new()
	d.feed(bytes)
	var r := d.next()
	return r[1] if r[0] else null


static func _encode(out: StreamPeerBuffer, v: Variant) -> void:
	match typeof(v):
		TYPE_NIL:
			out.put_u8(0xc0)
		TYPE_BOOL:
			out.put_u8(0xc3 if v else 0xc2)
		TYPE_INT:
			_encode_int(out, v)
		TYPE_FLOAT:
			out.put_u8(0xcb)
			out.put_double(v)
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			var b: PackedByteArray = String(v).to_utf8_buffer()
			var n := b.size()
			if n < 32:
				out.put_u8(0xa0 | n)
			elif n < 0x100:
				out.put_u8(0xd9)
				out.put_u8(n)
			elif n < 0x10000:
				out.put_u8(0xda)
				out.put_u16(n)
			else:
				out.put_u8(0xdb)
				out.put_u32(n)
			out.put_data(b)
		TYPE_PACKED_BYTE_ARRAY:
			var n: int = v.size()
			if n < 0x100:
				out.put_u8(0xc4)
				out.put_u8(n)
			elif n < 0x10000:
				out.put_u8(0xc5)
				out.put_u16(n)
			else:
				out.put_u8(0xc6)
				out.put_u32(n)
			out.put_data(v)
		TYPE_DICTIONARY:
			var n: int = v.size()
			if n < 16:
				out.put_u8(0x80 | n)
			elif n < 0x10000:
				out.put_u8(0xde)
				out.put_u16(n)
			else:
				out.put_u8(0xdf)
				out.put_u32(n)
			for k in v:
				_encode(out, k)
				_encode(out, v[k])
		TYPE_OBJECT:
			if v is Ext:
				_encode_ext(out, v)
			else:
				push_error("Msgpack: cannot encode object %s" % v)
				out.put_u8(0xc0)
		_:
			if v is Array or typeof(v) >= TYPE_PACKED_INT32_ARRAY:
				var n: int = v.size()
				if n < 16:
					out.put_u8(0x90 | n)
				elif n < 0x10000:
					out.put_u8(0xdc)
					out.put_u16(n)
				else:
					out.put_u8(0xdd)
					out.put_u32(n)
				for e in v:
					_encode(out, e)
			else:
				push_error("Msgpack: cannot encode %s" % type_string(typeof(v)))
				out.put_u8(0xc0)


static func _encode_int(out: StreamPeerBuffer, i: int) -> void:
	if i >= 0:
		if i < 128:
			out.put_u8(i)
		elif i < 0x100:
			out.put_u8(0xcc)
			out.put_u8(i)
		elif i < 0x10000:
			out.put_u8(0xcd)
			out.put_u16(i)
		elif i < 0x100000000:
			out.put_u8(0xce)
			out.put_u32(i)
		else:
			out.put_u8(0xcf)
			out.put_u64(i)
	else:
		if i >= -32:
			out.put_u8(i & 0xff)
		elif i >= -0x80:
			out.put_u8(0xd0)
			out.put_8(i)
		elif i >= -0x8000:
			out.put_u8(0xd1)
			out.put_16(i)
		elif i >= -0x80000000:
			out.put_u8(0xd2)
			out.put_32(i)
		else:
			out.put_u8(0xd3)
			out.put_64(i)


static func _encode_ext(out: StreamPeerBuffer, e: Ext) -> void:
	var n := e.data.size()
	match n:
		1: out.put_u8(0xd4)
		2: out.put_u8(0xd5)
		4: out.put_u8(0xd6)
		8: out.put_u8(0xd7)
		16: out.put_u8(0xd8)
		_:
			if n < 0x100:
				out.put_u8(0xc7)
				out.put_u8(n)
			elif n < 0x10000:
				out.put_u8(0xc8)
				out.put_u16(n)
			else:
				out.put_u8(0xc9)
				out.put_u32(n)
	out.put_8(e.type)
	out.put_data(e.data)


## Incremental decoder: [method feed] bytes as they arrive from the pipe and
## call [method next] until it reports nothing complete is left.
class Decoder:
	extends RefCounted

	var _buf := PackedByteArray()
	var _pos := 0
	var _short := false

	func feed(bytes: PackedByteArray) -> void:
		if _pos > 0:
			_buf = _buf.slice(_pos)
			_pos = 0
		_buf.append_array(bytes)

	## Returns [true, value] for a complete value, or [false, null] when more
	## bytes are needed.
	func next() -> Array:
		var start := _pos
		_short = false
		var v: Variant = _read()
		if _short:
			_pos = start
			return [false, null]
		return [true, v]

	func _need(n: int) -> bool:
		if _pos + n > _buf.size():
			_short = true
			return false
		return true

	func _u(n: int) -> int:
		if not _need(n):
			return 0
		var r := 0
		for i in n:
			r = (r << 8) | _buf[_pos + i]
		_pos += n
		return r

	func _s(n: int) -> int:
		var r := _u(n)
		var bits := n * 8
		if bits < 64 and r >= (1 << (bits - 1)):
			r -= 1 << bits
		return r

	func _bytes(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		var r := _buf.slice(_pos, _pos + n)
		_pos += n
		return r

	func _read() -> Variant:
		if not _need(1):
			return null
		var b := _buf[_pos]
		_pos += 1
		if b <= 0x7f:
			return b
		if b >= 0xe0:
			return b - 0x100
		if b & 0xe0 == 0xa0:
			return _str(b & 0x1f)
		if b & 0xf0 == 0x90:
			return _arr(b & 0x0f)
		if b & 0xf0 == 0x80:
			return _map(b & 0x0f)
		match b:
			0xc0: return null
			0xc2: return false
			0xc3: return true
			0xc4: return _bytes(_u(1))
			0xc5: return _bytes(_u(2))
			0xc6: return _bytes(_u(4))
			0xc7: return _ext(_u(1))
			0xc8: return _ext(_u(2))
			0xc9: return _ext(_u(4))
			0xca:
				var raw := _bytes(4)
				if _short:
					return null
				raw.reverse()
				return raw.decode_float(0)
			0xcb:
				var raw := _bytes(8)
				if _short:
					return null
				raw.reverse()
				return raw.decode_double(0)
			0xcc: return _u(1)
			0xcd: return _u(2)
			0xce: return _u(4)
			0xcf: return _u(8)
			0xd0: return _s(1)
			0xd1: return _s(2)
			0xd2: return _s(4)
			0xd3: return _s(8)
			0xd4: return _ext(1)
			0xd5: return _ext(2)
			0xd6: return _ext(4)
			0xd7: return _ext(8)
			0xd8: return _ext(16)
			0xd9: return _str(_u(1))
			0xda: return _str(_u(2))
			0xdb: return _str(_u(4))
			0xdc: return _arr(_u(2))
			0xdd: return _arr(_u(4))
			0xde: return _map(_u(2))
			0xdf: return _map(_u(4))
		push_error("Msgpack: invalid byte 0x%02x" % b)
		return null

	func _str(n: int) -> Variant:
		if _short:
			return null
		var raw := _bytes(n)
		return null if _short else raw.get_string_from_utf8()

	func _arr(n: int) -> Variant:
		var a := []
		for i in n:
			if _short:
				return null
			a.append(_read())
		return null if _short else a

	func _map(n: int) -> Variant:
		var d := {}
		for i in n:
			if _short:
				return null
			var k: Variant = _read()
			var v: Variant = _read()
			d[k] = v
		return null if _short else d

	func _ext(n: int) -> Variant:
		if _short:
			return null
		var t := _s(1)
		var data := _bytes(n)
		return null if _short else Ext.new(t, data)
