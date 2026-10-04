# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 主动对话模块（pet_proactive.gd）的离线自检 —— 2026-09-29 第③条搬家之后补的。
##
## 用**假宿主**把 tick() 的每一道门、ask() 的走向都走一遍：不联网、不花额度。
## 真·让她开口那条（联网）在 probe_live.gd 的 B 段。
##
## 为什么值得单独一块：tick() 里那几道门的**顺序**就是它的全部行为 ——
## 搬家最容易出的错就是顺序错 / 漏一道门。这里把每一道都试一遍。
##
## 用法：--headless --path <项目> --script res://tools/probe_proactive.gd

extends SceneTree

const PetProactive := preload("res://scripts/ai/pet_proactive.gd")

# ------------------------------------------------------------------ 假宿主
# 只暴露 pet_proactive 会碰的那些成员（改名之前先看 pet_proactive.gd 头部那行清单）

class FakeChat:
	func backend_reachable() -> bool: return true
	func probe_now() -> void: pass

class FakeMood:
	var muted := false
	func is_muted() -> bool: return muted

class FakeBubble:
	var visible := false
	func is_visible() -> bool: return visible

class FakePeek:
	func wants_proactive_peek() -> bool: return false
	func peek_screen() -> String: return ""
	func proactive_peek_prompt() -> String: return ""

class FakeShortTerm:
	func retry_prompt() -> String: return ""

class FakeHost extends Node:     # 模块 setup(host: Node) 要求 Node，假宿主也得是 Node
	var self_talk_enabled := true
	var _proactive_on := true
	var self_talk_after := Vector2(300.0, 900.0)
	var _rng := RandomNumberGenerator.new()
	var _chat: FakeChat = FakeChat.new()
	var _mood := FakeMood.new()
	var bubble := FakeBubble.new()
	var _peek := FakePeek.new()
	var _shortterm := FakeShortTerm.new()
	var _offline_flag := false
	var _ai_busy_flag := false
	var _chat_streaming := false
	var _camera_busy := false
	var _panel_open := false
	var _last_origin := ""
	var _opts_kind_override := ""
	var _peak_reduce_on := false
	var send_ok := true
	var asks := 0
	var said := ""
	var sent_prompt := ""

	func _offline() -> bool: return _offline_flag
	func _ai_busy() -> bool: return _ai_busy_flag
	func _ui_panel_open() -> bool: return _panel_open
	func _say(s: String) -> void: said = s
	func _say_local() -> void: said = "LOCAL"
	func _begin_stream_bubble() -> void: pass
	func _refresh_persona(p: String) -> void: pass
	func _send_first(prompt: String, shot: String) -> bool:
		sent_prompt = prompt
		asks += 1
		return send_ok


var _ok := 0
var _bad := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   " + msg)
	else:
		_bad += 1
		print("  [FAIL] " + msg)

