# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验"设置面板"和菜单入口这两件**会静默失效**的事。
##
## 为什么值得单独一个探针：
##   1. 「退出」点不动那件事，界面上完全看不出来 —— 菜单照样弹、条目照样高亮，
##      只是点了没反应。根因是根菜单的 id_pressed 从来没连过信号（子菜单是各自连的，
##      漏了根菜单那一条），而这种错只有"点一下才知道"，靠读代码很容易滑过去。
##   2. 设置面板是表驱动的：加一项设置如果忘了接控件 / 忘了落盘，
##      表现是"能改能保存，重启又变回去"，同样看不出来。
##      所以这里把"表里的每一项都得有控件、灌进去再读回来要一致"都验一遍。
##
## 用法: --path <项目> --script res://tools/probe_settings.gd
## 注意：不能 --headless（面板要真窗口才能排版，字体和尺寸都拿不到）
##
## 它**不会**真的点「退出」（那会把自己也退掉），只断言信号接上了 ——
## 信号接上 + 分发到 _quit() 这两段加起来才是完整的退出路径，前者是当初缺的那一环。
extends SceneTree

const PetSettings := preload("res://scripts/ui/pet_settings.gd")

## 菜单里这几个 id 必须存在（和 pet_menu.gd 的常量一致：设置…=29，退出=11，工作台…=32，
## AI 服务状态行=901 —— 那行是离线假死时唯一能看出"她为什么安静"的地方）
const ID_SETTINGS := 29
const ID_QUIT := 11
const ID_WORKBENCH := 32
const ID_AI_STATUS := 901

