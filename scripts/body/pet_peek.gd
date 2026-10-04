# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 「偷看屏幕」和「看一眼摄像头」：她隔一阵自己抓一张画面，交给视觉模型说一句。
##
## 从 desktop_pet.gd 搬出来（作业单 B6.1b）。为什么值得独立：这是**一条完整的感知链** ——
## 定时 → 忙 / 离线 / 没配视觉模型三道挡板 → 抓图（截屏 或 摄像头）→ 压 JPEG →
## 发一次带图请求。它和"被摸到的反应"是两条互不相干的链（作业单原先把两者的行号圈在一起了）。
##
## 与宿主的分工：宿主那些普通字段与方法直接读写（`_peek_on` / `_peek_timer` /
## `_camera_busy` / `_camera_last_error` / `camera_index` / `peek_every_min` / `_say` /
## `_vision_ready()` / `_send_first()` …）。两条提示词常量跟着本模块走，宿主不再需要它们。
## 参数 `host` **故意不标类型**（防循环 preload，见 CONVENTIONS.md）。
##
## 接口面：截当前屏幕、开本机摄像头、发一次带图请求、往气泡里说一句。
## 不碰文件；网络那截在宿主那条链上（`_send_first`）
extends RefCounted

## 偷看屏幕到点了但她正忙着：过这么久再看一眼，而不是白等一整个 peek_every_min
const PEEK_RETRY_SEC := 15.0
## 偷看屏幕那条的提示词。
##
## 后面那半句是 2026-09-27 加的：用户报"打开游戏后截不到游戏" —— 原因是**独占全屏**
## 的游戏不进桌面合成，抓屏只能拿到桌面。画面里没有的东西
## 就别让她编，不然她会把桌面说成"你在用某个软件" ✗。真正的解法见 README：
## 游戏改成**无边框窗口**；或者以后换抓屏后端（Windows Graphics Capture / 放大镜 API）
const PROMPT_PEEK := "（这是主人屏幕现在的样子。看一眼他在干什么，就着画面说一句话。" \
	+ "只说你真看到的东西，别猜他在玩什么 —— 独占全屏的游戏不会出现在这种截图里，" \
	+ "所以画面只剩桌面时，别硬说他在用某个软件，随口问一句他在忙什么就好）"
## 摄像头那条的提示词
const CAMERA_QUESTION := "（用摄像头看一下主人这边，随便说说你看到的，一两句就好）"

var _host = null

func setup(host) -> void:
	_host = host

## 偷看屏幕：定时截图发给她，让她就着画面里我在做什么说一句。
## 走的是同一个 /api/chat，只是带上 image_data —— 后端要配多模态模型
## （CHAT_MODEL 得是带 vision 的名字），不然图片会被丢掉。
func check_peek(delta: float) -> void:
	if not _host._peek_on or _host._chat == null:
		return
	# 没配视觉模型 = 关掉看图：连截屏都不必，更别说把图发出去（见 _vision_ready）
	if not _host._vision_ready():
		_host._peek_timer = maxf(1.0, _host.peek_every_min) * 60.0
		return
	# 假死：后端联系不上，截了图也没地方发 —— 连截图这一步都省了
	if _host._offline():
		_host._peek_timer = maxf(1.0, _host.peek_every_min) * 60.0
		return
	_host._peek_timer -= delta
	if _host._peek_timer > 0.0:
		return
	# 到点了但她正忙着（在收流 / 面板开着 / 在等摄像头）：过一小会儿再看一眼。
	# 别在这儿把倒计时重置成整个间隔 —— 那会白等一整个 peek_every_min
	if _host._chat.is_busy() or _host._ui_panel_open() or _host._chat_streaming or _host._camera_busy:
		_host._peek_timer = PEEK_RETRY_SEC
		return
	_host._peek_timer = maxf(1.0, _host.peek_every_min) * 60.0
	peek_and_comment()

