# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 按当前代码把"开机自启动"重新登记一次，并把结果读回来。
##
## 平时点菜单里那个开关就够了。这个工具是给"想从命令行重来一次 / 查它到底写了什么"用的，
## 也是一份自检：它会真写 .cmd + 真写注册表，再把注册表读回来打给你看 ——
## 失败了直接能看到原因，不用去点菜单猜。
##
## 用法：
##   & $godot --headless --path . --script res://tools/apply_autostart.gd          # 开
##   & $godot --headless --path . --script res://tools/apply_autostart.gd -- off   # 关
##
## 注意：导出版和编辑器里登记的**不是同一条**命令（导出版 = exe 自己，
## 编辑器里 = Godot 跑这个项目）。想让她开机跑最新代码，就在编辑器里跑这个工具。

extends SceneTree

const PetShell := preload("res://scripts/sys/shell/pet_shell.gd")

var _shell: PetShell = null
var _want := true

func _initialize() -> void:
	_want = not OS.get_cmdline_user_args().has("off")
	_shell = PetShell.new()
	# 不接桌宠节点：只有"检查器里的默认值"拿不到，自启动这条路用不着它们
	_shell.setup(null)

func _process(_delta: float) -> bool:
	if _shell == null:
		return true
	var ok := _shell.set_autostart(_want)
	print("=== 自启动 %s ===" % ("开启" if _want else "关闭"))
	print("写入结果 = %s%s" % [ok, "" if ok else " ← 失败原因：%s" % _shell.last_error])
	if _want:
		print("登记的命令 = %s" % _shell.autostart_command())
	_shell.refresh()
	print("读回状态 = %s（autostart_on=%s）" % [_shell.autostart_status(), _shell.autostart_on])
	print("注册表里的实际内容 = %s" % ["<没有>" if _shell.read_registered_command() == "" else _shell.read_registered_command()])
	print("（有没有被系统真正拉起来，看 user://pet_start.log 里有没有新的一行）")
	_shell = null
	quit(0 if ok else 1)
	return true
