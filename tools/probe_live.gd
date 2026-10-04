# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 真机联调自检：把代码真正会走的**四条路**各跑一遍。**需要配好一个能用的 AI 服务**。
##
##     godot --path . --script res://tools/probe_live.gd        （要真窗口：场景要排版）
##
## 它会**真发请求**（会花额度），所以归在"换后端之后 / 大改之后手动跑一次"那一类：
##   A) 打字聊天：_submit_chat → 流式回复 + 聊天记录 + 快速回答（本地那组 → 模型那组）
##   B) 她自己先开口：_ask_proactive → 回复里带 %% 候选 → 气泡只显示她那句、按钮就是候选
##   C) 后台一次性请求：ask_once（抽事实 / 摘要 / 候选用的那条）
##   D) 看图：给视觉客户端一张 96×96 纯色 JPEG（和偷看屏幕同一种格式）
##
## 判据都是硬检查。**例外**：B 里"模型有没有照格式写 %%"只算警告 ——
## 模型不照格式写时她会退回本地那组候选，按钮照样在，不算 bug。
##
## 两个踩过的坑，改这个文件时别踩回去：
##   1. **别用 lambda 捕获局部变量**：GDScript 的 lambda 按值捕获，
##      `connect("replied", func(t): raw = t)` 改不到外层的 raw（读出来永远是空串）。
##      所以下面一律用成员变量 + 具名回调
##   2. 等待全部按**时间**判断：帧数在无头 / 不限帧的运行里完全不可靠
var _pet: Node = null
var _chat = null
var _fail := 0
var _warn := 0

var _reply_raw := ""
var _bubble_at := ""
var _btns_at: Array = []
var _once_text := ""
var _once_err := ""
var _vis_text := ""
var _vis_err := ""

func _initialize() -> void:
	_go.call_deferred()

# ------------------------------------------------------------------ 回调（具名，见文件头第 1 条）

func _on_replied(t: String) -> void:
	_reply_raw = t
	# 气泡 1.8 秒就淡出，所以要**在这一刻**读：出了这个点就读不到了
	_bubble_at = _bubble_text()
	_btns_at = _buttons()

func _on_once_done(t: String) -> void:
	_once_text = t

func _on_once_failed(m: String) -> void:
	_once_err = m

func _on_vis_done(t: String) -> void:
	_vis_text = t

func _on_vis_failed(m: String) -> void:
	_vis_err = m

# ------------------------------------------------------------------ 流程

func _go() -> void:
	_pet = (load("res://scenes/pet.tscn") as PackedScene).instantiate()
	get_root().add_child(_pet)
	await _frames(8)
	_chat = _pet.get("_chat")
	if _chat == null:
		_ok(false, "没建起聊天客户端")
		quit(1)
		return
	# 概率拉满：不然"按钮该出现"这件事变成掷骰子（0.7 会让自检时灵时不灵）
	_pet.set("quick_chance", 1.0)
	_pet.set("quick_chance_chat", 1.0)
	_chat.connect("replied", _on_replied)
	_chat.connect("once_done", _on_once_done)
	_chat.connect("once_failed", _on_once_failed)
	var vis = _pet.get("_vision")
	if vis != null:
		vis.connect("replied", _on_vis_done)
		vis.connect("failed", _on_vis_failed)
	_chat.call("probe_now")
	if not await _reachable(20.0):
		_ok(false, "后端连不上（先把 AI 配置配好）")
		quit(1)
		return
	print("后端可达 ✓｜模型=%s｜关思考=%s｜地址=%s" % [
		_chat.get("model"), str(_chat.get("no_think")), _chat.get("url")])

	await _stage_chat()
	await _stage_first_person()
	await _stage_once()
	await _stage_vision()

	print("")
	if _fail == 0:
		print("===== 结论：全部通过（警告 %d 条）=====" % _warn)
	else:
		print("===== 结论：失败 %d 项，警告 %d 条 =====" % [_fail, _warn])
	quit(0)

## A) 打字聊天：和你在输入框里打字走的是同一个函数
func _stage_chat() -> void:
	print("")
	print("=== A) 打字聊天（流式）===")
	_reply_raw = ""
	var log0: int = (_pet.get("_chat_log") as Array).size()
	_pet.call("_submit_chat", "今天加班到十点，好累")
	if not await _busy_done():
		_ok(false, "A：没等到回复（45 秒）")
		return
	_ok(_reply_raw.strip_edges() != "", "A：收到回复 → %s" % _reply_raw.strip_edges().substr(0, 40))
	_ok(_reply_raw.find("%%") < 0, "A：回复里没有 %% 残留（那是「她自己先开口」那条才有的格式）")
	_ok((_pet.get("_chat_log") as Array).size() >= log0 + 2, "A：聊天记录多了两条（她 + 你）")
	await _frames(20)
	var seen := _buttons()
	_ok(seen.size() >= 2, "A：快速回答先摆出本地那组（%d 个）" % seen.size())
	# 再等一会儿看模型那组会不会换上来（换不上不算 bug —— 洗不出候选就该保持本地那组）
	var t := Time.get_ticks_msec() + 15000
	var upgraded: Array = []
	while Time.get_ticks_msec() < t:
		await process_frame
		var now := _buttons()
		if now.size() >= 2 and str(now) != str(seen):
			upgraded = now
			break
	if upgraded.is_empty():
		_warn_soft("A：模型那组没换上来（继续用本地那组，按钮在 —— 不算 bug）")
	else:
		print("     模型那组换上了：%s" % str(upgraded))
	var h: int = _chat.call("cache_hit_tokens")
	var m: int = _chat.call("cache_miss_tokens")
	print("     token 账：命中缓存 %s / 未命中 %s（后端不报就是 -1）" % [str(h), str(m)])

