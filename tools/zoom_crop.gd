# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 把窗口里指定区域按真实像素放大，并可切变体做 A/B —— 定位"某条边缘看着不对"用。
## 想看整体效果/几何有没有被改坏，用 tools/check_effect.gd（或根目录的 检查效果.bat）更省事。
## 用法: --script res://tools/zoom_crop.gd -- out.png zoom x y w h [variant]
## variant: base / noaa / nomsaa / nossaa / nodilate / linear / noscissor / nospec / nolight
##          / nouvinset / uv0125 / uv025 / feetcam / feetcam_nouvinset / onlyshoe
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 4000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var out: String = a[0] if a.size() > 0 else "res://_crop.png"
	var zoom: int = int(a[1]) if a.size() > 1 else 8
	var cx: int = int(a[2]) if a.size() > 2 else 130
	var cy: int = int(a[3]) if a.size() > 3 else 400
	var cw: int = int(a[4]) if a.size() > 4 else 100
	var ch: int = int(a[5]) if a.size() > 5 else 60
	var variant: String = a[6] if a.size() > 6 else "base"

	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	# UV 内缩是 _ready 里做的，所以这几个变体必须在入树之前设置
	if variant == "nouvinset" or variant == "feetcam_nouvinset":
		pet.set("uv_inset_texels", 0.0)
	elif variant == "uv0125":
		pet.set("uv_inset_texels", 0.125)
	elif variant == "uv025":
		pet.set("uv_inset_texels", 0.25)
	get_root().add_child(pet)
	await process_frame
	await process_frame

	pet.set_process(false)
	var shadow: Node3D = pet.get_node_or_null("Shadow")
	if shadow != null:
		shadow.visible = false

	# 先跑一会儿让待机姿势稳定，再冻住，各个变体才可比
	for i in 40:
		await process_frame
	for p in [pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer"),
			pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer2")]:
		if p != null:
			p.pause()

	match variant:
		"noaa":
			get_root().msaa_3d = Viewport.MSAA_DISABLED
			get_root().scaling_3d_scale = 1.0
		"nomsaa":
			get_root().msaa_3d = Viewport.MSAA_DISABLED
		"nossaa":
			get_root().scaling_3d_scale = 1.0
		"nodilate":
			pet.dilate_pixels = 0
			pet._harden_materials()
		"linear":
			pet.texture_filter_mode = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			pet._harden_materials()
		"noscissor":
			pet.alpha_scissor_threshold = 0.99
			pet._harden_materials()
		"feetcam", "feetcam_nouvinset", "onlyshoe":
			# 把相机压到脚前方、压低俯角，复现 F5 里"正对鞋子"的视角
			var cam: Camera3D = pet.get_node_or_null("Camera3D")
			if cam != null:
				var t := Vector3(0.0, 0.06, -0.2)
				cam.look_at_from_position(t + Vector3(0.0, 0.45, 1.7), t, Vector3.UP)
				cam.size = 0.45
			if variant == "onlyshoe":
				_hide_except(pet, ["LeftFoot", "RightFoot"])
		"nospec":
			_set_specular(pet)
		"nolight":
			_set_specular(pet)
			for n in ["KeyLight", "FillLight"]:
				var l: Node3D = pet.get_node_or_null(n)
				if l != null:
					l.visible = false

	print("变体=%s  msaa=%d ssaa=%.2f 透明背景=%s" % [
		variant, get_root().msaa_3d, get_root().scaling_3d_scale, get_root().transparent_bg])

	for i in 40:
		await process_frame

	var img: Image = get_root().get_texture().get_image()
	img.decompress()
	var vp := img.get_size()
	var x0: int = clampi(cx, 0, maxi(vp.x - 1, 0))
	var y0: int = clampi(cy, 0, maxi(vp.y - 1, 0))
	cw = mini(cw, vp.x - x0)
	ch = mini(ch, vp.y - y0)
	var crop: Image = img.get_region(Rect2i(x0, y0, cw, ch))

	var big: Image = Image.create(cw * zoom, ch * zoom, false, Image.FORMAT_RGBA8)
	var over_dark: Image = Image.create(cw * zoom, ch * zoom, false, Image.FORMAT_RGBA8)
	var over_white: Image = Image.create(cw * zoom, ch * zoom, false, Image.FORMAT_RGBA8)
	var dark := Color(0.08, 0.09, 0.14)
	for y in ch:
		for x in cw:
			var c := crop.get_pixel(x, y)
			var d := dark.lerp(c, c.a)
			var wt := Color.WHITE.lerp(c, c.a)
			for dy in zoom:
				for dx in zoom:
					big.set_pixel(x * zoom + dx, y * zoom + dy, c)
					over_dark.set_pixel(x * zoom + dx, y * zoom + dy, d)
					over_white.set_pixel(x * zoom + dx, y * zoom + dy, wt)
	var base_path := ProjectSettings.globalize_path(out)
	big.save_png(base_path)
	over_dark.save_png(base_path.replace(".png", "_dark.png"))
	over_white.save_png(base_path.replace(".png", "_white.png"))
	print("已保存 %s(带alpha) / _dark / _white；视口=%s 裁剪(%d,%d %dx%d) 放大 %dx" % [
		out, vp, x0, y0, cw, ch, zoom])

	# 亮且半透明的像素：叠在深色桌面上就会发白 —— 正是"白色小锯齿"的候选
	var bp := 0
	var bo := 0
	var solid := 0
	var samples: Array = []
	for y in ch:
		for x in cw:
			var c := crop.get_pixel(x, y)
			if c.a > 0.5:
				solid += 1            # 实心像素数：用来确认某个变体没有把几何吃掉
			var lum := (c.r + c.g + c.b) / 3.0
			if lum <= 0.5:
				continue
			if c.a < 0.98:
				bp += 1
				if samples.size() < 14:
					samples.append("(%d,%d) rgb=(%.2f,%.2f,%.2f) a=%.2f" % [
						x0 + x, y0 + y, c.r, c.g, c.b, c.a])
			else:
				bo += 1
	print("SUMMARY %s solid=%d bright_partial=%d bright_opaque=%d" % [variant, solid, bp, bo])
	print("  亮(>0.5)+半透明(a<0.98): %d  <- 叠深色桌面会发白的候选" % bp)
	print("  亮(>0.5)+不透明:          %d" % bo)
	for s in samples:
		print("    " + s)
	quit(0)

## 只保留名字以给定前缀开头的 MeshInstance3D，其余隐藏 ——
## 用来确认"某个白色形状"到底是哪一块部件。
func _hide_except(root: Node, prefixes: Array) -> void:
	var hidden := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not (n is MeshInstance3D):
			continue
		var keep := false
		for p in prefixes:
			if String(n.name).begins_with(p):
				keep = true
				break
		if not keep:
			(n as MeshInstance3D).visible = false
			hidden += 1
	print("  只留 [%s]，隐藏了 %d 个网格" % [", ".join(prefixes), hidden])

## 关掉高光，用来判断亮边是不是镜面反射造成的
func _set_specular(root: Node) -> void:
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
			var m: Material = mi.get_surface_override_material(si)
			if m == null:
				m = mi.mesh.surface_get_material(si)
			if m is StandardMaterial3D:
				var sm: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
				sm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				mi.set_surface_override_material(si, sm)