## 定时"看一眼摄像头"：和偷看屏幕一样，到点了她正忙就过一小会儿再看。
##
## 注意 `camera_look()` 是协程，这里**故意不 await**：本函数跑在 _process 那条链路上，
## 在那儿 await 会让本帧提前返回、把状态机重入。fire-and-forget 让它自己跑完，
## 期间用 _camera_busy 挡住重入。
func check_camera(delta: float) -> void:
	if not _host._camera_on or not _host._vision_ready():
		return
	# 假死：同偷看那条 —— 别对着空气开摄像头
	if _host._offline():
		_host._camera_timer = maxf(1.0, _host.camera_every_min) * 60.0
		return
	_host._camera_timer -= delta
	if _host._camera_timer > 0.0:
		return
	if _host._ai_busy() or _host._ui_panel_open() or _host._chat_streaming or _host._camera_busy:
		_host._camera_timer = PEEK_RETRY_SEC
		return
	_host._camera_timer = maxf(1.0, _host.camera_every_min) * 60.0
	camera_look()

func peek_and_comment() -> void:
	if _host._vision == null:
		_host._say("我这边还没配好看图的模型呢…")
		return
	# 摄像头那条链路也用这一个气泡，同时来会互相顶掉
	if _host._ai_busy():
		_host._say("等我先把这句说完～")
		return
	var shot: String = peek_screen()
	if shot == "":
		_host._say("截屏失败了…")
		return
	_host._begin_stream_bubble()
	_host._last_origin = "peek"          # 记忆：这轮是偷看屏幕引出来的
	if not _host._send_first(PROMPT_PEEK, shot):
		_host._chat_streaming = false
		_host._say("发送失败，稍后再试～")

## 抓当前屏幕 → JPEG → data URL。
## 用 JPEG 不用 PNG：一张 1080p 的 PNG 能有 3MB，base64 之后 4MB，
## 后端和模型都吃不消；JPEG 0.75 通常只有一两百 KB。
func peek_screen() -> String:
	var img := DisplayServer.screen_get_image(DisplayServer.window_get_current_screen())
	if img == null or img.is_empty():
		return ""
	if img.get_width() > 1280:
		var ratio: float = 1280.0 / float(img.get_width())
		img.resize(int(img.get_width() * ratio), int(img.get_height() * ratio),
			Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(0.75)
	if jpg.is_empty():
		return ""
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(jpg)

# ------------------------------------------------------------------ 主动开口时"先瞥一眼"

## 主动开口那句的提示词。里面那个 `%s` 是**前台窗口**（见 foreground_text）。
##
## 为什么要它（2026-09-27 用户报的"假现实"）：抓屏走的是桌面合成，**独占全屏 / 带反作弊**
## 的游戏抓不到，那一瞬间屏幕上有什么就抓到什么 —— 主人玩游戏时她可能只拿到一张铺满
## 文件夹的桌面，于是说"你在整理文件"。窗口标题是**唯一能在这种情况下纠偏的信息**
## （只读标题，不注入、不抓屏，反作弊管不着）。
const PROMPT_PROACTIVE_PEEK := "（你刚瞥了一眼主人的屏幕：这张就是他屏幕现在的样子。" \
	+ "你顺便看到他前台开着的是「%s」。别回答我这句话，自己找个话题跟主人说一句，一两句就好，" \
	+ "像随口聊天。**只说你真看到的东西**：要是画面和他前台开着的东西对不上" \
	+ "（全屏游戏、反作弊屏蔽画面时，你只会看到桌面），就别硬猜他在干什么，随口问一句就行）"

## 问"前台窗口是谁"用的 PowerShell。
##
## 两条硬经验（都踩过）：
##   1. **必须写成 .ps1 文件再执行** —— 不能把 DllImport 塞进命令行：那些引号要过
##      GDScript → 命令行 → PowerShell 三层剥皮，实测被咬（Add-Type 报
##      "当前上下文中不存在名称 user32"）；
##   2. **结果也写成文件再读回来** —— `OS.execute` 收 stdout 会按系统 ANSI 页解码，
##      窗口标题里的中文会乱码（同一个坑 pet_harness.gd 也记着）。
const FG_PS1 := """param([string]$Out)
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PetFg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
$h = [PetFg]::GetForegroundWindow()
$sb = New-Object System.Text.StringBuilder 512
[void][PetFg]::GetWindowText($h, $sb, 512)
$r = New-Object PetFg+RECT
[void][PetFg]::GetWindowRect($h, [ref]$r)
$title = $sb.ToString()
$size = ($r.Right - $r.Left).ToString() + "x" + ($r.Bottom - $r.Top).ToString()
[System.IO.File]::WriteAllText($Out, $title + "`n" + $size, (New-Object System.Text.UTF8Encoding($false)))
"""

## 前台窗口 → 一句人话（例如「某个游戏（看起来是满屏的）」）。拿不到返回空串。
##
## 别把它放 _process 里：`OS.execute` 是阻塞的（约 0.3~0.5 秒）。只在"主动开口时瞥了一眼"
## 和"偷看屏幕"这两条链上调用 —— 那两条本来就要等一次抓图 / 一次请求，多这半秒无所谓。
func foreground_text() -> String:
	var script_path := "user://pet_fg.ps1"
	var out_path := "user://pet_fg.txt"
	# 解释器路径走宿主那套现成的（pet_shell.powershell → pet_windows）——
	# 别自己拼 "powershell"：模块那边已经处理过路径与平台差异（2026-09-27 先写错过名字）
	var ps := ""
	if _host.shell != null:
		ps = _host.shell.powershell()
	if ps == "":
		return ""
	var sf := FileAccess.open(script_path, FileAccess.WRITE)
	if sf == null:
		return ""
	sf.store_string(FG_PS1)
	sf.close()
	var out: Array = []
	var code := OS.execute(ps, PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
		ProjectSettings.globalize_path(script_path),
		ProjectSettings.globalize_path(out_path)]), out, true)
	if code != 0:
		return ""
	var rf := FileAccess.open(out_path, FileAccess.READ)
	if rf == null:
		return ""
	var title := rf.get_line().strip_edges()
	var size := rf.get_line().strip_edges()
	rf.close()
	if title == "":
		return ""
	# 满屏的话说清楚 —— 那正是"抓屏多半抓不到"的场合
	var full := ""
	var parts := size.split("x")
	if parts.size() == 2 and String(parts[0]).is_valid_int() and _host._screen != null:
		if int(parts[0]) >= _host._screen.size.x - 2:
			full = "（看起来是满屏的）"
	return title + full

