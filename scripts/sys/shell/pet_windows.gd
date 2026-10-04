# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 跟 Windows 系统打交道的那三件：**隐藏任务栏图标**、**开机自启动**、
## 以及它们共用的一套执行层（"拼一次 PowerShell / reg 调用并等它返回"）。
##
## 从 pet_shell.gd 搬出来（作业单 B5.3）。作业单原本要拆成 `pet_autostart.gd` +
## `pet_taskbar.gd` 两个文件，复核后**合并成一个**：那两支共用同一套执行层
## （`_powershell` / `_b64` / `_ps` / `_run` / `reg_tool`），硬拆会让这套东西变成第三个文件，
## 反而更碎；而"跟 Windows 打交道"本身就是一个说得清的职责。
##
## 与宿主（pet_shell.gd）的分工：`hide_taskbar` / `autostart_on` / `autostart_cmd` /
## `supported` / `last_error` 都是宿主的状态（要存进配置、要给菜单看），所以这里通过
## 宿主对象读写它们。参数 `host` **故意不标类型**（防循环 preload，见 CONVENTIONS.md）。
##
## 接口面：**这里面有几处会动到项目外面** —— 把辅助脚本写到 user://、
## 读写注册表 `HKCU\...\Run`（关掉自启动时会删掉那条值）、改我们自己窗口的样式标志。
## 除此之外不碰别的；这些行为都是原样搬过来的，没有新增
extends RefCounted

const ShellPs1 := preload("res://scripts/sys/shell/pet_shell_ps1.gd")

## 改窗口样式的脚本落在这儿（运行时写出来，见 pet_shell_ps1.gd）
const PS1_FILE := "user://pet_shell_window.ps1"
## 自启动登记的注册表位置与值名
const RUN_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
const RUN_NAME := "DesktopPet"
## 上面为什么必须是 ASCII：原来叫「桌宠」——实测这台机器重启后它根本没被执行
## （`pet_start.log` 没有新行，Windows 的启动项记录里也从来没给它建过条目），
## 而同一个 Run 键下别的条目（OneDrive / QQ / Epic…）全是 ASCII，只有我们这条是中文。
## 中文值名是头号嫌疑；反正值名是给我们自己看的，桌面上那个名字在菜单里，不靠它。
## 老版本用过中文值名，关自启动时顺手清掉（它反正不执行）
const RUN_NAME_LEGACY := "桌宠"
## 脚本那边回"这条值不存在"用的暗号（见 read_registered_command）
const MISSING_MARK := "__MISSING__"

var _host = null
var _ps1_path := ""

func setup(host) -> void:
	_host = host

# ------------------------------------------------------------------ 隐藏任务栏图标

## 设/取消"不进任务栏"。
## 注意这个标志**不影响桌宠本身显示**：窗口照样在最上层、照样能点，
## 只是在任务栏和 Alt+Tab 里找不到她 —— 正是桌宠想要的（后台常驻但不占地方）。
func set_hide_taskbar(on: bool) -> void:
	_host.hide_taskbar = on
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_POPUP_WM_HINT, on)
	_host.apply_native()
	_host.save_want()   # 让辅助进程下一轮就按新意愿维持（它每 800ms 读一次这个文件）
	_host._save()

## 叫 PowerShell 去改 WS_EX_TOOLWINDOW。
##
## **必须非阻塞**（OS.create_process 而不是 OS.execute）：
## 改窗口样式会给我们**自己的窗口**发消息（SetWindowLong 发 WM_STYLECHANGING、
## ShowWindow 更是一串），而主线程如果正卡在"等 PowerShell 返回"，
## 就成了"我在等你、你在等我"的死锁 —— 实测这么卡死过一次，
## 180 秒超时，输出正好停在调用那一行。
##
## open_console 传 false：不然每次改设置都会闪一个黑色控制台窗口。
func native_hide(on: bool) -> void:
	var script: String = ensure_ps1()
	if script == "":
		return
	OS.create_process(_powershell(), PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", script,
		"hide", str(OS.get_process_id()), "1" if on else "0",
	]), false)

