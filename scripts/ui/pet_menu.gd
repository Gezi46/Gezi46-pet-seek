# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 桌宠的右键菜单：按功能分类的多级菜单 + AI 服务设置面板
##
## 为什么改成运行时搭：
##   原来菜单写在 pet.tscn 里（item_N 和 id 一一对应），条目一多就既没法分组、
##   也没法加子菜单。现在整棵菜单在这里生成 —— 分类就是子菜单，加功能只动这一个文件，
##   场景里只留一个空的 PopupMenu 节点。
##
## 分工：
##   本模块只管「菜单长什么样」：分组、条目、勾选状态、AI 设置面板；
##   点了之后**干什么**仍然由主脚本的 _on_menu_id(id) 决定（通过 action 信号转过去）。
##
## 用法：
##   var menu := PetMenu.new()
##   menu.setup($UI, $UI/Menu, _cjk_font)
##   menu.action.connect(_on_menu_id)
##   menu.ai_saved.connect(_on_ai_settings_saved)

extends RefCounted

## 某个功能被点了。id 沿用主脚本原来的编号，新增的往后排
signal action(id: int)
## AI 设置面板点了保存（url / key / model）
signal ai_saved(settings: Dictionary)
## AI 设置面板关掉了（主脚本要把键盘焦点还回去）
signal ai_panel_closed()

## 面板零件的出处（卡片 / 标签 / 输入框都从这儿来，和设置面板共用一套长相）
const PetUi := preload("res://scripts/ui/pet_ui.gd")

# ------------------------------------------------------------------ 动作 id
# 下面这些必须和主脚本 _on_menu_id 的分支一一对应

const ID_PET := 0
const ID_FEED := 1
const ID_SLEEP := 2
const ID_JUMP := 3
const ID_SCALE_75 := 4
const ID_SCALE_100 := 5
const ID_SCALE_135 := 6
const ID_TOGGLE_TOP := 7
const ID_TALK_LOCAL := 8
const ID_HOME_HERE := 9
const ID_HOME_DEFAULT := 10
const ID_QUIT := 11
const ID_CHAT := 12
const ID_ASK := 13
const ID_PEEK_NOW := 14
const ID_CAMERA_NOW := 15
const ID_PROACTIVE := 16
const ID_PEEK := 17
const ID_CAMERA := 18
## 打开 AI 服务设置（后端地址 / 密钥 / 模型）
const ID_AI_SETTINGS := 19
## 立刻重新探一次 AI 服务（改完地址、或服务刚起来时用）
const ID_AI_RECONNECT := 20
## 开机自启动（Windows 注册表 Run 项，见 scripts/pet_shell.gd）
const ID_AUTOSTART := 21
## 隐藏任务栏图标（不进任务栏 / Alt+Tab）
const ID_HIDE_TASKBAR := 22
## 全屏时保持安静（检测到全屏就只在小范围里挪动）
const ID_QUIET_FULLSCREEN := 23
## 托盘图标（任务栏右下角"隐藏的图标"里那一个）
const ID_TRAY := 24
## 主动说话的频率。四档单选，对应 pet_proactive.gd 里 rate 的下标
## （宿主从 `_proactive.rate` 取当前档）
const ID_TALK_SELDOM := 25
const ID_TALK_NORMAL := 26
const ID_TALK_OFTEN := 27
const ID_TALK_VERY_OFTEN := 28
## 打开设置面板（人设 / 记忆 / 说话 / 窗口 / 系统，见 scripts/pet_settings.gd）
const ID_SETTINGS := 29
## 让她用本机 dsh（DeepSeek Harness）干活：开关 / 派活（见 scripts/pet_harness.gd）
const ID_HARNESS := 30
const ID_HARNESS_TASK := 31
## 打开工作台（派活 / 看原文 / 重启她，见 scripts/pet_workbench.gd）
const ID_WORKBENCH := 32
## 「只在小范围走动」——「位置与窗口」里的勾选项，和设置面板同一个键
const ID_STAY_NEARBY := 33
## 主动说话时先瞥一眼屏幕（2026-09-27 用户要求：绑定 + 概率性 + 默认开）
const ID_PROACTIVE_PEEK := 34
## 哄哄她：她"连着被冷落 4 次、生气不主动说话"时用它回来（2026-09-27 用户要求）
const ID_SOOTHE := 35
## 高峰时段少说话：晚上 AI 高峰时把主动开口间隔 ×5（2026-09-29 用户要求）
const ID_PEAK_REDUCE := 36
## 透明模式（点不到我）：整窗不接鼠标，点不到她、也不挡后面的窗口（2026-09-30 用户要求）
const ID_GHOST := 37
## 回复按钮的出现频率。四档单选，对应 quick_chance 的值（见 desktop_pet._set_quick_chance）
const ID_QUICK_NEVER := 38
const ID_QUICK_RARE := 39
const ID_QUICK_HALF := 40
const ID_QUICK_OFTEN := 41
## 移动频率。四档单选，对应 move_chance 的值（见 desktop_pet._set_move_chance）
const ID_MOVE_NEVER := 42
const ID_MOVE_RARE := 43
const ID_MOVE_SOME := 44
const ID_MOVE_OFTEN := 45
## 自启动状态那一行：只用来显示，点了什么也不做。
## 给个大编号躲开真实动作的号段 —— 万一哪天漏了拦截，也不会误触发别的功能
const ID_AUTOSTART_STATUS := 900
## AI 服务状态那一行（连着没连着）。离线时她进"假死"，这行就是让人看出"她为什么这么安静"
const ID_AI_STATUS := 901

