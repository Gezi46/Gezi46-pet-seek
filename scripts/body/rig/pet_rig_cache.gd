## 启动那两趟采样的**预烘焙缓存**（阶段 5，2026-10-09）。
##
## 存的是什么：
##   `_calibrate()`            量出的 `pet._calib_aabb`（中位数盒 + 待机最低点）
##   `measure_action_ends()`   量出的 `pet._action_end`（13 个动作"真正到哪一刻"）
##
## 为什么能缓存（判据，不是想当然 ✓）：这两趟是**纯采样** ——
##   输入只有三样：**模型几何 + 动画内容 + 我们自己的阈值常量** ✓✓
##   不依赖运行时状态、不依赖用户操作、不依赖帧率 → 同一份模型 + 同一版代码，
##   结果**每次启动都一模一样** ✓（这也是"可缓存"的定义 ✓）。
##
## 为什么值得单独一个文件：它是启动耗时的大头 ✓（真机 526ms 里绝大部分在这里 ——
## `_calibrate` 要采 10 个动画 × 最多 45 帧 × 567 个网格 ✓）。
##
## 签名（判缓存还作不作数）只算**便宜**的那几样 ✓：
##   网格数、面数、逐网格 AABB 的粗哈希、动画名与时长之和、加一个 VERSION。
##   ⚠️ **别把逐顶点数据放进来** ✗：取它要 `surface_get_arrays()` 逐个走一遍，
##      那本身就接近采样一条动画的价钱 —— 等于白缓存 ✗（想清楚才这么写的 ✓）。
##   ⚠️ **采样口径一改就要把 VERSION + 1** ✗，否则老缓存会被当成有效，
##      表现成"代码改了却没生效" ✗ —— 这个坑最难查，别省这一步 ✓。
##
## 命中/未命中：
##   命中  → 直接塞回宿主字段，整趟采样**一次都不跑** ✓（连动画播放器都不碰 ✓）
##   未命中 / 文件不存在 / 版本或签名不符 / 内容缺损 → 老实采一遍，**采完才写盘** ✓
## 也就是说：写盘只发生在未命中那一次 ✓，之后每次启动都是只读 ✓。
##
## 放哪：`user://rig_bake.cfg`（ConfigFile，和 pet_mood.cfg 同一套习惯 ✓）。
## 手机上是应用私有目录 ✓ —— 装包 / 清数据后会丢，那一次重新采 ✓ 属正常 ✓。
extends RefCounted

const FILE := "user://rig_bake.cfg"
## 采样口径版本。`_calibrate` / `measure_action_ends` / `ACTION_*` 那几个阈值常量
## 只要有改动，就必须 +1 ✗（见头部那条最难的坑 ✓）
const VERSION := 1

static var _sig := ""
static var _sig_ready := false


## 本次启动的签名（只算一次 ✓）。够便宜：只读网格自身的 AABB 与动画表，不碰逐顶点数据 ✓
static func signature(pet: Node3D) -> String:
	if _sig_ready:
		return _sig
	var mesh_n := 0
	var face_n := 0
	var geo := 0
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			mesh_n += 1
			face_n += mi.mesh.get_surface_count()
			var b: AABB = mi.mesh.get_aabb()
			geo += int(round((b.position.x + b.position.y + b.position.z
					+ b.size.x + b.size.y + b.size.z) * 1000.0))
	var anim_n := 0
	var anim_sum := 0
	var lib: AnimationLibrary = pet._anim.get_animation_library("")
	if lib != null:
		var names := lib.get_animation_list()
		anim_n = names.size()
		for nm in names:
			anim_sum += String(nm).hash()
			var a: Animation = lib.get_animation(nm)
			if a != null:
				anim_sum += int(round(a.length * 100.0))
	_sig = "%d|m%d|f%d|g%d|a%d|s%d" % [VERSION, mesh_n, face_n, geo, anim_n, anim_sum]
	_sig_ready = true
	return _sig


## 读盘并核对签名。任何一步不对都返回 null ✓（调用方只管看结果 ✓，不用管到底是哪种失配 ✓）
static func _read(pet: Node3D) -> ConfigFile:
	var cf := ConfigFile.new()
	if cf.load(FILE) != OK:
		return null
	if String(cf.get_value("rig", "sig", "")) != signature(pet):
		return null
	return cf


## 写盘。⚠️ 签名变了就**整份作废重建** ✗ ——
## 否则会把上一版模型留下的另一半留在文件里，签上新的名，下次启动就被当成有效 ✗✗
static func _write(pet: Node3D, values: Dictionary) -> void:
	var cf := ConfigFile.new()
	cf.load(FILE)
	if String(cf.get_value("rig", "sig", "")) != signature(pet):
		cf = ConfigFile.new()
	cf.set_value("rig", "sig", signature(pet))
	for k in values.keys():
		cf.set_value("rig", String(k), values[k])
	cf.save(FILE)


# ------------------------------------------------------------------ 包围盒

static func load_calib(pet: Node3D) -> bool:
	var cf := _read(pet)
	if cf == null:
		return false
	var v: Variant = cf.get_value("rig", "calib", null)
	if not (v is Array) or (v as Array).size() != 6:
		return false
	var a: Array = v
	pet._calib_aabb = AABB(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]))
	pet._calibrated = true
	if OS.is_debug_build():
		print("[PetDeek] 启动数据命中缓存：包围盒 %s" % pet._calib_aabb)
	return true


static func save_calib(pet: Node3D) -> void:
	var b: AABB = pet._calib_aabb
	_write(pet, {"calib": [b.position.x, b.position.y, b.position.z,
			b.size.x, b.size.y, b.size.z]})


# ------------------------------------------------------------------ 动作结束时刻

static func load_action_ends(pet: Node3D) -> bool:
	var cf := _read(pet)
	if cf == null:
		return false
	var names: Variant = cf.get_value("rig", "action_names", null)
	var ends: Variant = cf.get_value("rig", "action_ends", null)
	if not (names is Array) or not (ends is Array):
		return false
	if (names as Array).size() != (ends as Array).size() or (names as Array).is_empty():
		return false
	pet._action_end.clear()
	for i in (names as Array).size():
		pet._action_end[String(names[i])] = float(ends[i])
	if OS.is_debug_build():
		print("[PetDeek] 启动数据命中缓存：动作 %d 个" % pet._action_end.size())
	return true


static func save_action_ends(pet: Node3D) -> void:
	var names: Array = []
	var ends: Array = []
	for k in pet._action_end.keys():
		names.append(String(k))
		ends.append(float(pet._action_end[k]))
	_write(pet, {"action_names": names, "action_ends": ends})
