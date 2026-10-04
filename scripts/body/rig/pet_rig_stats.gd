# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 动画的**采样与统计**：一个一次性动作"真正做到哪一刻"、因此该计多长。
##
## 从 pet_rig.gd 搬出来（作业单 B3.1）。为什么值得单独一个文件：
## 这是"**量**"，而 pet_rig 剩下的主要是"**装配**"（把模型改造成能用的样子）——
## 两件事的失败方式完全不同：装配错了是白边 / 错骨骼，量错了是"动作播一半被切走"。
## 而这里还自带一套阈值常量 + 一段方法论（见 measure_action_ends 的注释）。
##
## 全是 **static**，宿主节点当参数传进来（`pet` = 桌宠根节点，借它的 `_anim` / `_model` /
## `_has` / `_action_end`）。pet_rig.gd 留同名壳转发，所以调用点和探针不用改。
##
## 接口面：**读**宿主的动画节点与网格；**写**宿主的 `_action_end`（只写这一个字段）。
## 不碰文件、不碰网络、不发信号
extends RefCounted

## 一次性动作的候选：启动时逐个量"动作真正做到哪一刻"（见 measure_action_ends）
const ACTION_NAMES: Array[String] = [
	"jump", "swing_hand", "swing_offhand", "use_mainhand", "use_offhand", "attacked",
	"extra0", "extra2", "extra3", "extra4", "extra5", "extra6", "extra7",
]
## 判定"还在动"的绝对下限：单步位移小于它就算静止。模型高约 2.7，
## 0.015 相当于 1.5 厘米量级。
const ACTION_MOVE_EPS := 0.015
## 判定"还在动"的相对下限：单步位移还得超过本动作峰值位移的这个比例。
## 只有绝对下限的话，静止尾巴上那点回正残留会被当成还在动（实测只裁到 83%）。
const ACTION_MOVE_RATIO := 0.15
## 量到"最后在动的时刻"之后再留一点，别把动作的收势剪掉
const ACTION_TAIL := 0.25

## 动作动画按当前播放速度换算成真实时长，再留 extra 秒缓冲。
## 时长取**动作真正结束的时刻**（measure_action_ends 量出来的）而不是动画全长：
## extra 这类动画在手势做完之后会回到站立姿势空转一段，按全长算就会空等。
static func action_time(pet: Node3D, name: String, extra: float = 0.35) -> float:
	var length := 0.5
	if pet._has.has(name):
		var a: Animation = pet._anim.get_animation(name)
		if a != null:
			length = a.length
	if pet.action_tail_trim and pet._action_end.has(name):
		length = pet._action_end[name]
	return length / maxf(pet.anim_speed, 0.01) + extra

## 逐个量出一次性动作"动作真正做到哪一刻"，结果放进 pet._action_end。
##
## 为什么要这一趟：从 glb 里量出来的图标不同 —— 有些 extra 动画在手势做完后
## 会**回到站立姿势继续空转**（实测 extra0 只动到全长的 51%、extra2/3 到 67%、
## extra4 到 55%、extra5 只有 39%；extra6/extra7 则是全程 99%）。
## 按动画全长计时，那段时间就是"动作不动了、看起来回到静止动画"。
##
## 判据用"两帧之间动得最厉害的那个节点位移了多少"：平均值会被大量静止节点稀释，
## 取最大值才不会被漏掉（一个挥手只有几个节点在动）。
static func measure_action_ends(pet: Node3D) -> void:
	pet._action_end.clear()
	var meshes := sample_meshes(pet, 64)
	if meshes.is_empty():
		return
	var lib: AnimationLibrary = pet._anim.get_animation_library("")
	var saved_speed: float = pet._anim.speed_scale
	pet._anim.speed_scale = 1.0        # 按动画自身时间轴采样，不受整体放慢倍率影响
	for name in ACTION_NAMES:
		if not pet._has.has(name) or lib == null or not lib.has_animation(name):
			continue
		var a: Animation = lib.get_animation(name)
		if a == null or a.length <= 0.001:
			continue
		const SAMPLES := 32
		var step: float = a.length / float(SAMPLES)
		pet._anim.play(name)
		var prev := sample_positions(meshes)
		var peak := 0.0
		var moves: Array = []          # [进度, 该步最活跃节点的位移]
		for i in SAMPLES:
			pet._anim.advance(step)
			var cur := sample_positions(meshes)
			var mv := max_node_delta(cur, prev)
			peak = maxf(peak, mv)
			moves.append([pet._anim.current_animation_position, mv])
			prev = cur
		# 阈值同时受绝对下限和峰值约束：
		#   - 只用绝对下限，静止尾巴上那点"呼吸/回正"的残留晃动会被当成还在动（实测只裁到 83%）；
		#   - 只用峰值比例，遇到本来就很轻的动作会把整段都判成"没动"。
		var thr: float = maxf(ACTION_MOVE_EPS, peak * ACTION_MOVE_RATIO)
		var last_move := 0.0
		for m in moves:
			if m[1] >= thr:
				last_move = maxf(last_move, m[0])
		var end: float = clampf(last_move + ACTION_TAIL, 0.0, a.length)
		pet._action_end[name] = end
		if OS.is_debug_build():
			print("[PetDeek] %s：动作到 %.2fs / 全长 %.2fs（%.0f%%）" % [
				name, end, a.length, end / maxf(a.length, 0.001) * 100.0])
	pet._anim.stop()
	pet._anim.speed_scale = saved_speed

## 等间隔抽一批网格节点用来衡量动作幅度。
## 等间隔而不是"取前 N 个"：节点的排列大致是分部位的，取前面一串会整批落在同一个部位上。
static func sample_meshes(pet: Node3D, count: int) -> Array:
	var all: Array = []
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			all.append(n)
	if all.size() <= count:
		return all
	var out: Array = []
	var stride: float = float(all.size()) / float(count)
	for i in count:
		out.append(all[int(i * stride)])
	return out

static func sample_positions(meshes: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for m in meshes:
		out.append((m as Node3D).global_position)
	return out

## 两批采样之间"动得最厉害的那个节点"移动了多少
static func max_node_delta(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var best := 0.0
	for i in mini(a.size(), b.size()):
		best = maxf(best, a[i].distance_to(b[i]))
	return best
