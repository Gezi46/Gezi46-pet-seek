# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 把一张现成的图片裁成图标（正方形 PNG）。
##
## 用法: --path <项目> --script res://tools/make_icon.gd -- <源图> [模式] [边长] [输出]
##   源图  = 绝对路径（Image.load_from_file 要的是真实路径）
##   模式  = head（默认，以脸为中心按整高取方形）/ pad（按角色实际宽度取方形，四周补底色）
##   边长  = 默认 256
##   输出  = 默认 res://icon.png
##
## 为什么不用普通截图工具手裁：这张源图是 322x177 的横条，**背景是不透明的深灰
## (25,25,25)**。手裁很难对准 —— 这里先把"跟底色不一样"的像素扫出实际范围，
## 再据此定位，最后补成正方形，所以角色一定是居中的。
extends SceneTree

## 跟底色差多少才算"是角色"。底色是纯色平面，所以这个阈值只要躲开压缩噪点即可
const BG_TOL := 12
## pad 模式上方额外留的边距（占角色尺寸的比例）
const PAD_RATIO := 0.08

var _src := ""
var _mode := "head"
var _size := 256
var _out := "res://icon.png"

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		push_error("用法: -- <源图> [head|pad] [边长] [输出]")
		quit(1)
		return
	_src = String(a[0])
	if a.size() > 1:
		_mode = String(a[1])
	if a.size() > 2:
		_size = maxi(int(a[2]), 16)
	if a.size() > 3:
		_out = String(a[3])
	_go.call_deferred()

func _go() -> void:
	var img := Image.load_from_file(_src)
	if img == null or img.is_empty():
		push_error("读不了这张图：%s" % _src)
		quit(1)
		return
	img.convert(Image.FORMAT_RGBA8)
	var bg := img.get_pixel(0, 0)
	var box := _content_box(img, bg)
	print("源图 %dx%d  底色=%s  角色实际范围=%s" % [
		img.get_width(), img.get_height(), bg, box])
	if box.size.x <= 0:
		push_error("找不到角色（整张都是底色？）")
		quit(1)
		return

	var out := _crop(img, box, bg)
	out.resize(_size, _size, Image.INTERPOLATE_LANCZOS)
	out.save_png(_out)
	print("已保存 %s  %dx%d（裁剪方式=%s）" % [_out, out.get_width(), out.get_height(), _mode])
	quit(0)

## "跟底色不一样"的像素的实际范围
func _content_box(img: Image, bg: Color) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	var br := int(bg.r * 255.0)
	var bgc := int(bg.g * 255.0)
	var bb := int(bg.b * 255.0)
	for y in h:
		var row := y * w * 4
		for x in w:
			var i := row + x * 4
			var dr: int = absi(int(data[i]) - br)
			var dg: int = absi(int(data[i + 1]) - bgc)
			var db: int = absi(int(data[i + 2]) - bb)
			if maxi(dr, maxi(dg, db)) > BG_TOL:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0 or max_y < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)

## 按模式裁出正方形。两种都保证不切到角色的水平中线（以角色范围的中心为准）。
func _crop(img: Image, box: Rect2i, bg: Color) -> Image:
	var cx: int = box.position.x + box.size.x / 2
	if _mode == "pad":
		# 按角色实际尺寸取方形，空的地方补底色 —— 角色一定顶满、居中。
		# 只在上方留边距，**底部齐平**：源图是在胸口裁断的，底下再垫一块底色
		# 就会露出一条"裁切线"，看着像少了一截。
		var base: int = maxi(box.size.x, box.size.y)
		var side: int = base + int(round(float(base) * PAD_RATIO))
		var canvas := _new_image(side, side)
		canvas.fill(bg)
		var dst := Vector2i((side - box.size.x) / 2, side - box.size.y)
		canvas.blit_rect(img, box, dst)
		return canvas
	# head（默认）：用源图的整高做边长，横向以角色中心对齐 ——
	# 源图本身就是"头肩"裁切，这样出来的方图上下正好顶到边，不浪费像素
	var side2: int = img.get_height()
	var x0: int = clampi(cx - side2 / 2, 0, maxi(img.get_width() - side2, 0))
	var canvas2 := _new_image(side2, side2)
	canvas2.fill(bg)
	canvas2.blit_rect(img, Rect2i(x0, 0, side2, side2), Vector2i.ZERO)
	return canvas2

## 按引擎版本选构造函数：新版本把 Image.create 改名成 create_empty 了
func _new_image(w: int, h: int) -> Image:
	if ClassDB.class_has_method("Image", "create_empty", true):
		return Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	return Image.create(w, h, false, Image.FORMAT_RGBA8)
