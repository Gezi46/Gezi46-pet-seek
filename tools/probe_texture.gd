# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 分析贴图：alpha 分布，以及"完全透明但紧邻不透明"的那圈像素是什么颜色。
## 如果那圈颜色偏白/偏亮，线性过滤就会把它混进边缘 —— 那就是白边的来源。
var _frames := 0

func _initialize() -> void:
	# 万一还是卡住，600 帧后强制退出，避免命令行一直挂着
	_run.call_deferred()

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 600:
		printerr("看门狗触发：分析超时")
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
	print("贴图 %dx%d format=%d" % [w, h, img.get_format()])

	var total := 0
	var zero := 0
	var full := 0
	var mid := 0
	for y in h:
		for x in w:
			var a: float = img.get_pixel(x, y).a
			total += 1
			if a <= 0.001:
				zero += 1
			elif a >= 0.999:
				full += 1
			else:
				mid += 1
	print("总 %d：完全不透明 %d (%.1f%%)，完全透明 %d (%.1f%%)，半透明 %d (%.2f%%)" % [
		total, full, 100.0 * full / total, zero, 100.0 * zero / total, mid, 100.0 * mid / total])

	var ring: Array[Color] = []
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.001:
				continue
			var touches := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if img.get_pixel(nx, ny).a > 0.5:
					touches = true
					break
			if touches:
				ring.append(c)

	print("透明但紧贴不透明区的像素数: %d" % ring.size())
	if ring.is_empty():
		quit(0)
		return
	var sum := Vector3.ZERO
	var bright := 0
	for c in ring:
		sum += Vector3(c.r, c.g, c.b)
		if (c.r + c.g + c.b) / 3.0 > 0.5:
			bright += 1
	var avg: Vector3 = sum / float(ring.size())
	print("这圈平均 RGB = (%.3f, %.3f, %.3f)，平均亮度 %.3f" % [
		avg.x, avg.y, avg.z, (avg.x + avg.y + avg.z) / 3.0])
	print("偏亮(>0.5)占比: %.1f%%" % (100.0 * bright / ring.size()))
	var sample := ""
	for i in mini(8, ring.size()):
		sample += "(%.2f,%.2f,%.2f) " % [ring[i].r, ring[i].g, ring[i].b]
	print("样本: %s" % sample)
	quit(0)
