# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 打印每个动画的"真实长度"和"脚本算出来的动作时长"(_action_time)，
## 用来定位"较长动画播到一半就被切回待机"这类问题。
## 用法: --headless --script res://tools/probe_anim_stats.gd
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 2000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame

	var ap: AnimationPlayer = pet.get_node("Character/Pivot/Model/AnimationPlayer")
	var lib: AnimationLibrary = ap.get_animation_library("")
	print("AnimationPlayer 有 get_animation 方法吗: %s" % ap.has_method("get_animation"))
	print("anim_speed=%s behavior_pace=%s rest=[%s, %s]" % [
		pet.get("anim_speed"), pet.get("behavior_pace"),
		pet.get("rest_min"), pet.get("rest_max")])
	print("")
	print("%-24s %9s %11s %11s  %s" % ["动画", "length", "_action_time", "差值", "循环"])
	var names: Array = lib.get_animation_list()
	names.sort()
	var bad := 0
	for n in names:
		var a: Animation = lib.get_animation(n)
		var t: float = pet.call("_action_time", n)
		var d: float = t - a.length
		var flag: String = ""
		if d < -0.05:
			flag = " <== 计时比动画短，会被中途切走"
			bad += 1
		print("%-24s %9.3f %11.3f %11.3f  %s%s" % [
			n, a.length, t, d,
			"循环" if a.loop_mode == Animation.LOOP_LINEAR else "一次", flag])
	print("")
	print("计时短于动画的动画数: %d" % bad)
	quit(0)
