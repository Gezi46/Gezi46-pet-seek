# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 量化每个动画"到底动没动"，用来排查"播放某些 extra 时看着像静止"的问题。
## 指标（都用全部网格节点的世界坐标）：
##   最大/平均单步位移 —— 动画在动吗（趋近 0 = 这个动画其实是静态的）
##   最近待机距离     —— 动画里有没有某一刻几乎就是待机姿势
##   末段单步位移     —— 后半段还在动吗（趋近 0 = 动作只做了一半就停住）
## 用法: --headless --script res://tools/probe_pose_curve.gd [-- 动画名...]
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 6000:
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
	pet.set_process(false)
	var ap: AnimationPlayer = pet.get_node("Character/Pivot/Model/AnimationPlayer")
	var lib: AnimationLibrary = ap.get_animation_library("")
	var meshes := _collect(pet)
	print("采样网格数 = %d（全部）" % meshes.size())

	ap.stop()
	ap.play("idle")
	ap.advance(0.5)
	var idle_sig := _sig(meshes)

	var names := OS.get_cmdline_user_args()
	if names.is_empty():
		names = lib.get_animation_list()
		names.sort()

	print("")
	print("%-12s %7s %10s %10s %12s  %s" % [
		"动画", "长度", "峰值位移", "最后动于", "占长度", "判定"])
	for name in names:
		var nm := String(name)
		if not lib.has_animation(nm):
			continue
		ap.stop()
		ap.play(nm)
		var length: float = ap.current_animation_length
		if length <= 0.001:
			print("%-12s %7.3f %10s %10s %12s  静帧" % [nm, length, "-", "-", "-"])
			continue
		# 采样要密一点，才看得出"最后动于哪一刻"
		var samples := 48
		var step: float = length / float(samples)
		var prev := _sig(meshes)
		var peak := 0.0
		var last_move := 0.0
		var moves: Array = []          # [progress, 该样本最活跃节点的位移]
		var guard := 0
		while ap.current_animation_position < length - 1e-4 and guard < 400:
			ap.advance(step)
			guard += 1
			var cur := _sig(meshes)
			var mv := _max_node_dist(cur, prev)     # 只用"最活跃的那个节点"，不被不动的节点稀释
			peak = maxf(peak, mv)
			moves.append([ap.current_animation_position / length, mv])
			prev = cur
		# 阈值取峰值的 15%：低于它就算"已经不做动作了"
		var thr: float = maxf(peak * 0.15, 0.002)
		for m in moves:
			if m[1] >= thr:
				last_move = maxf(last_move, m[0])
		var verdict := ""
		if peak < 0.01:
			verdict = "几乎不动（这个动画是空的）"
		elif last_move < 0.55:
			verdict = "动作只做了前 %.0f%%，后面停住" % (last_move * 100.0)
		elif last_move < 0.85:
			verdict = "动作做到 %.0f%%，尾巴有点空" % (last_move * 100.0)
		else:
			verdict = "全程都有动作"
		print("%-12s %7.3f %10.4f %9.0f%% %11.0f%%  %s" % [
			nm, length, peak, last_move * 100.0, last_move * 100.0, verdict])
	quit(0)

## 两个签名之间"最活跃那个节点的位移"——比均方根稳，不会被大量不动的节点稀释
func _max_node_dist(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var best := 0.0
	var i := 0
	while i + 2 < a.size():
		var dx: float = a[i] - b[i]
		var dy: float = a[i + 1] - b[i + 1]
		var dz: float = a[i + 2] - b[i + 2]
		best = maxf(best, sqrt(dx * dx + dy * dy + dz * dz))
		i += 3
	return best

func _collect(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			out.append(n)
	return out

func _sig(meshes: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for m in meshes:
		var p: Vector3 = (m as Node3D).global_position
		out.append(p.x)
		out.append(p.y)
		out.append(p.z)
	return out

func _dist(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n: int = mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var s := 0.0
	for i in n:
		var d: float = a[i] - b[i]
		s += d * d
	return sqrt(s / float(n))
