# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 复现并验证一个状态卡死 bug：
## 走路中点一下角色（几乎不移动鼠标）→ _begin_drag() 把 _state 设成 DRAG 并播 jump，
## 松开时 _end_drag() → _react_click() 恰好落在"摸头冷却"里直接 return，
## 旧代码会把 _state 永远留在 DRAG —— 此后不再走路/做表情，僵在 jump 最后一帧。
## 用法: --headless --script res://tools/probe_drag_state.gd
var _frames := 0
var _pet: Node
var _ap: AnimationPlayer

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 3000:
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
	_pet.set("pet_cooldown", 5.0)     # 把冷却拉长，确保第二次点击必中冷却分支

	print("--- 第 1 次点击（不在冷却里，正常播动作）---")
	_pet.call("_begin_drag")
	_pet.set("_moved", 0.0)
	_pet.call("_end_drag")
	print("点击后: state=%s (2=DRAG) 当前动画=%s" % [_pet.get("_state"), _ap.current_animation])

	for i in 10:
		await process_frame

	print("--- 第 2 次点击（必然落在冷却里）---")
	_pet.call("_begin_drag")
	_pet.set("_moved", 0.0)
	_pet.call("_end_drag")
	print("点击后: state=%s (2=DRAG / 0=IDLE) 当前动画=%s" % [
		_pet.get("_state"), _ap.current_animation])

	# 再等几秒，看状态机有没有恢复"自己动"的能力
	await _wait_sec(3.0)
	print("3 秒后: state=%s 当前动画=%s （0=IDLE 且动画在轮换 = 恢复正常）" % [
		_pet.get("_state"), _ap.current_animation])
	quit(0)

func _wait_sec(sec: float) -> void:
	var t := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t) < int(sec * 1000.0):
		await process_frame
