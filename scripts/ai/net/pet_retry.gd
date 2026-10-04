# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 429（模型太挤）自动重试：**只负责决定**，不碰连接。
##
## 从 pet_chat.gd 搬出来（作业单 B1.3）。免费额度的公开 API 很容易撞上 429，GLM 的原文是：
##     {"error":{"code":"1305","message":"该模型当前访问量过大，请您稍后再试"}}
## 不处理的话，表现成"她经常不说话"，而且完全不知道为什么 —— 所以撞上就
## **等一会儿把同一条请求原样再发一次**。
##
## 分工：本模块记住"哪条请求、还剩几次、什么时候可以试"；
## **真正 start() 请求的动作留在 pet_chat**（那是连接层的事）——
## 于是这里能完全离线测（`tools/probe_memory.gd` 里那组就是）。
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 撞上 429 之后等多久再试（毫秒）
const AFTER_MS := 2500
## 同一轮最多试几次
const MAX := 2

## 待重发的那条请求：{kind, path, headers, body}；空 = 没有。
## 故意不存 host / port / tls —— 那些是连接层的、pet_chat 自己就知道
var want: Dictionary = {}
## 还能试几次
var left := 0
## 什么时候可以重发（0 = 没有待重发的）
var at_ms := 0

## 发之前记一份原样请求（`kind` 用 "chat" / "once" 区分两条链路）。
## **重试时不要调 send()**：那条会往历史里再塞一遍用户消息 —— 重试必须原样重发
func remember(kind: String, path: String, headers: PackedStringArray,
		body: PackedByteArray) -> void:
	want = {"kind": kind, "path": path, "headers": headers, "body": body}
	left = MAX
	at_ms = 0

## 有等着重发的吗 —— **这期间也算"忙"**（见 pet_chat.is_busy 的注释：
## 不算忙的话别的链路会插进来开新流，然后旧请求几秒后重发，她会冒一句不相关的话）
func pending() -> bool:
	return at_ms > 0

## 撞上"模型太挤" → 排一次重试。返回 true = 已排好（调用方别走失败流程）
func schedule(what: String) -> bool:
	if left <= 0 or want.is_empty():
		return false
	left -= 1
	at_ms = Time.get_ticks_msec() + AFTER_MS
	if OS.is_debug_build():
		print("[PetDeek] %s：模型说它忙（429），%.1f 秒后自动再试（还剩 %d 次）" % [
			what, AFTER_MS / 1000.0, left])
	return true

## 到点了吗（要重发就再 take()）
func due() -> bool:
	return at_ms > 0 and Time.get_ticks_msec() >= at_ms

## 取出这条待重发的请求并清掉计时（空字典 = 没有）
func take() -> Dictionary:
	var req := want
	at_ms = 0
	return req

## 这次失败是不是"模型太挤"。GLM 是 HTTP 429；还有的后端喜欢回 200 + 错误文本，
## 所以除了状态码也认一下错误码 / 原话
static func looks_busy(code: int, body_text: String) -> bool:
	if code == 429:
		return true
	return body_text.find("1305") >= 0 or body_text.find("1302") >= 0 \
		or body_text.find("访问量过大") >= 0 \
		or body_text.to_lower().find("rate limit") >= 0
