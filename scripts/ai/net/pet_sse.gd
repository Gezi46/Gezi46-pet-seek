# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 流式（SSE）分片解析：把 OpenAI 兼容的 `data: {...}` 行变成「正文增量 / 思考增量 / 收尾 / 出错」。
##
## 从 pet_chat.gd 搬出来（作业单 B1.2）。它**只认字节和 JSON** —— 不认识连接、不认识信号、
## 不认识对话历史，所以能整段离线测（`tools/probe_memory.gd` 里"流式解析"那组就是塞几段
## 分片进去、看它吐出什么）。**信号由宿主发**（见 `pet_chat._drain_parser`）：
## 解析器只把增量放进队列，这样它才不依赖任何场景。
##
## 用法（状态机风格，和项目其它模块一致 —— 这里不许 await）：
##     var p := Sse.new()
##     p.reset()
##     p.feed(chunk)                    # 收到一段字节就喂；内部**按字节**切行
##     for t in p.take_tokens(): ...    # 该冒给气泡的字
##     for r in p.take_thoughts(): ...  # 思考（只给日志 / 思考面板看）
##     p.flush()                        # 收尾时补发还攒着的那一小段
##     p.text / p.reasoning / p.finished / p.stream_error / p.usage
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 上游令牌失效时，服务端会把错误当成**普通正文**吐出来，形如
## "\n\n[代理错误] 上游业务错误 40003…"。得认出来，否则桌宠会把报错当回复念出来（实测）
const UPSTREAM_ERR_MARK := "[代理错误]"

## 累计正文（她这一轮说的话）
var text := ""
## 累计思考（reasoning_content）
var reasoning := ""
## 见到 `data: [DONE]`
var finished := false
## 服务端把错误塞在流里时的原文（GLM 会回 {"error":{"code":"1305","message":"…"}}）
var stream_error := ""
## 这一轮的 token 账（服务端给了才有；字段名各家不同，取值见 pet_chat 的 _usage_field）
var usage: Dictionary = {}

var _line_buf := PackedByteArray()
## 攒着还没决定要不要冒的正文（判断"开头是不是报错"用，见 _on_line）
var _pending := ""
var _emit_started := false
var _tokens: Array = []
var _thoughts: Array = []

## 开新一轮（发请求、cancel、429 重发都要调它）
func reset() -> void:
	text = ""
	reasoning = ""
	finished = false
	stream_error = ""
	usage = {}
	_line_buf = PackedByteArray()
	_pending = ""
	_emit_started = false
	_tokens.clear()
	_thoughts.clear()

## 喂一段字节。**必须按字节切行**：
## 直接对可能以半个多字节字符结尾的 chunk 调 get_string_from_utf8()，
## 截断处会被替换成 U+FFFD 并永久丢掉那几个字节，拼不回来。
func feed(chunk: PackedByteArray) -> void:
	if chunk.is_empty():
		return
	_line_buf.append_array(chunk)
	while true:
		var i := _line_buf.find(0x0A)
		if i < 0:
			break
		var line := _line_buf.slice(0, i).get_string_from_utf8().strip_edges()
		_line_buf = _line_buf.slice(i + 1)
		if line.begins_with("data:"):
			_on_line(line.substr(5).strip_edges())

## 收尾时把还攒着的那一小段补进队列。很短的回复（短于 [代理错误] 那个长度）会一直
## 攒在手里，不补的话气泡里什么都看不到（完整回复仍会走 replied，
## 但"逐字冒"那条路就断了）
func flush() -> void:
	if _pending != "":
		if _pending.strip_edges() != "":
			_tokens.append(_pending)
		_pending = ""
	_emit_started = true

func take_tokens() -> Array:
	var out := _tokens
	_tokens = []
	return out

func take_thoughts() -> Array:
	var out := _thoughts
	_thoughts = []
	return out

## 解析一行 `data:` 后面的内容（原来叫 `_handle_event`）。
## 认得出：分片正文 / 思考 / usage / 服务端错误 / `[DONE]`
func _on_line(raw: String) -> void:
	if raw == "[DONE]":
		finished = true
		return
	var j: Variant = JSON.parse_string(raw)
	if typeof(j) != TYPE_DICTIONARY:
		return
	var d0 := j as Dictionary
	# usage 必须在**认 choices 之前**收下来：开了 stream_options 之后，
	# 最后那一块是 choices 为空、只有 usage 的 —— 按老写法会先被下面那个 return 丢掉
	_absorb_usage(d0)
	# 后端把错误塞在流里：把原文留下来，比最后只报一句"后端没返回内容"有用得多
	var err: Variant = d0.get("error")
	if typeof(err) == TYPE_DICTIONARY:
		stream_error = "服务端报错：%s" % \
			String((err as Dictionary).get("message", str(err))).substr(0, 120)
		return
	var choices: Variant = d0.get("choices")
	if typeof(choices) != TYPE_ARRAY or (choices as Array).is_empty():
		return
	var ch: Variant = (choices as Array)[0]
	if typeof(ch) != TYPE_DICTIONARY:
		return
	var delta: Variant = (ch as Dictionary).get("delta")
	if typeof(delta) != TYPE_DICTIONARY:
		return
	var d := delta as Dictionary
	# 取值必须**判类型**再取：官方 API 的流式分片里 reasoning_content 经常是 null
	# （只有正文分片才有内容），而 String(null) 在 GDScript 里会直接抛
	# "Nonexistent 'String' constructor" 把整条流打崩 —— 实测踩过。
	var think := _text(d.get("reasoning_content"))
	if think != "":
		reasoning += think
		_thoughts.append(think)
	var t := _text(d.get("content"))
	if t == "":
		return
	text += t
	if _emit_started:
		_tokens.append(t)
		return
	# —— 开头这一小段要特别小心 ——
	# 上游令牌失效那种错误是**当正文吐出来**的，形如
	# "\n\n[代理错误] 上游业务错误 40003…"。在判出来之前先攒着别发：
	#   * 发早了 → 报错的前缀会闪进气泡（实测漏了 1 个分片）；
	#   * 判太晚（比如按长度）→ 整段报错已经在手里了，照样漏。
	# 所以攒到 strip 之后够长、能拿 [代理错误] 做前缀比对为止，再决定发还是不发。
	_pending += t
	var head := text.strip_edges()
	if head.length() <= UPSTREAM_ERR_MARK.length():
		return                       # 还判不出来，继续攒（就几毫秒）
	if head.begins_with(UPSTREAM_ERR_MARK):
		_pending = ""                # 是报错：正文留给宿主判成失败
		return
	# 确认是正常正文：把攒着的一起发出去，之后就一路直发
	_emit_started = true
	if _pending.strip_edges() != "":
		_tokens.append(_pending)
	_pending = ""

## 收 usage（后端不给这个字段就什么都收不到，不报错 —— 本机 web-api 就是这样）
func _absorb_usage(d: Dictionary) -> void:
	var u: Variant = d.get("usage")
	if typeof(u) == TYPE_DICTIONARY:
		usage = u

## 只把真正的字符串当文本；null / 数字 / 字典一律当空。
## 别用 String(v)：v 是 null 时它会抛异常（不是返回空串）。
## （pet_chat 里有一个同名同义的函数：两边各自兜住自己那条链路，
##   不让"解析器"反过来依赖 PetChat —— 见文件头的接口面那条）
func _text(v: Variant) -> String:
	return v if typeof(v) == TYPE_STRING else ""