## B) 她自己先开口：候选应该和那句话**同一次**回来
func _stage_first_person() -> void:
	print("")
	print("=== B) 她自己先开口（流式 + %% 候选）===")
	_reply_raw = ""
	_bubble_at = ""
	_btns_at = []
	_pet.call("_ask_proactive")
	if not await _busy_done():
		_ok(false, "B：没等到回复（45 秒）")
		return
	var pet_gd: GDScript = load("res://scripts/desktop_pet.gd")
	var sp: Dictionary = pet_gd.split_options(_reply_raw)
	var say := String(sp["say"])
	var opts: Array = sp["options"]
	_ok(say.strip_edges() != "", "B：她那句能拆出来 → %s" % say.strip_edges().substr(0, 40))
	_ok(_bubble_at.strip_edges() == say.strip_edges(),
		"B：气泡里**只有她那句话**（没有 %% / 中括号漏进去）")
	if opts.size() < 2:
		_warn_soft("B：模型没照格式写 %%（候选为空）—— 会退回本地那组，不算 bug")
	else:
		print("     她那句：%s" % say.strip_edges().substr(0, 40))
		print("     候选：%s" % str(opts))
		var a := _btns_at.duplicate()
		a.sort()
		_ok(a.size() >= 2, "B：按钮出来了（%d 个）" % a.size())
		var quick = _pet.get("_quick")
		_ok((quick.get("_want") as Dictionary).is_empty(),
			"B：没有再排第二次请求（候选已经跟着那句话给出来了）")

## C) 后台那条（抽事实 / 摘要 / 候选都用它）
func _stage_once() -> void:
	print("")
	print("=== C) 后台 ask_once（非流式 + temperature=0）===")
	_once_text = ""
	_once_err = ""
	# 后台只有一条连接：她刚说完之后记忆抽取往往正占着，先等它空出来
	var t := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < t and bool(_chat.call("once_busy")):
		await process_frame
	var sent: bool = _chat.call("ask_once", "只输出 JSON 数组，不要解释。",
		"给「今天好累」想 3 句主人可能接的话", 2000)
	_ok(sent, "C：发得出去")
	if not sent:
		return
	var t2 := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < t2 and _once_text == "" and _once_err == "":
		await process_frame
	_ok(_once_err == "" and _once_text.strip_edges() != "",
		"C：能拿到结果 → %s" % (_once_text if _once_text != "" else _once_err))

## D) 看图那条（偷看屏幕 / 看摄像头用同一种格式）
func _stage_vision() -> void:
	print("")
	print("=== D) 看图（视觉模型 + data:image/jpeg;base64）===")
	_vis_text = ""
	_vis_err = ""
	var vis = _pet.get("_vision")
	if vis == null or String(_pet.get("vision_model")).strip_edges() == "":
		_warn_soft("D：没配视觉模型 —— 看图这条本来就该是关的（跳过）")
		return
	var sent: bool = vis.call("send", "这张图主要是什么颜色？两个字", _tiny_jpeg())
	_ok(sent, "D：发得出去")
	if not sent:
		return
	var t := Time.get_ticks_msec() + 40000
	while Time.get_ticks_msec() < t and _vis_text == "" and _vis_err == "":
		await process_frame
	_ok(_vis_err == "" and _vis_text.strip_edges() != "",
		"D：能拿到结果 → %s" % (_vis_text if _vis_text != "" else _vis_err))

# ------------------------------------------------------------------ 小工具

func _frames(n: int) -> void:
	for i in n:
		await process_frame

## 等她开始忙、再等她忙完。返回 false = 一直没忙起来或没忙完（超时）
func _busy_done() -> bool:
	var t1 := Time.get_ticks_msec() + 8000
	var started := false
	while Time.get_ticks_msec() < t1:
		await process_frame
		if bool(_chat.call("is_busy")):
			started = true
			break
	if not started:
		return false
	var t2 := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < t2 and bool(_chat.call("is_busy")):
		await process_frame
	await _frames(12)
	return true

func _reachable(sec: float) -> bool:
	var t := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < t:
		await process_frame
		if bool(_chat.call("backend_reachable")):
			return true
	return false

func _bubble_text() -> String:
	var b = _pet.get("_bubble")
	if b == null:
		return ""
	# 别用 String(v)：v 是 null 时会抛（GDScript 的 String() 不认 null）
	var v = b.get("text")
	return v if typeof(v) == TYPE_STRING else ""

func _buttons() -> Array:
	var out: Array = []
	var quick = _pet.get("_quick")
	if quick == null:
		return out
	var box = quick.get("_box")
	if box == null:
		return out
	for c in box.get_children():
		var v = c.get("text")
		out.append(v if typeof(v) == TYPE_STRING else "")
	return out

## 和桌宠偷看屏幕时一模一样的形状：96×96 纯色 JPEG + data-url 前缀
func _tiny_jpeg() -> String:
	var img := Image.create(96, 96, false, Image.FORMAT_RGB8)
	img.fill(Color(0.85, 0.2, 0.15))
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(img.save_jpg_to_buffer())

func _ok(cond: bool, what: String) -> void:
	if cond:
		print("  [OK]   %s" % what)
	else:
		_fail += 1
		print("  [FAIL] %s" % what)

func _warn_soft(what: String) -> void:
	_warn += 1
	print("  [警告] %s" % what)
