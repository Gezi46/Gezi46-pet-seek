# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 装配：包围盒与校准、腿部方块校正、动画扫描、待机合成、眨眼叠加层 ——
## 也就是"把模型改造成能用的样子"（由 desktop_pet.gd preload 为 PetRig）。
##
## 2026-09-23 按作业单 B3 拆过两次，**量**和**贴图修整**各自独立成模块：
##   `pet_rig_stats.gd`  动作采样与计时（动作真正做到哪一刻、因此该计多长）
##   `pet_rig_tex.gd`    贴图/材质修整（消白边、消棱边锯齿、图集边缘外扩）
##
## 方法名保留主脚本时代的下划线命名：主脚本留同名门面逐字转发，
## 探针（_play_action / _action_time / _play / _blink）打的就是那层门面。

const BLINK_NAMES: Array[String] = ["BlinkEye", "BlinkTwo"]
## 持续动作：播完要无缝接回自己，所以必须循环。
## 不循环的话动画播完会停在最后一帧 —— "走路/跑步走到一半突然定住"就是这么来的
## （模型导出的动画默认是 LOOP_NONE）。
const LOOPING_ANIMS: Array[String] = [
	"idle", "walk", "run", "walkBack", "sneak", "sit", "sleep",
	"climb", "swim", "fly", "ride", "boat", "elytra_fly",
	"ladder_up", "ladder_down", "ladder_stillness",
]
## 动作采样与计时在 **pet_rig_stats.gd**（作业单 B3.1）；贴图/材质修整在
## **pet_rig_tex.gd**（B3.2）。两个模块都是 **static**，宿主节点当参数传进去
const RigStats := preload("res://scripts/body/rig/pet_rig_stats.gd")
const RigTex := preload("res://scripts/body/rig/pet_rig_tex.gd")
## 判断"方块是否长在模型另一半"的 x 阈值（模型中线在 x=0）
const CROSSED_LEG_X := 0.03
## 角色包围盒缓存多少帧刷新一次。
## 悬停检测和可点区域每帧都要这个盒子，但它变化很慢（只是呼吸/走路），
## 而算一次要遍历 567 个 MeshInstance3D —— 这是 `_process` 里唯一的每帧大头。
const AABB_REFRESH_FRAMES := 3

## 宿主（桌宠根节点）：读它的检查器参数 / 动画节点 / 内部状态
var pet: Node3D = null


func setup(pet_node: Node3D) -> void:
	pet = pet_node


# ------------------------------------------------------------------ 包围盒 / 校准

## 角色包围盒的节流缓存入口：每帧都会被悬停检测和可点区域调用，
## 而盒子变化很慢（只是呼吸/走路），所以按 AABB_REFRESH_FRAMES 帧才算一次。
## 需要"每次都必须是最新值"的调用方（`_calibrate()` 会手动逐帧推进动画采样）
## 请直接调 `_compute_model_aabb()`。
func _raw_model_aabb() -> AABB:
	var frame := Engine.get_process_frames()
	if pet._aabb_frame >= 0 and frame - pet._aabb_frame < AABB_REFRESH_FRAMES:
		return pet._aabb_cache
	pet._aabb_cache = _compute_model_aabb()
	pet._aabb_frame = frame
	return pet._aabb_cache

## 实际计算角色在模型本地空间里占用的范围。
## 关键：动画驱动的是 mesh 的**祖先**节点（Root/MAllBody 等），所以必须用
## global_transform；用 mi.transform（相对父节点）永远只能量到静止姿势。
##
## 用 `Transform3D * AABB` 交给 C++ 算，而不是自己循环 8 个端点 ——
## `_calibrate()` 启动时要把 10 个动画逐帧采样几百次，567 个 mesh × 8 个端点
## 全在 GDScript 里做是启动卡顿的主要来源。
## 代价是旋转过的盒子会略微变大（AABB 变换的固有性质），反正这里本来就在做合并。
func _compute_model_aabb() -> AABB:
	var to_local: Transform3D = pet._model.global_transform.affine_inverse()
	var first := true
	var out := AABB()
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			var box: AABB = to_local * (mi.global_transform * mi.get_aabb())
			out = box if first else out.merge(box)
			first = false
	return out

