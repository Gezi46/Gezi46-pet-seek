# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 面板公用的 UI 零件：卡片底、标题、标签、输入框、勾选框、数字框、按钮。
##
## 为什么单独一个文件：
##   AI 设置面板（pet_menu.gd）和设置面板（pet_settings.gd）本来各写了一份
##   _label() / _edit() / 卡片样式 —— 改一处忘一处，两个面板的风格就开始漂
##   （字号差 1、圆角一个有一个没有，都是这么来的）。这里只放"长什么样"。
##
## 全是 static：不需要实例，也不该持有状态 —— 面板自己拿它搭控件就行。
##
## 注意字体要**显式传进来**：中文字体是主脚本运行时建的 SystemFont
## （项目里没配全局中文字体，不挂的话中文会掉字），模块不该自己去 new 一个。

const TEXT_MAIN := Color(0.10, 0.11, 0.20)
const TEXT_SUB := Color(0.42, 0.44, 0.52)
const TEXT_WARN := Color(0.45, 0.35, 0.25)
const BORDER := Color(0.62, 0.64, 0.74)

## 面板卡片底：白底 + 圆角 + 一圈淡边框。
## 桌面是五花八门的，纯白卡片才压得住（半透明的话身后的壁纸会透进来，字就糊了）
static func card() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.96)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)
	sb.border_color = Color(0.60, 0.63, 0.75)
	sb.set_border_width_all(1)
	return sb

## 给 Control 套中文字体。
## 注意 PopupMenu 不能走这里（它是 Window 不是 Control，类型不对会直接编译失败）——
## 菜单那边是另一条路，见 pet_menu.gd 的 _apply_menu_font。
static func apply_font(c: Control, font: Font) -> void:
	if font != null:
		c.add_theme_font_override("font", font)

## 面板外壳。调用方自己决定尺寸/锚点（设置面板占满整窗，AI 面板是居中固定宽）
static func panel() -> PanelContainer:
	var p := PanelContainer.new()
	# STOP：面板是实心的，点它不该穿到后面的窗口去
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel", card())
	return p

static func label(text: String, font: Font, size: int = 12, color: Color = TEXT_MAIN) -> Label:
	var l := Label.new()
	l.text = text
	apply_font(l, font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

## 面板大标题
static func title(text: String, font: Font) -> Label:
	return label(text, font, 15, TEXT_MAIN)

## 分组标题
static func section(text: String, font: Font) -> Label:
	return label(text, font, 13, Color(0.20, 0.24, 0.45))

## 说明文字：小、灰、自动换行
static func hint(text: String, font: Font) -> Label:
	var l := label(text, font, 11, TEXT_SUB)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

## 输入框的白底样式。抽出来是因为 SpinBox 内部那个 LineEdit 也要用同一套 ——
## 不然一列控件里白底输入框和黑底数字框混在一起，看着像两个时代的界面
static func edit_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.98)
	sb.border_color = BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(4)
	return sb

## 输入框。
## **字色必须自己指定**：我们把底色换成了白的，但默认主题的字色是给深色底准备的
## 浅灰 —— 结果就是"打进去的字几乎看不见"，只有下标光标在动。
## （这个毛病在原来的 AI 设置面板里就有，只是没人细看。）
static func edit(placeholder: String, font: Font) -> LineEdit:
	var e := LineEdit.new()
	apply_font(e, font)
	e.add_theme_font_size_override("font_size", 12)
	e.placeholder_text = placeholder
	e.add_theme_color_override("font_color", TEXT_MAIN)
	e.add_theme_color_override("font_selected_color", TEXT_MAIN)
	e.add_theme_color_override("caret_color", TEXT_MAIN)
	e.add_theme_color_override("font_placeholder_color", TEXT_SUB)
	var sb := edit_style()
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", sb)
	return e

## 勾选框。**文字颜色必须自己指定**：默认主题是按深色背景设计的，它的字色是浅灰，
## 落在我们这张白卡片上几乎看不清（实测截图确认过）。三种状态都指定，不然鼠标一停
## 上去颜色又变了。
static func check(text: String, on: bool, font: Font) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	apply_font(c, font)
	c.add_theme_font_size_override("font_size", 12)
	c.add_theme_color_override("font_color", TEXT_MAIN)
	c.add_theme_color_override("font_hover_color", TEXT_MAIN)
	c.add_theme_color_override("font_pressed_color", TEXT_MAIN)
	c.add_theme_color_override("font_focus_color", TEXT_MAIN)
	return c

## 数字框。左右两个箭头就能调，也可以直接敲数字。
## custom_minimum_size 是必须的：不给定宽的话它会被拉满整行，一列数字框看着很怪
static func spin(value: float, lo: float, hi: float, step: float, font: Font) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = clampf(value, lo, hi)
	s.custom_minimum_size = Vector2(92, 0)
	apply_font(s, font)
	# SpinBox 真正的文字在它内部的 LineEdit 里：字体、对齐、底色、字色都得单独给它
	# （对齐设在 LineEdit 上，SpinBox 自己不保证有 alignment 这个属性）
	var le := s.get_line_edit()
	if le != null:
		apply_font(le, font)
		le.add_theme_font_size_override("font_size", 12)
		le.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		le.add_theme_color_override("font_color", TEXT_MAIN)
		le.add_theme_color_override("font_selected_color", TEXT_MAIN)
		le.add_theme_color_override("caret_color", TEXT_MAIN)
		var sb := edit_style()
		le.add_theme_stylebox_override("normal", sb)
		le.add_theme_stylebox_override("focus", sb)
	return s

static func option(items: Array, sel: int, font: Font) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(String(it))
	if not items.is_empty():
		o.selected = clampi(sel, 0, items.size() - 1)
	apply_font(o, font)
	o.add_theme_font_size_override("font_size", 12)
	return o

static func button(text: String, font: Font) -> Button:
	var b := Button.new()
	b.text = text
	apply_font(b, font)
	b.add_theme_font_size_override("font_size", 12)
	return b

static func hbox(sep: int = 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h

## 把剩下的横向空间吃掉，用来把后面的东西顶到右边
static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c
