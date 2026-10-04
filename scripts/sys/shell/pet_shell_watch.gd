# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 「命令通道 + 看门狗」：那个后台辅助进程（PowerShell 小循环）的生死，以及和它的双向通信。
##
## 从 pet_shell.gd 搬出来（作业单 B5.2）。为什么值得独立：这是一个**常驻子进程**的生命周期
## （拉起 → 每 0.5 秒探活 → 死了重拉 → 退出收掉）＋ 三条小文件通道（状态 / 命令 / 意愿）——
## 和"窗口样式长什么样"是两件事；而且它踩过的坑特别多（残留命令、心跳过期、重启冷却、
## 权限位被重算冲掉），值得有自己的地方把话说明白。
##
## 与宿主（pet_shell.gd）的分工：
##   - **共享字段留在宿主**：`fullscreen` / `fullscreen_aware` / `tray_icon` / `popup_open` /
##     `top_wish` 是 desktop_pet 在读写的对外状态，所以这里通过宿主对象读写它们
##   - **进程号 / 限流 / 重启计数**这些只有本模块关心，住在这儿
##   - 拉起进程要用宿主的两样本事：`_ensure_ps1()`（脚本落盘）和 `_powershell()`（解释器路径）
##
## 参数 `host` **故意不标类型**（它属于 pet_shell.gd，标上就成循环 preload —— 见 CONVENTIONS.md）。
##
## 接口面：拉起并看管一个**后台子进程**、读写 user:// 下三个小文件、
## 改窗口显示模式（最小化/还原）与置顶标志。不碰网络、不发信号
extends RefCounted

## "现在有没有全屏窗口"的答案写在这里（辅助脚本写、我们读）。
## 内容就一个字符：1 / 0。用文件而不是 stdout：辅助进程是 OS.create_process 拉起来的
## （拿它的输出就得阻塞，主线程一卡就死锁，见 pet_shell.gd 里 _native_hide 的注释）。
const STATE_FILE := "user://pet_shell_state.txt"
## 状态文件多久没更新就认为辅助进程死了（它会每 ~10 秒写一次心跳）
const STATE_STALE_SEC := 15.0
## 托盘菜单的命令从这儿回来（辅助进程写、我们读，读完立刻删）。
## 方向是反的：文件是我们传给它的"结果"，命令是它传给我们的"动作"。
const CMD_FILE := "user://pet_shell_cmd.txt"
## "要不要不进任务栏"这个意愿写在这儿，辅助进程每轮读一遍。
## 为什么要有这个文件：那一位会被 Godot 自己冲掉（它一动窗口就重算样式），
## 所以得让辅助进程持续维持；而意愿可能中途改（用户点菜单），又不能为此重启进程。
const WANT_FILE := "user://pet_shell_want.txt"
## GPU 占用率（0~100，-1 = 检测不到）写在这里（辅助进程写、我们读）。
## 2026-10-03 用户要求：GPU 高（打游戏）时自动"透视"自己
const GPU_FILE := "user://pet_gpu.txt"
## 置顶现在由辅助进程每 800ms 用原生 SetWindowPos 维持，见 save_want()

## 宿主（pet_shell.gd）。弱类型 —— 理由见文件头
var _host = null
var _state_path := ""
var _pid := -1
var _next_poll := 0.0
var _want_popup := false
var _retry_at := 0.0
var _restarts := 0

func setup(host) -> void:
	_host = host

## 辅助进程的进程号（> 0 = 现在有这么一个进程；探针/日志要看）
func pid() -> int:
	return _pid

## 开关"全屏检测"
func set_fullscreen_aware(on: bool) -> void:
	if _host.fullscreen_aware == on:
		return
	_host.fullscreen_aware = on
	if on:
		_restarts = 0
		start()
	elif not _host.tray_icon:
		# 只有托盘也关着时才能把进程收掉 —— 否则托盘图标会跟着消失
		stop()
		_host.fullscreen = false

## 开关托盘图标
func set_tray_icon(on: bool) -> void:
	if _host.tray_icon == on:
		return
	_host.tray_icon = on
	if on:
		start()
	elif not _host.fullscreen_aware:
		stop()

