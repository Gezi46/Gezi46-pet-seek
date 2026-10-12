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
## 启动那两趟采样的预烘焙缓存（阶段 5，2026-10-09）——
## 它就是上面"采 10 个动画 × 567 个网格"那一步的速取通道 ✓
const RigCache := preload("res://scripts/body/rig/pet_rig_cache.gd")
## 判断"方块是否长在模型另一半"的 x 阈值（模型中线在 x=0）
const CROSSED_LEG_X := 0.03
## 判"方块和它挂的骨头分居两侧"时的死区：任意一头离中线比它近，就不算跨侧。
## 0.06 是量出来的（2026-10-08）：再小就会把中线附近那些正常的交界方块也卷进来
const CROSSED_SIDE_MIN := 0.06
## 找镜像骨头的位置容差。模型左右对称，(-x, y, z) 那根就是镜像；
## 容差给 0.03 是因为导入后的骨骼原点未必严丝合缝（量到的是 0.269 / -0.269 这种）
const CROSSED_MIRROR_TOL := 0.03
## 位置匹配失败后，按名字找对侧时的距离上限。模型左右**并不严格对称**：
## 帽子两角的骨差 0.12（实测），所以这里放到 0.25 —— 反正名字那一关（共同片段 ≥6 字）
## 已经够严，距离只是防它跨到别的部位去
const CROSSED_NAME_TOL := 0.25
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
	# 阶段 5（2026-10-09）：先试预烘焙缓存 —— 命中就整趟不跑 ✓
	# 这是启动最贵的一步（10 个动画 × 最多 45 帧 × 567 个网格），
	# 而它的输入只有模型几何 + 动画内容 + 阈值常量 → 结果可复用 ✓（判据见 pet_rig_cache.gd 头部）
	if RigCache.load_calib(pet):
		return
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
	# 采完了才写盘 ✓（命中那次根本走不到这里 ✓）
	RigCache.save_calib(pet)

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
	# ── 2026-10-08 试过"按名字修左右挂反"，**结论：不能用** ✗，留个记录免得重走 ──────────
	# 起因：真机截图里鞋上那块白色方块看着是斜的，探针量出 `LeftFoot4` 挂在 `RightFoot11` 下，
	# 于是按名字把它挪回 `LeftFoot13`。结果三条通道互相打架 ✗：
	#     位置判据（腿）→ 挪到 RightFoot11（正确）
	#     名字判据（我加的）→ 挪回 LeftFoot13（错）
	#     位置判据（跨侧）→ 又挪回 RightFoot11（正确）
	# 根因：**这个模型的左右命名本身就不可信** —— `LeftFoot4` 实际坐在 x=+0.119（右侧）✗，
	# 而耳朵 / HairSide 那一族又是"Right 在负侧"✗ —— 两族方向还相反，一条通吃两族的
	# 名字判据必然搞错一边 ✓。所以**只保留位置判据**，名字只用来打日志 ✓
	# （相关辅助 `_all_meshes` / `_find_bone_core` 也跟着删了）

	# 这里其实是"几何修整"这条链的总入口（函数名是历史原因只提了腿）：
	# 上面那条判据是"方块在模型的 x 正侧才算挂错"，可鞋舌那种**贴着中线**的块
	# （|x| < CROSSED_LEG_X = 0.03）会被它直接跳过 ✗。
	# 真机证据：鞋子上那块白色方块看着是斜的（正方形变梯形）→ 探针量出来
	# **`LeftFoot4` 挂在 `RightFoot11` 下** ✗ —— 静止时位置是对的（世界变换保持），
	# 可脚一动它就跟着**对面那只脚**转，一转到斜角，方块看起来就不再是正方形 ✓
	#
	# 这一族（Left/Right 名字把左右写死了的：LeftFoot4 / RightLowerLeg…）**只按名字修就够了** ✓
	# —— 脚和腿的命名是可信的（Left = x 负侧 ✓），不像 ears / HairSide 那族是反的 ✗
	# 这里其实是"几何修整"这条链的总入口（函数名是历史原因只提了腿）：
	#   腿 → 左右挂反（按名字）→ 跨侧件 → 裙摆外扩
	# 都合在这里调，两个宿主（桌面 / 手机）都不用改
	_fix_crossed_parts()
	_expand_skirt()