## 逐个播一段代表性动画并采样包围盒。两个坑：
##   1. 不能用 AnimationPlayer.seek() 采样——seek 不会立刻刷新 3D 变换，
##      量出来永远是静止姿势；必须让动画真正跑起来、跨帧采样。
##   2. 个别动画（趴下、游泳、死亡）会把角色挪很远，直接取并集机位会被拉飞，
##      所以横向用中位数盒，落地高度只看待机动画。
func _calibrate() -> void:
	var probes: Array[String] = []
	for n in [pet._idle_anim, "walk", "run", "jump", "sit", "sleep", "extra0", "extra7", "swim", "climb"]:
		if pet._has.has(n) and not probes.has(n):
			probes.append(n)

	if probes.is_empty():
		pet._calib_aabb = _compute_model_aabb()
		pet._calibrated = true
		return

	var boxes: Array[AABB] = []
	var idle_box := AABB()
	var have_idle := false
	for name in probes:
		pet._anim.play(name)
		var frames: int = clampi(int(pet._anim.current_animation_length * 30.0), 4, 45)
		var acc := _compute_model_aabb()
		for i in frames:
			pet._anim.advance(1.0 / 30.0)
			acc = acc.merge(_compute_model_aabb())
		boxes.append(acc)
		if name == pet._idle_anim:
			idle_box = acc
			have_idle = true
	pet._anim.stop()
	if not have_idle:
		idle_box = boxes[0]

	var sorted := boxes.duplicate()
	sorted.sort_custom(func(a: AABB, b: AABB) -> bool: return a.size.y < b.size.y)
	var median: AABB = sorted[sorted.size() / 2]

	# 横向取中位数（避免被跑偏的动画拽走），纵向用中位数身高（保证头脚都不裁），
	# 落地高度只用待机动画（避免待机时浮在阴影上方）。
	pet._calib_aabb = median
	pet._calib_aabb.position.y = idle_box.position.y
	pet._calib_aabb.size.y = median.position.y + median.size.y - idle_box.position.y
	pet._calibrated = true

	if OS.is_debug_build():
		print("[PetDeek] 采样 %d 个动画 -> 包围盒 %s（待机最低点 %.4f）" % [
			probes.size(), pet._calib_aabb, idle_box.position.y])

# ------------------------------------------------------------------ 动画工具

func _scan_animations() -> void:
	pet._has.clear()
	var lib: AnimationLibrary = pet._anim.get_animation_library("")
	if lib != null:
		for n in lib.get_animation_list():
			pet._has[String(n)] = true

	# 表情叠加层：眨眼只驱动眼睛/眉毛，放在第二个 player 就不会和身体抢轨道
	pet._anim_face = AnimationPlayer.new()
	pet._anim_face.name = "AnimationPlayer2"
	pet._model.add_child(pet._anim_face)
	var face_lib := AnimationLibrary.new()
	if lib != null:
		for n in BLINK_NAMES:
			if lib.has_animation(n):
				face_lib.add_animation(n, _strip_to_face(lib.get_animation(n)))
	# AnimationPlayer 需要一个存在的默认动画，否则 play() 会报错
	var rest := Animation.new()
	rest.length = 0.1
	face_lib.add_animation("idle_face", rest)
	pet._anim_face.add_animation_library("", face_lib)
	pet._anim_face.play("idle_face")
	pet._anim_face.animation_finished.connect(_on_face_finished)

## 眨眼动画实际覆盖了全身（实测 BlinkEye/BlinkTwo 各 39 条轨道，从 Root 到四肢，
## 和 walk 的轨道集合一样），只是身体部分的键值恰好是站立姿势。
## 原样放进叠加层的话，叠加层在树里排在主 player 后面、同节点冲突它赢：
## 眨眼那 0.7~1.1 秒全身被钉成站立姿势 —— 走路中触发就是
## "突然变成静止动画，窗口还在平移"（两层自愈看不见它：主 player 确实还在播 walk）。
## 所以拷进叠加层时只保留 "/Face/" 下的轨道（眼皮 / 眉毛 / wink），
## 身体继续由主 player 驱动。必须 duplicate 再裁，否则会把主库里的共享资源也裁掉。
func _strip_to_face(src: Animation) -> Animation:
	var out: Animation = src.duplicate(true)
	for i in range(out.get_track_count() - 1, -1, -1):
		if not String(out.track_get_path(i)).contains("/Face/"):
			out.remove_track(i)
	return out

