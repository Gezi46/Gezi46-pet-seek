# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
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
## 摄像头那条的提示词。
##
## 后半句是 2026-10-09 加的（用户实测报的"瞎说话"）：手机/平板**平放着**的时候，
## 摄像头对着的是**天花板** ✗ —— 画面里根本没有"主人"。而模型不会说"我看不清"，
## 它会顺着这句话把自己的想象编成一个故事（她当时张口就来"你在看手机、杯子空了" ✗）。
## 所以这里明说"看不清就直说"，并且 camera_shot() 发之前还会先量一遍画面（纯色就压根不发 ✓）
const CAMERA_QUESTION := "（你抬眼看了一眼主人这边。别当「描述画面」的任务来做 —— " \
	+ "像你抬头瞥了一眼、顺口跟他说一句那样，挑你真注意到的一两处说，口气照你平时的来；" \
	+ "别一件件报画面里有什么，也别写成解说。" \
	+ "要是画面是空的、糊的，或者只有天花板/墙/桌面（设备平放时对着的就是这些），" \
	+ "就直接说看不清、问他在哪儿 —— 别猜，更别编他在干嘛。" \
	+ "另外这张图可能没有颜色（手机上的摄像头有时只给明暗）—— 那就别聊颜色）"
## 画面有、但没内容时说的话（纯色 / 全黑 / 被挡住 / 对着天花板）。
## 为什么专门备一句：不这么说只有两个下场 —— 要么说"看不到画面"（其实拿到了 ✓ 误导排查 ✗），
## 要么把那张纯色图发给模型（它一定会编 ✗，2026-10-09 用户实测）
const LINES_CAMERA_BLANK: Array[String] = [
	"唔…我这边看到的是一片空空的，你是把设备放平了吗？",
	"诶？我这边什么都看不清呀，是不是挡着了？",
]

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
		elif _host._camera_last_error.find("几乎是纯色") >= 0:
			_host._say(LINES_CAMERA_BLANK[randi() % LINES_CAMERA_BLANK.size()])
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
			print("[PetDeek] %s" % _host._camera_last_error)
		return ""
	var feed: CameraFeed = _pick_feed()
	if feed == null:
		_host._camera_last_error = "枚举到设备了，但拿不到可用的 feed"
		return ""
	# ⚠️ **必须先选格式**才能激活（2026-10-09 真机 logcat 实测，安卓）：
	#   ERROR: CameraFeed format needs to be set before activating.
	#          Selected format index: -1 (formats size: 65)
	#          at: activate_feed (modules/camera/camera_android.cpp:230)
	# 引擎给了 65 个候选，一个都没选 → 激活直接失败 ✓（Windows 上根本枚举不到设备，
	# 所以这条以前从来没露过头 ✓）。先挑第 0 个：具体哪个格式画质/比例最好，以后按需再调 ✓
	# ⚠️ feed 已经在播的时候再 set_format 会报错（真机：at set_format camera_android.cpp:358 ✗）
	var formats: Array = feed.get_formats()
	if not feed.is_active() and not formats.is_empty():
		var fi := _pick_format_index(formats)
		feed.set_format(fi, formats[fi])
		if OS.is_debug_build():
			print("[PetDeek] 选了格式 #%d / 共 %d 档：%s" % [fi, formats.size(), str(formats[fi])])
	if not feed.is_active():
		feed.set_active(true)
	var img: Image = await _grab_camera_frame(feed)
	if img == null or img.is_empty():
		_host._camera_last_error = "摄像头在，但没能取到画面（可能被别的程序占用，或者摄像头开关/快捷键关着）"
		if OS.is_debug_build():
			print("[PetDeek] %s" % _host._camera_last_error)
		return ""
	# YCbCr 的 feed 给的是"Y 在 R、G/B 空"的假红图 ✗ → 掰成诚实的灰度（见 _collapse_to_gray ✓）
	#（真 RGBA 的机子不动它 ✓ —— Linux 那边的颜色是真的 ✓）
	var dt := feed.get_datatype()
	if dt == CameraFeed.FEED_YCBCR or dt == CameraFeed.FEED_YCBCR_SEP:
		img = _collapse_to_gray(img, 480)
	# ⚠️ 发出去之前先量一眼"这张图有没有信息量"（2026-10-09，用户实测报的"瞎说话"）：
	#   设备平放着 → 摄像头对着天花板 → 画面几乎是**一块纯色** ✗。
	#   这种图连人眼都看不出东西，发给模型它只会编 —— 她当时说"你在看手机、杯子空了"，
	#   而实际画面里只有天花板 ✓。判据两条：亮度标准差太小、或某一种颜色占了绝大多数采样点
	var st := _image_stats(img)
	if OS.is_debug_build():
		print("[PetDeek] 相机这帧的信息量：亮度均值 %.3f ｜ 标准差 %.4f ｜ 最大同色占比 %.2f" % [
			st["mean"], st["std"], st["same"]])
		# 真机排查专用：把这一帧落盘，adb 拉出来**亲眼看**她收到了什么 ✓
		#（怀疑"她是不是瞎说话"时，这是唯一能定案的证据 ✓）
		img.save_jpg("user://cam_last.jpg", 0.85)
	if float(st["std"]) < 0.02 or float(st["same"]) > 0.92:
		_host._camera_last_error = "画面几乎是纯色（对着天花板 / 被挡住 / 全黑）—— 没信息量，不发"
		if OS.is_debug_build():
			print("[PetDeek] %s" % _host._camera_last_error)
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

