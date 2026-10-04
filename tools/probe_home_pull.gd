# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 验"家 / 初始位置"这一套。**必须带窗口跑**（headless 下 window_get_size() 是 0，
## 停靠位置和"离家多远"都测不出来）：
##   用法: & $godot --path . --script res://tools/probe_home_pull.gd
##   A. 默认锚点是右下角，_home_pos() 落在可用区域右下角贴边
##   B. 远离家时 _pick_move_dir 偏向回家；关掉 home_pull 就回到随机
##   C. set_home_here() 记住当前位置；新实例能读回来；菜单「恢复右下角」能重置
##   D. 菜单项数量/文案
## 会临时改动 user://pet_home.cfg，跑完把原内容还回去。
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 3000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var cfg_path: String = ProjectSettings.globalize_path("user://pet_home.cfg")
	var had := FileAccess.file_exists(cfg_path)
	var backup := FileAccess.get_file_as_bytes(cfg_path) if had else PackedByteArray()

	var pet: Node = await _spawn()
	var screen: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	print("屏幕可用区域=%s 窗口=%s" % [screen, DisplayServer.window_get_size()])
	print("A 默认锚点=%s -> 家的窗口位置=%s（期望右下角贴边 %s）" % [
		pet.get("home_anchor"), pet.call("_home_pos"),
		screen.position + screen.size - DisplayServer.window_get_size()])

	# B. 把窗口挪到屏幕左上角（离家最远），看挑方向是否偏向家（右下）
	DisplayServer.window_set_position(screen.position + Vector2i(20, 20))
	var toward := 0
	var N := 300
	for i in N:
		var d: Vector2 = pet.call("_pick_move_dir")
		if d == Vector2.RIGHT or d == Vector2.DOWN:
			toward += 1
	print("B 在左上角（离家 %d px）：%d/%d 次指向家" % [
		Vector2(screen.position + Vector2i(20, 20) - pet.call("_home_pos")).length(), toward, N])
	pet.set("home_pull", 0.0)
	toward = 0
	for i in N:
		var d: Vector2 = pet.call("_pick_move_dir")
		if d == Vector2.RIGHT or d == Vector2.DOWN:
			toward += 1
	print("  关掉引力后：%d/%d 次朝右下（期望约一半）" % [toward, N])
	pet.set("home_pull", 0.8)

	# C. 拖到某处 -> set_home_here() -> 新实例读回
	var moved: Vector2i = screen.position + Vector2i(screen.size.x / 3, screen.size.y / 4)
	DisplayServer.window_set_position(moved)
	pet.call("set_home_here")
	var expected: Vector2 = Vector2(moved - screen.position) / Vector2(
		screen.size - DisplayServer.window_get_size())
	print("C 挪到 %s 后 set_home_here()：锚点=%s（期望约 %s）  存盘=%s" % [
		moved, pet.get("home_anchor"), expected.round(),
		FileAccess.get_file_as_string(cfg_path).strip_edges().replace("\n", " | ")])
	pet.queue_free()
	await process_frame
	var pet2: Node = await _spawn()
	print("  新实例读回锚点=%s（期望约 %s）  家的窗口位置=%s（期望 %s）" % [
		pet2.get("home_anchor"), expected.round(),
		pet2.call("_home_pos"), moved])
	pet2.call("_on_menu_id", 10)
	print("  菜单「恢复右下角」后锚点=%s（期望 (1, 1)）" % pet2.get("home_anchor"))

	# D. 菜单
	var menu: PopupMenu = pet2.get_node("UI/Menu")
	var texts: Array[String] = []
	for i in menu.item_count:
		texts.append("[%d] %s" % [menu.get_item_id(i), menu.get_item_text(i)])
	print("D 菜单 %d 项：%s" % [menu.item_count, " ".join(texts)])

	if had:
		var f := FileAccess.open(cfg_path, FileAccess.WRITE)
		f.store_buffer(backup)
		f.close()
	else:
		DirAccess.remove_absolute(cfg_path)
	print("配置已还原（原本%s）" % ("存在" if had else "不存在"))
	quit(0)

func _spawn() -> Node:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame
	pet.set_process(false)     # 别让它自己走动把窗口挪了，干扰测量
	return pet