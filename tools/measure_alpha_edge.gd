# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 直接分析透明渲染图自身的 alpha 边缘：
## 沿水平扫描线找 alpha 从 0 跳到 1 的位置，看"边缘那一两个半透明像素"的颜色。
## 如果那些像素偏亮/偏白，透到桌面上就是白边。
## 用法: godot --path <项目> --script res://tools/measure_alpha_edge.gd -- a.png b.png
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 1200:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	for p in OS.get_cmdline_user_args():
		_measure(p)
	quit(0)

func _measure(path: String) -> void:
	var abs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(path)
	var img := Image.new()
	if img.load(abs_path) != OK:
		print("%s : 读不到" % path)
		return
	img.decompress()
	var w := img.get_width()
	var h := img.get_height()

	var total := 0
	var opaque := 0
	var clear := 0
	var partial := 0
	var partial_lum := 0.0
	var partial_bright := 0
	var edge_lum := 0.0
	var edge_n := 0

	for y in h:
		for x in w:
			var a := img.get_pixel(x, y).a
			total += 1
			if a >= 0.99:
				opaque += 1
			elif a <= 0.01:
				clear += 1
			else:
				partial += 1
				var c := img.get_pixel(x, y)
				var lum := (c.r + c.g + c.b) / 3.0
				partial_lum += lum
				if lum > 0.5:
					partial_bright += 1

	# 只统计"半透明且左右邻居一透一实"的真正轮廓像素
	for y in h:
		for x in range(1, w - 1):
			var a := img.get_pixel(x, y).a
			if a <= 0.02 or a >= 0.98:
				continue
			var al := img.get_pixel(x - 1, y).a
			var ar := img.get_pixel(x + 1, y).a
			if (al <= 0.02 and ar >= 0.98) or (al >= 0.98 and ar <= 0.02):
				var c2 := img.get_pixel(x, y)
				edge_lum += (c2.r + c2.g + c2.b) / 3.0
				edge_n += 1

	print("=== %s ===" % path)
	print("  不透明 %d，全透明 %d，半透明 %d (%.3f%%)" % [
		opaque, clear, partial, 100.0 * partial / total])
	if partial > 0:
		print("  半透明平均亮度 %.3f，其中偏亮(>0.5) %d (%.1f%%)" % [
			partial_lum / partial, partial_bright, 100.0 * partial_bright / partial])
	print("  真正轮廓上的半透明像素: %d 个，平均亮度 %.3f" % [
		edge_n, (edge_lum / edge_n) if edge_n > 0 else 0.0])
