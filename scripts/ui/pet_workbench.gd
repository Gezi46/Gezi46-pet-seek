# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 工作台：把活交给本机的 dsh 去干，**结果原文都摆在这儿**。
##
## 和聊天框里那句"干活：…"的分工：
##   聊天那条 = 顺手的小活，她立刻用一句话讲给你听（人设不破）；
##   工作台   = 正儿八经的活：任务能写好几行、能选工作目录和文件权限、
##              结果原文留在界面上（不经过她的转述）、干完还能一键重启把改动生效。
##
## 它主要是给**"让她给自己升级"**用的：
##   工作目录指到她的项目目录，勾上「允许她改文件」，dsh 就会真去改那份源码。
##   权限那一步在 dsh 那边只放宽到 `workspace-write` —— 也就是**只能动工作目录里的东西**，
##   改不到别处去（见 pet_harness.gd 的文件头）。`danger-full-access` 故意不提供。
##   改完代码不会立刻生效，点一下「重启她」才会加载新代码。
##
## 自己的三样设置（工作目录 / 自我升级 / 允许改文件）存在自己的 cfg 里，
## 不塞进设置面板那张表：那张表是"全局参数"，这些是"工作台自己的选择"，
## 硬夹进去还得让 PetSettings.sanitize() 认识它们，没必要。

## 派活。opts = {task, workspace, allow_write, self_upgrade}
signal run_requested(task: String, opts: Dictionary)
## 关闭（ESC / 关闭按钮 / 点外面）
signal closed()
## 重启她自己（应用刚改的代码）
signal restart_requested()
## 打开某个目录（工作目录按钮）
signal open_dir_requested(path: String)
## 面板里的设置变了（工作目录 / 那两个勾），主脚本不用管，这个模块自己存

const PetUi := preload("res://scripts/ui/pet_ui.gd")
const CFG := "user://pet_workbench.cfg"
const MARGIN := 4.0
## 自我升级时附在任务前面的项目说明。**短一点**：她是通读代码的人，
## 这里只交代"这是哪儿、从哪看起、改完要做什么"，不要写成开发规范
const SELF_BRIEF := """【这是你自己的项目】你是桌面宠物小蓝，源码就在当前工作目录里（Godot 4.7 / GDScript）。
从 scripts/desktop_pet.gd（主控：状态机 / 交互 / 聊天接线）看起，她的性格和说话方式在
scripts/pet_persona.gd，设置面板在 scripts/pet_settings.gd，README.md 里记着每个模块的来历和坑。
这个项目注释密度很高、且**注释只写"为什么"**（不写"这里加一"这种废话），改代码请保持。
改完请：更新 README 相关段落；跑 `godot --headless --path . --check-only --script <改过的文件>` 确认能解析。
【要你做的事】"""

var _panel: PanelContainer = null
var _font: Font = null
var _status: Label = null
var _workdir: LineEdit = null
var _self_up: CheckButton = null
var _allow_write: CheckButton = null
var _task: TextEdit = null
var _log: TextEdit = null
var _run_btn: Button = null
var _running := false


# ------------------------------------------------------------------ 搭建