## 除了腿，还有一批"方块挂在对面骨头下"的同类问题（2026-10-08 探针查出来，共 22 块 ✗）：
##   corner_h12x~14x（16 块）挂在 corner_h151（x=+0.269）下，方块却在 x=-0.07~-0.27
##   CollarSide5/8/9 挂在 CollarSide10（-0.097）下，方块却在 +0.087~+0.113
##   MoreMoreUpperBody3/6/7 挂在 MoreMoreUpperBody12（-0.175）下，方块却在 +0.165~+0.216
##
## **判据不能用骨骼名**：这个模型里 ears / HairSide / Cornor 系列的 Right 骨**本来就长在
## x 负侧**（命名约定和腿相反 —— 拿名字判会误报 306 块 ✗，实测过）。只能用位置：
## **方块中心和它挂的骨头跨过了 x=0** 才算挂错。
##
## 为什么静止时看不出来：骨头的静止变换就是单位阵，方块挂谁下面都还在原地 ✓；
## 可骨头一动，方块就绕着**身体另一侧的支点**摆 —— 表现就是"衣服穿模 / 方块飞出去"。
##
## 修法和腿那条一样：**只挪不删**，并保持世界变换（静止姿势一个字不变，变的只是"跟着哪根骨头"）。
## 镜像骨头按**位置**找：模型左右对称，(-x, y, z) 那根就是。
func _fix_crossed_parts() -> void:
	var to_local: Transform3D = pet._model.global_transform.affine_inverse()
	var meshes: Array[MeshInstance3D] = []
	var bones: Array[Node3D] = []
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			meshes.append(n)
		elif n is Node3D and n != pet._model:
			bones.append(n)
	var moved := 0
	var no_mirror := 0
	var dups := 0
	for mi in meshes:
		var par := mi.get_parent() as Node3D
		if par == null:
			continue
		var box: AABB = to_local * (mi.global_transform * mi.get_aabb())
		var mcx: float = box.position.x + box.size.x * 0.5
		var porigin: Vector3 = to_local * par.global_transform.origin
		# 任意一头贴中线 → 不算跨侧（交界处那些方块本来就该在这儿）
		if absf(porigin.x) < CROSSED_SIDE_MIN or absf(mcx) < CROSSED_SIDE_MIN:
			continue
		if porigin.x * mcx > 0.0:
			continue                    # 同一侧：没问题
		var target: Node3D = _find_mirror_bone(bones, porigin, par, to_local)
		if target == null:
			# 位置凑不上时的退路：按**名字里的共同词**找对侧那根（见 _find_mirror_bone_by_name）
			target = _find_mirror_bone_by_name(bones, porigin, par, to_local)
		if target == null:
			no_mirror += 1
			continue                    # 找不到就对侧压根没有同类骨：原样留着，宁可不动也别挪错
		# 目标骨下已有"位置 + 尺寸都对得上"的同款 → 那是重复件，挪过去只会叠出 z-fighting
		if _has_duplicate_under(target, box.position + box.size * 0.5, box.size, to_local):
			dups += 1
			continue
		if OS.is_debug_build():
			print("  跨侧方块 %s：x=%+.3f ｜ %s → %s" % [mi.name, mcx, par.name, target.name])
		var keep: Transform3D = mi.global_transform
		par.remove_child(mi)
		target.add_child(mi)
		mi.global_transform = keep
		moved += 1
	if OS.is_debug_build():
		print("[PetDeek] 跨侧方块校正：移动 %d 块（%d 块对侧没有同类骨、%d 块是对侧已有的重复件；只挪不删）" % [
			moved, no_mirror, dups])

