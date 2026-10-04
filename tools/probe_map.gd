# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## **代码地图**：一行命令把 scripts/ 的结构打出来 —— 不用把九千行读一遍。
##
##     godot --headless --path . --script res://tools/probe_map.gd
##
## 每个文件给：行数、一句话职责（取文件第一个 `##` 注释）、函数数 / @export 数、
## 以及**分区**（形如 `# ---------------- 名字`）的名字与行号区间。
##
## 为什么要有这个：主脚本两千多行、19 个脚本九千多行，靠文件名猜不到哪块在哪。
## 改东西之前先跑它，就知道该动哪个文件、大概多少行 —— 也让"读代码"这件事
## 变成一次调用，而不是把整个文件吞进去
##
## 它只读文件、不改任何东西，跑完自动退出。

func _initialize() -> void:
	_scan("res://scripts", "脚本")
	_scan("res://tools", "工具/自检")
	quit(0)

## 递归收集 .gd；名字带上相对路径（`body/pet_pointer.gd`），一眼能看出它住在哪个子目录。
## 顺带跳过 `.godot` 那类点开头的目录
func _collect(dir_path: String, prefix: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			if not n.begins_with("."):
				_collect(dir_path + "/" + n, prefix + n + "/", out)
		elif n.ends_with(".gd"):
			out.append(prefix + n)
		n = dir.get_next()
	dir.list_dir_end()

func _scan(dir_path: String, title: String) -> void:
	# **递归**扫（作业单 D1 之后 scripts/ 分了 ai / ui / sys / body 四个子目录）——
	# 只扫一层会漏掉 36 个文件里的 35 个，而地图的用处正是"一眼看全"
	var names: Array = []
	_collect(dir_path, "", names)
	if names.is_empty():
		return
	# 按行数降序：大文件排前面，正好是"最该被拆/最该先看"的顺序
	var rows: Array = []
	var total := 0
	for name in names:
		# name 是无类型 Array 里的元素（Variant），拼出来也是 Variant —— 显式写 String
		var path: String = dir_path + "/" + String(name)
		var lines := _read_lines(path)
		total += lines.size()
		rows.append({"name": name, "lines": lines})
	rows.sort_custom(func(a, b): return a["lines"].size() > b["lines"].size())
	print("")
	print("=== %s（%s）：%d 个文件 / %d 行 ===" % [dir_path, title, rows.size(), total])
	for r in rows:
		_dump(String(r["name"]), r["lines"])

func _dump(name: String, lines: Array) -> void:
	var funcs := 0
	var exports := 0
	var marks: Array = []          # [{line, title}]
	for i in lines.size():
		var s := String(lines[i])
		if s.begins_with("func "):
			funcs += 1
		elif s.begins_with("@export"):
			exports += 1
		if s.begins_with("#") and _is_marker(s):
			marks.append({"line": i + 1, "title": _marker_title(s)})
	var purpose := _purpose(lines)
	print("")
	print("%5d 行  %-22s %s" % [lines.size(), name, purpose])
	print("       %d 个函数" % funcs + ("／%d 个 @export" % exports if exports > 0 else "") \
		+ ("／%d 个分区" % marks.size() if not marks.is_empty() else ""))
	# 宪法第一节：超过 500 行的文件要么拆，要么在文件头留一行「体量豁免」说明为什么拆不动。
	# 地图顺手把这两种情况分出来 —— 不然"该拆的"会一直躺在那里没人发现
	var exempt := _exempt(lines)
	if lines.size() > 500 and exempt == "":
		print("       ⚠ 超过 500 行、且没有「体量豁免」那行 —— 按 CONVENTIONS.md 第一节该找接缝拆")
	elif exempt != "":
		print("       体量豁免：%s" % exempt)
	for k in marks.size():
		var start := int(marks[k]["line"])
		var end: int = int(marks[k + 1]["line"]) - 1 if k + 1 < marks.size() else lines.size()
		var span := end - start
		if span < 25:
			continue          # 太短的分区不列，免得地图比代码还长
		print("            [%5d-%5d]  %s" % [start, end, String(marks[k]["title"])])

## 找文件头里的「体量豁免：…」那行（宪法第一节要求超标文件必须留案）。
## 只扫前 40 行 —— 它必须在头部，藏在文件中间就不算
func _exempt(lines: Array) -> String:
	for i in mini(lines.size(), 40):
		var s := String(lines[i]).strip_edges()
		if s.begins_with("##") and s.find("体量豁免") >= 0:
			return s.trim_prefix("#").strip_edges()
	return ""

## 取文件开头第一段 `##` 注释的第一句当职责说明
func _purpose(lines: Array) -> String:
	for i in lines.size():
		var s := String(lines[i]).strip_edges()
		if s.begins_with("##"):
			var t := s.trim_prefix("#").strip_edges()
			if t != "":
				return t.substr(0, 46)
		# extends / class_name 常常排在文件头注释**之前**（desktop_pet.gd 就是这样），
		# 所以这里只跳过、不能 break —— break 会让那种文件显示成"没有说明"
		elif s.begins_with("extends") or s.begins_with("class_name"):
			continue
	return "（文件头没有说明）"

## 分区标记：以 # 开头、后面跟着 3 个以上连字符（行尾有没有连字符都算）
func _is_marker(s: String) -> bool:
	var t := s.strip_edges()
	if not t.begins_with("#"):
		return false
	var body := t.trim_prefix("#").strip_edges()
	return body.begins_with("---")

func _marker_title(s: String) -> String:
	var body := s.strip_edges().trim_prefix("#").strip_edges()
	body = body.lstrip("-").strip_edges()
	body = body.rstrip("-").strip_edges()
	return body

func _read_lines(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		out.append(f.get_line())
	f.close()
	return out