## 挑一个 feed。手机上**前后是两个 feed**（2026-10-09 真机确认 ✓），
## 而"她看一眼"要看的是**前置** —— 对着主人那张脸 ✓，不是后置（对着桌子/天花板 ✗）。
## 用户 2026-10-09 就是拿这句点醒的：「手机分前后摄像头 你用前摄像头」✓
##
## 宿主的 `camera_position`：0 = 前置优先（默认 ✓）/ 1 = 只要前置 / 2 = 用后置。
## 桌面宿主没有这个字段（它那边枚举恒 0，根本走不到这儿 ✓），所以用 Object.get 取，
## 取不到就按 0 —— 别写成 `_host.camera_position`（桌面上会 "Invalid get index" ✗）
func _pick_feed() -> CameraFeed:
	var n := CameraServer.get_feed_count()
	if n <= 0:
		return null
	var front: CameraFeed = null
	var back: CameraFeed = null
	var fallback: CameraFeed = null
	var lines := ""
	for i in n:
		var f: CameraFeed = CameraServer.get_feed(i)
		if f == null:
			continue
		if i == _host.camera_index:
			fallback = f
		match f.get_position():
			CameraFeed.FEED_FRONT:
				if front == null:
					front = f
			CameraFeed.FEED_BACK:
				if back == null:
					back = f
		if OS.is_debug_build():
			lines += " #%d「%s」位置=%d" % [i, f.get_name(), f.get_position()]
	if OS.is_debug_build():
		print("[PetDeek] 摄像头枚举到 %d 个：%s" % [n, lines])
	if fallback == null:
		fallback = CameraServer.get_feed(0)
	var want := _want_position()
	if want == 2:
		return back if back != null else fallback
	if front != null:
		return front                                  # 默认（0）和"只要前置"（1）都走这条 ✓
	if back != null:
		return back
	return fallback                                   # 位置没报上来的设备（FEED_UNSPECIFIED）✓

## 宿主想让用哪个位置（见 _pick_feed）。台式宿主没这个字段 → 按默认 0 ✓
func _want_position() -> int:
	var v: Variant = _host.get("camera_position")
	return int(v) if v != null else 0

## 从引擎给的格式表里挑一档"真能跑起来"的。
## 真机实测（2026-10-09，安卓）：格式表**按分辨率从大到小**排，第 0 个是 4608×3456（12MP）；
## 选它时摄像头激活成功、却**一帧都不吐**（CameraTexture 恒 (0,0) → 读回来全黑 ✗）。
## 所以挑"离 1280×720 最近"的那档，并且尽量别超过 1920（省带宽，也不容易开不起来 ✓）
func _pick_format_index(fm: Array) -> int:
	var best := 0
	var best_score := -1.0
	for i in fm.size():
		var d: Dictionary = fm[i]
		var w := float(d.get("width", 0))
		var h := float(d.get("height", 0))
		if w <= 0.0 or h <= 0.0:
			continue
		var score := absf(w - 1280.0) + absf(h - 720.0)
		if w > 1920.0:
			score += 10000.0           # 大过 1080p 的直接排到后面去 ✓
		if best_score < 0.0 or score < best_score:
			best_score = score
			best = i
	return best

