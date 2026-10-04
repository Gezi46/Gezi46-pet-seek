# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 和操作系统打交道的那两件事：**开机自启动** 和 **隐藏任务栏图标**。
## （由 desktop_pet.gd preload 为 PetShell）
##
## 为什么单独一个模块：
##   1. 这两件事都跟桌宠的行为无关，混在主脚本里只会让主脚本更长；
##   2. 它们都有"系统不一定允许"的可能（非 Windows、注册表被组策略锁住），
##      失败时必须**安静地降级**，绝不能让桌宠起不来。
##
## 两条实现路径，各有各的坑，都记在下面，别重新踩：
##
## 开机自启动 —— 往 `HKCU\...\CurrentVersion\Run` 写一条命令。
##   用用户级（HKCU）不用机器级（HKLM）：不需要管理员权限，也不会影响别人。
##
## 隐藏任务栏图标 —— **Windows 上得自己动手改窗口样式**。
##   `WINDOW_FLAG_POPUP_WM_HINT` 在 4.7.2 的 Windows 后端上是**空操作**：
##   实测窗口的 extended style 从头到尾都是 0x8040018（含 WS_EX_APPWINDOW
##   = 强制给一个任务栏按钮），开关切来切去一位都没变。
##   而 `WINDOW_FLAG_POPUP` 更不行：主窗口设它会直接报 "Main window can't be popup"。
##   所以这边叫 PowerShell 去设 WS_EX_TOOLWINDOW / 清掉 WS_EX_APPWINDOW。

## 自启动的登记状态。用 user:// 和"家"、聊天设置一个套路：改完就记住，不动场景文件
const CONFIG := "user://pet_shell.cfg"

## 注册表位置 / 值名 / 脚本路径那几样跟着"Windows 集成"搬去了 **pet_windows.gd**
## （作业单 B5.3）：`RUN_KEY` / `RUN_NAME` / `RUN_NAME_LEGACY` / `MISSING_MARK` / `PS1_FILE`
## —— 连同"值名为什么必须是 ASCII""为什么不能过一层 .cmd"那几条教训一起搬的
##
## 改窗口样式的 PowerShell **脚本源码**（577 行）更早一步搬去了 **pet_shell_ps1.gd**（B5.1）。
## 这一份别名留着：`_ensure_ps1()` 那条链路（辅助进程要脚本落盘）仍旧按 PS1_SOURCE 找它
const ShellPs1 := preload("res://scripts/sys/shell/pet_shell_ps1.gd")
const PS1_SOURCE := ShellPs1.SOURCE


## 宿主（桌宠根节点）：读它的检查器默认值
var pet: Node3D = null

## 当前是否已登记开机自启动（以注册表为准，不是以我们的开关为准）
var autostart_on := false
## 上次开启时登记的启动命令。用来发现"exe 换了位置，登记的那条已经失效"
var autostart_cmd := ""
## 是否隐藏任务栏图标
var hide_taskbar := true
## 只有 Windows 有注册表自启动
var supported := false
## 上一次失败的原因，给菜单提示用
var last_error := ""

## （辅助脚本的落盘路径 `_ps1_path` 跟着 pet_windows.gd 搬走了 —— 只有它关心那个缓存）


func setup(pet_node: Node3D) -> void:
	pet = pet_node
	supported = OS.get_name() == "Windows"
	# 出厂值来自检查器里的导出参数，配置文件里有记录就覆盖它
	if pet != null:
		hide_taskbar = bool(pet.get("hide_taskbar_icon"))
		autostart_on = bool(pet.get("autostart_enabled"))
	# 下面两个模块都要宿主：它们通过 self 读写上面那几个共享字段
	#   _watch  借 _ensure_ps1() / _powershell() 拉起辅助进程（见 pet_shell_watch.gd）
	#   _win    写 hide_taskbar / autostart_on / autostart_cmd / last_error（见 pet_windows.gd）
	_watch.setup(self)
	_win.setup(self)
	_load()

## 在 _enter_tree 里调 —— 比 _ready 更早。
## 这里只设引擎自带的那个标志（支持它的平台上它自己就够用），
## 原生那条路要等窗口真的建出来，见 apply_native()。
func apply_early() -> void:
	DisplayServer.window_set_flag(
		DisplayServer.WINDOW_FLAG_POPUP_WM_HINT, hide_taskbar)

## 在 _ready 里（窗口已经建好）调：真正把任务栏图标藏起来。
func apply_native() -> void:
	if OS.get_name() != "Windows":
		return
	_win.native_hide(hide_taskbar)

# ------------------------------------------------------------------ 隐藏任务栏图标 / Windows 集成

## 跟 Windows 打交道那三件（隐藏任务栏 / 开机自启动 / 跑 PowerShell·reg）搬去了
## **pet_windows.gd** —— 作业单 B5.3 搬的。下面这一组是壳：菜单在调它们，
## 辅助进程模块也要借宿主拿 `_ensure_ps1()` 和 `_powershell()`
const PetWindows := preload("res://scripts/sys/shell/pet_windows.gd")
var _win := PetWindows.new()

## 设/取消"不进任务栏"（说明见 pet_windows.gd）
func set_hide_taskbar(on: bool) -> void:
	_win.set_hide_taskbar(on)

## 把内嵌脚本写到 user://（内容没变就不重写），返回它的真实路径
func _ensure_ps1() -> String:
	return _win.ensure_ps1()

# ------------------------------------------------------------------ 全屏检测 / 保持置顶 / 托盘