## 贴图/材质修整（消白边、消棱边锯齿、边缘外扩）全在 **pet_rig_tex.gd** ——
## 作业单 B3.2 搬的：B3.1 之后复核，剩下这两套机制只关贴图，和"装配"是两件事。
## 每一条注释背后都有一个量出来的现象，所以整段搬走、一字没改。
## 下面两个壳留着（desktop_pet 的 setup 就是按这个顺序调它们）
func _harden_materials() -> void:
	RigTex.harden_materials(pet)

func _inset_uvs() -> void:
	RigTex.inset_uvs(pet)

## 模型有个毛病：左腿的三个骨骼下各混进了 1 块其实长在右腿上的方块
## （它们相对模型的 x 是正的，而左腿在 x 负侧）。静止时看着还正常，
## 一动就露馅 —— 方块跟着左腿摆、人却在右腿那边，也就是"左脚的部分方块
## 跟着另一只脚走"。
##
## 处理方式：**只挪，不删。** 把它移到视觉上所属的那条腿的骨骼下，同时保持世界变换，
## 所以静止姿势和原模型一模一样，被修正的只有"跟随哪条腿"。
##
## 为什么不能删：这里曾经做过"另一侧已经有原点几乎重合的方块，就当成重复件删掉"，
## 结果把左鞋连鞋带一起削掉了 —— 那两块方块**原点相同但尺寸不同**
## （一块是鞋帮外壳、一块是里面更小的件），只比原点必然误判成重复。
## 外壳被删后袜子从缺口里透出来，表现就是"袜子盖住鞋面 / 鞋带消失 / 鞋变梯形"。
## 而模型本身在编辑器里看着是对的，说明该保留的是**两块都留**、只改父子关系。
func _fix_crossed_leg_parts() -> void:
	var pairs := [
		["LeftLeg", "RightLeg"],
		["LeftLowerLeg", "RightLowerLeg"],
		["LeftFoot", "RightFoot"],
	]
	var moved := 0
	var to_local: Transform3D = pet._model.global_transform.affine_inverse()
	for p in pairs:
		var from_bone: Node3D = _find_leg_bone(p[0])
		var to_bone: Node3D = _find_leg_bone(p[1])
		if from_bone == null or to_bone == null:
			continue
		# get_children() 给的是副本，循环里 remove_child 不会打乱遍历
		for child in from_bone.get_children():
			if not (child is MeshInstance3D):
				continue
			var item: Node3D = child
			var here: Vector3 = to_local * item.global_position
			if here.x < CROSSED_LEG_X:
				continue
			var keep: Transform3D = item.global_transform
			if OS.is_debug_build():
				# 顺带打出尺寸：原点重合的两块方块尺寸可能差很多（实测左鞋外壳 0.208 宽，
				# 脚下那块只有 0.068），只比原点必然误判成"重复件"。
				var mine: Vector3 = (item.global_transform * item.get_aabb()).size
				print("  挪动 %s：尺寸 %.3f×%.3f×%.3f" % [item.name, mine.x, mine.y, mine.z])
			from_bone.remove_child(item)
			to_bone.add_child(item)
			item.global_transform = keep
			moved += 1

	if OS.is_debug_build():
		print("[PetDeek] 腿部方块校正：移动 %d 块（不删除任何方块）" % moved)

## 找"某条腿"的骨骼节点。两个坑：
##   1. Godot 导入 glb 时会给重名节点加数字后缀，骨骼实际叫 LeftLeg9 / LeftFoot13
##      这种名字，所以只能用前缀匹配；
##   2. 方块节点也叫 LeftLeg4 / LeftFoot4，但它们是叶子（没有方块子节点），
##      用"直接挂着 MeshInstance3D"就能把它们排除掉。
func _find_leg_bone(bone_prefix: String) -> Node3D:
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not String(n.name).begins_with(bone_prefix):
			continue
		for c in n.get_children():
			if c is MeshInstance3D:
				return n as Node3D
	return null