## 量一张图"有多空"：亮度均值、标准差、以及"出现最多的那种颜色占多少比例"。
## 只抽大约 4000 个点（等步长撒网 ✓）—— 这一帧本来就要压成 JPEG 发走，
## 多花几毫秒换"不发一张纯色图去喂模型"完全值得 ✓
func _image_stats(img: Image) -> Dictionary:
	var step := maxi(1, int(sqrt(float(img.get_width() * img.get_height()) / 4000.0)))
	var n := 0
	var sum := 0.0
	var sum2 := 0.0
	var counts := {}
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			var l := (c.r + c.g + c.b) / 3.0
			sum += l
			sum2 += l * l
			# 颜色按 1/16 档粗分：跟"这几种颜色各自占多少"比精确值更抗噪 ✓
			var key := "%d_%d_%d" % [int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)]
			counts[key] = int(counts.get(key, 0)) + 1
			n += 1
	var f := maxf(1.0, float(n))
	var mean := sum / f
	var top := 0
	for k in counts.keys():
		top = maxi(top, int(counts[k]))
	return {
		"mean": mean,
		"std": sqrt(maxf(0.0, sum2 / f - mean * mean)),
		"same": float(top) / f,
		"n": n,
	}

## 从 feed 里取一帧 Image。整段最"脏"的地方，六条经验全是真机踩出来的：
##   ① **CameraFeed 没有 `get_texture()`** ✗（真机报 Nonexistent function）；
##      正路是 `CameraTexture`（Texture2D，靠 camera_feed_id 挂在某个 feed 上 ✓）
##   ② 那个"取哪一路图像"的成员叫 **`which_feed`** ✗（不是文档里写的 feed_image_type ✓）
##   ③ 这个引擎里 `FEED_RGBA_IMAGE` / `FEED_YCBCR_IMAGE` / `FEED_Y_IMAGE` **全是 0** ✗
##      （探针量出来的 ✓）→ "单独取亮度那一路"根本不存在，别再试了 ✓
##   ④ 安卓的 feed 是 **FEED_YCBCR_SEP**（Y 与 CbCr 分两路）→ 从 CameraTexture 取到的是
##      **串了路的图** ✗：用户 2026-10-09 实测"全是红的、糊糊的、一片暗"，而当时
##      **人脸就在镜头前** ✓（形状还在、颜色全错 = 典型的 YUV 被当 RGB 用 ✓）
##   ⑤ 文档里**唯一**说引擎会替我们合成 YCbCr→RGB 的地方是"把相机设成 **环境背景**" ✓
##      → 正路 = 开一个带自己 World3D 的 SubViewport、背景设成 BG_CAMERA_FEED ✓（彩色 ✓）；
##      CameraTexture 那条降为**兜底**（Linux 那边本来就是 RGB ✓，走它能成 ✓）
##   ⑥ **第一帧的曝光还没收敛**（头几百毫秒本来就是黑的 ✗）→ 等 ~0.8 秒再抓 ✓
## 把"Y 塞在 R 上"的假红图掰成**诚实的灰度图**。
##
## 真机实测（2026-10-09，安卓）：拿回来的那张图 **G/B 是空的**（R 均值 91.8 ／ G 0.3 ／ B 0.4 ✗）、
## 而亮点样例是 (131,1,0) (150,0,1) —— 也就是 Y（亮度）被塞进了 R 通道 ✓。
## 直接发出去 = 一张**假红图** ✗：形状对、颜色全假，她一提颜色就是错的（她当时就说"全是红的" ✗），
## 而真实场景到底是什么颜色，我们**并不知道** ✗ → 那就别装 ✓：给一张灰度图 ✓，
## 提示词里也明说了"可能没有颜色，别硬报颜色" ✓。
##
## 为什么不用 shader 干（2026-10-09 试过 ✗）：ShaderMaterial 挂在 TextureRect 上、
## 真机读回来 G/B 依然是 0 ✗ —— 既看不出是没编过、还是 SubViewport 那层不认，
## 也不值得再赌一轮 ✗。这里就是缩到目标宽度、再把 R 铺到三路 ✓：
## 缩了之后是 480×360 量级（≈17 万像素 ✓），GDScript 里跑一遍也就几百毫秒 ✓，稳 ✓
func _collapse_to_gray(img: Image, target_w: int) -> Image:
	if img.get_width() > target_w:
		var r := float(target_w) / float(img.get_width())
		img.resize(target_w, maxi(1, int(img.get_height() * r)), Image.INTERPOLATE_BILINEAR)
	img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var n := img.get_width() * img.get_height()
	for i in n:
		var lum := data[i * 3]
		data[i * 3 + 1] = lum
		data[i * 3 + 2] = lum
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, data)

