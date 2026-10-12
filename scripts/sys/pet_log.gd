# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 日志：把"出问题时的现场"留下来，并且能一键导出。
##
## **为什么要有这个文件**：导出版双击就跑、**没有控制台**。她一不对劲，用户能说的只有
## "它不动了"，而现场全在对方屏幕上飘一下就没了。
##
## 引擎那份 `user://logs/godot.log` 也写盘了（见 project.godot 的 `[debug]`），但它不够用：
##   ① 它取决于项目设置 —— 那一行被改掉 / 被覆盖，证据链就整条断了（自启动跑的是导出版，
##      最不能出岔子的就是它）；② 里面是一锅大杂烩，没有级别、没有分类；
##   ③ 它是"这个进程碰巧打印了什么"，不是"我们想让人看的那几句"。
## 所以这里再自己写一份带级别的：print 是给开发看的，这一份是给用户导出发出来的。
##
## 这里做两件事：
##   1) 自己往 `user://logs/pet.log` 写 —— 不依赖引擎日志那套，启动 / 退出 / 报错都落盘
##   2) `export_logs()`：把 logs 目录 + 一份系统信息收成一个 zip 丢到桌面。
##      用户右键转发过来，我就能看到"她跑在什么机器上、出了什么错"
##
## **和 pet_start.log 的分工**：那个文件（desktop_pet._log_line）**保持原样不动** ——
## 「自启动没生效时按这个顺序查」整套排查是照着它的格式写的（见 scripts/sys/README.md）。
## 这里记的是"别的东西"：报错、配置、网络、记忆。导出时两个都收。
##
## **隐私**：导出前每一行都过一遍 `_redact()`（Bearer / sk- / 已知密钥整串换掉）；
## 收走的只有"日志 + 系统信息"，**记忆（pet_memory.json）、聊天记录（pet_chat.cfg）、
## 密钥（pet_secret.dat）一个都不碰**。所以这份 zip 可以直接发给别人。
##
## 全 **static**（和 pet_ui.gd / pet_secret.gd 一个路子）：不碰宿主、不用实例化，
## 任何地方一句 `PetLog.err("聊天", "连不上")` 就能用，也不需要注册 autoload。
extends RefCounted

## 日志目录。引擎自己的 godot.log 也落在同一个目录里（见 project.godot 的 [debug]）
const DIR := "user://logs"
const PATH := "user://logs/pet.log"
## 轮转出来的上一份。只留一份：日志是用来查"刚刚那次"的，不是档案
const PATH_OLD := "user://logs/pet.log.1"
## 超过这个大小就轮转，别让它无限长（256 KB 够装几万行）
const MAX_BYTES := 262144

## 导出时收走的文件：`[导出后的名字, 源路径]`。
## 名字统一 `*.txt`：用户那边双击就能用记事本打开，不用先问"这是什么格式"
const EXPORT_FILES: Array = [
	["程序日志.txt", "user://logs/pet.log"],
	["程序日志（上一份）.txt", "user://logs/pet.log.1"],
	["引擎日志.txt", "user://logs/godot.log"],
	["启动与退出记录.txt", "user://pet_start.log"],
]

## 一眼能认出是密钥的形态。替换成同一句话 —— 导出的意义是"能发给别人看"
const SECRET_PATTERNS: Array = [
	"Bearer\\s+\\S+",
	"sk-[A-Za-z0-9._\\-]{8,}",
]

# ------------------------------------------------------------------ 记一行

## 普通事件（启动 / 退出 / 用户做了什么）
static func log(tag: String, msg: String) -> void:
	_write("INFO", tag, msg)

## 可疑但没断（重试、退回默认值、某项不可用）
static func warn(tag: String, msg: String) -> void:
	_write("WARN", tag, msg)

## 真的出错了。**这条是"导出日志"最主要想看到的东西**，
## 所以能判断出失败的地方都应该留一条（别静默 return）
static func err(tag: String, msg: String) -> void:
	_write("ERR ", tag, msg)

static func _write(level: String, tag: String, msg: String) -> void:
	var stamp := Time.get_datetime_string_from_system(false, true)
	var line := "[%s] %s [%s] %s" % [stamp, level, tag, msg]
	# 编辑器里跑时顺手打到输出面板，开发时不用来回开文件
	if OS.is_debug_build():
		print("[PetDeek] " + line)
	_append(line)