## 动画整体放慢：主体和表情叠加层共用一个倍率。
## 注意走路的位移速度也要跟着缩放（见 _begin_move），否则步频变慢后脚底会打滑。
func _apply_anim_speed() -> void:
	pet._anim.speed_scale = pet.anim_speed
	if pet._anim_face != null:
		pet._anim_face.speed_scale = pet.anim_speed

## 把"一次小动作之后隔多久回待机"的时长换算成放慢后的真实时长。
## 动作本身变慢了，等待时间也得同比拉长，否则动作还没播完就被打断。
func _beat(t: float) -> float:
	return t / maxf(pet.anim_speed, 0.01)

## 播放一次性的动作（挥手 / 表情 / 跳跃 / 喂食 / 被打），并把"多久之后才允许
## 考虑下一步"设成**动画自身的长度**，而不是写死的估计值。
##
## 之前这里是 `_timer = _beat(0.6)` 这种手写数字。一旦动作动画比这个估计值长，
## 计时器先到期，就会在动画播到一半时切走 —— 表现就是"某些动画卡在中间某一帧"。
func _play_action(name: String, blend: float = 0.15, extra: float = 0.35) -> void:
	_play(name, blend)
	pet._timer = _action_time(name, extra)

## 动作计多长 / 量"动作真正做到哪一刻"，实现在 **pet_rig_stats.gd**（作业单 B3.1）。
## 这两个壳留着，是因为宿主的门面（desktop_pet._action_time）和探针打的就是它们
func _action_time(name: String, extra: float = 0.35) -> float:
	return RigStats.action_time(pet, name, extra)

## 逐个量出一次性动作"真正做到哪一刻"（结果写进 pet._action_end）。
## 判据、阈值、以及"为什么不能按全长计时"都在 **pet_rig_stats.gd**（作业单 B3.1）
func _measure_action_ends() -> void:
	RigStats.measure_action_ends(pet)

func _pick(names: Array, fallback: String) -> String:
	var pool: Array[String] = []
	for n in names:
		if pet._has.has(n):
			pool.append(String(n))
	if pool.is_empty():
		return fallback
	return pool[pet._rng.randi_range(0, pool.size() - 1)]

## 把 idle 和 MainAnim 叠成一个待机动画：MainAnim 原本是 24 秒的呼吸摆动，
## 压到 idle 的周期上，两条循环就对齐了。互不冲突的轨道才会被合并。
func _build_idle_anim() -> void:
	if not pet._has.has("MainAnim") or not pet._has.has("idle"):
		pet._idle_anim = "idle" if pet._has.has("idle") else "MainAnim"
		return

	var lib: AnimationLibrary = pet._anim.get_animation_library("")
	var a: Animation = lib.get_animation("idle")
	var b: Animation = lib.get_animation("MainAnim")
	if a == null or b == null:
		return

	var out := Animation.new()
	# 待机用 **MainAnim**（那个"微微晃动的站着不动"，2026-10-01 用户要求）——
	# 所以长度取 MainAnim 的，且 MainAnim 优先占轨道；idle 只补它没有的轨道
	out.length = b.length
	out.loop_mode = Animation.LOOP_LINEAR
	var rate: float = a.length / maxf(b.length, 0.001)

	var used: Dictionary = {}
	_absorb(out, b, 1.0, used)      # MainAnim 优先
	_absorb(out, a, rate, used)     # idle 补缺

	var merged := "__pet_idle"
	if lib.has_animation(merged):
		lib.remove_animation(merged)
	lib.add_animation(merged, out)
	pet._has[merged] = true
	pet._idle_anim = merged