## 拉起那个后台进程（一个 PowerShell 小循环，800ms 转一圈）。
## 为什么要常驻而不是"隔几秒查一次"：每次拉起 PowerShell 都要几百毫秒的启动开销，
## 几秒一次等于一直在烧 CPU；常驻一个进程反而几乎是 0（循环体都是 P/Invoke，很轻）。
func start() -> void:
	# 托盘和全屏检测共用一个进程：两个都要才值得留它，都关掉就不留
	if not _host.supported or _pid > 0:
		return
	if not _host.fullscreen_aware and not _host.tray_icon:
		return
	# 宿主是弱类型（防循环 preload）→ 这里不能写 `:=` 让它推断（B4.1 也踩过同一个坑）
	var script: String = _host._ensure_ps1()
	if script == "":
		return
	# 起进程之前先清掉可能残留的命令文件。
	# 上一次如果是被强杀的（或者托盘点了退出、但没来得及删文件），命令会留在这儿，
	# 新一次启动就会把那条**旧命令**当成本次的命令执行 ——
	# 实测：残留的一条 "quit" 让新进程刚起来就自己退了，而且什么都不打印，极难查。
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CMD_FILE))
	save_want()
	_state_path = ProjectSettings.globalize_path(STATE_FILE)
	_pid = OS.create_process(_host._powershell(), PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", script,
		"watch", str(OS.get_process_id()), _state_path,
		ProjectSettings.globalize_path(CMD_FILE), _ensure_tray_icon(),
		ProjectSettings.globalize_path(WANT_FILE),
		ProjectSettings.globalize_path(GPU_FILE),
	]), false)
	if _pid <= 0 and OS.is_debug_build():
		print("[PetDeek] 辅助进程没能起来（create_process 返回 %d）" % _pid)

## 把项目图标解出来给托盘用。
## 导出版里 `res://icon.png` 是 PCK 里的一段数据、不是文件路径，而托盘要真实文件，
## 所以读出来写到 user://。读不到就返回空串（辅助脚本那边退回系统默认图标）。
##
## ⚠️ 原来是"缓存文件已存在就直接返回" —— 于是**换了 icon.png，托盘图标也不会变**：
## 那份缓存是第一次运行时写下的，之后永远沿用（2026-10-04 用户报"小图标还是没有变"，
## 查出来缓存还是一个月前生成的那一版）。现在比内容，不一样就重写。
func _ensure_tray_icon() -> String:
	var out := ProjectSettings.globalize_path("user://pet_shell_icon.png")
	var bytes := FileAccess.get_file_as_bytes("res://icon.png")
	if bytes.is_empty():
		return ""
	if FileAccess.file_exists(out):
		# 内容一样就别白写 —— 这函数每次拉起辅助进程都会走一遍
		if FileAccess.get_file_as_bytes(out) == bytes:
			return out
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return out

func stop() -> void:
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1

## 每帧调（内部自己限流）：读全屏状态 + 处理托盘命令 + 同步"意愿"
func tick() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# 菜单开关一变就立刻写意愿：菜单开着时不能再"保持置顶"，否则会盖住菜单
	if _host.popup_open != _want_popup:
		_want_popup = _host.popup_open
		_apply_top_flag()
		save_want()
	if _pid <= 0:
		return
	if now >= _next_poll:
		_next_poll = now + 0.5
		# 辅助进程要是死了就立刻重拉：它一死，任务栏隐藏的自愈、托盘图标、
		# 置顶维持会**一起**静默失效，而外面看起来只是"功能不灵了"。
		# （它的状态文件心跳要 15 秒才判定过期，太慢；这里直接看进程在不在）
		if _pid > 0 and not OS.is_process_running(_pid):
			if OS.is_debug_build():
				print("[PetDeek] 辅助进程没了，重拉一个")
			_pid = -1
			_restarts = 0
			start()
		# 托盘命令无论全屏检测开没开都要处理（两者共用一个进程）
		_poll_command()
		if _host.fullscreen_aware:
			_poll_state()
		_poll_gpu()

## 处理托盘菜单写进来的命令。一次一条，读完立刻删 ——
## 不删的话下个 0.5 秒又会执行一次（"切换显示"会变成疯狂闪烁）。
func _poll_command() -> void:
	if not FileAccess.file_exists(CMD_FILE):
		return
	var f := FileAccess.open(CMD_FILE, FileAccess.READ)
	if f == null:
		return
	var cmd := f.get_as_text().strip_edges()
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CMD_FILE))
	if OS.is_debug_build():
		print("[PetDeek] 托盘命令：%s" % cmd)
	match cmd:
		"toggle":
			toggle_visible()
		"ghost":
			# 托盘里的「透明模式」：开着时整窗点不到，只能靠托盘切回来
			if _host.pet != null:
				_host.pet.call("_toggle_ghost")
		"quit":
			if _host.pet != null and _host.pet.is_inside_tree():
				_host.pet.get_tree().quit()