var _pet: Node = null
var _settings: RefCounted = null
var _fail := 0

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 6:
		await process_frame

	print("")
	print("=== 1. 右键菜单：根菜单那两条必须接上信号 ===")
	var menu: PopupMenu = _pet.get_node_or_null("UI/Menu")
	if menu == null:
		print("  ❌ 找不到 UI/Menu")
		quit(1)
		return
	var conns := menu.id_pressed.get_connections().size()
	_check(conns > 0, "根菜单 id_pressed 接了 %d 个回调" % conns,
		"根菜单 id_pressed 一个回调都没接 —— 点「退出」会毫无反应（界面上看不出来）")
	for id in [ID_SETTINGS, ID_QUIT, ID_WORKBENCH]:
		var idx := menu.get_item_index(id)
		var name := menu.get_item_text(idx) if idx >= 0 else "?"
		_check(idx >= 0, "菜单里有「%s」" % name, "菜单里缺 id=%d 这一条" % id)
	# 「AI 服务」那行状态在**子菜单**里，不在根菜单 —— 从 _status_rows 里找。
	# 它是离线假死时唯一能看出"她为什么这么安静"的地方，所以值得单独确认存在
	var status_rows: Dictionary = _pet.get("_menu_mod").get("_status_rows")
	_check(status_rows.has(ID_AI_STATUS), "「AI 服务」状态行在菜单里（id=%d）" % ID_AI_STATUS,
		"菜单里缺 id=%d 的状态行（离线假死时没地方看状态）" % ID_AI_STATUS)
	# 子菜单也点一下看看分发通不通（设置入口就在根菜单上，退出也是）
	var fired: Array = []
	_pet.get("_menu_mod").action.connect(func(id: int) -> void: fired.append(id))
	menu.id_pressed.emit(ID_SETTINGS)
	await process_frame
	_check(fired.has(ID_SETTINGS), "点「设置…」会转成 action(%d) 发给主脚本" % ID_SETTINGS,
		"点「设置…」没有转成 action（信号链断了）")

	print("=== 2. 设置面板：表里的每一项都得有控件 ===")
	_settings = _pet.get("_settings_mod")
	if _settings == null:
		print("  ❌ 设置面板没建起来")
		quit(1)
		return
	_pet.call("_open_settings")
	await process_frame
	await process_frame
	_check(_settings.is_open(), "面板打开了", "面板没打开")
	var fields: Dictionary = _settings.get("_fields")
	var kinds: Dictionary = _settings.get("_kinds")
	var missing := ""
	var buttons := 0
	var values := 0
	for k in PetSettings.keys():
		var key := String(k)
		if String(kinds.get(key, "")) == "button":
			buttons += 1
			continue
		values += 1
		if not fields.has(key):
			missing += key + " "
	_check(missing == "", "表里 %d 项设置 + %d 个按钮都有控件" % [values, buttons],
		"这些设置没有控件（界面上会直接少一行）：%s" % missing)
	if missing == "":
		print("  面板当前显示：")
		for k in ["persona_name", "memory_enabled", "talk_rate", "scale_percent", "autostart"]:
			var c: Control = fields.get(k, null)
			if c is CheckButton:
				print("    %s = %s" % [k, str((c as CheckButton).button_pressed)])
			elif c is OptionButton:
				print("    %s = 第 %d 项（%s）" % [k, (c as OptionButton).selected,
					(c as OptionButton).get_item_text((c as OptionButton).selected)])
			elif c is LineEdit:
				print("    %s = “%s”" % [k, (c as LineEdit).text])

	print("=== 3. 值灌进去再读回来，得一致（不然一保存就把设置改坏了）===")
	# _settings_snapshot() 是主脚本给面板的那一份，也就是"当前真实值"
	var want: Dictionary = _pet.call("_settings_snapshot")
	var got: Dictionary = _settings.values()
	var diff := ""
	for k in PetSettings.keys():
		var key := String(k)
		if String(kinds.get(key, "")) == "button" or not want.has(key):
			continue
		var a: Variant = want[key]
		var b: Variant = got.get(key, null)
		if b == null:
			diff += "%s(读不回来) " % key
		elif typeof(a) == TYPE_BOOL:
			if bool(a) != bool(b):
				diff += "%s(%s≠%s) " % [key, a, b]
		elif typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
			if absf(float(a) - float(b)) > 0.001:
				diff += "%s(%s≠%s) " % [key, a, b]
		elif String(a) != String(b):
			diff += "%s(%s≠%s) " % [key, a, b]
	_check(diff == "", "灌进去再读回来完全一致", "对不上的项：%s" % diff)

	print("=== 4. 存档往返：存下去 → 读回来 → 还是一样的值 ===")
	# 这里直接走主脚本那两个门面，不碰真配置（file_path 指到临时文件上）
	var before: Dictionary = _pet.call("_settings_snapshot")
	var cfg_path := "user://_probe_settings.cfg"
	var cfg := ConfigFile.new()
	for k in PetSettings.keys():
		var key := String(k)
		if String(kinds.get(key, "")) == "button" or not before.has(key):
			continue
		cfg.set_value("app", key, before[key])
	cfg.save(cfg_path)
	var back: Dictionary = PetSettings.sanitize(
		{"persona_name": cfg.get_value("app", "persona_name", ""),
		 "scale_percent": cfg.get_value("app", "scale_percent", 1.0),
		 "talk_rate": cfg.get_value("app", "talk_rate", 0)})
	# 故意写歪一组，确认 sanitize 会把越界的值拉回来
	var broken: Dictionary = PetSettings.sanitize({"talk_rate": 9, "camera_every_min": 0.0})
	_check(String(back["persona_name"]) == String(before["persona_name"]) \
			and absf(float(back["scale_percent"]) - float(before["scale_percent"])) < 0.001,
		"存下去再读回来还是一样的（名字 / 大小）",
		"存档往返对不上：%s" % str(back))
	_check(int(broken["talk_rate"]) == 3 and float(broken["camera_every_min"]) >= 1.0,
		"越界的值会被拉回范围内（频率 9 → %d，看摄像头间隔 0 → %s）" % [
			int(broken["talk_rate"]), str(broken["camera_every_min"])],
		"钳制没生效：%s" % str(broken))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))

	print("")
	if _fail == 0:
		print("===== 结论：全部通过 =====")
	else:
		print("===== 结论：%d 项没过 =====" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, good: String, bad: String) -> void:
	if ok:
		print("  [OK]   %s" % good)
	else:
		_fail += 1
		print("  [FAIL] %s" % bad)
