# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 渲染带 alpha 的透明图（不加底板），用于分析轮廓边缘。
## 用法: godot --path <项目> --script res://tools/shot_alpha.gd -- out.png [linear|nearest] [frames]
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 1200:
		quit(2)
		return true
	return false

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "res://_alpha.png"
	var mode: String = args[1] if args.size() > 1 else "nearest"
	var frames: int = int(args[2]) if args.size() > 2 else 40

	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame

	if mode == "linear":
		_set_filter(pet, BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	else:
		_set_filter(pet, BaseMaterial3D.TEXTURE_FILTER_NEAREST)

	pet.set_process(false)
	var model: Node3D = pet.get_node_or_null("Character/Pivot/Model")
	if model != null:
		model.rotation.y = PI
	var shadow: Node3D = pet.get_node_or_null("Shadow")
	if shadow != null:
		shadow.visible = false          # 阴影会干扰边缘统计
	var player: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	if player != null and player.has_animation("idle"):
		player.play("idle")
		player.pause()

	for i in frames:
		await process_frame
	var img: Image = get_root().get_texture().get_image()
	img.save_png(out)
	print("已保存 %s (filter=%s)" % [out, mode])
	quit(0)

func _set_filter(root: Node, f: int) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not (n is MeshInstance3D):
			continue
		var mi: MeshInstance3D = n
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var cur: Material = mi.get_surface_override_material(si)
			if cur is StandardMaterial3D:
				var sm: StandardMaterial3D = (cur as StandardMaterial3D).duplicate()
				sm.texture_filter = f
				mi.set_surface_override_material(si, sm)