## 位置凑不上时的退路：在对侧找一根**名字里有共同词**的骨头。
##
## 为什么需要它（2026-10-08 实测）：这个模型的左右**并不严格对称** —— 帽子两个角，
## `corner_h151` 在 +0.269，对侧那根 `LeftCorner16` 在 -0.343（差 0.12），
## 纯位置匹配永远够不着；但两个名字里都带 "corner" ✓。
## 反过来，领子那 3 块（`CollarSide10`）在对侧压根没有同类骨 —— 名字比对找不到 → 保持原样 ✓
## （这正是我要的：宁可不动，也别把领子错配到 Ribbon 上）
func _find_mirror_bone_by_name(bones: Array[Node3D], origin: Vector3, exclude: Node3D,
		to_local: Transform3D) -> Node3D:
	var key := _name_core(String(exclude.name))
	if key.length() < 6:
		return null
	var best: Node3D = null
	var best_d := CROSSED_NAME_TOL
	for b in bones:
		if b == exclude:
			continue
		var o: Vector3 = to_local * b.global_transform.origin
		if o.x * origin.x > 0.0 or absf(o.x) < CROSSED_SIDE_MIN:
			continue                    # 必须真在对侧
		if not _shares_token(_name_core(String(b.name)), key):
			continue
		var d: float = absf(o.x + origin.x) + absf(o.y - origin.y) + absf(o.z - origin.z)
		if d < best_d:
			best_d = d
			best = b
	return best

## 名字的"字母骨架"：砍掉所有数字。Godot 导入 glb 时会给重名节点加数字后缀
## （LeftLeg9 / LeftCorner16 就是这么来的，见 _find_leg_bone），比名字必须先剥掉它们
func _name_core(n: String) -> String:
	var out := ""
	for i in n.length():
		var c := n[i]
		if c >= "0" and c <= "9":
			continue
		out += c
	return out.to_lower()

## 两个名字有没有 ≥6 个字符的共同片段（大小写不敏感）。
## 取 6 是因为实测要能认出 corner_h ↔ LeftCorner（共同片段 "corner" 正好 6），
## 而 3~4 个字符的重合太容易误配（一堆 bone / side / hair）
func _shares_token(a: String, b: String) -> bool:
	if a.length() < 6 or b.length() < 6:
		return false
	for i in range(0, b.length() - 5):
		if a.find(b.substr(i, 6)) >= 0:
			return true
	return false

## 目标骨下是不是已经有"位置 + 尺寸都对得上"的同款方块 —— 有就说明这是对侧已有的重复件，
## 再挪过去只会两块重叠（z-fighting）。
##
## **判据必须是中心 + 尺寸一起比，不能只比原点**：这个工程踩过 —— 只比原点会把
## 鞋帮外壳和它里面更小的件当成重复，删错一次左鞋连鞋带一起没了。
## 这里比的是"中心距离 + 尺寸距离"都 < 0.005，够严
func _has_duplicate_under(target: Node3D, center: Vector3, size: Vector3,
		to_local: Transform3D) -> bool:
	for c in target.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi: MeshInstance3D = c
		var b: AABB = to_local * (mi.global_transform * mi.get_aabb())
		if (b.position + b.size * 0.5).distance_to(center) < 0.005 \
				and b.size.distance_to(size) < 0.005:
			return true
	return false

