# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 行为：待机 / 起步 / 随机散步 / 回家引力 / 沿屏幕走 / 平滑朝向
## （由 desktop_pet.gd preload 为 PetWalk）。
##
## 方法名保留主脚本时代的下划线命名：主脚本只留 _pick_move_dir / _update_facing
## 两个门面（探针打的就是它们），其余由 _ready / _process 直接调 walk._xxx。

## 模型的正面朝向 -Z，相机在 +Z 看向原点，所以基准旋转 PI 时正好面向镜头。
## 用 tools/shoot_pose.gd 分别渲染 yaw=0 / yaw=180 验证过：180 那一侧能看到脸。
const FACING_BASE := PI

## 宿主（桌宠根节点）：读它的检查器参数 / 模型节点 / 内部状态
var pet: Node3D = null


func setup(pet_node: Node3D) -> void:
	pet = pet_node


func _start_idle(t: float) -> void:
	pet._state = pet.State.IDLE
	pet._speed = 0.0
	pet._timer = t
	pet._play(pet._idle_anim, 0.25)

func _begin_move() -> void:
	if pet._sleeping:
		pet._timer = _idle_time()
		return

	# 假死状态（联系不上外面）：待在原地不动。放在骰子**前面** ——
	# 免得"离线时恰好掷中了"还是走了，也免得有人把 move_chance 调到 1.0 这层就失效。
	# 眨眼 / 呼吸 / 被摸的反应照常 —— 那些是基础功能
	if pet.hibernate_when_offline and pet._offline():
		pet._timer = _idle_time()
		return

	# 待机时间到 ≠ 必须起身 —— 先掷一次骰子，没中就地再等一轮。
	# 这是"减小移动概率"的主开关（以前是时间一到必定走）
	if pet._rng.randf() >= pet.move_chance:
		pet._timer = _idle_time()
		return

	# 小概率来个表情动作（原地做手势，不算移动）
	if pet._rng.randf() < pet.emote_chance:
		var em: String = pet._pick(pet.EMOTE_NAMES, "")
		if em != "":
			pet._play_action(em, 0.15)
			pet._state = pet.State.IDLE
			return

	# （全屏安静**不再**挡跑步 / 缩短移动 —— 2026-10-01 用户要求删掉"全屏降低移动"那层）
	pet._run = pet._rng.randf() < pet.run_chance
	# 位移速度跟着动画倍率走：步频慢了还按原速移动会明显打滑
	pet._speed = (pet.run_speed if pet._run else pet.walk_speed) * pet.anim_speed
	pet._move_dir = _pick_move_dir()
	pet._move_accum = Vector2.ZERO
	pet._state = pet.State.WALK
	var dur: Vector2 = pet.run_duration if pet._run else pet.walk_duration
	pet._timer = pet._rng.randf_range(dur.x, dur.y) * pet.behavior_pace
	var anim := "run" if (pet._run and pet._has.has("run")) else "walk"
	if OS.is_debug_build():
		print("[PetDeek] 开始移动：%s 动画=%s 时长=%.2fs 方向=%s" % [
				"跑步" if pet._run else "走路", anim, pet._timer, pet._move_dir])
	pet._play(anim, 0.15)

## 这一轮待机等多久。**全屏安静不再拉长它**（2026-10-01 用户要求删掉"全屏降低移动"那层）
func _idle_time() -> float:
	return pet._rng.randf_range(pet.idle_before_move.x, pet.idle_before_move.y) * pet.behavior_pace

## 随机挑一个移动方向。左右是基础，上下按 vertical_move_weight 加权出现。
## 屏幕上的"上/下"在 3D 里对应"背对镜头走远 / 正对镜头走近"。
## 先问"回家引力"：离 home_anchor 越远，越可能直接返回指向家的方向。
func _pick_move_dir() -> Vector2:
	var pull := _home_pull_dir()
	if pull != Vector2.ZERO:
		return pull
	if not pet.allow_vertical_move or pet.vertical_move_weight <= 0.0:
		return Vector2.RIGHT if pet._rng.randf() < 0.5 else Vector2.LEFT
	# 左右各占 1 份权重，上下各占 vertical_move_weight 份
	var r: float = pet._rng.randf() * (2.0 + 2.0 * pet.vertical_move_weight)
	if r < 1.0:
		return Vector2.RIGHT
	if r < 2.0:
		return Vector2.LEFT
	if r < 2.0 + pet.vertical_move_weight:
		return Vector2.UP
	return Vector2.DOWN

## 离家太远时按距离概率返回指向家的方向（四方向之一）；否则返回零向量 = 照常随机。
## 概率从 home_deadzone 处的 0 线性爬到"半个屏幕对角线"处的 home_pull，
## 所以只是偶尔飘远，不会刚出家门就被拽回来。
func _home_pull_dir() -> Vector2:
	if pet.home_pull <= 0.0:
		return Vector2.ZERO
	var to_home: Vector2 = Vector2(pet._home_pos() - DisplayServer.window_get_position())
	var dist: float = to_home.length()
	if dist < pet.home_deadzone:
		return Vector2.ZERO
	var span: float = maxf(pet._screen.size.length() * 0.5 - pet.home_deadzone, 1.0)
	var chance: float = pet.home_pull * clampf((dist - pet.home_deadzone) / span, 0.0, 1.0)
	if pet._rng.randf() >= chance:
		return Vector2.ZERO
	# 屏幕 y 向下。上下移动被关掉时只看水平分量
	if not pet.allow_vertical_move or pet.vertical_move_weight <= 0.0:
		if absf(to_home.x) < 1.0:
			return Vector2.ZERO
		return Vector2.RIGHT if to_home.x > 0.0 else Vector2.LEFT
	# 按两个轴的分量比例加权挑轴：斜着离家就斜着回去，不会永远先走完某一条轴
	if pet._rng.randf() < absf(to_home.x) / maxf(absf(to_home.x) + absf(to_home.y), 0.001):
		return Vector2.RIGHT if to_home.x > 0.0 else Vector2.LEFT
	return Vector2.DOWN if to_home.y > 0.0 else Vector2.UP

