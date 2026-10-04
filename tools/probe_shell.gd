# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验证「隐藏任务栏图标」和「开机自启动」真的生效。
##
## 关键：**不只看引擎里的 flag**。`DisplayServer.window_get_flag()` 只能说明
## "Godot 记下了这个开关"，不能说明 Windows 那边真的改了窗口样式 ——
## 实测 `WINDOW_FLAG_POPUP_WM_HINT` 在 4.7.2 的 Windows 后端上是**空操作**
## （extended style 一点没变，窗口始终带 WS_EX_APPWINDOW = 强制进任务栏）。
## 开机自启动同理：不能只看我们的开关，要看注册表里到底写进去了什么。
## 所以这里借 pet_shell 内嵌的那个 PowerShell 脚本去问操作系统本身。
##
## 用法: --path <项目> --script res://tools/probe_shell.gd
## 注意：**不要用 --headless** —— 那样没有真窗口，查不到窗口样式。
extends SceneTree

var _shell: RefCounted = null
var _pid := 0

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	for i in 5:
		await process_frame

	_shell = pet.get("shell")
	if _shell == null:
		print("! pet.shell 没建起来 —— 模块接错了吧")
		quit(1)
		return
	_pid = OS.get_process_id()
	print("")
	print("环境：%s / %s   默认隐藏任务栏=%s" % [
		OS.get_name(), "导出版" if OS.has_feature("template") else "编辑器",
		_shell.hide_taskbar])
	print("辅助脚本 = %s" % _shell.ps1_path())

	await _part_a()
	await _part_b()
	quit(0)

# ------------------------------------------------------------ A. 隐藏任务栏图标

func _part_a() -> void:
	print("")
	print("=== A. 隐藏任务栏图标 ===")
	print("  看 Windows 的 extended style：TOOLWINDOW 才有用（不进任务栏 / Alt+Tab）；")
	print("  带 APPWINDOW 是反着的 —— 强制给一个任务栏按钮")

	print("  A1 启动时（apply_early + apply_native 都跑过）：")
	# 原生那条路要等 PowerShell 起来（约 1 秒），不等的话会误报成"没生效"
	await _settle()
	await _dump()

	print("  A2 顺手试 WINDOW_FLAG_POPUP（引擎级的弹窗标志，主窗口会报错，只作对照）：")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_POPUP, true)
	await _dump()
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_POPUP, false)

	print("  A3 走菜单那条路关掉隐藏：")
	_shell.set_hide_taskbar(false)
	await _settle()
	await _dump()

	print("  A4 再打开（确认能反复切，不是只有启动那一次管用）：")
	_shell.set_hide_taskbar(true)
	await _settle()
	await _dump()

# ------------------------------------------------------------ B. 开机自启动

func _part_b() -> void:
	print("")
	print("=== B. 开机自启动 ===")
	var before: String = _reg()
	print("  B1 动手前注册表 = %s" % _show(before))
	print("     该登记的命令 = %s" % _shell.autostart_command())

	var ok: bool = _shell.set_autostart(true)
	print("  B2 打开：返回=%s  状态=%s" % [ok, _shell.autostart_status()])
	if not ok:
		print("     ! 失败原因：%s" % _shell.last_error)
	var got: String = _reg()
	print("     注册表实际值 = %s" % _show(got))
	print("     与登记的逐字一致 = %s" % (got == _shell.autostart_command()))

	_shell.refresh()
	print("  B3 refresh() 从注册表读回 autostart_on=%s" % _shell.autostart_on)

	# `-- keep` 时留着不删：好让外面用别的工具去读一遍注册表，
	# 核对写进去的中文路径到底对不对（经 Godot 读回来那串可能是假的乱码，
	# 见下面 _reg() 的注释）
	if OS.get_cmdline_user_args().has("keep"):
		print("  B4 参数带 keep —— 留着不删，交给外面独立核对")
		print("     最终注册表 = %s" % _show(_reg()))
		return

	_shell.set_autostart(false)
	print("  B4 关掉：状态=%s" % _shell.autostart_status())
	print("     注册表 = %s（应为 <没有>）" % _show(_reg()))

	# 还原：本来开着就恢复，本来没有就保持没有
	if before != "":
		print("  B5 原来是开着的，恢复回去")
		_shell.set_autostart(true)
	print("     最终注册表 = %s" % _show(_reg()))

# ------------------------------------------------------------------ 小工具

func _dump() -> void:
	await process_frame
	await process_frame
	var n := 0
	for l in _ps(["styles", str(_pid)]):
		var t := String(l).strip_edges()
		if t == "":
			continue
		n += 1
		# 只打印我们自己那个窗口（可见 + 有标题）
		if t.contains("visible=True") and t.contains("titled=True"):
			print("     %s %s" % ["✅" if t.contains("TOOLWINDOW=True") else "❌", t])
	if n == 0:
		print("     （没查到窗口）")

## 等原生那条路跑完（PowerShell 启动 + 编译 P/Invoke，约 1 秒）。
## 注意用 create_timer 而不是干等：等待期间主线程必须继续处理消息 ——
## PowerShell 那边会向我们的窗口发消息（SetWindowLong / ShowWindow），
## 主线程不处理就又死锁了（实测卡死过一次，180 秒超时）。
func _settle(sec := 2.5) -> void:
	await create_timer(sec).timeout

## 经 Godot 读回注册表里的那条命令。
## 模块那边是走 base64 回传的（早期直接回文本时，中文读回来是 "妗屽疇" ——
## UTF-8 字节被按 GBK 解了。注册表里存的其实一直是对的，外面核过）。
func _reg() -> String:
	return _shell.read_registered_command()

func _show(v: String) -> String:
	return "<没有>" if v == "" else v

func _ps(args: Array) -> Array:
	var out: Array = []
	var full: Array = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _shell.ps1_path()]
	full.append_array(args)
	OS.execute(_shell.powershell(), full, out, true)
	return out