## 主动开口时要不要先瞥一眼屏幕。三道闸：开关（默认开）/ 配了视觉模型 / 概率。
func wants_proactive_peek() -> bool:
	# 读的是**运行时**那个 `_proactive_peek_on`（菜单开关切的就是它）——
	# `proactive_peek_enabled` 只是出厂默认值 / 存档缺键时的回落值。
	# 2026-09-27 先写错成读 @export：表现成"菜单里关掉也不生效"（探针当场抓到）
	if not bool(_host._proactive_peek_on):
		return false
	if not _host._vision_ready():
		return false          # 没配视觉模型：连抓都不抓（和定时偷看同一个规矩）
	return _host._rng.randf() < float(_host.proactive_peek_chance)

## 瞥过一眼之后，主动开口那句要用的提示词（带上前台窗口）
func proactive_peek_prompt() -> String:
	var fg := foreground_text()
	if fg == "":
		fg = "（查不到）"
	return PROMPT_PROACTIVE_PEEK % fg

## 菜单「看一眼摄像头」/ 定时那条：用**本机摄像头**抓一张，让视觉模型就着照片说一句。
##
## 走 Godot 自带的 CameraServer 自己采集 —— 不再依赖 AIGirlfriend 那个外部程序，
## 所以这条链路也是发到视觉模型（和偷看屏幕同一条，见 vision_url / vision_model）。
##
## 这个函数是**协程**（要等相机吐第一帧，冷启动可能几秒）。它由菜单信号或
## 定时那条调用，不在 _process 里跑 —— _process 里 await 会让本帧提前返回、
## 状态机被重入，那是另一个故事。
func camera_look() -> void:
	if not _host._vision_ready():
		_host._say("我这边还没配好看图的模型呢…")
		return
	if _host._ai_busy():
		_host._say("等我先把这句说完～")
		return
	_host._camera_busy = true
	# 先撑住气泡说句话，别让她干站着等相机
	_host.bubble.hold_with("让我看看…")
	var shot: String = await camera_shot()
	_host._camera_busy = false
	if shot == "":
		# 两种情况分开说 —— 排查方向完全不同：
		#   "没设备" = 权限 / 驱动 / 引擎枚举（先看 Windows 相机能不能打开）
		#   "有设备没画面" = 被占用，或者笔记本的摄像头硬开关/快捷键关着
		if _host._camera_last_error.find("没能取到画面") >= 0:
			_host._say("我这边有摄像头，但看不到画面诶…")
		elif OS.get_name() == "Windows":
			# 说清楚是"我这边不行"，而不是"你的相机有问题" ——
			# 免得主人跑去折腾驱动、权限、设备管理器（实测那些全都是好的）
			_host._say("唔…我这台机器上用不了摄像头诶。")
		else:
			_host._say("我这边没找到摄像头诶…")
		return
	_host._begin_stream_bubble()
	_host._last_origin = "camera"        # 记忆：这轮是看摄像头引出来的
	if not _host._send_first(CAMERA_QUESTION, shot):
		_host._chat_streaming = false
		_host._say("发送失败，稍后再试～")

