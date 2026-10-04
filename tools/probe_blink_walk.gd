# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 严谨的眨眼干扰验证（第二版）：
##   - Engine.max_fps = 60，帧长稳定
##   - 腿部位置换算到 **模型本地空间**（排除 _update_facing 转身造成的世界位移）
##   - 打印叠加层里 BlinkTwo 裁剪后的轨道数（确认 _strip_to_face 生效）
##   - A = 修复后的眨眼；B = 把主库完整版 BlinkEye 塞给叠加层（修复前行为）
## 用法: --headless --script res://tools/probe_blink_walk.gd
var _frames := 0
var _pet: Node
var _ap: AnimationPlayer
var _ap_face: AnimationPlayer
var _leg: Node3D
var _model: Node3D

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 8000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _leg_local() -> Vector3:
	return _model.global_transform.affine_inverse() * _leg.global_position

func _run() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	await process_frame
	await process_frame
	_ap = _pet.get_node("Character/Pivot/Model/AnimationPlayer")
	_ap_face = _pet.get_node("Character/Pivot/Model/AnimationPlayer2")
	_model = _pet.get_node("Character/Pivot/Model")
	_leg = _find_bone("LeftLowerLeg")
	var face_lib: AnimationLibrary = _ap_face.get_animation_library("")
	for n in ["BlinkEye", "BlinkTwo"]:
		if face_lib.has_animation(n):
			print("叠加层 %s：%d 条轨道（裁剪后）" % [n, face_lib.get_animation(n).get_track_count()])

	# 强制 WALK，方向向右
	_pet.set("_state", 1)
	_pet.set("_timer", 60.0)
	_pet.set("_move_dir", Vector2.RIGHT)
	_pet.set("_run", false)
	_pet.set("_speed", 46.0 * float(_pet.get("anim_speed")))
	_pet.call("_play", "walk", 0.0)

	# 等 2 秒让转身完成、步态稳定，再量基准
	await _wait(2.0)
	var base := await _measure(1.5)
	print("基准：走路时腿部（模型本地）活动帧 %d/%d，最大单帧位移 %.4f" % [base[1], base[2], base[0]])

	# A. 修复后的眨眼
	_pet.call("_blink")
	var bn: String = _ap_face.current_animation
	var after := await _measure(1.5)
	print("A 修复后：%s 期间活动帧 %d/%d，最大单帧位移 %.4f  %s" % [
		bn, after[1], after[2], after[0], "OK（一直在走）" if after[1] > base[1] * 0.5 else "FAIL 仍被钉住"])

	# B. 对照：完整版 BlinkEye（修复前行为）
	await _wait(1.0)
	var raw: Animation = _ap.get_animation("BlinkEye")
	face_lib.add_animation("BlinkRaw", raw)
	_ap_face.play("BlinkRaw")
	var before := await _measure(1.5)
	print("B 对照（完整 39 轨）：活动帧 %d/%d，最大单帧位移 %.4f  %s" % [
		before[1], before[2], before[0],
		"旧毛病复现（一下.snap 后钉住）" if before[1] < base[1] * 0.5 else "身体没被它钉住"])
	quit(0)

## 返回 [最大单帧位移, 活动帧数, 总帧数]
func _measure(sec: float) -> Array:
	var best := 0.0
	var active := 0
	var prev: Vector3 = _leg_local()
	var frames := int(sec * 60.0)
	for i in frames:
		await process_frame
		var cur: Vector3 = _leg_local()
		var d: float = cur.distance_to(prev)
		best = maxf(best, d)
		if d > 0.003:
			active += 1
		prev = cur
	return [best, active, frames]

func _wait(sec: float) -> void:
	for i in int(sec * 60.0):
		await process_frame

func _find_bone(prefix: String) -> Node3D:
	var model: Node = _pet.get_node("Character/Pivot/Model")
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if String(n.name).begins_with(prefix) and n is Node3D:
			return n
	return null
