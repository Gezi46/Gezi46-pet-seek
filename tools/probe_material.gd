# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
# 检查导入后材质的透明/抗锯齿相关设置，用来定位白边来源。
var _frames := 0

func _initialize() -> void:
	_go.call_deferred()

# 看门狗：脚本中途报错时也必须退出。
# 之前这里访问了 Godot 4.7 已不存在的属性 alpha_hash_enabled，_go() 直接抛错，
# 而 quit(0) 写在函数末尾永远执行不到 —— --script 模式下 Godot 不会自己退出，
# 于是进程一直挂着，命令行看起来就是"卡死"。其它 tools 脚本都有这个兜底，这里补上。
func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 900:
		printerr("看门狗触发：probe_material 超时")
		quit(2)
		return true
	return false

func _go() -> void:
	var ps: PackedScene = load("res://peekdeek_opt.glb")
	var m: Node = ps.instantiate()
	get_root().add_child(m)
	await process_frame

	var seen := {}
	var stack: Array[Node] = [m]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			if mi.mesh == null:
				continue
			for si in mi.mesh.get_surface_count():
				var mat: Material = mi.get_surface_override_material(si)
				if mat == null:
					mat = mi.mesh.surface_get_material(si)
				if mat == null:
					continue
				var key := str(mat.get_instance_id())
				if seen.has(key):
					continue
				seen[key] = true
				print("材质: %s (%s)" % [mat.resource_name, mat.get_class()])
				if mat is StandardMaterial3D:
					var sm: StandardMaterial3D = mat
					print("  transparency      = %d" % sm.transparency)
					print("  alpha_scissor_thr = %.4f" % sm.alpha_scissor_threshold)
					print("  alpha_antialias   = %s" % sm.alpha_antialiasing_mode)
					print("  alpha_hash_scale  = %.3f" % sm.alpha_hash_scale)
					print("  blend_mode        = %d" % sm.blend_mode)
					print("  cull_mode         = %d" % sm.cull_mode)
					print("  albedo_texture    = %s" % ("有" if sm.albedo_texture != null else "无"))
					if sm.albedo_texture != null:
						print("  tex filter        = %s" % sm.texture_filter)
					# 高光相关：glTF 的 metallicFactor 缺省是 1.0，导入后就成了强反射，
					# 会在方块边缘的掠射角上烧出一圈白色高光边。
					print("  metallic          = %.3f" % sm.metallic)
					print("  metallic_specular = %.3f" % sm.metallic_specular)
					print("  roughness         = %.3f" % sm.roughness)
					print("  specular_mode     = %d" % sm.specular_mode)
					print("  specular          = %.3f" % sm.specular)
					print("  rim_enabled       = %s" % sm.rim_enabled)
					print("  shading_mode      = %d" % sm.shading_mode)
	print("不同材质数量: %d" % seen.size())
	quit(0)