## 追加一行。READ_WRITE 打不开就退回 WRITE 重开 —— 这个写法是从
## desktop_pet._log_line 抄来的（那边实测过：READ_WRITE 遇到"文件还没建"会给 null）
static func _append(line: String) -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)
	_rotate_if_needed()
	var f := FileAccess.open(PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return          # 磁盘满了 / 没权限：这里再报错也没地方可报，认了
	f.seek_end()
	f.store_line(line)
	f.close()

static func _rotate_if_needed() -> void:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var too_big := f.get_length() > MAX_BYTES
	f.close()
	if not too_big:
		return
	if FileAccess.file_exists(PATH_OLD):
		DirAccess.remove_absolute(PATH_OLD)
	DirAccess.rename_absolute(PATH, PATH_OLD)

# ------------------------------------------------------------------ 导出

## 把日志 + 系统信息收成一个包，返回**绝对路径**（失败给空串）。
##
## `extra`：宿主那边的状态（后端地址 / 模型 / 有没有配 key …），原样列成一节。
## `secret_values`：手上有的密钥明文，整串换掉（比正则靠谱）；
##                  **数量是"有没有配"，值本身永远不写进日志**。
static func export_logs(extra: Dictionary = {}, secret_values: Array = []) -> String:
	var stamp := Time.get_datetime_string_from_system(false, true)
	stamp = stamp.replace(":", "-").replace(" ", "_")
	# ⚠️ 落点要**真去建目录才算数**，不能只看"空不空 / 在不在"（2026-10-09 手机真机实测）：
	#   Android 上 `OS.get_system_dir(DESKTOP)` 返回 `/storage/emulated/0` ——
	#   路径**存在** ✓，但那是公共存储、应用**写不进去** ✗（scoped storage ✓）。
	#   老写法只判存在 → 判定通过 → 建目录失败 → 直接报"导出失败" ✗，
	#   而它本该退回 `user://`（手机宿主随后会用 PetBridge 把包挪进公共「下载」✓）。
	#   所以挨个候选落点**真去建**，第一个建得出来的才用 ✓
	var folder := ""
	for base in _export_bases():
		var candidate: String = base.path_join("PetDeek-日志-%s" % stamp)
		if DirAccess.make_dir_recursive_absolute(candidate) == OK:
			folder = candidate
			break
	if folder == "":
		return ""
	# 系统信息第一个写：就算下面那些日志全是空的，这一份也够说明"跑在什么机器上"
	_write_text(folder.path_join("系统信息.txt"), info_text(extra))
	for pair in EXPORT_FILES:
		var src := String(pair[1])
		if not FileAccess.file_exists(src):
			continue
		var text := _read_text(src)
		if text.strip_edges() == "":
			continue
		_write_text(folder.path_join(String(pair[0])), _redact(text, secret_values))
	# 打成 zip 才好转发（用户直接拖进聊天窗口）。打不出来就留着文件夹，一样能用
	var zip_path := folder + ".zip"
	if _zip(folder, zip_path):
		_cleanup_dir(folder)
		return zip_path
	return folder

## 导出的候选落点，按顺序试 ✓：桌面 → 数据目录。
## 手机上没有"桌面"这回事 ✓，而 `/storage/emulated/0` **存在却写不进** ✗ ——
## 所以判据只能是"真去建目录"，见 export_logs 里那段说明 ✓
static func _export_bases() -> Array:
	var out: Array = []
	# ⚠️ 安卓上**别把那个候选放进来**：它返回 /storage/emulated/0，写不进还让引擎
	# 吐一条 `ERROR: Could not create directory: …` ✗（功能没错，但日志里那条红字会误导人 ✓）
	if OS.get_name() != "Android":
		var desk := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
		if not desk.is_empty() and DirAccess.dir_exists_absolute(desk):
			out.append(desk)
	out.append(OS.get_user_data_dir())      # 兜底：一定写得进去 ✓
	return out

## 系统信息：程序 / 机器 / 她那些设置。**任何一项取不到都不算错** —— 缺的那行跳过
static func info_text(extra: Dictionary = {}) -> String:
	var v := Engine.get_version_info()
	var lines: Array[String] = []
	lines.append("PetDeek 日志")
	lines.append("导出时间：%s" % Time.get_datetime_string_from_system(false, true))
	lines.append("")
	lines.append("—— 程序 ——")
	# 版本串里本来就带构建名（"4.7.2-stable (steam)"），别再补一个括号
	var ver := String(v.get("string", "?"))
	lines.append("引擎：Godot %s" % ver)
	var build := String(v.get("build", ""))
	if build != "" and not ver.contains(build):
		lines.append("构建：%s" % build)
	lines.append("可执行文件：%s" % OS.get_executable_path())
	lines.append("启动参数：%s" % " ".join(OS.get_cmdline_args()))
	lines.append("数据目录：%s" % OS.get_user_data_dir())
	lines.append("调试版：%s" % ("是" if OS.is_debug_build() else "否"))
	lines.append("主场景：%s" % String(ProjectSettings.get_setting("application/run/main_scene", "")))
	lines.append("渲染方式：%s" % String(ProjectSettings.get_setting(
		"rendering/renderer/rendering_method", "")))
	if OS.has_method("get_video_adapter_driver_info"):
		var drv: PackedStringArray = OS.get_video_adapter_driver_info()
		if drv.size() >= 2:
			lines.append("显卡：%s %s" % [drv[0], drv[1]])
	lines.append("")
	lines.append("—— 机器 ——")
	lines.append("系统：%s %s" % [OS.get_name(), OS.get_version()])
	# ⚠️ 安卓上这两样都取不到（2026-10-09 真机导出的包里就是"CPU：（8 核）"和"-0.0 GB" ✗）——
	# 一份要发给别人看的报告里，宁可写"拿不到"，也别写一个让人误会的数字 ✓
	var cpu := OS.get_processor_name().strip_edges()
	if cpu != "":
		lines.append("CPU：%s（%d 核）" % [cpu, OS.get_processor_count()])
	else:
		lines.append("CPU：%d 核（这台机器取不到型号）" % OS.get_processor_count())
	var mem: Dictionary = OS.get_memory_info()
	if mem.has("physical") and float(mem["physical"]) > 0.0:
		# 报 physical / free。**别用 available** —— 那个是"可用虚拟内存"，
		# 算出来比物理内存还大（实测见过"内存 31.7 GB，可用 87.5 GB"），只会把人带偏
		lines.append("内存：%.1f GB（空闲 %.1f GB）" % [
			float(mem["physical"]) / 1073741824.0, float(mem.get("free", 0)) / 1073741824.0])
	var tz: Dictionary = Time.get_time_zone_from_system()
	lines.append("时区：%s（%d 分钟）" % [String(tz.get("name", "")), int(tz.get("bias", 0))])
	lines.append("语言：%s" % OS.get_locale())
	lines.append("")
	lines.append("—— 窗口 ——")
	var scr := DisplayServer.window_get_current_screen()
	# headless（探针 / --script 跑）时这块是空的，会写出"第 -1 块 (0, 0)"这种噪音
	if scr >= 0:
		lines.append("屏幕：%s（第 %d 块，缩放 %.2f，DPI %d）" % [
			DisplayServer.screen_get_size(scr), scr,
			DisplayServer.screen_get_scale(scr), DisplayServer.screen_get_dpi(scr)])
		lines.append("窗口尺寸：%s" % DisplayServer.window_get_size())
	else:
		lines.append("屏幕：取不到（没有窗口 / headless 跑的）")
	if not extra.is_empty():
		lines.append("")
		lines.append("—— 她那边的设置 ——")
		for k in extra.keys():
			lines.append("%s：%s" % [k, extra[k]])
	return "\n".join(lines) + "\n"

## 把密文形态的东西换掉。**顺序是刻意的**：先按形态扫（Bearer / sk-），
## 再拿手上那个真 key 整串替换 —— 后者能覆盖"形态不像密钥"的自建后端 token
static func _redact(text: String, secret_values: Array = []) -> String:
	var out := text
	var re := RegEx.new()
	for p in SECRET_PATTERNS:
		if re.compile(p) != OK:
			continue
		out = re.sub(out, "<已隐去>", true)
	for v in secret_values:
		var s := String(v).strip_edges()
		if s.length() >= 8:
			out = out.replace(s, "<已隐去>")
	return out

static func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

static func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()

## 目录打成 zip。
##
## **ZIPPacker 故意用 ClassDB 拿、而不是直接 `ZIPPacker.new()`**：万一哪个版本没有
## 这个类，直接写类名会让**整个 desktop_pet.gd 编译不过**（表现是"她根本起不来"）——
## 那代价太大。这里拿不到就返回 false，退化成"留一个文件夹"，功能照旧
static func _zip(dir: String, zip_path: String) -> bool:
	var packer: Object = ClassDB.instantiate("ZIPPacker")
	if packer == null:
		return false
	if packer.call("open", zip_path) != OK:
		return false
	var da := DirAccess.open(dir)
	if da == null:
		packer.call("close")
		return false
	var ok := false
	for name in da.get_files():
		var f := FileAccess.open(dir.path_join(name), FileAccess.READ)
		if f == null:
			continue
		var bytes := f.get_buffer(f.get_length())
		f.close()
		if packer.call("start_file", name) != OK:
			continue
		packer.call("write_file", bytes)
		packer.call("close_file")
		ok = true
	packer.call("close")
	return ok

## zip 打成了就把文件夹收掉（只删自己刚建的那几个文件 —— 目录是这次新建的）
static func _cleanup_dir(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for name in da.get_files():
		DirAccess.remove_absolute(dir.path_join(name))
	DirAccess.remove_absolute(dir)
