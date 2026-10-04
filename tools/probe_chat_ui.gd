# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 验聊天这一套的 UI 与端到端：面板显隐、窗口焦点切换、流式气泡、截屏编码。
## **必须带窗口跑**（headless 下 screen_get_image() 拿不到画面，
## 而且没有真窗口就测不出 NO_FOCUS 标志的切换）：
##   用法: & $godot --path . --script res://tools/probe_chat_ui.gd
##
## 需要 giftia 后端在跑（默认 http://127.0.0.1:8000）：
##   D 段会真发一句话，后端不可达会在这里失败。
##
##   A. 右键菜单 19 项，12~18 是聊天/看看相关的七条
##   B. _open_chat()：面板显示、NO_FOCUS 被摘掉、输入框拿到焦点
##   C. _close_chat()：面板隐藏、NO_FOCUS 恢复
##   D. 发一句话：流式期间直接改 _bubble.text（不能走 _say，会被淡出藏掉），
##      收完是完整回复且 _chat_streaming 归位
##   E. _peek_screen()：屏幕 → JPEG → data URL，能解回真图片
##   F. 偷看屏幕真链路：把截图塞进 /api/chat 的 image_data，后端得回话
##      （要后端 `CHAT_MODEL` 是多模态的，见 backend/model_config.py）
##   G. 摄像头那条链路（AIGirlfriend /api/see）：没开开关只哼一声；
##      开了之后无论对面在不在，气泡里都得出现一句话（真回复或"连不上"）
##   H. 三个开关（主动说话 / 偷看屏幕 / 摄像头）：勾选态和实际状态一致、
##      点一下能翻转、勾选跟着走、真写进存档；老存档缺键时落回检查器值。
##      **会动 user://pet_chat.cfg**，先备份原文、跑完还原
var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	if Time.get_ticks_msec() - _start_ms > 900000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _spawn() -> Node:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame
	pet.set_process(false)   # 关掉自己的 _process，网络推进由探针手动喂
	return pet