## 裙摆外扩（2026-10-08，用户要求"裙子穿模有点严重，往外扩一扩"）。
##
## 现象：裙子那圈裙板和她的腿/胯在空间上是**互相插着**的（实测裙板 × 腿件重叠 105 对），
## 近景一看腿就从裙面里捅出来 ✗。
##
## ⚠️ **第一版是错的，而且错得很难看** ✗ —— 第一版对 global_transform 乘了一个
## **世界空间的水平缩放** Basis.scaled(k,1,k)，想着"整圈裙摆一起外扩"。
## 结果：这些裙板是**绕圈斜着摆**的（每块朝向都不同，实测同骨下各块 Z 角 28.9° / 73.9° /
## -36.1°…），而**世界空间的非等比缩放作用在旋转过的基上就是剪切** ——
## 板子被拉成平行四边形，贴图边缘变成斜线，看着完全就是"裙子建模坏了 / 穿模" ✗。
## 实测：50/50 块全被剪切（基向量归一化后互点积最大 0.107），关掉外扩后 0/50 ✓。
##
## ✅ 现在只做两件**不产生剪切**的操作：
##   ① 沿板子**自身轴等比放大**（`mi.scale *= grow`）—— 等比缩放与旋转可交换，
##      不会把斜板子拉歪（世界空间的非等比缩放才会）；
##   ② 沿**径向平移**（`mi.global_position += radial * push * t`）—— 平移只改原点、
##      **不改基向量**，所以也不歪。
##   推的力度按"离腰多高"给（t：腰 0 → 摆 1），所以**裙腰贴着身体不动、越往下越往外张** ✓，
##   而不是把整圈平推出去（那样腰部会离开身体，露出一圈缝 ✗）。
##
## 为什么不改模型文件：模型是游戏原版导出的 glb，改了以后换版本要重做一遍；
## 这里是运行时补偿，参数挂在宿主上（`skirt_expand`，1.0 = 关闭），随时能调、能对比。
func _expand_skirt() -> void:
	var k: float = pet.skirt_expand
	if is_equal_approx(k, 1.0):
		return
	var model: Node3D = pet._model
	var to_model: Transform3D = model.global_transform.affine_inverse()
	var grow: float = 1.0 + (k - 1.0) * 0.5      # 自身轴等比放大，温和一点
	var push: float = (k - 1.0) * 0.35           # 径向推出去的总距离（模型单位）
	var waist_y := 1.45                          # 裙腰 / 裙摆高度（实测：顶部 1.4~1.45，下摆 ~0.95）
	var hem_y := 0.95
	var n := 0
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for c in nd.get_children():
			stack.push_back(c)
		if not (nd is MeshInstance3D):
			continue
		var mi: MeshInstance3D = nd
		var par := mi.get_parent()
		# 裙板判据：父骨叫 SkirtBone*（这个模型里整条裙子都挂在它下面）
		if par == null or not String(par.name).begins_with("SkirtBone"):
			continue
		var box: AABB = to_model * (mi.global_transform * mi.get_aabb())
		var ctr: Vector3 = box.position + box.size * 0.5
		var radial := Vector3(ctr.x, 0.0, ctr.z)
		if radial.length() < 0.05:
			continue            # 贴着中线的块没有"径向"可言，不动它
		radial = radial.normalized()
		var t: float = clampf((waist_y - ctr.y) / (waist_y - hem_y), 0.0, 1.0)
		# ① 自身轴等比放大（不会歪）
		mi.scale *= grow
		# ② 径向平移（不会歪；`radial` 在模型空间，转成世界方向再加）
		mi.global_position += model.global_transform.basis * (radial * push * t)
		n += 1
	if OS.is_debug_build():
		print("[PetDeek] 裙摆外扩 ×%.3f：%d 块（自身轴等比 + 径向平移，两者都不产生剪切）" % [k, n])

## 找 origin 关于 x=0 的镜像骨头，取最近且近于 CROSSED_MIRROR_TOL 的那根。
## 名字不能用（见 _fix_crossed_parts 上面那段），只能比位置。
func _find_mirror_bone(bones: Array[Node3D], origin: Vector3, exclude: Node3D,
		to_local: Transform3D) -> Node3D:
	var best: Node3D = null
	var best_d := CROSSED_MIRROR_TOL
	for b in bones:
		if b == exclude:
			continue
		var o: Vector3 = to_local * b.global_transform.origin
		var d: float = absf(o.x + origin.x) + absf(o.y - origin.y) + absf(o.z - origin.z)
		if d < best_d:
			best_d = d
			best = b
	return best

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
	# 阶段 5：同上，第二贵的一步（13 个动作 × 32 次采样 × 64 个节点）✓
	if RigCache.load_action_ends(pet):
		return
	RigStats.measure_action_ends(pet)
	RigCache.save_action_ends(pet)

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
