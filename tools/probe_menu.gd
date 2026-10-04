# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 验"右键菜单一打开就被盖住"这件事。
##
## 根因是**每 2 秒一次的"重申置顶"**：宠物自己是置顶窗口，重申会把它抬到
## "置顶组最前面"，也就是菜单前面。菜单（PopupMenu）是独立系统窗口、Godot 本来
## 就把它建成了置顶（实测 ex-style 里 TOPMOST=True），所以只要**菜单开着时别重申**，
## 它自然就在上面。
##
## 判据用系统 z 序：宠物和菜单同属一个进程，按"有标题 / 没标题"分别取编号，
## 编号小的在上面。菜单开着的 3.5 秒里连续采样 —— 这期间至少会跨过一次重申，
## 正是以前出问题的那一刻。
##
## 用法: --path <项目> --script res://tools/probe_menu.gd
## 注意：不能 --headless（要真窗口，菜单也是真窗口）
extends SceneTree

var _pet: Node = null
var _shell: RefCounted = null
var _menu: PopupMenu = null

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 6:
		await process_frame
	_shell = _pet.get("shell")
	_menu = _pet.get_node_or_null("UI/Menu")
	if _shell == null or _menu == null:
		print("! shell 或 UI/Menu 没找到")
		quit(1)
		return

	print("")
	print("=== 菜单打开期间，它必须一直在宠物前面 ===")
	_menu.popup(Rect2i(Vector2i(200, 200), Vector2i.ZERO))
	await process_frame
	await process_frame
	print("  菜单弹出后，意愿文件 =「%s」（第 3 个数应为 1 = 菜单开着）" % _want())
	print("  这会儿的窗口列表：")
	for l in _styles():
		var t := String(l).strip_edges()
		if t.contains("visible=True"):
			print("    %s" % t)

	var until := Time.get_ticks_msec() + 8000
	var bad := 0
	var samples := 0
	var first := true
	while Time.get_ticks_msec() < until:
		await process_frame
		if _menu.visible:
			var z := _zboth()
			if first:
				print("  第一次采样：宠物=%d 菜单=%d  当前意愿=「%s」" % [z[0], z[1], _want()])
				first = false
			if z[0] >= 0 and z[1] >= 0:
				samples += 1
				if z[1] >= z[0]:
					bad += 1
	print("  菜单开着 8 秒（跨过好几轮维持）采样 %d 次：被压到后面 %d 次  %s" % [
		samples, bad, "✅ 一直稳稳在前面" if (bad == 0 and samples > 0) else "❌ 还是会被盖住"])
	print("  shell.popup_open=%s（菜单开着时为 true，重申才会被跳过）" % _shell.popup_open)
	for l in _styles():
		var t := String(l).strip_edges()
		if t.contains("visible=True") and t.contains("titled=False"):
			print("  菜单那个窗口的 ex-style：%s %s" % [
				"✅" if t.contains("TOPMOST=True") else "❌", t])

	_menu.hide()
	await process_frame
	await process_frame
	print("  关掉菜单后 popup_open=%s（应为 false，置顶该恢复了）" % _shell.popup_open)
	# 关菜单会恢复置顶，那一步会让 Godot 重算窗口样式、把"不进任务栏"冲掉，
	# 要靠辅助进程补回来 —— 所以这里多等几轮，并把它活着没活着一起打出来
	await create_timer(6.0).timeout
	var wpid: int = _shell.get("_watcher_pid")
	print("  辅助进程 pid=%s 活着=%s（它负责把被冲掉的样式补回来）" % [
		wpid, OS.is_process_running(wpid) if wpid > 0 else false])
	var z2 := _zboth()
	print("  恢复置顶后：宠物 z 序=%d  菜单窗口 z 序=%d（-1 = 已经没有这个窗口）" % [z2[0], z2[1]])
	print("  宠物还在任务栏隐藏状态吗：%s" % _styles_toolwindow())
	print("  （下面是她所有可见窗口，方便判断检查本身有没有看错）")
	for l in _styles():
		var t := String(l).strip_edges()
		if t.contains("visible=True"):
			print("    %s" % t)
	quit(0)

## 顺手确认"维持置顶"这件事没有再把任务栏那一位冲掉
func _styles_toolwindow() -> String:
	for l in _styles():
		var t := String(l).strip_edges()
		if t.contains("visible=True") and t.contains("TOOLWINDOW=True"):
			return "✅ 是（%s）" % t
	return "❌ 不在隐藏状态"

## 一次拿到两个 z 序编号：[她自己的窗口, 菜单窗口]（0 = 最上层，越小越靠前）
## 用 TOOLWINDOW 位区分两者（她那位是我们设的），不靠"有没有标题"——
## Godot 给 PopupMenu 也设了窗口标题，按标题分不开
func _zboth() -> Array:
	var out: Array = []
	OS.execute(_shell.powershell(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _shell.ps1_path(), "zboth", str(OS.get_process_id())], out, true)
	var text := ""
	for l in out:
		text += String(l)
	var p: PackedStringArray = text.strip_edges().split(" ")
	if p.size() >= 2:
		return [int(p[0]), int(p[1])]
	return [-1, -1]

func _want() -> String:
	var f := FileAccess.open("user://pet_shell_want.txt", FileAccess.READ)
	if f == null:
		return "<没有文件>"
	var t := f.get_as_text().strip_edges()
	f.close()
	return t

func _styles() -> Array:
	var out: Array = []
	OS.execute(_shell.powershell(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _shell.ps1_path(), "styles", str(OS.get_process_id())], out, true)
	return out