func _pump(pet: Node, ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		pet.call("_tick_chat", 1.0 / 60.0)
		await process_frame

## 按文案找菜单项。不按 id 找是为了别在探针里再抄一份 id 表
## （抄了就会和 pet.tscn 悄悄对不上）
func _find_menu(menu: PopupMenu, text: String) -> int:
	for i in menu.item_count:
		if menu.get_item_text(i) == text:
			return i
	return -1

func _run() -> void:
	var ok := true
	var pet: Node = await _spawn()
	var bubble: Label = pet.get_node("UI/Anchor/Bubble")
	var panel: Control = pet.get("_chat_panel")
	var input: LineEdit = pet.get("_chat_input")
	var menu: PopupMenu = pet.get_node("UI/Menu")

	# ---------------------------------------------------------- A. 菜单
	var items: PackedStringArray = []
	for i in menu.item_count:
		items.append("%d:%s" % [menu.get_item_id(i), menu.get_item_text(i)])
	print("A 菜单 %d 项 -> %s" % [menu.item_count, items])
	if menu.item_count != 19:
		ok = false
		printerr("A 失败：菜单应为 19 项")
	for want in ["跟我说话", "主动说一句", "看看我在干嘛", "摄像头", "主动说话", "偷看屏幕"]:
		var found := false
		for i in menu.item_count:
			if menu.get_item_text(i).contains(want):
				found = true
		if not found:
			ok = false
			printerr("A 失败：菜单里没有「%s」" % want)

	# ---------------------------------------------------------- B. 开面板
	pet.call("_open_chat")
	await process_frame
	await process_frame
	var no_focus_open: bool = DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)
	print("B 面板可见=%s _chat_open=%s NO_FOCUS=%s（应为 false）输入框有焦点=%s 中文字体=%s" % [
		panel.visible, pet.get("_chat_open"), no_focus_open,
		input.has_focus(), pet.get("_cjk_font") != null])
	if not panel.visible or not pet.get("_chat_open") or no_focus_open or not input.has_focus():
		ok = false
		printerr("B 失败：面板/焦点状态不对")

	# ---------------------------------------------------------- C. 关面板
	pet.call("_close_chat")
	await process_frame
	await process_frame
	var no_focus_closed: bool = DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)
	print("C 面板可见=%s _chat_open=%s NO_FOCUS=%s（应为 true）" % [
		panel.visible, pet.get("_chat_open"), no_focus_closed])
	if panel.visible or pet.get("_chat_open") or not no_focus_closed:
		ok = false
		printerr("C 失败：收起后该还原 NO_FOCUS 并藏掉面板")

	# ---------------------------------------------------------- D. 真发一句
	if pet.get("_chat") == null:
		printerr("D 失败：_chat 没建起来（chat_enabled 关了？）")
		ok = false
	else:
		# 直接盯 token 信号：回复很短时几个 token 会在同一帧到齐，
		# 按帧采样根本看不到"变长"的过程（那是探针的错觉，不是产品的问题）。
		# 这里挂在桌宠自己的处理函数之后，所以读到的是它刚写进去的气泡文本。
		var chat = pet.get("_chat")
		var seen: Array[String] = []
		chat.token.connect(func(_t: String) -> void: seen.append(bubble.text))
		pet.call("_submit_chat", "桌宠UI探针：随便回我一句")
		var faded_while_streaming := false
		var deadline := Time.get_ticks_msec() + 60000
		while Time.get_ticks_msec() < deadline:
			pet.call("_tick_chat", 1.0 / 60.0)
			# 只在"还在流"时看透明度：收流之后 _say() 的淡出是本来就该有的，
			# 把它算成失败就是误判（回复很短时收流和收尾 _say 会挤在同一帧）
			if pet.get("_chat_streaming") and bubble.visible and bubble.modulate.a < 0.99:
				faded_while_streaming = true
			if not pet.get("_chat_streaming") and not seen.is_empty():
				break
			await process_frame
		var monotonic := true
		for i in range(1, seen.size()):
			if seen[i].length() < seen[i - 1].length():
				monotonic = false
		var last_token_text: String = seen.back() if not seen.is_empty() else ""
		# 最后一个 token 快照得是最终气泡文字的**前缀**，不是"完全相等"：
		# 回复很短时 token 和收尾会挤在同一帧，收尾的 _say(完整回复) 会在快照之后
		# 把气泡补齐 —— 那种情况要求完全相等就是假失败（这条踩过）
		var token_in_bubble: bool = last_token_text != "" and bubble.text.begins_with(last_token_text)
		print("D token 个数=%d token写进气泡=%s 长度单调=%s 最终气泡=%s 流式期间没淡出=%s _chat_streaming=%s" % [
			seen.size(), token_in_bubble, monotonic,
			bubble.text, not faded_while_streaming, pet.get("_chat_streaming")])
		if not token_in_bubble:
			ok = false
			printerr("D 失败：token 没有直接写进气泡（最后一个 token=%s 气泡=%s）" % [
				last_token_text, bubble.text])
		if not monotonic:
			ok = false
			printerr("D 失败：气泡文字不是逐字追加的")
		if faded_while_streaming:
			ok = false
			printerr("D 失败：流式期间气泡被淡出了（说明混进了 _say 的 tween）")
		if bubble.text.contains("\uFFFD"):
			ok = false
			printerr("D 失败：气泡里有替换符，中文解码坏了")

	# ---------------------------------------------------------- E. 截屏编码
	var shot: String = pet.call("_peek_screen")
	var head := shot.substr(0, 23)
	var b64 := shot.substr(shot.find(",") + 1) if shot != "" else ""
	var raw: PackedByteArray = Marshalls.base64_to_raw(b64) if b64 != "" else PackedByteArray()
	print("E data URL 前缀=%s 解码后=%d 字节 是JPEG=%s" % [
		head, raw.size(), raw.size() > 2 and raw[0] == 0xFF and raw[1] == 0xD8])
	if not shot.begins_with("data:image/jpeg;base64,") or raw.size() < 1000:
		ok = false
		printerr("E 失败：截屏没编成可用的 JPEG data URL")

	# ---------------------------------------------------------- F. 偷看屏幕真链路
	if pet.get("_chat") == null:
		printerr("F 失败：_chat 没建起来")
		ok = false
	else:
		var chat_f = pet.get("_chat")
		var peek_replies: Array[String] = []
		var peek_fails: Array[String] = []
		chat_f.replied.connect(func(t: String) -> void: peek_replies.append(t))
		chat_f.failed.connect(func(m: String) -> void: peek_fails.append(m))
		pet.call("_peek_and_comment")
		var f_deadline := Time.get_ticks_msec() + 120000
		while Time.get_ticks_msec() < f_deadline:
			pet.call("_tick_chat", 1.0 / 60.0)
			if not peek_replies.is_empty() or not peek_fails.is_empty():
				break
			await process_frame
		var peek_reply: String = peek_replies[0] if not peek_replies.is_empty() else ""
		print("F 带图一轮的回复=%s 失败=%s 气泡=%s" % [peek_reply, peek_fails, bubble.text])
		if peek_reply.strip_edges() == "":
			ok = false
			printerr("F 失败：带截图的那一轮没拿到回复")
		if peek_reply.contains("\uFFFD"):
			ok = false
			printerr("F 失败：回复里有替换符，中文解码坏了")
		if peek_fails.size() > 0:
			ok = false
			printerr("F 失败：带图请求报错 %s" % [peek_fails])

	# ---------------------------------------------------------- G. 摄像头那条链路
	# 默认是关的，点了只哼一声（不会真去连）
	pet.set("_camera_on", false)
	pet.call("_camera_look")
	await process_frame
	print("G 开关关着时的气泡=%s" % bubble.text)
	if bubble.text != "我这边还没接摄像头呢～":
		ok = false
		printerr("G 失败：开关关着时该提示没接摄像头")

	# 开着再点一次：对面（AIGirlfriend）在不在都得给出一句话。
	# 等的是"这次请求真的结束了"（_camera_busy 落回 false），不是"气泡变了"
	# —— 中途被摸头之类的台词顶掉气泡会假通过，这里踩过一次
	pet.set("_camera_on", true)
	pet.set("camera_look_url", "http://127.0.0.1:8777")
	pet.call("_camera_look")
	if not pet.get("_camera_busy"):
		ok = false
		printerr("G 失败：开了开关之后没进「忙」状态")
	var g_deadline := Time.get_ticks_msec() + 300000
	while Time.get_ticks_msec() < g_deadline and pet.get("_camera_busy"):
		await process_frame
	print("G 开着时的气泡=%s（AIGirlfriend 没跑时应为「摄像头那边连不上…」）" % bubble.text)
	if bubble.text.strip_edges() == "" or bubble.text == "让我看看…":
		ok = false
		printerr("G 失败：开了开关之后没有任何回音")
	if pet.get("_camera_busy"):
		ok = false
		printerr("G 失败：请求结束后 _camera_busy 没归位")
	if pet.get("_chat_streaming"):
		ok = false
		printerr("G 失败：摄像头链路不该碰 _chat_streaming，收流状态被带脏了")

	# ---------------------------------------------------------- H. 三个开关
	# 会动 user://pet_chat.cfg：先备份原文，跑完还原，别改用户自己的设置
	var cfg_path := "user://pet_chat.cfg"
	var had_cfg := FileAccess.file_exists(cfg_path)
	var cfg_backup := PackedByteArray()
	if had_cfg:
		var bf := FileAccess.open(cfg_path, FileAccess.READ)
		cfg_backup = bf.get_buffer(bf.get_length())
		bf.close()

	var toggles := [
		{"label": "主动说话", "var": "_proactive_on", "key": "proactive"},
		{"label": "偷看屏幕", "var": "_peek_on", "key": "peek"},
		{"label": "摄像头", "var": "_camera_on", "key": "camera"},
	]
	for t: Dictionary in toggles:
		var label: String = t["label"]
		var var_name: String = t["var"]
		var key: String = t["key"]
		var idx := _find_menu(menu, label)
		if idx < 0:
			ok = false
			printerr("H 失败：菜单里找不到「%s」" % label)
			continue
		if not menu.is_item_checkable(idx):
			ok = false
			printerr("H 失败：「%s」不是勾选项" % label)
			continue
		var before: bool = bool(pet.get(var_name))
		if menu.is_item_checked(idx) != before:
			ok = false
			printerr("H 失败：「%s」开局时的勾选(%s)和实际开关(%s)对不上" % [
				label, menu.is_item_checked(idx), before])
		pet.call("_on_menu_id", menu.get_item_id(idx))
		await process_frame
		var after: bool = bool(pet.get(var_name))
		var want_tip: String = "%s：%s" % [label, "开" if after else "关"]
		print("H %s 点之前=%s 点之后=%s 勾选=%s 气泡=%s" % [
			label, before, after, menu.is_item_checked(idx), bubble.text])
		if after == before:
			ok = false
			printerr("H 失败：「%s」点一下没翻过来" % label)
		if menu.is_item_checked(idx) != after:
			ok = false
			printerr("H 失败：「%s」勾选没跟着走" % label)
		if bubble.text != want_tip:
			ok = false
			printerr("H 失败：「%s」的气泡提示不对：%s" % [label, bubble.text])
		# 真写进存档了吗（读回来核对，不是看内存里的值）
		var cfg_now := ConfigFile.new()
		if cfg_now.load(cfg_path) != OK:
			ok = false
			printerr("H 失败：「%s」切完没写出存档" % label)
		elif bool(cfg_now.get_value("chat", key, not after)) != after:
			ok = false
			printerr("H 失败：「%s」存档里没记住" % label)
		# 模拟"重启"：把内存里的值抹成反的，重新从存档读一遍 + 同步菜单勾选
		pet.set(var_name, not after)
		pet.call("_load_chat_config")
		pet.call("_sync_menu_toggles")
		if bool(pet.get(var_name)) != after or menu.is_item_checked(idx) != after:
			ok = false
			printerr("H 失败：「%s」重启后没恢复（开关=%s 勾选=%s，应为 %s）" % [
				label, pet.get(var_name), menu.is_item_checked(idx), after])
		# 点回去，别把用户的开关留成改过的样子
		pet.call("_on_menu_id", menu.get_item_id(idx))
		await process_frame

	# 「主动说话」关掉之后，她也不该自己找话说（总闸得管住这条，
	# 不然关掉只是"后端推送不来"，她自己照样开口）。用哨兵文字看气泡有没有被动过：
	# 后端可达时她会开始冒字（_chat_streaming 变真），不可达时会换成一句本地台词，
	# 两条路都会露馅
	pet.set("_peek_on", false)
	pet.set("self_talk_enabled", true)
	pet.set("_proactive_on", false)
	pet.set("_chat_streaming", false)
	# 倒计时挪进 pet_proactive.gd 了（2026-09-29 第③条）—— 走宿主留的那个壳，
	# 别去抠模块内部（宿主里那个方法名是给探针留的稳定接口）
	pet.call("_proactive_due_now")
	bubble.text = "哨兵"
	pet.call("_tick_chat", 1.0 / 60.0)
	await process_frame
	var silent_ok: bool = not pet.get("_chat_streaming") and bubble.text == "哨兵"
	print("H 主动说话关着时她自己不开口=%s" % silent_ok)
	if not silent_ok:
		ok = false
		printerr("H 失败：「主动说话」关着时她还自己找话说（气泡=%s）" % bubble.text)

	# 老存档里没有 peek / camera 这两个键时，必须落回**检查器里的值**而不是 false，
	# 否则"新加的开关"会在老用户那儿被静默关掉，看着像"改了参数却不生效"
	var old_cfg := ConfigFile.new()
	# ⚠️ 这一步会**临时改写你的真配置**（user://pet_chat.cfg）。所以顺序是：
	#    改 → 立刻读回来验 → **立刻还原**，还原之后才做别的事。
	#    2026-09-23 这里踩过一次：还原那一步原本排在后面，而后面那个调用写错了方法名
	#    （`_sync_toggle_menu` —— 早就改名成 `_sync_menu_toggles` 了），探针走到那儿就死，
	#    连 quit() 都到不了，于是配置就留在"探针写过的那份"上 —— **AI 的 key 就是这么丢的**。
	old_cfg.set_value("chat", "proactive", true)
	old_cfg.save(cfg_path)
	pet.set("peek_enabled", true)
	pet.set("camera_look_enabled", true)
	pet.set("_peek_on", false)
	pet.set("_camera_on", false)
	pet.call("_load_chat_config")
	var fallback_ok: bool = bool(pet.get("_peek_on")) and bool(pet.get("_camera_on"))
	print("H 老存档缺键时 peek/camera 落回检查器值=%s" % fallback_ok)
	# ← 还原**就在这里**，别往后挪
	if had_cfg:
		var wf := FileAccess.open(cfg_path, FileAccess.WRITE)
		wf.store_buffer(cfg_backup)
		wf.close()
	else:
		var ud := DirAccess.open("user://")
		if ud != null:
			ud.remove("pet_chat.cfg")
	print("H 存档已还原（原来%s）" % ("有" if had_cfg else "没有"))
	if not fallback_ok:
		ok = false
		printerr("H 失败：老存档缺键时没落回检查器里的值")

	# 收尾：把探针改动过的检查器值与运行时开关复位，菜单勾选同步回去
	pet.set("peek_enabled", false)
	pet.set("camera_look_enabled", false)
	pet.set("_peek_on", false)
	pet.set("_camera_on", false)
	# ⚠️ 方法名**以宿主为准**：这里原来写的 `_sync_toggle_menu` 已经不存在了，
	#    `Object.call()` 打不存在的名字会让整条协程死掉（不报 SCRIPT ERROR，所以特别难查）。
	#    教训：**探针里写死的宿主方法名，重构改名时必须全仓搜一遍**
	pet.call("_sync_menu_toggles")
	print("  （收尾：菜单勾选已同步回去）")

	print("PROBE_CHAT_UI %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)