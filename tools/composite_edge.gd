# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 把带 alpha 的透明渲染图合成到深色背景上（模拟桌面），并统计边缘色偏，
## 这样能看到"透到桌面上"到底是什么颜色。
## 用法: godot --path <项目> --script res://tools/composite_edge.gd -- in.png out.png
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
	var src: String = args[0]
	var dst: String = args[1]
	var bgcol := Color(0.08, 0.09, 0.14)

	var img := Image.new()
	if img.load(ProjectSettings.globalize_path(src)) != OK:
		printerr("读不到 " + src)
		quit(1)
		return
	img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)

	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			out.set_pixel(x, y, bgcol.lerp(c, c.a))
	out.save_png(ProjectSettings.globalize_path(dst))

	# 统计"轮廓外侧 2 像素环"的平均亮度：模型是深蓝，环若偏亮就说明有亮边
	var ring_lum := 0.0
	var ring_n := 0
	for y in range(2, h - 2):
		for x in range(2, w - 2):
			if img.get_pixel(x, y).a > 0.5:
				continue
			# 该像素附近 3x3 内有实体，说明它在轮廓外圈
			var near := false
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if img.get_pixel(x + dx, y + dy).a > 0.5:
						near = true
						break
				if near:
					break
			if near:
				var c2 := out.get_pixel(x, y)
				ring_lum += (c2.r + c2.g + c2.b) / 3.0
				ring_n += 1

	print("已保存 %s" % dst)
	print("  轮廓外圈(2px)像素数 %d，平均亮度 %.4f" % [ring_n, (ring_lum / ring_n) if ring_n > 0 else 0.0])
	quit(0)