## 把内嵌脚本写到 user://（内容没变就不重写），返回它的真实路径
func ensure_ps1() -> String:
	if _ps1_path != "" and FileAccess.file_exists(_ps1_path):
		return _ps1_path
	var path := ProjectSettings.globalize_path(PS1_FILE)
	if not FileAccess.file_exists(path) or FileAccess.get_file_as_string(path) != ShellPs1.SOURCE:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			_host.last_error = "写不出辅助脚本：%s" % path
			return ""
		f.store_string(ShellPs1.SOURCE)
		f.close()
	_ps1_path = path
	return path

## 辅助脚本的真实路径（探针要拿它去查窗口样式）
func ps1_path() -> String:
	return ensure_ps1()

# ------------------------------------------------------------------ 开机自启动

## 开机时该跑的那条命令。**就一条普普通通的 exe 启动命令，别的什么都不加。**
##   导出版  = exe 自己的路径；
##   编辑器里 = Godot 编辑器 + `--path <项目目录>`（等价于跑这个项目）。
## 编辑器里也这么登记，是为了"没导出也能先验证自启动到底通不通"。
##
## 为什么是这么"笨"的写法 —— 这里踩过两个坑，最后指向同一个结论：
##
##   1) 先试过"过一层 .cmd，好在被触发的那一刻先写一行日志"（好区分"没被触发"
##      和"起来就崩了"）。结果 `.cmd` 里拼中文路径会散架：cmd.exe 按 OEM 代码页
##      读它，`…\桌宠` 落盘再读出来成了 "妗屽疇"，那条路径根本打不开。
##   2) 于是改成在 .cmd 里放 base64 的 `powershell -EncodedCommand`（编码不会乱）。
##      这条**被杀软当木马删了** —— 而且报毒是应该的：隐藏窗口 + 编码命令 +
##      拉起进程，正是恶意软件的典型特征，正常软件不会这么写自启动。
##
## 所以：自启动里**不放脚本、不做编码、不隐藏窗口**，就登记一条一眼看得懂的
## exe 路径。路径用**反斜杠**（Windows 的写法），整条命令加引号。
## 想知道"到底有没有被系统拉起来"，看桌宠自己写的 `user://pet_start.log`
## （每次启动追加一行，见 desktop_pet.gd 的 _log_startup）。
func autostart_command() -> String:
	var exe := OS.get_executable_path().replace("/", "\\")
	if OS.has_feature("template"):
		return '"%s"' % exe
	var dir := ProjectSettings.globalize_path("res://").trim_suffix("/").replace("/", "\\")
	return '"%s" --path "%s"' % [exe, dir]

## 从注册表读回真实状态。
## **只认 reg query 的返回码，不去解析它的输出** —— reg.exe 的输出走控制台代码页，
## 路径里带中文（比如 <导出目录>\pet.exe）读回来就是乱码，
## 拿乱码去比字符串只会得到错的结论。
## "登的是不是当前这个 exe"另用我们自己存的 autostart_cmd 比对，见 autostart_status()。
func refresh() -> void:
	_host.last_error = ""
	if not _host.supported:
		_host.autostart_on = false
		return
	var r := _run(["query", RUN_KEY, "/v", RUN_NAME])
	_host.autostart_on = int(r["code"]) == 0

## 开关开机自启动。返回是否成功（失败原因在宿主的 last_error）
func set_autostart(on: bool) -> bool:
	_host.last_error = ""
	if not _host.supported:
		_host.last_error = "这台系统不支持（只有 Windows 有注册表自启动）"
		return false
	if on:
		var cmd := autostart_command()
		var res := _ps(["setrun", _b64(RUN_NAME), _b64(cmd)])
		if res != "OK":
			_host.last_error = "写入注册表失败：%s" % (res if res != "" else "辅助脚本没跑起来")
			_host.autostart_on = false
			return false
		_host.autostart_on = true
		_host.autostart_cmd = cmd
	else:
		# 本来就没有这条不算失败（delrun 那边把"找不到"当成功处理）
		_ps(["delrun", _b64(RUN_NAME)])
		# 老版本那种中文值名一起清掉，别留着占位（它反正不执行）
		if RUN_NAME_LEGACY != RUN_NAME:
			_ps(["delrun", _b64(RUN_NAME_LEGACY)])
		_host.autostart_on = false
		_host.autostart_cmd = ""
	_host._save()
	return true

