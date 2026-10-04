# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 一次性（非流式）请求：给"记忆抽取 / 摘要 / 候选句子"这类后台小任务用。
##
## 从 pet_chat.gd 搬出来（作业单 B1.3）。它**自带一条连接**（和聊天那条互不排队），
## 职责只有两件：**把 body 发出去**、**把 HTTP 响应原样交回来**（连不上/超时才算失败）。
##
## 为什么"不解释响应"：怎么解释要看宿主的状态 —— 429 要不要原样重发、正文在
## `choices[0].message.content` 里怎么抠、空正文算不算失败。这些留在 pet_chat
## （见它的 `_on_bg_got`），所以这条链路的重试判断不会被信号时序绕过。
## 真正的解析写成 `parse()` 这个 **static**：能离线测（probe_memory 里那组就是）。
##
## 它 preload 了 pet_conn（那条连接的实现）—— pet_conn 是**纯叶子**、不会再依赖回来，
## 所以没有循环依赖的风险（宪法第三节那条说的是别互相依赖）
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 拿到了 HTTP 响应（哪怕 4xx / 5xx）：怎么解释交给宿主
signal got(code: int, body: String)
## 连不上 / 超时：这类没有"响应"可解释
signal failed(msg: String)

const Conn := preload("res://scripts/ai/net/pet_conn.gd")

## 连不上 / 等回话的超时。**这条必须有**：挂死的话 busy() 永远 true，
## 记忆抽取 / 摘要就再也不跑了（pet_chat 原来踩过这个）
const TIMEOUT_CONNECT_MS := 10000
const TIMEOUT_IDLE_MS := 90000

var _c := Conn.new()
var _buf := PackedByteArray()

## 发一条（body 由宿主拼好 —— 只有它知道 model / no_think / messages）
func start(host: String, port: int, path: String, headers: PackedStringArray,
		body: PackedByteArray, tls: bool) -> bool:
	if busy():
		return false
	_buf = PackedByteArray()
	_c.start(host, port, path, headers, body, tls)
	return true

func busy() -> bool:
	return _c.busy()

func tick() -> void:
	if _c.phase == _c.IDLE:
		return
	_c.poll()
	if _c.phase == _c.CONNECTING and _c.since_start_ms() > TIMEOUT_CONNECT_MS:
		_c.cancel()
		failed.emit("等后端超时（%d 秒没连上）" % int(TIMEOUT_CONNECT_MS / 1000.0))
		return
	if _c.phase == _c.READING and _c.since_rx_ms() > TIMEOUT_IDLE_MS:
		_c.cancel()
		failed.emit("等后端回话超时")
		return
	match _c.phase:
		_c.READING:
			_buf.append_array(_c.take())
		_c.DONE:
			_buf.append_array(_c.take())
			var code := _c.code
			_c.cancel()
			got.emit(code, _buf.get_string_from_utf8())
		_c.FAILED:
			var msg := _c.error if _c.error != "" else "后台请求失败"
			_c.cancel()
			failed.emit(msg)

## 拼一次性请求的 body（**static**：离线可测，也只有宿主知道 model / no_think）
## max_tokens 默认给 2000 是**有意的**：带思考的模型会把预算先花在 reasoning_content 上，
## 给小了正文就是空的（调用方会收到"模型返回是空的"）
static func build_body(model: String, system: String, user: String, max_tokens: int,
		no_think: bool) -> PackedByteArray:
	var msgs: Array = []
	if system.strip_edges() != "":
		msgs.append({"role": "system", "content": system})
	msgs.append({"role": "user", "content": user})
	var body := {
		"model": model,
		"stream": false,
		"temperature": 0.0,   # 抽事实要稳，不要发挥
		"max_tokens": max_tokens,
		"messages": msgs,
	}
	if no_think:
		body["thinking"] = {"type": "disabled"}
	return JSON.stringify(body).to_utf8_buffer()

## 解析响应。返回 {ok, text, msg, usage}：
##   ok = 拿到正文了；text = 正文；msg = 失败原因；usage = 这一轮的 token 账
## 响应结构和流式不一样：正文在 choices[0].message.content
static func parse(text: String) -> Dictionary:
	var j: Variant = JSON.parse_string(text)
	if typeof(j) != TYPE_DICTIONARY:
		return {"ok": false, "text": "", "msg": "返回不是 JSON（%d 字节）" % text.length(), "usage": {}}
	var d := j as Dictionary
	var usage: Dictionary = d["usage"] if typeof(d.get("usage")) == TYPE_DICTIONARY else {}
	# 令牌失效这类错误在这里是 HTTP 200 + error 字段，别当成正文
	if d.get("error") != null:
		return {"ok": false, "text": "", "usage": usage,
			"msg": "服务端报错：%s" % str(d["error"]).substr(0, 120)}
	var choices: Variant = d.get("choices")
	if typeof(choices) != TYPE_ARRAY or (choices as Array).is_empty():
		return {"ok": false, "text": "", "msg": "返回里没有 choices", "usage": usage}
	var first: Variant = (choices as Array)[0]
	if typeof(first) != TYPE_DICTIONARY:
		return {"ok": false, "text": "", "msg": "choices[0] 结构不对", "usage": usage}
	var msg: Variant = (first as Dictionary).get("message")
	if typeof(msg) != TYPE_DICTIONARY:
		return {"ok": false, "text": "", "msg": "返回里没有 message", "usage": usage}
	var content := _text((msg as Dictionary).get("content")).strip_edges()
	if content == "":
		return {"ok": false, "text": "", "msg": "模型返回是空的", "usage": usage}
	return {"ok": true, "text": content, "msg": "", "usage": usage}

## 只把真正的字符串当文本；null / 数字 / 字典一律当空。
## 别用 String(v)：v 是 null 时它会抛异常（不是返回空串）
static func _text(v: Variant) -> String:
	return v if typeof(v) == TYPE_STRING else ""
