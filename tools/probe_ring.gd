# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 贴图分析（关键）：完全透明、但紧贴着不透明像素的那圈 texel，RGB 到底是什么颜色。
## 用最近邻采样时，方块边缘的 UV 很容易正好落在这一圈上 —— 如果它是白的，就是白边。
var _f := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_f += 1
	if _f > 900:
		quit(2)
		return true
	return false

func _run() -> void:
	var res: Variant = load("res://peekdeek_opt_0.png")
	var img: Image = null
	if res is Texture2D:
		img = (res as Texture2D).get_image()
	elif res is Image:
		img = res
	if img == null:
		printerr("拿不到 Image")
		quit(1)
		return
	img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	print("贴图 %dx%d" % [w, h])

	var ring: Array[Color] = []
	var white_texels := 0
	var opaque := 0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				opaque += 1
				if minf(c.r, minf(c.g, c.b)) > 0.9:
					white_texels += 1
				continue
			var touches := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					if img.get_pixel(nx, ny).a > 0.5:
						touches = true
						break
				if touches:
					break
			if touches:
				ring.append(c)

	print("不透明 texel %d（其中近白 %d，占 %.1f%%）" % [
		opaque, white_texels, 100.0 * white_texels / maxi(opaque, 1)])
	print("紧贴不透明区的透明 texel: %d" % ring.size())
	if ring.is_empty():
		quit(0)
		return
	var s := Vector3.ZERO
	var bright := 0
	var near_white := 0
	for c in ring:
		s += Vector3(c.r, c.g, c.b)
		var lum := (c.r + c.g + c.b) / 3.0
		var mx := maxf(c.r, maxf(c.g, c.b))
		var mn := minf(c.r, minf(c.g, c.b))
		if lum > 0.5:
			bright += 1
		if lum > 0.7 and (mx - mn) < 0.15:
			near_white += 1
	var avg: Vector3 = s / float(ring.size())
	print("  平均 RGB = (%.3f, %.3f, %.3f)，亮度 %.3f" % [avg.x, avg.y, avg.z, (avg.x + avg.y + avg.z) / 3.0])
	print("  偏亮(>0.5) %d (%.1f%%)，接近白(>0.7且低饱和) %d (%.1f%%)" % [
		bright, 100.0 * bright / ring.size(), near_white, 100.0 * near_white / ring.size()])
	quit(0)