## 服务来源预设：选一下就把地址和两个模型填好，省得手抄。
## 两个都是 OpenAI 兼容协议，桌宠只换地址/密钥/模型名。
const PROVIDERS: Array = [
	{
		"name": "官方 API（付费 key）",
		"url": "https://api.deepseek.com",
		"model": "deepseek-flash",
		"vision": "deepseek-v4-flash-vision-exp",
	},
	{
		"name": "本地网页版（deepseek-web-api）",
		"url": "http://127.0.0.1:8520/v1",
		"model": "deepseek-chat",
		"vision": "",
	},
]

var _menu: PopupMenu = null
var _font: Font = null
## 勾选项 id -> 它所在的子菜单（找回去才能改勾选状态）
var _check_owner: Dictionary = {}
## 状态行的 id -> [菜单, 下标]。要反复改文本，所以把位置记下来（见 _status_row）
var _status_rows: Dictionary = {}

# AI 设置面板
var _panel: PanelContainer = null
var _provider_btn: OptionButton = null
var _url_edit: LineEdit = null
var _key_edit: LineEdit = null
var _model_edit: LineEdit = null
var _vision_edit: LineEdit = null
var _status: Label = null
var _settings: Dictionary = {
	"url": "", "key": "", "model": "", "vision_url": "", "vision_model": "",
}

# ------------------------------------------------------------------ 搭建

func setup(ui_layer: CanvasLayer, menu: PopupMenu, font: Font) -> void:
	_menu = menu
	_font = font
	# 根菜单也要连！子菜单是 _submenu() 里各自连的，而根菜单上的条目
	# （「设置…」「退出」）走的是它自己这条信号 —— 漏了这一步，点「退出」什么都不会
	# 发生，而且界面上完全看不出问题：菜单正常弹、条目正常高亮，就是点了没反应。
	if not _menu.id_pressed.is_connected(_on_item):
		_menu.id_pressed.connect(_on_item)
	_build_menu()
	_build_ai_panel(ui_layer)

## 菜单条目被点了：统一转成 action 信号，由主脚本决定干什么
func _on_item(id: int) -> void:
	action.emit(id)

