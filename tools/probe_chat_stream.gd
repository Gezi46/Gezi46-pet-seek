# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 验桌宠侧的对话客户端（scripts/pet_chat.gd）跟 **deepseek-web-api** 的连通性。
##
## 先起服务：双击 deepseek-web-api\start.cmd（或 node start.mjs），
## 服务地址 http://127.0.0.1:8520，管理页在 /admin。
##
##   用法: & $godot --path . --headless --script res://tools/probe_chat_stream.gd
##
## 覆盖：
##   A. SSE 按字节切行：多字节汉字被从中间切开，绝不能变成 U+FFFD
##   B. 真实一轮对话：OpenAI 分片 → token 流 → 收尾恰好一次
##   C. probe_now() 让 backend_reachable() 变 true
##      （注意 /healthz 在**根路径**，不在 /v1 下面 —— 这条就是验路径拼对了）
##   D. 服务不可达时 failed 给出可读原因，且 reachable 变 false
##   E. 上游令牌失效时（服务端把错误当**正文**吐出来）必须被识别成失败并给出提示，
##      而不是把报错当回复念出来 —— 网页端 userToken 过期就是这个样子
##   F. 思考通道：deepseek-reasoner 的 reasoning_content 会走 thought 信号
##      （令牌失效时验不了，只在 B 段真拿到回复时才跑）
const PetChat = preload("res://scripts/ai/pet_chat.gd")

## 用桌宠**当前实际使用的配置**：就近读 user://pet_chat.cfg
## （也就是菜单「AI 服务设置…」存下的那份），所以这个探针验的就是线上那条链路
const CFG := "user://pet_chat.cfg"

func _settings() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(CFG) != OK:
		return {}
	return {
		"url": String(cfg.get_value("ai", "url", "")),
		"key": String(cfg.get_value("ai", "key", "")),
		"model": String(cfg.get_value("ai", "model", "")),
	}

var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	# 看门狗按墙钟算：headless 帧率上万，按帧数会在几十毫秒内就误判超时
	if Time.get_ticks_msec() - _start_ms > 300000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

class Sink:
	var tokens: Array[String] = []
	var replies: Array[String] = []
	var fails: Array[String] = []
	var thoughts: Array[String] = []
	var ended := 0
	var reach: Array[bool] = []

	func attach(c) -> void:
		c.token.connect(func(t: String) -> void: tokens.append(t))
		c.replied.connect(func(t: String) -> void: replies.append(t))
		c.failed.connect(func(m: String) -> void: fails.append(m))
		c.thought.connect(func(t: String) -> void: thoughts.append(t))
		c.stream_ended.connect(func() -> void: ended += 1)
		c.reachable.connect(func(ok: bool) -> void: reach.append(ok))

	func text() -> String:
		return "".join(tokens)

