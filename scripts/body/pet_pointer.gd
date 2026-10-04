# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 鼠标 / 互动：悬停检测、点击穿透区域、拖拽、摸头 / 喂食 / 睡觉 / 跳跃反应
## （由 desktop_pet.gd preload 为 PetPointer）。
##
## 方法名保留主脚本时代的下划线命名：主脚本留 _input（虚函数转发）、
## _update_passthrough_region（PetWindow 回调）、_begin_drag / _end_drag（探针）
## 四个门面，其余由 _process / 菜单直接调 pointer._xxx。

## 可点区域变化的死区（像素）：小于它就懒得去重建窗口区域，避免每帧都动窗口
const PASSTHROUGH_DEADZONE := 8.0

## 宿主（桌宠根节点）：读它的检查器参数 / 相机节点 / 内部状态
var pet: Node3D = null
## 按下时鼠标在窗口里的位置。摸头 / 摸手 / 摸腿 得靠它判部位 ——
## _end_drag 那一刻的鼠标位置已经不准了（拖完手会挪），所以要在按下时就记下来
var _press_pos := Vector2.INF


## 按点击落在角色的哪个部位分类。参数是**归一化坐标**：
## (0,0) = 外接矩形左上，(1,1) = 右下。
##
## 用的是"人形站立、双手垂在身侧"这个姿势的近似分带，够用就行 ——
## 想精确判部位得先有骨骼，而这个模型是 722 个节点的刚体层级（没有 skin），
## 真要按网格判会非常费劲。分带还更好调：想改手感就改这几个数字。
static func classify_touch(rel: Vector2) -> String:
	var nx := clampf(rel.x, 0.0, 1.0)
	var ny := clampf(rel.y, 0.0, 1.0)
	if ny < 0.26:
		return "head"
	# 两侧是垂下来的手臂/手，胸腹在中间那条带里 —— 所以先判"够不够靠边"
	if absf(nx - 0.5) > 0.26 and ny < 0.66:
		return "hand"
	if ny < 0.52:
		return "chest"
	if ny > 0.72:
		return "leg"
	return "body"


func setup(pet_node: Node3D) -> void:
	pet = pet_node


## 角色包围盒投影到窗口坐标，用来判断鼠标是不是"碰到角色"
func _char_screen_rect() -> Rect2:
	var aabb: AABB = pet._raw_model_aabb()
	var vp: Vector2 = pet.get_viewport().get_visible_rect().size
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for i in 8:
		var world: Vector3 = pet._pivot.global_transform * aabb.get_endpoint(i)
		if pet._camera.is_position_behind(world):
			continue
		var p: Vector2 = pet._camera.unproject_position(world)
		minp = minp.min(p)
		maxp = maxp.max(p)
	if minp.x > maxp.x:
		return Rect2(vp * 0.5, Vector2.ZERO)
	return Rect2(minp, maxp - minp)

func _update_hover() -> void:
	var mouse: Vector2 = pet.get_viewport().get_mouse_position()
	var want_catch: bool = _char_screen_rect().grow(pet.catch_padding).has_point(mouse)
	pet._hover = want_catch

	# 关键：不要在这里切换"整窗可点 / 整窗穿透"。
	# window_set_mouse_passthrough 的参数是"接受鼠标事件的区域"，
	# 每次调用都会让 Windows 重建窗口区域，鼠标碰到角色时闪的那一下就是这么来的。
	# 改成始终把区域固定成角色矩形，只在包围盒真的变化时才更新 —— 鼠标进出角色
	# 完全不动窗口，空白处照样穿透。
	_update_passthrough_region()

	if want_catch != pet._catching:
		pet._catching = want_catch
		Input.set_default_cursor_shape(
				Input.CURSOR_POINTING_HAND if pet._catching else Input.CURSOR_ARROW)

