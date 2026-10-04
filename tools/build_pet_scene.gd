# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 一次性构建脚本：把导入后的 peekdeek_opt.glb 组装成 scenes/pet.tscn
## 用法：
##   godot --path <项目> --headless --script res://tools/build_pet_scene.gd
##
## 它做四件事：
##   1. 实例化 peekdeek_opt.glb
##   2. 在模型下加一个 AnimationPlayer2 作为"表情叠加层"（眨眼），
##      这样眨眼不会覆盖身体动画
##   3. 组装 相机 / 灯光 / 环境 / 软阴影 / 气泡 / 右键菜单
##   4. 存成 res://scenes/pet.tscn，窗口尺寸由 desktop_pet.gd 按模型高度自适应

const MODEL_PATH := "res://peekdeek_opt.glb"
const OUT_PATH := "res://scenes/pet.tscn"
const PET_SCRIPT := "res://scripts/desktop_pet.gd"

func _initialize() -> void:
	_build.call_deferred()

func _build() -> void:
	print("=== 构建 pet.tscn ===")

	var model_scene: PackedScene = load(MODEL_PATH)
	if model_scene == null:
		printerr("找不到 %s" % MODEL_PATH)
		quit(1)
		return

	# ---------------------------------------------------------- 根节点
	var root := Node3D.new()
	root.name = "Pet"
	root.set_script(load(PET_SCRIPT))

	# ---------------------------------------------------------- 角色
	var character := Node3D.new()
	character.name = "Character"
	root.add_child(character)
	character.owner = root

	# Pivot 负责把角色抬到地面上（原模型脚底不在 y=0）；
	# 跳跃补间作用在 Model 自己的 position 上，两者互不干扰。
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	character.add_child(pivot)
	pivot.owner = root

	var model: Node3D = model_scene.instantiate()
	model.name = "Model"
	pivot.add_child(model)
	model.owner = root
	# 注意：绝对不要去改 GLB 实例内部节点的 owner。
	# 一旦内部节点被 owner 标记，PackedScene.pack() 会把整棵树（567 个 MeshInstance3D）
	# 内联展开写进 pet.tscn，而不是留下一个 instance=ExtResource 引用。

	# 模型里已经带了一个 AnimationPlayer（身体动画）
	var main_player: AnimationPlayer = _find_player(model)
	if main_player == null:
		printerr("模型里没有 AnimationPlayer")
		quit(1)
		return
	# 表情叠加层（眨眼）由 desktop_pet.gd 在运行时创建，避免动到实例内部结构

	# ---------------------------------------------------------- 相机
	# 仅作为占位：真正的机位由 desktop_pet.gd 的 _apply_window_size() 按模型
	# 包围盒计算，这里只保证保存出来的场景在编辑器里也能看到角色。
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.2
	cam.fov = 40.0
	cam.near = 0.05
	cam.far = 100.0
	root.add_child(cam)
	cam.owner = root
	# 节点已在树里，look_at 可用
	cam.look_at_from_position(Vector3(0, 0.7, 6.5), Vector3(0, 0.65, 0), Vector3.UP)

	# ---------------------------------------------------------- 环境 / 灯光
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.90, 1.0)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 1.2
	env.ssao_enabled = false
	env.glow_enabled = false
	we.environment = env
	root.add_child(we)
	we.owner = root

	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	key.rotation_degrees = Vector3(-38, 32, 0)
	key.light_energy = 1.15
	key.light_color = Color(1.0, 0.97, 0.92)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 12.0
	root.add_child(key)
	key.owner = root

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-14, -128, 0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.78, 0.86, 1.0)
	fill.shadow_enabled = false
	root.add_child(fill)
	fill.owner = root

	# ---------------------------------------------------------- 脚下软阴影
	var shadow := MeshInstance3D.new()
	shadow.name = "Shadow"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	shadow.mesh = quad
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;
uniform float strength : hint_range(0.0, 1.0) = 0.5;
void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = smoothstep(1.0, 0.05, d);
	ALBEDO = vec3(0.0);
	ALPHA = a * strength;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	shadow.material_override = mat
	shadow.rotation_degrees = Vector3(-90, 0, 0)
	shadow.position = Vector3(0, 0.006, 0)
	root.add_child(shadow)
	shadow.owner = root

	# ---------------------------------------------------------- UI
	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	ui.owner = root

	var anchor := Control.new()
	anchor.name = "Anchor"
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(anchor)
	anchor.owner = root

	var bubble := Label.new()
	bubble.name = "Bubble"
	bubble.text = ""
	bubble.visible = false
	bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bubble.add_theme_color_override("font_color", Color(0.10, 0.12, 0.20))
	bubble.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	bubble.add_theme_constant_override("outline_size", 4)
	bubble.add_theme_font_size_override("font_size", 15)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.94)
	sb.border_color = Color(0.55, 0.68, 0.92, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(9)
	sb.set_content_margin_all(7)
	bubble.add_theme_stylebox_override("normal", sb)
	bubble.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bubble.offset_left = 12
	bubble.offset_right = -12
	bubble.offset_top = 8
	bubble.offset_bottom = 58
	anchor.add_child(bubble)
	bubble.owner = root

	var menu := PopupMenu.new()
	menu.name = "Menu"
	ui.add_child(menu)
	menu.owner = root
	# 显式给每一项分配 id，和 desktop_pet.gd 的 _on_menu_id 一一对应
	# （顺序 = id，加/删/挪位置都要和 scenes/pet.tscn 里的 item_N/id 对齐）
	var labels: Array[String] = [
		"摸摸头", "喂食", "睡觉 / 起床", "跳一下", "缩小", "原始大小",
		"放大", "切换窗口置顶", "说点什么", "把当前位置设为家",
		"初始位置恢复右下角", "退出", "跟我说话（双击我也行）", "让她主动说一句",
		"让她看看我在干嘛", "看看我这边（摄像头）", "主动说话", "偷看屏幕", "摄像头",
	]
	for i in labels.size():
		menu.add_item(labels[i], i)

	# ---------------------------------------------------------- 保存
	var packed := PackedScene.new()
	var err: int = packed.pack(root)
	if err != OK:
		printerr("pack 失败: %d" % err)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))
	err = ResourceSaver.save(packed, OUT_PATH)
	if err != OK:
		printerr("保存失败 %s: %d" % [OUT_PATH, err])
		quit(1)
		return

	print("已保存 %s" % OUT_PATH)
	print("  角色包围盒: %s" % _model_aabb(model))
	print("  主体动画: %d 条" % (main_player.get_animation_library("").get_animation_list().size() if main_player.get_animation_library("") != null else 0))
	root.free()
	print("=== OK ===")
	quit(0)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))

func _find_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r: AnimationPlayer = _find_player(c)
		if r != null:
			return r
	return null

func _model_aabb(model: Node3D) -> AABB:
	var first := true
	var out := AABB()
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			var box: AABB = mi.transform * mi.get_aabb()
			if first:
				out = box
				first = false
			else:
				out = out.merge(box)
	return out