## 整棵菜单：一级就是分类。改了分组只动这里
func _build_menu() -> void:
	# 场景里那套 item_N 是旧版写死的菜单，这里整棵重建 —— clear() 掉它
	_menu.clear()
	_apply_menu_font(_menu)

	var play := _submenu("互动")
	_item(play, "摸摸头", ID_PET)
	_item(play, "喂点东西", ID_FEED)
	_item(play, "睡觉 / 起床", ID_SLEEP)
	_item(play, "跳一下", ID_JUMP)
	_item(play, "说点什么", ID_TALK_LOCAL)
	_item(play, "哄哄她", ID_SOOTHE)
	_menu.add_submenu_node_item("互动", play)

	var where := _submenu("位置与窗口")
	_item(where, "记住当前位置", ID_HOME_HERE)
	_item(where, "回到右下角", ID_HOME_DEFAULT)
	_toggle(where, "只在小范围走动", ID_STAY_NEARBY,
		"开着她只在家附近那一小块里转，不再满屏溜达。范围大小在设置面板里调")
	var mrate := _submenu_of(where, "移动频率")
	_radio(mrate, "从不（一直待着）", ID_MOVE_NEVER)
	_radio(mrate, "很少", ID_MOVE_RARE)
	_radio(mrate, "偶尔", ID_MOVE_SOME)
	_radio(mrate, "经常", ID_MOVE_OFTEN)
	where.add_submenu_node_item("移动频率", mrate)
	where.add_separator()
	_item(where, "窗口置顶", ID_TOGGLE_TOP)
	_toggle(where, "透明模式（点不到我）", ID_GHOST,
		"整窗不再接鼠标：点不到她、也不挡她后面的窗口；托盘图标里也能切回来")
	where.add_separator()
	_item(where, "小 (75%)", ID_SCALE_75)
	_item(where, "中 (100%)", ID_SCALE_100)
	_item(where, "大 (135%)", ID_SCALE_135)
	_menu.add_submenu_node_item("位置与窗口", where)

	var ai := _submenu("聊天与 AI")
	_item(ai, "打开聊天框", ID_CHAT)
	_item(ai, "让她想个话题", ID_ASK)
	ai.add_separator()
	_item(ai, "偷看屏幕看看", ID_PEEK_NOW)
	_item(ai, "看一眼摄像头", ID_CAMERA_NOW)
	ai.add_separator()
	_toggle(ai, "主动说话", ID_PROACTIVE, "闲下来会自己找话题")
	var rate := _submenu_of(ai, "主动说话的频率")
	_radio(rate, "很少（十几分钟一次）", ID_TALK_SELDOM)
	_radio(rate, "普通（5~15 分钟）", ID_TALK_NORMAL)
	_radio(rate, "频繁（2~5 分钟）", ID_TALK_OFTEN)
	_radio(rate, "很频繁（半分钟左右）", ID_TALK_VERY_OFTEN)
	ai.add_submenu_node_item("主动说话的频率", rate)
	var quickc := _submenu_of(ai, "回复按钮出现频率")
	_radio(quickc, "从不", ID_QUICK_NEVER)
	_radio(quickc, "偶尔（约 1/4）", ID_QUICK_RARE)
	_radio(quickc, "一半（约 1/2）", ID_QUICK_HALF)
	_radio(quickc, "经常（约 3/4）", ID_QUICK_OFTEN)
	ai.add_submenu_node_item("回复按钮出现频率", quickc)
	_toggle(ai, "高峰时段少说话", ID_PEAK_REDUCE,
		"DeepSeek 官方高峰（工作日 9~12 点、14~18 点）把主动开口间隔拉长 5 倍 —— 少撞限流")
	_toggle(ai, "定时偷看屏幕", ID_PEEK, "按间隔看一眼屏幕并说一句")
	_toggle(ai, "主动说话时先看一眼屏幕", ID_PROACTIVE_PEEK,
		"按概率先抓一张屏幕，她就着画面（和前台窗口）找话题 —— 默认开")
	_toggle(ai, "定时看摄像头", ID_CAMERA, "接入摄像头那条链路")
	ai.add_separator()
	# 本机 dsh（DeepSeek Harness）：让她把简单活派出去干
	_toggle(ai, "让她用 dsh 干活", ID_HARNESS,
		"把简单的活交给本机的 DeepSeek Harness；推理档按任务大小自动挑（off / low / high / max）")
	_item(ai, "给她派个活…", ID_HARNESS_TASK, "打开聊天框，写「干活：要她做的事」")
	ai.add_separator()
	# 这一行是状态：连着 = 正常；连不上 = 她进"假死"（只剩基础功能）
	_status_row(ai, ID_AI_STATUS, "AI 服务：…")
	_item(ai, "AI 服务设置…", ID_AI_SETTINGS)
	_item(ai, "重新连接 AI 服务", ID_AI_RECONNECT)
	_menu.add_submenu_node_item("聊天与 AI", ai)

	var sys := _submenu("开机与系统")
	_toggle(sys, "开机自启动", ID_AUTOSTART, "登录 Windows 后自动启动桌宠（写用户级注册表，随时可关）")
	_toggle(sys, "隐藏任务栏图标", ID_HIDE_TASKBAR, "不在任务栏和 Alt+Tab 里出现，桌面上照常显示")
	_toggle(sys, "全屏时保持安静", ID_QUIET_FULLSCREEN,
		"检测到全屏（看视频/玩游戏）就只在家的附近小范围挪动；关掉则不再留后台检测进程")
	_toggle(sys, "托盘图标", ID_TRAY, "任务栏右下角「隐藏的图标」里放一个，右键能显示/隐藏她或退出")
	sys.add_separator()
	_status_row(sys, ID_AUTOSTART_STATUS, "自启动：…")
	_menu.add_submenu_node_item("开机与系统", sys)

	_menu.add_separator()
	# 工作台放一级：它是"给她派活、看她改了什么"的地方，主要用来让她给自己升级
	_item(_menu, "工作台…", ID_WORKBENCH, "把活交给本机的 dsh 干：任务、工作目录、结果原文、" \
		+ "干完一键重启她")
	_item(_menu, "设置…", ID_SETTINGS)
	_item(_menu, "退出", ID_QUIT)

