# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
# 只播指定动画并截图，用来确认落地/朝向是否正确。
# 用法: godot --path <项目> --script res://tools/shoot_pose.gd -- idle 60
func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var args := OS.get_cmdline_user_args()
	var want: String = args[0] if args.size() > 0 else "idle"
	var frame: int = int(args[1]) if args.size() > 1 else 60

	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)

	var model: Node3D = pet.get_node_or_null("Character/Pivot/Model")
	var player: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	# 冻结桌宠自身逻辑，避免它自己切动画
	pet.set_process(false)
	# 用参数强制一个朝向，方便确认哪一面才是正面
	var yaw: float = float(args[2]) if args.size() > 2 else 0.0
	if model != null:
		model.rotation.y = deg_to_rad(yaw)
	if player != null:
		if player.has_animation(want):
			player.play(want)
			player.pause()

	for i in frame:
		await process_frame

	var img: Image = get_root().get_texture().get_image()
	var out := "res://_pose_%s_%d.png" % [want, int(yaw)]
	img.save_png(out)
	print("已保存 %s  动画=%s yaw=%.0f" % [out, want, yaw])
	quit(0)