## 命令通道 + 看门狗（那个后台辅助进程的生死、三条文件通道）搬去了
## **pet_shell_watch.gd** —— 作业单 B5.2 搬的。下面这几个字段**留在本文件**：
## 它们是 desktop_pet 在读写的对外状态，模块通过宿主对象（self）读写它们
const ShellWatch := preload("res://scripts/sys/shell/pet_shell_watch.gd")
var _watch := ShellWatch.new()

## 当前是否检测到全屏窗口（前景窗口占满整个显示器）
var fullscreen := false
## 最近一次读到的 GPU 占用率（0~100，-1 = 检测不到 / 辅助进程没跑）。watch 每 0.5s 刷一次
var gpu_usage := -1
## 是否启用这套检测。关掉 = 不再需要全屏检测（但托盘还开着的话进程照样留）
var fullscreen_aware := true
## 托盘图标（"隐藏的图标"里那一个）。Godot 没有托盘 API，图标由辅助进程托管
var tray_icon := true
## 有没有弹窗（右键菜单）正开着。开着的时候要把自己从"置顶"里摘出去 ——
## 宠物和菜单都是置顶窗口时，谁在上面取决于谁最后被抬起，而她一移动就会被抬起来，
## 菜单就会一阵一阵被盖住。摘出去之后"菜单(置顶) 在 宠物(非置顶) 之上"是硬保证。
var popup_open := false
## 用户"要不要置顶"的**意愿**。不能直接看窗口标志：菜单开着时我们会故意把置顶摘掉，
## 标志跟着变成 false，再拿它当意愿就错了（菜单一关就再也回不去）
var top_wish := true

## 下面这一组都是**壳**：实现全在 **pet_shell_watch.gd**（作业单 B5.2）。
## 留壳是因为 desktop_pet 和探针一直按这些名字调；共享字段（上面那几个）就住在本文件

## 辅助进程的进程号（探针 / 日志用；≤ 0 = 现在没有这个进程）。
## 进程号本来就住在 pet_shell_watch.gd 里，这里开一个口子 —— 探针不该去 `get("_watcher_pid")`
## （B5.2 搬完它就摸不到了，tools/probe_tray.gd 当场卡死过一次）
func watcher_pid() -> int:
	return _watch.pid()

## 开关"全屏检测"
func set_fullscreen_aware(on: bool) -> void:
	_watch.set_fullscreen_aware(on)

## 开关托盘图标
func set_tray_icon(on: bool) -> void:
	_watch.set_tray_icon(on)

## 拉起那个后台辅助进程（PowerShell 小循环，800ms 转一圈 —— 理由见 pet_shell_watch.gd）
func start_watcher() -> void:
	_watch.start()

func stop_watcher() -> void:
	_watch.stop()

## 每帧调（内部自己限流）：读全屏状态 + 处理托盘命令 + 同步"意愿"
func tick() -> void:
	_watch.tick()

## 托盘菜单的「显示 / 隐藏」（用最小化，不用 hide —— 主窗口不允许改 visible，踩过）
func toggle_visible() -> void:
	_watch.toggle_visible()

## 把"意愿"写下来给辅助进程读（格式与理由见 pet_shell_watch.gd）
func save_want() -> void:
	_watch.save_want()

## 用户改了"窗口置顶"
func set_top_wish(on: bool) -> void:
	_watch.set_top_wish(on)

## 退出收尾：别把辅助进程留在后台
func stop() -> void:
	_watch.stop()

# ------------------------------------------------------------------ 开机自启动 / 外部命令

## 开机自启动（注册表读写）和"跑一次 PowerShell / reg"那套都在 **pet_windows.gd**
## （作业单 B5.3 搬的）。这一组壳留着：菜单和探针按老名字调它们，
## 而 `_powershell()` 那个壳是给辅助进程模块用的（它借宿主拿解释器路径）
##
## 为什么那两支合成一个文件：它们共用同一套执行层（`_powershell` / `_b64` / `_ps` / `_run`），
## 硬拆成"自启动"和"任务栏"两个文件，这套执行层就得变成第三个 —— 反而更碎

## 开机时该跑的那条命令（为什么是这么"笨"的写法，见 pet_windows.gd 的长注释）
func autostart_command() -> String:
	return _win.autostart_command()

## 从注册表读回真实状态（只认返回码，不解析输出 —— 理由见 pet_windows.gd）
func refresh() -> void:
	_win.refresh()

## 开关开机自启动。返回是否成功（失败原因在 last_error）
func set_autostart(on: bool) -> bool:
	return _win.set_autostart(on)

## 读回注册表里那条命令本身（自检和探针用）。没有这条返回空串
func read_registered_command() -> String:
	return _win.read_registered_command()

## 自启动的实际状况，直接写给人看
func autostart_status() -> String:
	return _win.autostart_status()

func powershell() -> String:
	return _win.powershell()

func _powershell() -> String:
	return _win._powershell()

# ------------------------------------------------------------------ 存档

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG)     # 读回来再改，别把文件里其它键冲掉
	cfg.set_value("autostart", "on", autostart_on)
	cfg.set_value("autostart", "cmd", autostart_cmd)
	cfg.set_value("window", "hide_taskbar", hide_taskbar)
	cfg.save(CONFIG)

## 读回上次的选择。缺键时落回**检查器里的值**（和聊天的做法一致）——
## 不这样的话，新加的开关在老存档上会被读成 false，看起来像"改了检查器不生效"。
func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG) != OK:
		return
	autostart_on = bool(cfg.get_value("autostart", "on", autostart_on))
	autostart_cmd = String(cfg.get_value("autostart", "cmd", ""))
	hide_taskbar = bool(cfg.get_value("window", "hide_taskbar", hide_taskbar))