## 把窗口的"可点区域"固定成角色轮廓的凸包，区域之外一律穿透到后面的窗口。
##
## 语义已经实测确认过：window_set_mouse_passthrough 的参数就是"窗口存在的区域"
## —— 传 (100,100)-(200,200) 给 Windows，查出来的窗口 region 正好是那一块。
## 所以传角色轮廓 = 轮廓内可点、其余穿透。
##
## 之前那套"整窗可点 / 整窗穿透"来回切的做法有两个毛病：每次切换都会让 Windows
## 重建窗口区域（鼠标碰到角色时闪的那一下），而且非悬停时传的是整窗矩形，
## 按上面的语义那仍然是整窗可点 —— 也就是穿透其实一直没生效。
##
## 死区是为了不让呼吸动画每帧都去重建窗口区域。
func _update_passthrough_region() -> void:
	if not pet.mouse_passthrough_enabled:
		return
	if pet._ui_panel_open():
		# 聊天框 / AI 设置面板都是实心的，得整窗接收点击，否则面板自己都点不动
		return
	if pet._use_opaque():
		# 卡片形态是一张实心矩形，整窗都该接收点击，不需要挖穿透区
		if not pet._passthrough_set:
			pet._passthrough_set = true
			DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
		return
	var poly: PackedVector2Array = _char_screen_polygon()
	if poly.size() < 3:
		return
	var bound := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		bound = bound.expand(poly[i])
	# 快速回答按钮露出来时，把它也算进"可点区域"（取并集的外框矩形）。
	# 不做这一步的话，按钮飘在角色轮廓之外，点上去会直接穿到后面的窗口 ——
	# 那按钮就成了个摆设（这就是这块 UI 唯一的坑）。
	# （锁按钮那套已改成按 GPU 自动透视，见 desktop_pet._tick_gpu，这里不再管它）
	var extra: Rect2 = pet.quick_clickable_rect()
	if extra.size.x > 0.0:
		bound = bound.merge(extra)
		poly = PackedVector2Array([
			bound.position, Vector2(bound.end.x, bound.position.y),
			bound.end, Vector2(bound.position.x, bound.end.y),
		])
	if pet._passthrough_set \
			and absf(bound.position.x - pet._passthrough_bound.position.x) < PASSTHROUGH_DEADZONE \
			and absf(bound.position.y - pet._passthrough_bound.position.y) < PASSTHROUGH_DEADZONE \
			and absf(bound.size.x - pet._passthrough_bound.size.x) < PASSTHROUGH_DEADZONE \
			and absf(bound.size.y - pet._passthrough_bound.size.y) < PASSTHROUGH_DEADZONE:
		return
	pet._passthrough_bound = bound
	pet._passthrough_set = true
	DisplayServer.window_set_mouse_passthrough(poly)

## 角色轮廓的近似多边形：把包围盒 8 个端点投影到屏幕，取凸包，再沿质心外扩 catch_padding。
## 比直接丢一个矩形贴合得多 —— 人形在屏幕上是个斜六边形，头顶两侧的空白能正确穿透。
func _char_screen_polygon() -> PackedVector2Array:
	var aabb: AABB = pet._raw_model_aabb()
	var pts := PackedVector2Array()
	for i in 8:
		var world: Vector3 = pet._pivot.global_transform * aabb.get_endpoint(i)
		if pet._camera.is_position_behind(world):
			continue
		pts.append(pet._camera.unproject_position(world))
	if pts.size() < 3:
		return PackedVector2Array()
	var hull: PackedVector2Array = Geometry2D.convex_hull(pts)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	if hull.size() < 3:
		return PackedVector2Array()
	var center := Vector2.ZERO
	for p in hull:
		center += p
	center /= float(hull.size())
	var out := PackedVector2Array()
	for p in hull:
		out.append(p + (p - center).normalized() * pet.catch_padding)
	return out

## 由主脚本的 _input 虚函数逐字转发过来（RefCounted 收不到引擎输入回调）。
func _input(event: InputEvent) -> void:
	# 聊天框开着时才吃键盘。窗口平时是 NO_FOCUS 的，只有开着输入框
	# 才会临时把焦点抢回来（见 _set_chat_focus），所以这里不用担心误吞按键
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE and pet._ui_panel_open():
			pet._close_panels()
			pet.get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if pet._ui_panel_open():
			# 面板开着时，鼠标事件只剩两件有意义的事：点在面板上、点在面板外面收起它。
			# **绝不能继续往下走**：面板是实心的，指针底下正好压着她的轮廓
			# （设置面板更是占满整窗），继续走的话点一下复选框就会顺手把窗口拖走，
			# 看着像"按钮点了没反应"。右边那一下也一样，不在这儿弹菜单
			if mb.pressed and not pet._point_in_any_panel(mb.position):
				pet._close_panels()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _char_screen_rect().grow(pet.catch_padding).has_point(mb.position):
					_press_pos = mb.position      # 记下来判部位，见 classify_touch
					_begin_drag()
			else:
				_end_drag()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			if _char_screen_rect().grow(pet.catch_padding).has_point(mb.position):
				pet._open_menu(mb.position)
	elif event is InputEventMouseMotion and pet._dragging:
		pet._moved += (event as InputEventMouseMotion).relative.length()

