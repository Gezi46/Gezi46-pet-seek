# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 气泡：显示 / 撑高 / 淡出，以及流式冒字期间的"按住"（由 desktop_pet.gd preload 为 PetBubble）。
##
## 刻意不碰任何"忙"标记 —— 收流（PetChatHub 的 streaming）和摄像头
## （camera_busy）是两条独立的链路，只是共用这一个气泡，状态各管各的。

## 宿主（Node3D），只用来 create_tween —— tween 得挂在场景树上的节点上
var pet: Node3D = null
## 场景里的气泡 Label（UI/Anchor/Bubble）
var label: Label = null
## 淡出用的 tween，留着是为了中途掐掉
var tween: Tween = null


func setup(pet_node: Node3D, bubble_label: Label) -> void:
	pet = pet_node
	label = bubble_label


## 说一句就淡出。流中途**不能**用它 —— 那会带一个 1.8 秒的淡出，把气泡藏掉
func say(text: String) -> void:
	label.text = text
	label.visible = true
	label.modulate.a = 1.0
	fit(text)
	# 先掐掉上一次的淡出：不掐的话流式冒字到一半会被旧 tween 把气泡藏掉
	if tween != null and tween.is_valid():
		tween.kill()
	tween = pet.create_tween()
	tween.tween_interval(1.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.6)
	tween.tween_callback(func() -> void: label.visible = false)


## 流式冒字的起手式：清空气泡、掐掉旧的淡出 tween
func begin_stream() -> void:
	hold()


## 把气泡"按住"：掐掉旧的淡出 tween、清空、显出来
func hold() -> void:
	if tween != null and tween.is_valid():
		tween.kill()
	label.text = ""
	label.modulate.a = 1.0
	label.visible = true
	fit("…")


## 按住并先写一句起手词（摄像头冷启动要等一两分钟，别让她干站着）
func hold_with(text: String) -> void:
	hold()
	label.text = text
	fit(text)


## 流式冒字：追加一段增量，重新撑高
func append_token(t: String) -> void:
	label.text += t
	fit(label.text)


## 气泡是不是还亮着（判断"有没有人在互动"用）
func is_visible() -> bool:
	return label.visible


## 气泡在场景里是固定 50px 高，两行以上会被裁掉。
## 按实际排版高度把底边撑开（autowrap 开着，得用字体量）
func fit(text: String) -> void:
	var f: Font = label.get_theme_font("font")
	if f == null:
		return
	var fs: int = label.get_theme_font_size("font_size")
	var w: float = maxf(40.0, label.size.x)
	var h: float = f.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_CENTER, w, fs).y
	label.offset_bottom = label.offset_top + maxf(50.0, h + 16.0)
