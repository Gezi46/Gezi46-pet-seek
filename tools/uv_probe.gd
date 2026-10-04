# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 临时诊断：打印指定节点下各表面的 UV 矩形，并检查矩形"边界内/外各 2 个 texel"的颜色。
## 用来判断方块棱边的亮线，是采样漂移到相邻 UV 岛，还是岛自身的边缘 texel 就是亮的。
## 用法: --script res://tools/_uvprobe.gd -- <节点名关键字>
var _frames := 0

func _initialize() -> void:
	_go.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 900:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _go() -> void:
	var args := OS.get_cmdline_user_args()
	var key: String = args[0] if args.size() > 0 else "Foot"
	var ps: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = ps.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame
	await process_frame

	var stack: Array[Node] = [pet]
	var shown := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not (n is MeshInstance3D):
			continue
		if not String(n.name).contains(key):
			continue
		var mi: MeshInstance3D = n
		if mi.mesh == null:
			continue
		print("=== %s （表面数 %d）===" % [mi.get_path(), mi.mesh.get_surface_count()])
		for si in mi.mesh.get_surface_count():
			var m: Material = mi.get_surface_override_material(si)
			if m == null:
				m = mi.mesh.surface_get_material(si)
			if not (m is StandardMaterial3D):
				continue
			var tex: Texture2D = (m as StandardMaterial3D).albedo_texture
			if tex == null:
				continue
			var img: Image = tex.get_image()
			if img == null:
				continue
			img.convert(Image.FORMAT_RGBA8)
			var arr: Array = mi.mesh.surface_get_arrays(si)
			if arr.size() <= Mesh.ARRAY_TEX_UV or arr[Mesh.ARRAY_TEX_UV] == null:
				print("  表面 %d: 没有 UV" % si)
				continue
			var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for uv in uvs:
				lo = lo.min(uv)
				hi = hi.max(uv)
			var W := float(img.get_width())
			var H := float(img.get_height())
			print("  表面 %d: UV u=[%.5f,%.5f] v=[%.5f,%.5f]  跨度 %.2f x %.2f texel" % [
				si, lo.x, hi.x, lo.y, hi.y, (hi.x - lo.x) * W, (hi.y - lo.y) * H])
			var mu := (lo.x + hi.x) * 0.5
			var mv := (lo.y + hi.y) * 0.5
			_probe(img, mu, lo.y, 0, -1, "上边")
			_probe(img, mu, hi.y, 0, 1, "下边")
			_probe(img, lo.x, mv, -1, 0, "左边")
			_probe(img, hi.x, mv, 1, 0, "右边")
			shown += 1
			if shown >= 6:
				print("...（样本够了，停止）")
				quit(0)
				return
	quit(0)

## k 为 0 表示正好在矩形边界上，负数在矩形内侧，正数在外侧（单位 = texel）
func _probe(img: Image, u: float, v: float, du: int, dv: int, tag: String) -> void:
	var W := img.get_width()
	var H := img.get_height()
	var parts := []
	for k in [-1, 0, 1, 2]:
		var uu: float = u + du * float(k) / float(W)
		var vv: float = v + dv * float(k) / float(H)
		var x: int = clampi(int(floor(uu * float(W))), 0, W - 1)
		var y: int = clampi(int(floor(vv * float(H))), 0, H - 1)
		var c := img.get_pixel(x, y)
		parts.append("%+d(%d,%d)a=%.2f rgb=%.2f,%.2f,%.2f" % [k, x, y, c.a, c.r, c.g, c.b])
	print("    %s: %s" % [tag, "  ".join(parts)])