func _begin_drag() -> void:
	if pet._state == pet.State.SLEEP:
		_wake_up()
	pet._dragging = true
	pet._drag_origin_mouse = DisplayServer.mouse_get_position()
	pet._drag_origin_win = DisplayServer.window_get_position()
	pet._moved = 0.0
	pet._state = pet.State.DRAG
	pet._play("jump" if pet._has.has("jump") else pet._idle_anim, 0.08)

func _process_drag() -> void:
	if not pet._dragging:
		return
	# mouse_get_position() 返回 Vector2i，先转成 Vector2 再相减
	var d: Vector2 = Vector2(DisplayServer.mouse_get_position()) - pet._drag_origin_mouse
	DisplayServer.window_set_position(pet._drag_origin_win + Vector2i(int(d.x), int(d.y)))

func _end_drag() -> void:
	if not pet._dragging:
		return
	pet._dragging = false
	if pet._moved < 6.0:
		_react_click()
	else:
		pet._play_action("attacked" if pet._has.has("attacked") else pet._idle_anim, 0.12)
		pet._state = pet.State.IDLE
		# 拖到哪儿哪儿就是"家"：以后飘远了会自己走回来，下次启动也停在这儿
		# （单纯点一下不改家，那不算拖拽；不想要这个行为就把 drag_sets_home 关掉）
		if pet.drag_sets_home:
			pet.set_home_here()

func _react_click() -> void:
	var now_ms: int = Time.get_ticks_msec()
	var dbl: bool = (now_ms - pet._last_click_ms) < pet.double_click_ms
	pet._last_click_ms = now_ms

	if dbl:
		pet._open_chat()
		return

	if now_ms / 1000.0 - pet._last_pet < pet.pet_cooldown:
		# 冷却中不播新动作，但必须把状态从 DRAG 拉回 IDLE：
		# 进到这里说明刚经历了一次"按下→松开"（_end_drag），_state 还停在 DRAG。
		# 直接 return 的话 _state 就永远是 DRAG —— _begin_move 不会再被调用
		# （从此不再走路/跑步/做表情），animation_finished 也被 DRAG 守护挡住，
		# 宠物会僵在 _begin_drag 播的 jump 最后一帧。外观就是"该走的时候不播走路动画"。
		pet._state = pet.State.IDLE
		pet._timer = minf(pet._timer, pet._beat(0.8))
		return
	pet._last_pet = now_ms / 1000.0

	# 摸哪儿？把按下时的位置换算成"在角色矩形里的比例"，再交给分带判断。
	# 菜单里的「摸摸头」没有坐标（_press_pos 还是 INF），那就按头算 —— 菜单项本来就叫摸头
	var part := "head"
	if _press_pos != Vector2.INF:
		var r := _char_screen_rect()
		if r.size.x > 1.0 and r.size.y > 1.0:
			part = classify_touch((_press_pos - r.position) / r.size)
	pet._touch_react(part)

func _do_jump() -> void:
	pet._play_action("jump" if pet._has.has("jump") else pet._idle_anim, 0.08)
	pet._state = pet.State.IDLE
	if pet._hop_tween != null and pet._hop_tween.is_valid():
		pet._hop_tween.kill()
	# 抬的是模型本体，不要把相机一起抬起来
	pet._hop_tween = pet.create_tween()
	pet._hop_tween.tween_property(pet._model, "position:y", pet.hop_height, pet._beat(0.32)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	pet._hop_tween.tween_property(pet._model, "position:y", 0.0, pet._beat(0.34)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

func _wake_up() -> void:
	pet._sleeping = false
	pet._say(pet.LINES_WAKE[pet._rng.randi_range(0, pet.LINES_WAKE.size() - 1)])
	pet.walk._start_idle(pet._beat(1.0))

func _go_sleep() -> void:
	pet._sleeping = true
	pet._state = pet.State.SLEEP
	pet._speed = 0.0
	pet._play("sleep" if pet._has.has("sleep") else pet._idle_anim, 0.3)
	pet._say(pet.LINES_SLEEP[pet._rng.randi_range(0, pet.LINES_SLEEP.size() - 1)])

func _feed() -> void:
	if pet._state == pet.State.SLEEP:
		_wake_up()
	# 吃的动作：优先 use_mainhand_eat（Godot 把原名的冒号改成了下划线），没有就退回 use_mainhand
	pet._play_action(pet._pick(["use_mainhand_eat", "use_mainhand"], pet._idle_anim), 0.1)
	pet._state = pet.State.IDLE
	pet._say(pet.LINES_FEED[pet._rng.randi_range(0, pet.LINES_FEED.size() - 1)])
	pet._mood.cheer()      # 喂了东西 = 开心（心情系统，见 pet_mood.gd）
