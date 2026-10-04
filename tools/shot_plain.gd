# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 按桌宠正常流程渲染一张，不做任何材质/视图覆盖。
## 加深色底板是为了让透明轮廓上的白边显形。
## 用法: godot --path <项目> --script res://tools/shot_plain.gd -- out.png
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 900:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "res://_plain.png"
	var frames: int = int(args[1]) if args.size() > 1 else 40

	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)

	# 深色底板（贴在角色后面），白边在深色上最容易看见
	var backdrop := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(20, 20)
	backdrop.mesh = quad
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.06, 0.08, 0.13)
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backdrop.material_override = bm
	backdrop.position = Vector3(0, 1.4, -6)
	pet.add_child(backdrop)

	# 冻结逻辑并固定朝向/动画，保证可重复
	pet.set_process(false)
	var model: Node3D = pet.get_node_or_null("Character/Pivot/Model")
	if model != null:
		model.rotation.y = PI
	var player: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	if player != null and player.has_animation("idle"):
		player.play("idle")
		player.pause()

	for i in frames:
		await process_frame
	var img: Image = get_root().get_texture().get_image()
	img.save_png(out)
	print("已保存 %s" % out)
	print("  msaa_3d=%d screen_space_aa=%d" % [
		get_root().msaa_3d, get_root().screen_space_aa])
	quit(0)