func build(layer: CanvasLayer, font: Font) -> void:
	if layer == null:
		return
	_font = font
	_panel = PetUi.panel()
	_panel.name = "Workbench"
	_panel.visible = false
	# 和设置面板一样占满整窗：窗口只有 330x470，缩放档还会更小
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = MARGIN
	_panel.offset_top = MARGIN
	_panel.offset_right = -MARGIN
	_panel.offset_bottom = -MARGIN
	layer.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	_panel.add_child(vb)

	vb.add_child(PetUi.title("工作台", _font))
	# 状态单独一行。**别把它塞进"标题 + 弹簧"那一行**：hint() 带自动换行，
	# 而 HBox 里带弹簧时它会被压到只剩几像素宽 —— 实测那行字竖着排成一条，
	# 高度撑到一百多像素，把下面所有东西顶出窗口（截图才发现）
	_status = PetUi.hint("", _font)
	vb.add_child(_status)

	# ---- 干活的地方
	vb.add_child(PetUi.section("在哪儿干", _font))
	var row := PetUi.hbox(4)
	_workdir = PetUi.edit("工作目录（dsh 只能改这里的文件）", _font)
	_workdir.tooltip_text = "dsh 的 workspace 根目录：勾了「允许她改文件」时，它只能动这个目录里的东西"
	row.add_child(_workdir)
	var pick := PetUi.button("项目目录", _font)
	pick.tooltip_text = "填成她自己的项目目录（自我升级就用这个）"
	pick.pressed.connect(func() -> void:
		_workdir.text = project_dir()
		_save_cfg())
	row.add_child(pick)
	vb.add_child(row)

	_self_up = PetUi.check("自我升级（附上项目说明，并允许改文件）", false, _font)
	_self_up.tooltip_text = "勾上之后：任务前面会自动加一段“这是你自己的项目”的说明，" \
		+ "工作目录也强制指到项目目录。适合“给小蓝加个新功能”这种活"
	_self_up.toggled.connect(_on_self_up_toggled)
	vb.add_child(_self_up)

	_allow_write = PetUi.check("允许她改文件", false, _font)
	_allow_write.tooltip_text = "dsh 那边只放宽到 workspace-write —— 只能改工作目录里的文件，" \
		+ "改不到别处去。不勾就是只读（看代码、回答问题）"
	_allow_write.toggled.connect(func(_on: bool) -> void: _save_cfg())
	vb.add_child(_allow_write)

	# ---- 任务
	vb.add_child(PetUi.section("要她做什么", _font))
	_task = TextEdit.new()
	PetUi.apply_font(_task, _font)
	_task.add_theme_font_size_override("font_size", 12)
	_task.add_theme_color_override("font_color", PetUi.TEXT_MAIN)
	_task.add_theme_color_override("caret_color", PetUi.TEXT_MAIN)
	_task.add_theme_color_override("font_placeholder_color", PetUi.TEXT_SUB)
	_task.placeholder_text = "比如：给小蓝加一个“今天几号”的菜单项"
	_task.custom_minimum_size = Vector2(0, 58)
	_task.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	var tsb := PetUi.edit_style()
	_task.add_theme_stylebox_override("normal", tsb)
	_task.add_theme_stylebox_override("focus", tsb)
	vb.add_child(_task)

	var btns := PetUi.hbox(5)
	_run_btn = PetUi.button("派活", _font)
	_run_btn.tooltip_text = "交给本机的 DeepSeek Harness 去干。跑起来可能要几分钟（它在真的读代码、改文件）"
	_run_btn.pressed.connect(_on_run)
	btns.add_child(_run_btn)
	var clear := PetUi.button("清空", _font)
	clear.pressed.connect(func() -> void:
		_task.text = ""
		_log.text = "")
	btns.add_child(clear)
	btns.add_child(PetUi.spacer())
	btns.add_child(PetUi.label("推理档按任务自动挑", _font, 10, PetUi.TEXT_SUB))
	vb.add_child(btns)

	# ---- 结果（占满剩下的地方）
	vb.add_child(PetUi.section("结果", _font))
	_log = TextEdit.new()
	PetUi.apply_font(_log, _font)
	_log.add_theme_font_size_override("font_size", 11)
	_log.add_theme_color_override("font_color", PetUi.TEXT_MAIN)
	_log.editable = false
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 70)
	_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	var lsb := PetUi.edit_style()
	lsb.bg_color = Color(0.97, 0.97, 0.99, 0.98)
	_log.add_theme_stylebox_override("normal", lsb)
	_log.add_theme_stylebox_override("focus", lsb)
	vb.add_child(_log)

	# ---- 底部
	var foot := PetUi.hbox(5)
	var open_dir := PetUi.button("打开工作目录", _font)
	open_dir.tooltip_text = "在资源管理器里打开工作目录（看看她改了什么）"
	open_dir.pressed.connect(func() -> void: open_dir_requested.emit(_workdir.text.strip_edges()))
	foot.add_child(open_dir)
	var restart := PetUi.button("重启她（应用改动）", _font)
	restart.tooltip_text = "GDScript 是启动时加载的：改完代码要重启她才会生效"
	restart.pressed.connect(func() -> void: restart_requested.emit())
	foot.add_child(restart)
	foot.add_child(PetUi.spacer())
	# 注意别把局部变量叫 close：那会盖住本模块的 close() 方法，
	# 于是 connect(close) 传进去的是个 Button 而不是 Callable（编译期就报错）
	var close_btn := PetUi.button("关闭", _font)
	close_btn.pressed.connect(close)
	foot.add_child(close_btn)
	vb.add_child(foot)

	_load_cfg()

# ------------------------------------------------------------------ 开关

func open(status: String = "") -> void:
	if _panel == null:
		return
	_panel.visible = true
	set_status(status)

func close() -> void:
	if _panel == null or not _panel.visible:
		return
	_save_cfg()
	_panel.visible = false
	closed.emit()

func is_open() -> bool:
	return _panel != null and _panel.visible

func point_inside(pos: Vector2) -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(pos)

func set_status(text: String) -> void:
	if _status != null:
		_status.text = text

func is_running() -> bool:
	return _running