func _grab_camera_frame(feed: CameraFeed) -> Image:
	# ⚠️ 顺序是量出来的：**先走 CameraTexture**（真机实测能拿到 960×720 的真画面 ✓），
	# 环境背景那条（BG_CAMERA_FEED）在这台 + GLES3 上是**全黑** ✗ → 只当兜底 ✓
	var img := await _grab_via_texture(feed)
	if img != null and not img.is_empty():
		var s := _image_stats(img)
		if float(s["std"]) > 0.02 and float(s["same"]) < 0.92:
			return img                      # 有内容 ✓
	if OS.is_debug_build():
		print("[PetDeek] CameraTexture 那条没内容 → 试环境背景兜底")
	return await _grab_via_environment(feed)

## 正路：把相机设成**环境背景**，让引擎自己做 YCbCr→RGB（见头部 ⑤）
func _grab_via_environment(feed: CameraFeed) -> Image:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)          # 跟我们挑的那档格式一致 → 不拉伸、不裁 ✓
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.own_world_3d = true
	var w := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CAMERA_FEED
	env.background_camera_feed_id = feed.get_id()
	w.environment = env
	sub.world_3d = w
	sub.add_child(Camera3D.new())           # 3D 视口得有个相机，背景才是它渲出来的 ✓
	_host.add_child(sub)
	feed.set_active(true)
	var out: Image = null
	for i in 300:                           # 60fps × 300 ≈ 5 秒（含前面的曝光收敛 ✓）
		await _host.get_tree().process_frame
		if i < 48 or i % 15 != 0:
			continue                        # 前 0.8 秒别读（读也是黑的）；之后每 15 帧试一次
		out = sub.get_texture().get_image()
		if out != null and not out.is_empty():
			var st := _image_stats(out)
			if float(st["std"]) > 0.02 and float(st["same"]) < 0.92:
				break
	sub.queue_free()
	if OS.is_debug_build():
		print("[PetDeek] 环境背景：%s ｜ %s" % [
			"空 ✗" if out == null or out.is_empty() else "%dx%d" % [out.get_width(), out.get_height()],
			"{}" if out == null or out.is_empty() else str(_image_stats(out))])
		if out != null and not out.is_empty():
			out.save_jpg("user://cam_env.jpg", 0.9)      # 亲眼看用 ✓
	return out

## 兜底：走 CameraTexture（见头部 ①②④）。安卓上颜色会串 ✗，Linux 那边才是对的 ✓
func _grab_via_texture(feed: CameraFeed) -> Image:
	var tex := CameraTexture.new()
	tex.camera_feed_id = feed.get_id()
	var route := ""
	for p in ["feed_image_type", "which_feed"]:
		if tex.get(p) != null:
			route = p
			break
	if route != "":
		tex.set(route, CameraServer.FEED_RGBA_IMAGE)
	tex.camera_is_active = true
	var sub := SubViewport.new()
	sub.size = Vector2i(960, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := TextureRect.new()
	rect.texture = tex
	rect.size = Vector2(sub.size)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 这张图里的"颜色"是假的（Y 在 R、G/B 空 ✗）→ 读回来之后由调用方掰成灰度 ✓
	#（见 _collapse_to_gray：真机上试过用 shader 在渲染这层抹，没成 ✗）
	sub.add_child(rect)
	_host.add_child(sub)
	var waited := 0
	while tex.get_size().x <= 0.0 and waited < 300:          # 等纹理被相机填起来 ✓
		await _host.get_tree().process_frame
		waited += 1
	if OS.is_debug_build():
		print("[PetDeek] CameraTexture：等了 %d 帧 → %s" % [waited, str(tex.get_size())])
	if tex.get_size().x <= 0.0:
		sub.queue_free()
		return null
	for i in 48:                                             # 曝光收敛 ✓
		await _host.get_tree().process_frame
	var img: Image = null
	for i in 40:
		await _host.get_tree().process_frame
		img = sub.get_texture().get_image()
		if img != null and not img.is_empty():
			break
	sub.queue_free()
	if OS.is_debug_build() and img != null and not img.is_empty():
		print("[PetDeek] CameraTexture：%dx%d ｜ %s" % [
			img.get_width(), img.get_height(), str(_image_stats(img))])
		img.save_jpg("user://cam_texture.jpg", 0.9)
	return img
