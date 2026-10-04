# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 地址与请求头：把 `https://host:port/前缀` 拆成连接要的三段，以及拼请求头。
##
## 从 pet_chat.gd 搬出来（作业单 B1.4）。全是 **static**：不碰连接、不碰状态 ——
## 于是能整段离线测（tools/probe_memory.gd 里那组就是），也是这个文件唯一的存在理由
## （pet_chat 当时 598 行，超过宪法里的 500 行软上限）。
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 拆 URL → `{host, port, tls, base_path}`。
##
## 注意 Content-Length 不要自己加：`request_raw` 的 API 没给它留位置，
## Godot 按 `body.size()` 自己写，重复的头会让 uvicorn 解析出错。
static func parse_url(url: String) -> Dictionary:
	var tls := false
	var base_path := ""
	var s := url.strip_edges()
	if s.begins_with("https://"):
		tls = true
		s = s.substr(8)
	elif s.begins_with("http://"):
		s = s.substr(7)
	var slash := s.find("/")
	if slash >= 0:
		base_path = s.substr(slash).rstrip("/")
		s = s.substr(0, slash)
	var host := s
	var port := 443 if tls else 80
	var colon := s.rfind(":")
	if colon > 0:
		port = int(s.substr(colon + 1))
		host = s.substr(0, colon)
	if port <= 0 or port > 65535:
		port = 443 if tls else 80
	return {"host": host, "port": port, "tls": tls, "base_path": base_path}

## 请求头。配了 key 就带 `Authorization: Bearer`（本机那些不要 key 的后端留空即可）
static func headers(access_key: String, content_type: String, accept: String) -> PackedStringArray:
	var h := PackedStringArray([
		"Content-Type: " + content_type,
		"Accept: " + accept,
	])
	var k := access_key.strip_edges()
	if k != "":
		h.append("Authorization: Bearer " + k)
	return h

## 流式对话的请求体。里面有两处是**刻意的**：
##   `stream_options.include_usage` —— 不带的话流式那条路上看不到 usage（缓存命中 / token 数）
##   `thinking: {type: disabled}`   —— 见 pet_chat.no_think 的声明处（实测 15 秒 → 1 秒）。
## 两个都是"可选优化"，不是所有后端都认：不认的回 400，pet_chat 会**逐个摘掉**再重来
## （见 _note_unsupported）—— 所以换服务商不会因为这两项卡死
static func chat_body(model: String, msgs: Array, no_think: bool,
		send_usage: bool = true) -> Dictionary:
	var body := {
		"model": model,
		"stream": true,
		"messages": msgs,
	}
	if send_usage:
		body["stream_options"] = {"include_usage": true}
	if no_think:
		body["thinking"] = {"type": "disabled"}
	return body

## 拼一次请求的 messages。**顺序是刻意的**：
##   人设（逐字不变）→ 历史 → 这一轮的上下文 → 这一句
## 上下文**不写进历史**：它是"此刻的参考"、不是对话内容 —— 不进历史才能保证
## 下一轮的前缀是这一轮的延长线（服务商的前缀缓存就吃这一条，见 README 的"缓存"一节）。
##
## 写成 static 是为了能**离线量两轮之间前缀有多长**：tools/probe_memory.gd 会量这个数
static func messages(system_prompt: String, history: Array, context: String,
		message: String, image_data: String) -> Array:
	var msgs: Array = []
	if system_prompt.strip_edges() != "":
		msgs.append({"role": "system", "content": system_prompt})
	for h in history:
		msgs.append(h)
	if context.strip_edges() != "":
		msgs.append({"role": "system", "content": context})
	msgs.append({"role": "user", "content": user_content(message, image_data)})
	return msgs

## 带图的消息按 OpenAI 的多模态格式给；不带图就是普通字符串。
## 注意：本机 deepseek-web-api 只把 messages 拼成一段文本，图片不会被真正看到 ——
## 所以偷看屏幕那条链路拿不到画面（文字提示仍会发过去），README 里写明了
static func user_content(message: String, image_data: String) -> Variant:
	if image_data.strip_edges() == "":
		return message
	return [
		{"type": "text", "text": message},
		{"type": "image_url", "image_url": {"url": image_data}},
	]