## 每个子菜单单独连一次 id_pressed —— 点了子项也要转成 action
func _submenu(title: String) -> PopupMenu:
	var m := PopupMenu.new()
	m.name = "Sub" + title
	_apply_menu_font(m)
	m.id_pressed.connect(_on_item)
	# 弹出时优先挪到父菜单左侧（见 _mirror_submenu）
	m.about_to_popup.connect(_mirror_submenu.bind(m))
	_menu.add_child(m)
	return m

## 子菜单弹出时，**优先把它挪到父菜单左侧**（2026-10-03 用户要求"子菜单优先向左侧展示"）。
##
## 为什么不改引擎的方向：PopupMenu 的方向由内部的 is_layout_rtl() 决定（LTR 默认向右，
## 只有右侧放不下才镜像到左）。而那个值在 Godot 4.7 里只能靠项目设置
## `internationalization/rendering/root_node_layout_direction` —— **实测设成 3（RTL）也不生效**
## （Label / PopupMenu 的 is_layout_rtl() 都还是 false），何况它一旦生效会把整个 UI
## 的左右都镜像一遍。所以改成弹出时自己摆位置：只动菜单，别的都不碰。
##
## 左边放不下（会跑出屏幕）就原样不动，让引擎按老规矩往右开。
##
## 时机讲究：引擎是在 `popup()` 内部、**发完 about_to_popup 之后**才把位置写上的 ——
## 实测直接在信号里改会被随后的覆盖掉（子菜单照旧停在父菜单右边）。所以延到本帧末再挪。
func _mirror_submenu(sub: PopupMenu) -> void:
	_move_submenu_left.call_deferred(sub)

func _move_submenu_left(sub: PopupMenu) -> void:
	if not sub.visible:
		return
	var parent_menu := sub.get_parent() as PopupMenu
	if parent_menu == null:
		return
	var target_x: int = parent_menu.position.x - sub.size.x
	var scr := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	if target_x < scr.position.x:
		return
	sub.position = Vector2i(target_x, sub.position.y)