## 托盘菜单的「显示 / 隐藏」。
##
## 用最小化，不用 `Window.hide()`：**主窗口不允许改 visible** —— 实测直接报
## `Can't change visibility of main window`（而且是在 _process 里抛，真机上表现为
## "点了没反应 + 日志一堆错"）。她本来就不在任务栏和 Alt+Tab 里（WS_EX_TOOLWINDOW），
## 所以一最小化就等于从桌面上消失了。
func toggle_visible() -> void:
	if _host.pet == null:
		return
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		# 还原会让 Windows 把窗口样式重做一遍，**"不进任务栏"那一位会丢** ——
		# 实测：不补这一步，从托盘叫回来之后她就出现在任务栏和 Alt+Tab 里了。
		_host.apply_native()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	if OS.is_debug_build():
		print("[PetDeek] 托盘切换显示 -> mode=%d" % DisplayServer.window_get_mode())

## 把"意愿"写下来给辅助进程读（它每 800ms 读一次并照着维持）：
##   第 1 个数 = 不进任务栏；第 2 个数 = 保持置顶；第 3 个数 = 菜单正开着。
##
## 为什么置顶也要它来维持、而不是 Godot 自己重申：Godot 的窗口操作会**重算窗口样式**，
## 每重申一次就把"不进任务栏"那一位冲掉一次 —— 实测每 2 秒丢失一次，任务栏上忽隐忽现。
## 交给辅助进程用原生 SetWindowPos 做，两边就不打架了（而且带 SWP_NOACTIVATE，不抢焦点）。
##
## 菜单开着时第 3 个数写 1：辅助进程会去顶**菜单**、而不是顶她。
## 光"不顶她"不够 —— 她一移动（window_set_position）就会被 Windows 抬回置顶组最前面，
## 菜单照样被盖住。
func save_want() -> void:
	var f := FileAccess.open(WANT_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string("%d %d %d" % [
			1 if _host.hide_taskbar else 0, 1 if _host.top_wish else 0,
			1 if _host.popup_open else 0])
		f.close()

## 用户改了"窗口置顶"
func set_top_wish(on: bool) -> void:
	_host.top_wish = on
	_apply_top_flag()
	save_want()

## 真正去设那个标志：菜单开着时一律不置顶（用户意愿等菜单关了再生效）
func _apply_top_flag() -> void:
	DisplayServer.window_set_flag(
		DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, _host.top_wish and not _host.popup_open)

func _poll_state() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var f := FileAccess.open(STATE_FILE, FileAccess.READ)
	if f == null:
		_host.fullscreen = false
		_maybe_restart(now)
		return
	var text := f.get_as_text().strip_edges()
	f.close()
	# 文件太旧 = 辅助进程死了。这时候**不能**把过期的"全屏中"当真，
	# 否则宠物会一直缩在小范围里不肯出来（而且再也回不来）
	var age: float = Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(STATE_FILE))
	if age > STATE_STALE_SEC:
		_host.fullscreen = false
		if _pid > 0 and not OS.is_process_running(_pid):
			_pid = -1
		_maybe_restart(now)
		return
	_host.fullscreen = text == "1"

## 读辅助进程写的 GPU 占用率（0~100，-1 = 读不到 / 检测不到）。
## 和全屏那份一样，文件太旧就当"进程死了"，别把过期值当真 ——
## 否则她可能一直卡在"透视"里回不来
func _poll_gpu() -> void:
	var f := FileAccess.open(GPU_FILE, FileAccess.READ)
	if f == null:
		_host.gpu_usage = -1
		return
	var text := f.get_as_text().strip_edges()
	f.close()
	var age: float = Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(GPU_FILE))
	if age > STATE_STALE_SEC:
		_host.gpu_usage = -1
		return
	_host.gpu_usage = int(text) if text.is_valid_int() else -1

## 辅助进程死了就重拉（带冷却 + 次数上限，别变成无限重启）
func _maybe_restart(now: float) -> void:
	if not _host.supported or _pid > 0 or now < _retry_at or _restarts >= 3:
		return
	_retry_at = now + 20.0
	_restarts += 1
	start()
	if OS.is_debug_build():
		print("[PetDeek] 全屏检测没动静了，重启第 %d 次" % _restarts)
