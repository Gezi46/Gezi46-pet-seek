# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 验证一个猜想：动作 A 还没播完就被动作 B 打断时，
## Godot 会不会在 B 播放期间补发 animation_finished(A)？
## 如果会，_on_main_finished() 就会把正在播的 B 切回待机 —— 表现正是"长动画做一半回到静止"。
## 用法: --headless --script res://tools/probe_interrupt.gd
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
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	await process_frame
	await process_frame
	_ap = _pet.get_node("Character/Pivot/Model/AnimationPlayer")
	_ap.animation_finished.connect(_on_fin)
	_t0 = Time.get_ticks_msec()

	_pet.call("_play_action", "attacked", 0.12)
	print("t=0.00 播放 attacked（长度 %.3f，speed=%.2f -> 实际 %.3f 秒）" % [
		_ap.current_animation_length, _ap.speed_scale,
		_ap.current_animation_length / _ap.speed_scale])

	await _wait(0.10)
	_pet.call("_play_action", "extra7", 0.15)
	print("t=%.2f 用 extra7 打断它（打断时 attacked 播到 %.2f/%.3f）" % [
		_elapsed(), _ap.current_animation_position, _ap.current_animation_length])
	print("      此时 当前动画=%s  state=%s  timer=%.2f" % [
		_ap.current_animation, _pet.get("_state"), float(_pet.get("_timer"))])

	var last: String = _ap.current_animation
	while _elapsed() < 3.0:
		await process_frame
		if _ap.current_animation != last:
			print("t=%.2f 切换 %s -> %s   state=%s timer=%.2f" % [
				_elapsed(), last, _ap.current_animation,
				_pet.get("_state"), float(_pet.get("_timer"))])
			last = _ap.current_animation
	print("---- 结束：extra7 应该要播 10.7 秒，上面只要在 3 秒内切走就是复现了 ----")
	quit(0)

func _wait(sec: float) -> void:
	var t := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t) < int(sec * 1000.0):
		await process_frame

func _elapsed() -> float:
	return (Time.get_ticks_msec() - _t0) / 1000.0

func _on_fin(n: String) -> void:
	print("  [signal] animation_finished(%s)  t=%.2fs  此时当前动画=%s" % [
		n, _elapsed(), _ap.current_animation])
