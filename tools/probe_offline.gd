# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 验"离线假死"：联系不上 AI 服务时，她只保留基础功能。
##
## 停掉的（都是会**自己发起**的事）：主动说话、生闷气、定时偷看、定时看摄像头、
## 记忆抽取、聊天发消息、聊天那条派活、自己乱走。
## 保留的（基础功能）：摸头 / 喂食 / 睡觉 / 拖拽 / 菜单 / 本地台词 / 眨眼呼吸。
##
## 怎么测：直接拿 PetChat.reachable_set() 把探活结果**扳成离线** —— 那本来就是
## 探活结果落地的那条路（真探活 15 秒一次，所以整个离线段要在几秒内跑完，
## 不然真探活会把状态翻回去）。
##
## 顺序有讲究：**先测"恢复后能走"再测睡觉** —— 睡觉会把 _sleeping 置上，
## 之后 _begin_move 会因为"在睡觉"直接返回，那和假死那道门就分不清了。
##
## 用法: --path <项目> --script res://tools/probe_offline.gd（要真窗口：场景要排版）
extends SceneTree

var _pet: Node = null
var _fail := 0

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 8:
		await process_frame
	print("")
	var chat = _pet.get("_chat")
	if chat == null:
		print("  ❌ 没建起聊天客户端（chat_enabled 是关的？）")
		quit(1)
		return

	print("=== 1. 扳成离线：该停的都停 ===")
	# ⚠️ 先等**开局那次自动探活**落地，再扳离线。
	# 不等的话会撞上一个时序竞态（2026-09-27 实测：这里报 6 项没过）：开局探活是从第一帧
	# 就发出去的（_next_ms 初始 0），它几百毫秒后才回来 —— 回来时会把手工扳的"离线"
	# **覆盖成在线** ✗，于是下面每一条"该停下来"的检查全跟着错。
	# 等它落定之后，下一次自动探活是 15 秒后，中间这段没人会来改状态
	var waited := 0
	while waited < 60 * 8 and not bool(chat.call("backend_reachable")):
		await process_frame
		waited += 1
	chat.call("reachable_set", false)
	await process_frame
	await process_frame
	_check(bool(_pet.call("_offline")), "她判定自己离线了")
	_check(_ai_status().find("联系不上") >= 0, "菜单那行写着联系不上 → %s" % _ai_status())

	# 不再自己乱走（pet_walk 的那道门）
	_pet.get("walk").call("_begin_move")
	_check(int(_pet.get("_state")) == 0 and float(_pet.get("_speed")) == 0.0,
		"她待在原地不动（state=%s speed=%s）" % [_pet.get("_state"), _pet.get("_speed")])

	# 聊天：只收着不发，那条话也不进记录（等连上重试）
	var log_before: int = (_pet.get("_chat_log") as Array).size()
	_pet.call("_submit_chat", "你还在吗？")
	await process_frame
	_check(_last_said().find("联系不上") >= 0, "聊天被挡下并说清楚 → %s" % _last_said())
	_check((_pet.get("_chat_log") as Array).size() == log_before,
		"那条话没进聊天记录（输入框里的字也留着）")

	# 聊天那条派活也不接（工作台那条不受这个限制，那是明确指令）。
	# 要先把开关打开才轮得到离线判断（顺序是 开关 → 离线）；
	# 用完恢复原样，别把你的设置改了
	var harness_was := bool(_pet.get("harness_enabled"))
	_pet.set("harness_enabled", true)
	_pet.call("_begin_harness", "查个东西")
	_check(_last_said().find("接不了") >= 0 or _last_said().find("联系不上") >= 0,
		"派活被挡下 → %s" % _last_said())
	_pet.set("harness_enabled", harness_was)

	# 生闷气的等待被清掉：断网不算被冷落
	# （状态和判定在 scripts/pet_mood.gd，宿主只留了 _soothe / _touch_react 两个薄壳）
	var mood = _pet.get("_mood")
	mood.set_wait_deadline(1)
	mood.tick()
	_check(int(mood.wait_deadline()) == 0, "离线时把\"等的回话\"清了，不生闷气")

	# 记忆抽取：别发注定失败的请求（看轮数就知道有没有被吞）
	var flow = _pet.get("_memory_flow")
	var ex_before: int = int(flow.get("_exchange_count"))
	flow.call("_maybe_extract", "我叫阿哲，今年 24", "你好呀")
	_check(int(flow.get("_exchange_count")) == ex_before, "记忆抽取没有往外发")

	print("=== 2. 扳回在线：恢复 ===")
	chat.call("reachable_set", true)
	await process_frame
	await process_frame
	_check(not bool(_pet.call("_offline")), "她知道自己连上了")
	_check(_ai_status().find("已连接") >= 0, "菜单那行恢复 → %s" % _ai_status())

	# 离线段再补一刀（第 1 段跑得慢的话，真探活会把状态翻回去）：确认派活的门
	chat.call("reachable_set", false)
	await process_frame
	_pet.set("harness_enabled", true)
	_pet.call("_begin_harness", "查个东西")
	_check(_last_said().find("接不了") >= 0 or _last_said().find("联系不上") >= 0,
		"离线时派活被挡下 → %s" % _last_said())
	_pet.set("harness_enabled", harness_was)

	# 门开了没有：把骰子拉满（表情关掉），_begin_move 必须真的能动起来。
	# （要趁她还醒着测 —— 睡觉那步放在最后，不然 _sleeping 会挡住 _begin_move，
	#   和假死那道门就分不清了）
	chat.call("reachable_set", true)
	await process_frame
	_pet.set("move_chance", 1.0)
	_pet.set("emote_chance", 0.0)
	_pet.get("walk").call("_begin_move")
	_check(int(_pet.get("_state")) == 1, "恢复后她自己又能走了（state=WALK）")

	print("=== 3. 假死里（和平时）都该在的基础功能 ===")
	_pet.call("_touch_react", "head")
	_check(_last_said() != "", "摸头照常有反应 → %s" % _last_said())
	_pet.get("pointer").call("_go_sleep")
	_check(int(_pet.get("_state")) == 3, "睡觉照常（state=SLEEP）")
	_pet.call("_soothe")

	# 看图那条：视觉模型留空 = 关掉看图（AI 面板里就是这么写的），
	# 那就不该再截屏、更不该把图发出去 —— 那是白花的 token / 白截的屏
	var vm := String(_pet.get("vision_model"))
	_pet.set("vision_model", "")
	_check(not bool(_pet.call("_vision_ready")), "视觉模型留空 → 认得出来“看图是关的”")
	# 这两条就够说明问题了：_peek_and_comment / _camera_look 的**第一行**就是这个判断，
	# 为真就直接 return（连 _peek_screen() / _camera_shot() 都不走到），
	# 定时那条（_check_peek / _check_camera）也在入口挡掉。
	# 试过再加一条"看气泡说了什么 / 有没有开流"的断言，但那两样都是全宿主共用的，
	# 会被别的链路（睡觉时 _say 不吵她、harness 正占着气泡）污染，太脆，所以不写
	_pet.set("vision_model", vm)
	_check(bool(_pet.call("_vision_ready")), "填回视觉模型 → 看图又能用了")

	_summary()

func _ai_status() -> String:
	# 菜单那行状态文字：_status_rows 里存的是 [菜单, 下标]
	var rows: Dictionary = _pet.get("_menu_mod").get("_status_rows")
	var row: Array = rows.get(_pet.get("_menu_mod").ID_AI_STATUS, [])
	if row.is_empty():
		return "<没找到那行>"
	return (row[0] as PopupMenu).get_item_text(int(row[1]))

func _last_said() -> String:
	return String(_pet.get("_bubble").text).strip_edges()

func _summary() -> void:
	print("")
	if _fail == 0:
		print("===== 结论：全部通过 =====")
	else:
		print("===== 结论：%d 项没过 =====" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, what: String) -> void:
	if ok:
		print("  [OK]   %s" % what)
	else:
		_fail += 1
		print("  [FAIL] %s" % what)