## 「只在小范围走动」的活动范围：以 center（家）为中心、边长 2*radius 的正方形。
## **写成 static 是为了能离线验** —— 用到它的 _step_move 要 DisplayServer 和真窗口，
## 无头模式里跑不起来，而这个盒子的算术是可以单独试的（probe_memory.gd 会试）
static func nearby_box(center: Vector2i, radius: float) -> Rect2i:
	var r := maxi(1, int(radius))
	return Rect2i(center - Vector2i(r, r), Vector2i(r * 2, r * 2))

func _step_move(delta: float) -> void:
	pet._timer -= delta
	var cur: Vector2i = DisplayServer.window_get_position()
	var win: Vector2i = DisplayServer.window_get_size()

	# 窗口位置只能取整像素：把不足 1px 的位移累积起来，别让高帧率把它截断成 0
	pet._move_accum += pet._move_dir * pet._speed * delta
	var dx: int = int(pet._move_accum.x)
	var dy: int = int(pet._move_accum.y)
	pet._move_accum -= Vector2(dx, dy)

	# 活动范围统一表示成"窗口左上角允许落在哪"：
	#   平时   = 整个屏幕（留 4px 边距）
	#   安静模式 = 她进入安静模式那一刻所在的位置附近一小块（不是"家" ——
	#              以家为中心的话，你一开全屏她就会瞬间被夹到家的位置，像瞬移）
	var margin := 4
	var lo: Vector2i = pet._screen.position + Vector2i(margin, margin)
	var hi: Vector2i = pet._screen.position + pet._screen.size - win - Vector2i(margin, margin)
	if pet._quiet():
		var q: Rect2i = pet._quiet_bounds()
		lo = Vector2i(maxi(lo.x, q.position.x), maxi(lo.y, q.position.y))
		hi = Vector2i(mini(hi.x, q.end.x), mini(hi.y, q.end.y))
	# 「只在小范围走动」：以**家**为中心的一小块。
	# **已经在圈外就先不夹** —— 一开开关就把她瞬移回家，比不管还吓人；
	# 等她自己溜达回来（回家引力本来就在拉她）再开始管，看起来就是"她回来了"
	if pet.stay_nearby:
		var nb: Rect2i = pet._nearby_bounds()
		if nb.has_point(cur):
			lo = Vector2i(maxi(lo.x, nb.position.x), maxi(lo.y, nb.position.y))
			hi = Vector2i(mini(hi.x, nb.end.x), mini(hi.y, nb.end.y))
	# 范围比窗口还小时就地钉住：lo/hi 一旦反过来，下面的折返判断会来回乱跳
	hi.x = maxi(hi.x, lo.x)
	hi.y = maxi(hi.y, lo.y)

	var nx: int = cur.x + dx
	var ny: int = cur.y + dy

	# 撞到边界就把对应分量折返（另一个分量是 0，absf 之后仍是 0，不受影响）
	if nx <= lo.x:
		nx = lo.x
		pet._move_dir.x = absf(pet._move_dir.x)
	elif nx >= hi.x:
		nx = hi.x
		pet._move_dir.x = -absf(pet._move_dir.x)
	if ny <= lo.y:
		ny = lo.y
		pet._move_dir.y = absf(pet._move_dir.y)
	elif ny >= hi.y:
		ny = hi.y
		pet._move_dir.y = -absf(pet._move_dir.y)

	DisplayServer.window_set_position(Vector2i(nx, ny))

	if pet._timer <= 0.0:
		_start_idle(pet._rng.randf_range(pet.rest_min, pet.rest_max) * pet.behavior_pace)

func _update_facing(delta: float) -> void:
	var want: float = _facing_target_yaw()
	var diff: float = wrapf(want - pet._model.rotation.y, -PI, PI)
	# 转动只是"往差分走一小段"，所以 rotation.y 会一圈圈累加下去；
	# 归一到 [-PI, PI]，免得跑一整天之后 float32 的精度不够用
	pet._model.rotation.y = wrapf(
			pet._model.rotation.y + diff * minf(1.0, pet.turn_speed * delta), -PI, PI)

## 移动时该朝哪边转。
##
## 坐标系对照（相机在 +Z 看向原点，所以屏幕右 = 世界 +X，屏幕上 = 世界 -Z）：
##   屏幕向右 (1,0)  → 偏航 -90°，看到角色侧面
##   屏幕向上 (0,-1) → 偏航 0°，角色**背对镜头**往远处走
##   屏幕向下 (0, 1) → 偏航 180°，角色正对镜头走近
## 静止时回到 FACING_BASE（正对屏幕）。
## `face_move_direction` 在"永远正对屏幕"和"完全朝移动方向"之间插值。
func _facing_target_yaw() -> float:
	if pet._state != pet.State.WALK or pet._move_dir == Vector2.ZERO:
		return FACING_BASE
	# 屏幕方向（x 右 / y 下）→ 世界方向（y 下 = +Z 朝镜头），再换算成模型偏航
	var full: float = atan2(-pet._move_dir.x, -pet._move_dir.y)
	return FACING_BASE + wrapf(full - FACING_BASE, -PI, PI) * pet.face_move_direction