func _init() -> void:
	var p = PetProactive.new()
	var h = FakeHost.new()
	p.setup(h)
	print("=== 主动对话模块自检（假宿主，离线）===")

	# 到点就该开口
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1 and h._last_origin == "proactive",
		"到点开口：tick → ask → 来源记成 proactive（asks=%d）" % h.asks)

	# 门 1：总闸
	h._proactive_on = false
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 1 总闸关着：不开口")
	h._proactive_on = true

	# 门 2：self_talk_enabled
	h.self_talk_enabled = false
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 2 「闲了自己开口」关着：不开口")
	h.self_talk_enabled = true

	# 门 3：没建聊天客户端
	h._chat = null
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 3 没有聊天客户端：不开口")
	h._chat = FakeChat.new()

	# 门 4：生气闭嘴
	h._mood.muted = true
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 4 生气闭嘴（被冷落到顶）：不主动开口")
	h._mood.muted = false

	# 门 5：离线
	h._offline_flag = true
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 5 离线：不开口（宁可安静，别往死服务上撞）")
	h._offline_flag = false

	# 门 6：正忙
	h._ai_busy_flag = true
	p.timer = 0.0
	p.tick(0.1)
	_check(h.asks == 1, "门 6 正在忙：不开口")
	h._ai_busy_flag = false

	# 门 7：正在冒字 / 面板开着 / 气泡还在 / 等摄像头 —— 都算"有人在互动"
	for gate in ["冒字", "面板开着", "气泡还在", "等摄像头"]:
		match gate:
			"冒字": h._chat_streaming = true
			"面板开着": h._panel_open = true
			"气泡还在": h.bubble.visible = true
			"等摄像头": h._camera_busy = true
		p.timer = 0.0
		p.tick(0.1)
		_check(h.asks == 1, "门 7 有互动（%s）：不开口" % gate)
		h._chat_streaming = false
		h._panel_open = false
		h.bubble.visible = false
		h._camera_busy = false

	# 计时没到：不开口，但倒计时照常往下走
	p.timer = 100.0
	p.tick(1.0)
	_check(h.asks == 1 and p.timer < 100.0 and p.timer > 0.0,
		"没到点：不开口，倒计时照常走（100 → %.1f）" % p.timer)

	# 发送失败 → 退回本地台词（不是把报错怼脸上）
	h.send_ok = false
	p.timer = 0.0
	p.tick(0.1)
	_check(h.said == "LOCAL", "发送失败：退回本地台词（said=%s）" % h.said)
	h.send_ok = true

	# 频率档钳制 + 出厂值
	p.set_rate(99)
	_check(p.rate == 3, "频率档钳制：99 → 第 3 档")
	p.set_rate(-1)
	_check(p.rate == 0, "频率档钳制：-1 → 第 0 档")
	var fresh = PetProactive.new()
	_check(fresh.rate == 1 and fresh.timer == 0.0,
		"出厂值：档位 1（普通）、倒计时由 setup() 数")

	# 倒计时抽样落在区间里（普通档 300~1800 秒，含 15% 长尾）—— 验 rand_delay 没抽飞
	var all_in := true
	p.set_rate(1)
	for i in 40:
		var d: float = p.rand_delay()
		if d < 300.0 or d > 1800.0:
			all_in = false
	_check(all_in, "倒计时抽样落在区间里（300~1800 秒，含长尾）")

	# ---- 高峰时段少说话（DeepSeek 官方高峰：工作日 9~12、14~18；周末低谷）
	_check(PetProactive.peak_active(10, 1, true), "高峰：周一 10 点算高峰")
	_check(not PetProactive.peak_active(13, 1, true), "高峰：周一 13 点（午休）不算")
	_check(not PetProactive.peak_active(19, 1, true), "高峰：周一 19 点不算")
	_check(not PetProactive.peak_active(10, 0, true), "高峰：周日 10 点不算（周末低谷）")
	_check(not PetProactive.peak_active(15, 6, true), "高峰：周六 15 点不算")
	_check(not PetProactive.peak_active(10, 1, false), "开关关：周一 10 点也不算")

	# 开关开 + 在高峰内 → 间隔 ×5。用"很少"档验（lo=900，×5=4500 > 非高峰最大 3600），
	# 两头能一刀切开。固定时钟到"周一 10 点"（把模块的 clock 换成假函数）
	p.set_rate(0)
	h._peak_reduce_on = true
	p.clock = func() -> Dictionary: return {"hour": 10, "weekday": 1}
	var peak_min := INF
	for i in 40:
		peak_min = minf(peak_min, p.rand_delay())
	_check(peak_min >= 4500.0,
		"高峰 + 开关开：间隔拉长 5 倍（最少 %.0f 秒 ≥ 4500）" % peak_min)
	h._peak_reduce_on = false
	var off_max := 0.0
	for i in 40:
		off_max = maxf(off_max, p.rand_delay())
	_check(off_max <= 3600.0,
		"开关关：回到原间隔（最多 %.0f 秒 ≤ 3600）" % off_max)

	print("===== 结论：通过 %d 项，失败 %d 项 =====" % [_ok, _bad])
	quit(0 if _bad == 0 else 1)