## headless 下帧率远高于 60（一帧不到 1ms），按帧数等会等不到网络回包 ——
## 一律用毫秒截止时间。
func _pump(c, ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		c.tick()
		await process_frame

## 等一轮对话收尾，返回是否按时收尾
func _wait_round(c, s, ms: int) -> bool:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		c.tick()
		await process_frame
		if s.ended > 0:
			return true
	return false

func _run() -> void:
	var ok := true

	# ---------------------------------------------------------- A. 多字节切分
	var c1 = PetChat.new()
	var s1 := Sink.new()
	s1.attach(c1)
	# 造一条真实的 OpenAI 分片，然后从"你"（E4 BD A0）的第 2 个字节处切开。
	# 文本要够长：客户端会把开头一小段先攒起来判"是不是上游报错"，太短就还没往外发
	var txt := "你好世界这是切分测试"
	var line: PackedByteArray = \
		('data: {"choices":[{"delta":{"content":"%s"}}]}\n' % txt).to_utf8_buffer()
	var cut := -1
	for i in line.size() - 2:
		if line[i] == 0xE4:
			cut = i + 1
			break
	if cut < 0:
		printerr("A 构造失败：没找到汉字起始字节")
		quit(1)
		return
	# 注入点变了（作业单 B1.2）：流式解析搬去 pet_sse.gd 之后，字节直接喂给客户端的
	# 那个解析器，再让 pet_chat._drain_parser() 把增量转成信号 ——
	# 原来那两行是 `c1._sse.pending = ...; c1._drain_sse()`，语义一样（都在解析层的入口）
	c1._parser.feed(line.slice(0, cut))
	c1._drain_parser()
	var mid := s1.tokens.size()
	c1._parser.feed(line.slice(cut))
	c1._drain_parser()
	var got: String = s1.text()
	var has_repl: bool = got.contains("\uFFFD")
	print("A 前半段解出=%d 个 token（应为 0）；切完得到=%s（应为 %s）；含替换符=%s" % [
		mid, got, txt, has_repl])
	if mid != 0 or got != txt or has_repl:
		ok = false
		printerr("A 失败：多字节被截断后拼不回来")

	# ---------------------------------------------------------- C. 探活
	# 放在对话前面：先确认服务在，后面 B 段的现象才好解释
	var st := _settings()
	print("配置：url=%s model=%s key=%s" % [
		st.get("url", ""), st.get("model", ""),
		("有（%d 字符）" % String(st.get("key", "")).length()) if st.get("key", "") != "" else "空"])
	if st.is_empty():
		printerr("C 失败：读不到 %s —— 先在桌宠菜单「AI 服务设置…」里保存一次" % CFG)
		ok = false
	var c2 = PetChat.new()
	c2.configure(String(st.get("url", "")), String(st.get("key", "")), String(st.get("model", "")))
	var s2 := Sink.new()
	s2.attach(c2)
	c2.probe_now()
	await _pump(c2, 8000)
	print("C backend_reachable=%s（探活走 %s）reachable 信号=%s" % [
		c2.backend_reachable(), c2.url + " → /models", s2.reach])
	if not c2.backend_reachable():
		ok = false
		printerr("C 失败：服务应该在跑却探活失败（官方 API 查网络/key，本地版查 start.cmd 与端口）")

	# ---------------------------------------------------------- B / E. 真实一轮对话
	var reply := ""
	var fail := ""
	if c2.backend_reachable():
		if not c2.send("桌宠探针：回我两个字就行"):
			printerr("B 失败：send() 返回 false")
			ok = false
		if not await _wait_round(c2, s2, 120000):
			printerr("B 失败：120 秒没收尾")
			ok = false
		reply = s2.replies[0] if s2.replies.size() > 0 else ""
		fail = s2.fails[0] if s2.fails.size() > 0 else ""
		print("B token 数=%d 拼接=%s" % [s2.tokens.size(), s2.text()])
		print("B 回复=%s" % (reply if reply != "" else "（无）"))
		print("B 失败=%s" % (fail.split("\n")[0] if fail != "" else "（无）"))
		print("B stream_ended=%d（应为 1）" % s2.ended)
		if s2.ended != 1:
			ok = false
			printerr("B 失败：stream_ended 应恰好一次")
		if reply == "" and fail == "":
			ok = false
			printerr("B 失败：既没回复也没报错")
		if reply.contains("\uFFFD"):
			ok = false
			printerr("B 失败：回复里出现替换符，说明解码坏了")

		# E. 令牌过期：上游把错误当正文吐出来，必须被识别成"失败 + 提示"
		if reply == "" and fail != "":
			if fail.contains("令牌") or fail.contains("代理错误"):
				print("E OK：上游令牌失效被识别成失败并给出提示")
			else:
				ok = false
				printerr("E 失败：收到了失败，但不是令牌提示 —— 检查错误识别分支")

	# ---------------------------------------------------------- F. 思考通道
	if reply != "":
		var c3 = PetChat.new()
		c3.configure(String(st.get("url", "")), String(st.get("key", "")), "deepseek-reasoner")
		var s3 := Sink.new()
		s3.attach(c3)
		c3.send("1+1 等于几？只回答数字")
		await _wait_round(c3, s3, 180000)
		print("F 思考片段=%d 回复=%s" % [
			s3.thoughts.size(), s3.replies[0] if s3.replies.size() > 0 else "（无）"])
		if s3.thoughts.size() == 0 and OS.is_debug_build():
			print("F 提示：这次没收到 reasoning_content（模型可能没开深度思考，不算失败）")
	else:
		print("F 跳过：B 段没拿到真实回复（多半是 userToken 过期了）")

	# ---------------------------------------------------------- D. 服务不可达
	var c4 = PetChat.new()
	c4.configure("http://127.0.0.1:59999/v1", String(st.get("key", "")), "deepseek-chat")
	var s4 := Sink.new()
	s4.attach(c4)
	c4.send("有人在家吗")
	var d_deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < d_deadline and s4.fails.size() == 0:
		c4.tick()
		await process_frame
	c4.probe_now()
	await _pump(c4, 6000)
	print("D failed=%s reachable=%s last_error=%s" % [
		s4.fails, c4.backend_reachable(), c4.last_error()])
	if s4.fails.size() == 0 or c4.backend_reachable():
		ok = false
		printerr("D 失败：连不上时该报错并把 reachable 置 false")

	print("PROBE_CHAT_STREAM %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
