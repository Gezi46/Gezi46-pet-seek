# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 强制播放一个长动画（走的是 _begin_move 里选到 emote 的同一条路），
## 然后记录每一次"动画切换"和 animation_finished 信号，看是谁在中间把它切走的。
## 用法: --headless --script res://tools/probe_action_play.gd -- extra7
var _frames := 0
var _pet: Node
var _ap: AnimationPlayer
var _t0 := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 8000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var target: String = a[0] if a.size() > 0 else "extra7"
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	await process_frame
	await process_frame
	_ap = _pet.get_node("Character/Pivot/Model/AnimationPlayer")
	_ap.animation_finished.connect(_on_fin)

	_t0 = Time.get_ticks_msec()
	var ok: bool = _pet.call("_play_action", target, 0.15) == null
	print("强制播放 %s（调用成功=%s） length=%.3f  code>timer=%.3f  speed_scale=%.2f" % [
		target, ok, _ap.current_animation_length,
		float(_pet.get("_timer")), _ap.speed_scale])
	print("现在动画=%s" % _ap.current_animation)

	var last: String = _ap.current_animation
	var start_anim: String = last
	while (Time.get_ticks_msec() - _t0) < 22000:
		await process_frame
		var cur: String = _ap.current_animation
		if cur != last:
			print("t=%5.2fs  切换 %s -> %s   state=%s timer=%.2f pos=%.2f/%.2f" % [
				(Time.get_ticks_msec() - _t0) / 1000.0, last, cur,
				_pet.get("_state"), float(_pet.get("_timer")),
				_ap.current_animation_position, _ap.current_animation_length])
			last = cur
	print("---- 结束：%s 一共播放了 %.2f 秒（动画长度 %.3f）----" % [
		start_anim, (Time.get_ticks_msec() - _t0) / 1000.0, 0.0])
	quit(0)

func _on_fin(n: String) -> void:
	print("  [signal] animation_finished(%s)  t=%.2fs  pos=%.2f/%.2f  state=%s timer=%.2f" % [
		n, (Time.get_ticks_msec() - _t0) / 1000.0,
		_ap.current_animation_position, _ap.current_animation_length,
		_pet.get("_state"), float(_pet.get("_timer"))])