## 读回注册表里那条命令本身（自检和探针用）。没有这条返回空串。
## 脚本那头回的是 base64，这里解回来 —— 直接回文本会被两个进程的编码差异搞成乱码
## （实测中文路径读回来是 "妗屽疇"），base64 只有 ASCII，怎么过都不变形。
func read_registered_command() -> String:
	var v := _ps(["run", _b64(RUN_NAME)])
	if v == "" or v == MISSING_MARK:
		return ""
	return Marshalls.base64_to_utf8(v)

## 自启动的实际状况，直接写给人看
func autostart_status() -> String:
	if not _host.supported:
		return "这台系统不支持"
	if not _host.autostart_on:
		return "未开启"
	if _host.autostart_cmd != "" and _host.autostart_cmd != autostart_command():
		# 两种形态都是合法的：导出版（exe 自己）/ 编辑器里（Godot + --path 跑这个项目）。
		# 从 exe 里看"编辑器形态"的那条会对不上字符串，但那不是旧位置 —— 别误报，
		# 否则排查自启动时会把人带沟里（实测就被这行提示误导过）
		if String(_host.autostart_cmd).find("--path") >= 0:
			return "已开启"
		return "已开启，但登记的还是旧位置（关掉再开一次就刷新）"
	return "已开启"

# ------------------------------------------------------------------ 外部命令

## reg.exe 的绝对路径：用 SystemRoot 拼，别指望 PATH
func reg_tool() -> String:
	var root := OS.get_environment("SystemRoot")
	if root != "":
		var p := root.path_join("System32/reg.exe")
		if FileAccess.file_exists(p):
			return p
	return "reg"

func powershell() -> String:
	return _powershell()

func _powershell() -> String:
	var root := OS.get_environment("SystemRoot")
	if root != "":
		var p := root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
		if FileAccess.file_exists(p):
			return p
	return "powershell"

## UTF-8 -> base64。
## 注册表的**值名是中文、值里有引号和空格** —— 走命令行传会被 Windows 那套引号规则
## 拆坏（`reg add /d "\"D:/...exe\" --path \"C:/...\""` 实测就报"无效语法"，
## 因为内层引号没法转义，`--path` 被当成了独立的参数）。
## base64 之后只剩 ASCII，中间过几层都不会变形。
func _b64(s: String) -> String:
	return Marshalls.utf8_to_base64(s)

## 同步跑那个辅助脚本并取回它的输出。
## 阻塞是安全的：它只读写注册表，**不碰我们的窗口** ——
## 会碰窗口的是 hide 那一支，那支必须非阻塞，见 native_hide()。
func _ps(args: Array) -> String:
	var script: String = ensure_ps1()
	if script == "":
		return ""
	var full: Array = ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", script]
	full.append_array(args)
	var out: Array = []
	OS.execute(_powershell(), full, out, true)
	var text := ""
	for l in out:
		text += String(l)
	return text.strip_edges()

## 同步跑 reg.exe（只做只读查询，不碰窗口，所以阻塞是安全的）
func _run(args: Array) -> Dictionary:
	var out: Array = []
	var code := OS.execute(reg_tool(), args, out, true)
	# 手写拼接而不是 PackedStringArray.join()：这个版本（4.7.2）里
	# PackedStringArray **没有** join 方法，写了直接解析失败
	var text := ""
	for line in out:
		text += String(line) + "\n"
	return {"code": code, "out": text.strip_edges()}