func _absorb(dst: Animation, src: Animation, time_scale: float, used: Dictionary) -> void:
	for i in src.get_track_count():
		var path: NodePath = src.track_get_path(i)
		var kind: int = src.track_get_type(i)
		var sig := "%s|%d" % [String(path), kind]
		if used.has(sig):
			continue                        # 这条轨道已被占用，跳过避免打架
		used[sig] = true

		var t: int = dst.add_track(kind)
		dst.track_set_path(t, path)
		dst.track_set_interpolation_type(t, src.track_get_interpolation_type(i))
		var keys: int = src.track_get_key_count(i)
		for k in keys:
			dst.track_insert_key(
				t,
				src.track_get_key_time(i, k) * time_scale,
				src.track_get_key_value(i, k),
				src.track_get_key_transition(i, k))

## 给"持续动作"打开循环，否则动画播完会停在最后一帧。
## 导出 glb 里的动画 loop_mode 默认是 LOOP_NONE，走路/跑步靠着它循环起来。
func _apply_loop_modes() -> void:
	var lib: AnimationLibrary = pet._anim.get_animation_library("")
	if lib == null:
		return
	var n := 0
	for name in LOOPING_ANIMS:
		if lib.has_animation(name):
			var a: Animation = lib.get_animation(name)
			if a != null and a.loop_mode != Animation.LOOP_LINEAR:
				a.loop_mode = Animation.LOOP_LINEAR
				n += 1
	# 运行时合并出来的待机也是循环的
	if lib.has_animation("__pet_idle"):
		var idle_a: Animation = lib.get_animation("__pet_idle")
		if idle_a != null:
			idle_a.loop_mode = Animation.LOOP_LINEAR
			n += 1
	if OS.is_debug_build():
		print("[PetDeek] 设为循环的动画：%d 个" % n)

func _play(name: String, blend: float = 0.15) -> void:
	if not pet._has.has(name):
		if OS.is_debug_build():
			print("[PetDeek] _play 跳过：没有动画 %s" % name)
		return
	if pet._anim.current_animation == name:
		if OS.is_debug_build():
			print("[PetDeek] _play 跳过：已经在播 %s" % name)
		return
	pet._anim.play(name, blend)

func _blink() -> void:
	var n := _pick(BLINK_NAMES, "")
	if n != "":
		pet._anim_face.play(n, 0.05)

func _update_idle_face() -> void:
	if pet._state == pet.State.SLEEP:
		return
	if pet._anim_face.current_animation == "idle_face" and pet._rng.randf() < pet.blink_chance / pet.blink_slowdown:
		_blink()

func _on_face_finished(_n: String) -> void:
	pet._anim_face.play("idle_face")

func _on_main_finished(name: String) -> void:
	# 一次性动作播完就回到待机；拖动时不要插手
	if pet._state == pet.State.DRAG:
		return
	if name == pet._idle_anim:
		return
	if pet._state == pet.State.WALK:
		# 正常情况下 walk/run 是循环动画（_apply_loop_modes 设的），永远不会 finished。
		# 走路中收到 finished，说明这个动画的循环丢了 —— 不补一手的话，
		# 它会僵在最后一帧，而窗口还在按 WALK 平移，看起来就是
		# "走着走着突然变成静止姿势在滑行"。
		if (name == "walk" or name == "run") and pet._has.has(name):
			var a: Animation = pet._anim.get_animation(name)
			if a != null:
				if a.loop_mode != Animation.LOOP_LINEAR:
					a.loop_mode = Animation.LOOP_LINEAR
				pet._anim.play(name, 0.0)
		return
	pet._anim.play(pet._idle_anim, 0.2)

## 走路时的动画自愈：只要还处于 WALK，动画就必须是 walk/run。
## "人还在滑、动画却是静止的"这类毛病（历史上有 _state 卡在 DRAG 的坑）不管根因是什么，
## 在这里都能兜住 —— 动画不对就立刻纠正，debug 构建会留一条记录便于追查是谁改的。
func _ensure_walk_anim() -> void:
	if pet._state != pet.State.WALK:
		return
	var want := "run" if (pet._run and pet._has.has("run")) else "walk"
	if pet._anim.current_animation == want:
		return
	if OS.is_debug_build():
		print("[PetDeek] 走路中动画跑偏（当前=%s，应为 %s），已纠正" % [
			pet._anim.current_animation, want])
	pet._anim.play(want, 0.2)