## 跑起来了：锁住"派活"按钮，把状态说清楚（她这一趟在哪儿跑、什么档、能不能改文件）
func set_running(on: bool, effort: String = "", workspace: String = "") -> void:
	_running = on
	if _run_btn != null:
		_run_btn.disabled = on
	if on:
		set_status("正在跑…（%s｜%s%s）" % [
			effort, "能改文件" if values()["allow_write"] else "只读",
			"" if workspace == "" else "｜" + workspace.get_file()])

## 跑完了：原文摆出来（成功给答案，失败给 stderr —— 那里面才有"为什么失败"）
func set_result(ok: bool, answer: String, stderr: String, secs: float) -> void:
	if _log == null:
		return
	var head := "✔ 用时 %.1f 秒\n" % secs if ok else "✘ 没跑成（用时 %.1f 秒）\n" % secs
	var body := answer
	if not ok and stderr != "":
		body = stderr
	_log.text = head + body
	set_status("上次：%s %.1f 秒" % ["成功" if ok else "失败", secs])

## 面板上的三样选择
func values() -> Dictionary:
	return {
		"workdir": _workdir.text.strip_edges() if _workdir != null else "",
		"self_upgrade": _self_up.button_pressed if _self_up != null else false,
		"allow_write": _allow_write.button_pressed if _allow_write != null else false,
	}

# ------------------------------------------------------------------ 内部

## 勾了"自我升级"就顺带勾上"允许改文件"并把工作目录指到项目目录 ——
## 这三个本来就是一件事的三种说法，让人分三次勾只是找麻烦
func _on_self_up_toggled(on: bool) -> void:
	if on:
		_allow_write.button_pressed = true
		if _workdir.text.strip_edges() == "":
			_workdir.text = project_dir()
	_save_cfg()

func _on_run() -> void:
	var task := _task.text.strip_edges()
	if task == "":
		set_status("先写点要她做的事")
		return
	if _running:
		return
	var v := values()
	var opts := v.duplicate()
	# 自我升级：附上项目说明，而且**工作目录必须在项目里**，不然她改的是别的项目
	if bool(v["self_upgrade"]):
		opts["workdir"] = project_dir()
		task = SELF_BRIEF + "\n" + task
	opts["task"] = task
	run_requested.emit(task, opts)

# ------------------------------------------------------------------ 工作目录怎么猜

## 她自己的项目目录。
## 三档猜法（从准到不准）：
##   1. `res://` 下真的有 project.godot —— 编辑器里跑、或者从源码跑，这就对了；
##   2. exe **旁边**哪个子目录里有 project.godot（导出版用 junction 指回源码的情况，
##      实测 `dist/pet.exe` 旁边就是 `pet/`）；
##   3. 实在找不到就用 exe 所在目录 —— 至少不是空的。
## 猜错也不致命：工作台里能手动改，改完就记住了
static func project_dir() -> String:
	var res := ProjectSettings.globalize_path("res://")
	if FileAccess.file_exists(res.path_join("project.godot")):
		return res.trim_suffix("/")
	var exe_dir := OS.get_executable_path().get_base_dir()
	var below := find_project_below(exe_dir)
	return below if below != "" else exe_dir

## 在 dir 的**子目录**里找哪个有 project.godot，找不到返回空串。
## 单独一个函数是为了能真测到它 —— 编辑器里跑时 project_dir() 永远走第一档，
## 第二档（导出版那条）根本没有机会被执行
static func find_project_below(dir: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir() and FileAccess.file_exists(
				dir.path_join(name).path_join("project.godot")):
			d.list_dir_end()
			return dir.path_join(name)
		name = d.get_next()
	d.list_dir_end()
	return ""

func _save_cfg() -> void:
	var v := values()
	var cfg := ConfigFile.new()
	cfg.set_value("workbench", "workdir", String(v["workdir"]))
	cfg.set_value("workbench", "self_upgrade", bool(v["self_upgrade"]))
	cfg.set_value("workbench", "allow_write", bool(v["allow_write"]))
	cfg.save(CFG)

func _load_cfg() -> void:
	var v := {"workdir": project_dir(), "self_upgrade": false, "allow_write": false}
	var cfg := ConfigFile.new()
	if cfg.load(CFG) == OK:
		v["workdir"] = String(cfg.get_value("workbench", "workdir", v["workdir"]))
		v["self_upgrade"] = bool(cfg.get_value("workbench", "self_upgrade", false))
		v["allow_write"] = bool(cfg.get_value("workbench", "allow_write", false))
	if _workdir != null:
		_workdir.text = String(v["workdir"])
	if _self_up != null:
		# 先断开信号再设值：不然 _on_self_up_toggled 会在加载时又去改别的控件
		_self_up.set_pressed_no_signal(bool(v["self_upgrade"]))
	if _allow_write != null:
		_allow_write.set_pressed_no_signal(bool(v["allow_write"]))
