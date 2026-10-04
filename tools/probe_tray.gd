# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 验"托盘图标"这条链路：
##   A 辅助进程起来了（命令行里带着托盘要的参数），图标文件也解出来了
##   B 托盘下达命令的通道：写 toggle → 她隐藏；再写 toggle → 她回来
##   C quit → 整个进程退出（放最后，因为测到这里自己就没了）
##
## 没法从代码里断言的是"图标在托盘里长什么样"（那要开溢出区截图）—— 那部分得你亲眼看。
## 但通道验过了，就意味着菜单里那两项点下去一定会生效。
##
## 用法: --path <项目> --script res://tools/probe_tray.gd
## 注意：不能 --headless（要真窗口）
extends SceneTree

var _pet: Node = null
var _shell: RefCounted = null

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 6:
		await process_frame
	_shell = _pet.get("shell")
	if _shell == null:
		print("! pet.shell 没建起来")
		quit(1)
		return

	print("")
	print("=== A. 辅助进程与托盘参数 ===")
	await create_timer(1.5).timeout
	var pid: int = _shell.watcher_pid()
	print("  辅助进程 pid=%s 活着=%s  tray_icon=%s" % [
		pid, OS.is_process_running(pid) if pid > 0 else false, _shell.tray_icon])
	var cmd := _ps_cmdline(pid)
	print("  它的命令行里包含：")
	for want in ["pet_shell_window.ps1", "watch", "pet_shell_cmd.txt", "pet_shell_icon.png"]:
		print("    %s %s" % ["✅" if cmd.contains(want) else "❌", want])

	var src_len := FileAccess.get_file_as_bytes("res://icon.png").size()
	var icon_path := ProjectSettings.globalize_path("user://pet_shell_icon.png")
	var dst_len := -1
	if FileAccess.file_exists(icon_path):
		dst_len = FileAccess.get_file_as_bytes("user://pet_shell_icon.png").size()
	print("  托盘图标文件：user:// 下 %d 字节，res://icon.png %d 字节  %s" % [
		dst_len, src_len, "✅ 一致" if dst_len == src_len and dst_len > 0 else "❌ 对不上"])

	print("")
	print("=== B. 托盘命令通道 ===")
	print("  初始窗口模式=%d（0 = 普通，1 = 最小化）" % DisplayServer.window_get_mode())
	_write_cmd("toggle")
	var hid: bool = await _wait_until(
		func() -> bool: return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED, 4.0)
	print("  %s 写「toggle」→ 模式=%d" % ["✅" if hid else "❌", DisplayServer.window_get_mode()])
	_write_cmd("toggle")
	var back: bool = await _wait_until(
		func() -> bool: return DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED, 4.0)
	print("  %s 再写一次「toggle」→ 模式=%d" % ["✅" if back else "❌", DisplayServer.window_get_mode()])
	print("  （隐藏期间还能响应第二次 toggle 是关键：不然托盘就叫不回她了）")
	print("  恢复后：透明flag=%s 尺寸=%s 置顶=%s  %s" % [
		DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT),
		DisplayServer.window_get_size(),
		DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP),
		"✅" if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT) \
			and DisplayServer.window_get_size() == Vector2i(330, 470) else "❌ 有属性丢了"])
	await _wait(1.5)
	print("  她那还在不在任务栏里（应为 TOOLWINDOW=True）：%s" % _styles_toolwindow())

	print("")
	print("=== C. 退出命令 ===")
	print("  写「quit」—— 下面如果没有更多输出、进程也没了，就是生效了")
	_write_cmd("quit")
	await create_timer(8.0).timeout
	print("  ❌ 8 秒后我还活着，quit 没生效")
	quit(1)

# ------------------------------------------------------------------ 小工具

func _write_cmd(cmd: String) -> void:
	var f := FileAccess.open("user://pet_shell_cmd.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(cmd)
		f.close()

func _wait(sec: float) -> void:
	await create_timer(sec).timeout

func _wait_until(pred: Callable, timeout: float) -> bool:
	var until := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < until:
		if pred.call():
			return true
		await process_frame
	return pred.call()

## 顺带确认"恢复显示"之后她那一位（WS_EX_TOOLWINDOW）没丢 —— 最小化/还原会让 Windows
## 重做一遍窗口样式，所以这一步有可能把之前设的东西冲掉，值得盯一眼
func _styles_toolwindow() -> String:
	var out: Array = []
	OS.execute(_shell.powershell(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _shell.ps1_path(), "styles", str(OS.get_process_id())], out, true)
	for l in out:
		var t := String(l).strip_edges()
		if t.contains("visible=True") and t.contains("titled=True"):
			if t.contains("TOOLWINDOW=True"):
				return "✅ 是（%s）" % t
			return "❌ 丢了：%s" % t
	return "（没查到窗口）"

func _ps_cmdline(pid: int) -> String:
	var out: Array = []
	OS.execute(_shell.powershell(), ["-NoProfile", "-NonInteractive", "-Command",
		"(Get-CimInstance Win32_Process -Filter 'ProcessId=%d').CommandLine" % pid], out, true)
	var text := ""
	for l in out:
		text += String(l)
	return text
