# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 让宠物自己跑一段时间，记录每一次动画切换，并判定"上一个动画还没播完就被切走"。
## 判据：上一个动画**不是循环动画**、且切换时它还没播到 90% 长度 -> 算一次"被切走"。
## 用法: --headless --script res://tools/probe_watch.gd -- 120
var _frames := 0
var _pet: Node
var _ap: AnimationPlayer
var _lib: AnimationLibrary
var _t0 := 0
var _last := ""
var _last_len := 0.0
var _last_loop := false
var _last_change_ms := 0
var _changes := 0
var _cuts := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 40000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var secs: float = float(a[0]) if a.size() > 0 else 120.0
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	await process_frame
	await process_frame
	_ap = _pet.get_node("Character/Pivot/Model/AnimationPlayer")
	_lib = _ap.get_animation_library("")

	# 只是把"等多久"缩短，让动作密集发生 —— 计时机制本身一个字没改。
	# 第二个参数可以指定 emote_chance：设 0 就只走路/跑步，专门测移动动画。
	var emote: float = float(a[1]) if a.size() > 1 else 1.0
	_pet.set("emote_chance", emote)
	_pet.set("rest_min", 0.3)
	_pet.set("rest_max", 0.6)
	_pet.set("idle_before_move", Vector2(0.4, 0.8))
	_pet.set("move_duration", Vector2(0.5, 1.0))
	var sp: float = float(_pet.get("anim_speed"))
	print("高频动作模式（只缩短等待，机制不变）：观察 %.0f 秒，anim_speed=%.2f emote_chance=%.2f" % [secs, sp, emote])

	_t0 = Time.get_ticks_msec()
	_last = _ap.current_animation
	_record(_last)
	_last_change_ms = _t0
	while (Time.get_ticks_msec() - _t0) < int(secs * 1000.0):
		await process_frame
		var cur: String = _ap.current_animation
		if cur == _last:
			continue
		var now := Time.get_ticks_msec()
		var played := (now - _last_change_ms) / 1000.0     # 真实秒
		var expect: float = _last_len / maxf(sp, 0.01)     # 上一个动画本该播多久
		var cut: bool = (not _last_loop) and _last_len > 0.0 and played < expect * 0.9
		_changes += 1
		if cut:
			_cuts += 1
		print("t=%6.2fs  %-12s -> %-12s 上一个待了 %5.2fs/该 %5.2fs %s  state=%s timer=%6.2f" % [
			(now - _t0) / 1000.0, _last, cur, played, expect,
			("<<< 被中途切走" if cut else ""), _pet.get("_state"), float(_pet.get("_timer"))])
		_last = cur
		_record(cur)
		_last_change_ms = now
	print("---- 结束：切换 %d 次，其中'被中途切走' %d 次 ----" % [_changes, _cuts])
	quit(0)

func _record(name: String) -> void:
	if name.is_empty() or not _lib.has_animation(name):
		_last_len = 0.0
		_last_loop = true
		return
	var a: Animation = _lib.get_animation(name)
	_last_len = a.length
	_last_loop = a.loop_mode == Animation.LOOP_LINEAR