## 从本机摄像头抓一帧 → JPEG data URL；拿不到就返回 ""。
##
## 两个实测出来的坑：
##   1. **必须先开监控**：不调 set_monitoring_feeds(true)，get_feed_count() 恒返回 0，
##      而且会报 "CameraServer is not actively monitoring feeds"；
##   2. 摄像头刚打开时纹理会晚几帧才有内容，所以要等（最多约 5 秒），拿不到就认输。
func camera_shot() -> String:
	_host._camera_last_error = ""
	CameraServer.set_monitoring_feeds(true)
	# 开监控之后设备是**异步注册**的：立刻读可能还是 0，所以等最多约 1 秒再看一眼。
	# 这台机器上不是这个原因（等了 8 秒也是 0），但有的机器确实要晚一拍，白等 1 秒不亏
	var n := CameraServer.get_feed_count()
	var waited := 0
	while n <= 0 and waited < 60:
		await _host.get_tree().process_frame
		waited += 1
		n = CameraServer.get_feed_count()
	if n <= 0 or _host.camera_index >= n:
		# Windows 上这基本是**定局**，不是配置问题：官方 Godot 的 Windows 构建里
		# 根本没有摄像头后端 —— 两个版本（4.7 Steam tools / 4.6 官方标准版）的二进制里
		# 连 mfplat 这个字符串都没有，而 CameraServer / CameraFeed / wasapi 这些都在。
		# 所以枚举恒为 0，而且一个字都不报。别让主人去折腾相机驱动和权限
		if OS.get_name() == "Windows":
			_host._camera_last_error = "这台机器上 Godot 拿不到摄像头（Windows 版引擎没有摄像头后端；枚举到 %d 个）" % n
		else:
			_host._camera_last_error = "没找到摄像头设备（CameraServer 枚举到 %d 个）" % n
		if OS.is_debug_build():
			print("[桌宠] %s" % _host._camera_last_error)
		return ""
	var feed: CameraFeed = CameraServer.get_feed(_host.camera_index)
	if feed == null:
		_host._camera_last_error = "枚举到设备了，但拿到的 feed 是空的"
		return ""
	if not feed.is_active():
		feed.set_active(true)
	var img: Image = null
	for i in 300:                     # 60fps × 300 ≈ 5 秒
		var tex: Texture2D = feed.get_texture(CameraServer.FEED_RGBA_IMAGE)
		if tex != null and tex.get_width() > 0:
			img = tex.get_image()
			if img != null and not img.is_empty():
				break
		await _host.get_tree().process_frame
	if img == null or img.is_empty():
		_host._camera_last_error = "摄像头在，但没能取到画面（可能被别的程序占用，或者笔记本的摄像头开关/快捷键关着）"
		if OS.is_debug_build():
			print("[桌宠] %s" % _host._camera_last_error)
		return ""
	if img.get_width() > 1280:
		var ratio: float = 1280.0 / float(img.get_width())
		img.resize(int(img.get_width() * ratio), int(img.get_height() * ratio),
			Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(0.8)
	if jpg.is_empty():
		_host._camera_last_error = "画面拿到了，但压成 JPEG 失败"
		return ""
	_host._camera_last_error = ""
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(jpg)