## 嵌在别的子菜单里的子菜单。
## **不能用 _submenu()** —— 它会把新菜单挂到根 _menu 上，再想让上层当爹就会报
## "The submenu ... already has a different parent"（add_submenu_node_item 不会帮你换爹）。
## 这个错误在冒烟测试里才现形：菜单照样弹得出来，只是那一条不生效。
func _submenu_of(parent: PopupMenu, title: String) -> PopupMenu:
	var m := PopupMenu.new()
	m.name = "Sub" + title
	_apply_menu_font(m)
	m.id_pressed.connect(_on_item)
	# 嵌套的这几层同样优先往左（见 _mirror_submenu）
	m.about_to_popup.connect(_mirror_submenu.bind(m))
	parent.add_child(m)
	return m

func _item(m: PopupMenu, label: String, id: int, tip: String = "") -> void:
	m.add_item(label, id)
	if tip != "":
		var idx := m.get_item_index(id)
		if idx >= 0:
			m.set_item_tooltip(idx, tip)

func _toggle(m: PopupMenu, label: String, id: int, tip: String = "") -> void:
	_item(m, label, id, tip)
	var idx := m.get_item_index(id)
	if idx >= 0:
		# 注意方法名是 set_item_as_checkable（不是 set_item_checkable，
		# 那个名字在 Godot 4 里没有），读回来的是 is_item_checkable
		m.set_item_as_checkable(idx, true)
	_check_owner[id] = m

## 单选条目。PopupMenu 没有"单选组"这种东西，所以勾选状态得自己保证
## 同时只有一个（见 sync_talk_rate），这里只负责把它做成可勾的
func _radio(m: PopupMenu, label: String, id: int) -> void:
	_toggle(m, label, id)

## 主动说话的频率是四选一。PopupMenu 没有单选组，所以这里手动把
## 其余三个取消掉 —— 不然会出现"两个档同时打着勾"
func sync_talk_rate(idx: int) -> void:
	_set_checked(ID_TALK_SELDOM, idx == 0)
	_set_checked(ID_TALK_NORMAL, idx == 1)
	_set_checked(ID_TALK_OFTEN, idx == 2)
	_set_checked(ID_TALK_VERY_OFTEN, idx == 3)

## 回复按钮出现频率也是四选一（照 sync_talk_rate 的模式）
func sync_quick_chance(idx: int) -> void:
	_set_checked(ID_QUICK_NEVER, idx == 0)
	_set_checked(ID_QUICK_RARE, idx == 1)
	_set_checked(ID_QUICK_HALF, idx == 2)
	_set_checked(ID_QUICK_OFTEN, idx == 3)

## 移动频率也是四选一（照 sync_talk_rate 的模式）
func sync_move_chance(idx: int) -> void:
	_set_checked(ID_MOVE_NEVER, idx == 0)
	_set_checked(ID_MOVE_RARE, idx == 1)
	_set_checked(ID_MOVE_SOME, idx == 2)
	_set_checked(ID_MOVE_OFTEN, idx == 3)

## "让她用 dsh 干活"那个勾
func sync_harness(on: bool) -> void:
	_set_checked(ID_HARNESS, on)

## 一行纯显示的状态文字（灰色、点不动）。自启动和 AI 服务各用一行。
## 单独一个函数是因为它的下标记下来之后要反复改文本。
##
## 名字别叫 _status —— 本模块里 `_status` 已经是 AI 面板那个 Label 了，
## 同名会让整个脚本解析失败（报的是 "Could not preload"，不指出重名，很难猜）。
func _status_row(m: PopupMenu, id: int, text: String = "") -> void:
	m.add_item(text, id)
	var idx := m.get_item_index(id)
	if idx >= 0:
		m.set_item_disabled(idx, true)
		_status_rows[id] = [m, idx]

func _set_status_row(id: int, text: String) -> void:
	var row: Array = _status_rows.get(id, [])
	if row.is_empty():
		return
	(row[0] as PopupMenu).set_item_text(int(row[1]), text)

## AI 服务那行。**离线时她会进"假死"**（主动说话 / 生闷气 / 偷看 / 记忆抽取全停，
## 只留基础功能），这行就是让人一眼看出"她为什么这么安静"
func set_ai_status(text: String) -> void:
	_set_status_row(ID_AI_STATUS, "AI 服务：%s" % text)

## 给 Control 套中文字体这一步挪去了 pet_ui.gd（和设置面板共用一套）。
## 注意 PopupMenu **不是 Control**（它是 Popup → Window），走不了那条路 ——
## 菜单得用下面的 _apply_menu_font，类型写错会直接编译失败。

## 菜单得用 Theme 挂字体：PopupMenu 是 Window，没有 add_theme_font_override，
## 但它有 theme 属性，给 "PopupMenu" 类型设上 font 即可。
## （项目里没配全局中文字体，不挂的话菜单项的中文会掉字。）
func _apply_menu_font(m: PopupMenu) -> void:
	if _font == null:
		return
	var th := Theme.new()
	th.set_font("font", "PopupMenu", _font)
	m.theme = th
	if OS.is_debug_build():
		print("[菜单] %s 字体已挂：%s" % [
			m.name, m.theme != null and m.theme.has_font("font", "PopupMenu")])

# ------------------------------------------------------------------ 勾选同步

## PopupMenu 的勾选状态是它自己存的，和我们的运行时开关是两套东西，
## 所以每次改完都要同步一次 —— 否则菜单里显示的和实际生效的会对不上
## （尤其是从配置文件读出来之后）。
func sync_toggles(proactive: bool, peek: bool, camera: bool, proactive_peek: bool) -> void:
	_set_checked(ID_PROACTIVE, proactive)
	_set_checked(ID_PEEK, peek)
	_set_checked(ID_CAMERA, camera)
	_set_checked(ID_PROACTIVE_PEEK, proactive_peek)

## 「高峰时段少说话」的勾选同步（和主动说话那几个并列）
func sync_peak_reduce(on: bool) -> void:
	_set_checked(ID_PEAK_REDUCE, on)

## 「透明模式」的勾选同步
func sync_ghost(on: bool) -> void:
	_set_checked(ID_GHOST, on)

## 「只在小范围走动」的勾选同步（它不属于上面任何一组，单独一个）
func sync_stay_nearby(on: bool) -> void:
	_set_checked(ID_STAY_NEARBY, on)

## "开机与系统"那几个开关的勾选同步
func sync_system(autostart: bool, hide_taskbar: bool, quiet: bool, tray: bool) -> void:
	_set_checked(ID_AUTOSTART, autostart)
	_set_checked(ID_HIDE_TASKBAR, hide_taskbar)
	_set_checked(ID_QUIET_FULLSCREEN, quiet)
	_set_checked(ID_TRAY, tray)

## 更新自启动状态那一行。内容由 pet_shell.gd 给（它知道注册表的真实情况）
func set_autostart_status(text: String) -> void:
	_set_status_row(ID_AUTOSTART_STATUS, "自启动：%s" % text)

func _set_checked(id: int, on: bool) -> void:
	var m: PopupMenu = _check_owner.get(id, null)
	if m == null:
		return
	var idx := m.get_item_index(id)
	if idx >= 0:
		m.set_item_checked(idx, on)

# ------------------------------------------------------------------ AI 设置面板

## 面板挂在 UI 这个 CanvasLayer 底下（和聊天框一个套路），
## 不用独立窗口：项目里 embed_subwindows=false，弹独立窗会变成另一个 OS 窗口，
## 而桌宠平时是 no_focus 的，键盘焦点会很难处理。
func _build_ai_panel(layer: CanvasLayer) -> void:
	if layer == null:
		return
	_panel = PetUi.panel()
	_panel.name = "AiSettings"
	_panel.visible = false
	# 居中的小卡片：这个面板只有五格，不需要占满整窗（设置面板才需要）
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(300, 0)
	layer.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	_panel.add_child(vb)

	vb.add_child(PetUi.label("AI 服务", _font, 13, PetUi.TEXT_MAIN))
	# 来源下拉只是个"填表助手"：选完把地址和两个模型填进去，之后还能手改
	_provider_btn = OptionButton.new()
	PetUi.apply_font(_provider_btn, _font)
	for p in PROVIDERS:
		_provider_btn.add_item(String(p["name"]))
	_provider_btn.item_selected.connect(_on_provider_picked)
	vb.add_child(_provider_btn)

	vb.add_child(PetUi.label("后端地址", _font, 11, PetUi.TEXT_SUB))
	_url_edit = PetUi.edit("https://api.deepseek.com 或 http://127.0.0.1:8520/v1", _font)
	vb.add_child(_url_edit)

	vb.add_child(PetUi.label("访问密钥", _font, 11, PetUi.TEXT_SUB))
	_key_edit = PetUi.edit("官方 API 填 sk- 开头的 key；本地网页版填管理页第 ② 栏那串", _font)
	vb.add_child(_key_edit)

	vb.add_child(PetUi.label("文本模型（聊天用）", _font, 11, PetUi.TEXT_SUB))
	_model_edit = PetUi.edit("deepseek-flash", _font)
	vb.add_child(_model_edit)

	vb.add_child(PetUi.label("视觉模型（偷看屏幕 / 看摄像头用）", _font, 11, PetUi.TEXT_SUB))
	_vision_edit = PetUi.edit("deepseek-v4-flash-vision-exp（留空 = 关掉看图）", _font)
	vb.add_child(_vision_edit)

	_status = PetUi.label("", _font, 11, PetUi.TEXT_WARN)
	vb.add_child(_status)

	var row := PetUi.hbox(6)
	row.alignment = BoxContainer.ALIGNMENT_END
	var cancel := PetUi.button("取消", _font)
	cancel.pressed.connect(func() -> void: close_ai_panel())
	row.add_child(cancel)
	var save := PetUi.button("保存", _font)
	save.pressed.connect(_on_save)
	row.add_child(save)
	vb.add_child(row)

func ai_settings() -> Dictionary:
	return _settings.duplicate()

func set_ai_settings(d: Dictionary) -> void:
	_settings = {
		"url": String(d.get("url", "")),
		"key": String(d.get("key", "")),
		"model": String(d.get("model", "")),
		"vision_url": String(d.get("vision_url", "")),
		"vision_model": String(d.get("vision_model", "")),
	}

## 选来源 = 把地址和两个模型填进表单（不落盘，要按保存才行）
func _on_provider_picked(idx: int) -> void:
	if idx < 0 or idx >= PROVIDERS.size():
		return
	var p: Dictionary = PROVIDERS[idx]
	_url_edit.text = String(p["url"])
	_model_edit.text = String(p["model"])
	_vision_edit.text = String(p["vision"])

## 面板打开时填当前值。status 用来把"连不上/令牌过期"这类原因直接写给人看
func open_ai_panel(status: String = "") -> void:
	if _panel == null:
		return
	_url_edit.text = String(_settings.get("url", ""))
	_key_edit.text = String(_settings.get("key", ""))
	_model_edit.text = String(_settings.get("model", ""))
	_vision_edit.text = String(_settings.get("vision_model", ""))
	# 来源下拉只是助手：按地址反推当前选的是哪个，认不出来就不选
	var sel := -1
	for i in PROVIDERS.size():
		if String(PROVIDERS[i]["url"]) == String(_settings.get("url", "")):
			sel = i
			break
	_provider_btn.selected = sel
	_status.text = status
	_panel.visible = true
	_url_edit.grab_focus()

func close_ai_panel() -> void:
	if _panel == null or not _panel.visible:
		return
	_panel.visible = false
	ai_panel_closed.emit()

func ai_panel_visible() -> bool:
	return _panel != null and _panel.visible

func point_in_ai_panel(pos: Vector2) -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(pos)

func _on_save() -> void:
	var url := _url_edit.text.strip_edges()
	_settings = {
		"url": url,
		"key": _key_edit.text.strip_edges(),
		"model": _model_edit.text.strip_edges(),
		# 视觉默认跟文本同一个服务地址：官方 API 一个 key 同时能调两个模型
		"vision_url": url,
		"vision_model": _vision_edit.text.strip_edges(),
	}
	close_ai_panel()
	ai_saved.emit(_settings.duplicate())
