# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 设置面板：所有"平时会想改一下"的开关和数字都在这里。
##
## 为什么单独做一个面板，而不是继续往右键菜单里塞：
##   菜单适合"开关"和"动作"，不适合填名字、敲数字、看说明。设置一多，菜单会变成
##   三四层嵌套，找一样东西要点三下 —— 而且菜单里根本没法输入文本。
##
## 结构上是**表驱动**的：SECTIONS 这张表描述了全部可调项，界面按它生成，
## sanitize() 也按它做范围钳制。加一项设置只改这张表 + 主脚本里的应用那一步。
##
## 分工（别越界）：
##   本模块只管"显示 / 收集 / 钳制"；
##   值怎么落地、怎么立刻生效，全由主脚本决定（desktop_pet.gd 的 _apply_settings）。
##   所以这里既不碰记忆文件，也不碰窗口和注册表。
##
## 危险动作不做弹窗确认：项目里 embed_subwindows=false，弹窗会变成**另一个 OS 窗口**，
## 而桌宠平时是 no_focus 的，那种窗口很难收场。改成"同一个按钮点两下"。

## 点保存了。values 已经过 sanitize（类型和范围都对得上）
signal saved(values: Dictionary)
## 面板关掉了（取消 / 保存 / ESC 都会走这里，主脚本要把键盘焦点还回去）
signal closed()
## 面板里的按钮被按了（清空记忆 / 打开 AI 设置…）。名字见 SECTIONS 里的 cmd
signal command(name: String)

## 面板零件的出处（卡片 / 标签 / 输入框都从这儿来，两个面板共用一套长相）
const PetUi := preload("res://scripts/ui/pet_ui.gd")
## 点第二下确认的时限（毫秒）
const CONFIRM_MS := 5000
## 面板占窗口的边距（像素）。留一点边，不然卡片边框会贴着窗口边缘被裁掉
const MARGIN := 4.0

## ------------------------------------------------------------------ 设置表
##
## 这张表就是"有哪些设置"的唯一出处。
##   k     键名。主脚本按它认值，所以**不能随便改**（改了等于老存档读不出来）
##   t     控件类型：check / text / int / float / choice / button / note
##   label 面板上显示的名字
##   hint  鼠标停上去的说明（不占版面，设置项多，一行说明就是一行高度）
##   min/max/step  int、float 用
##   options/vals  choice 用：显示 options 里的第几项，就取 vals 里的第几个值
##   ph            text 用：输入框里的占位文字（要短，长了会被截）
##   confirm       button 用：true = 需要点两下
##
## 键名和主脚本 SETTING_VARS 那张表必须对得上（那边是"键 → 检查器变量"）。
const SECTIONS: Array = [
	{
		"title": "她这个人",
		"items": [
			{"k": "persona_name", "t": "text", "label": "名字", "ph": "比如：小蓝",
				"hint": "写进人设提示词。换名字改这里就行，不用动 pet_persona.gd"},
			{"k": "persona_extra", "t": "text", "label": "额外要求", "ph": "留空 = 不加要求",
				"hint": "追加在人设后面。比如“说话再短一点”“别用颜文字”"},
			{"k": "memory_enabled", "t": "check", "label": "长期记忆",
				"hint": "关掉 = 她每次都像第一次见你（文件还在，只是不读不写）"},
			{"k": "memory_ai_extract", "t": "check", "label": "让她用模型抽记忆",
				"hint": "会多一次非流式请求（很便宜但确实在花钱）。关掉只影响自动抽取，本地规则照常"},
			{"k": "memory_ai_every_sec", "t": "float", "label": "抽取间隔（秒）",
				"min": 5.0, "max": 300.0, "step": 5.0,
				"hint": "两次 AI 抽取之间至少隔这么久，防止连发几句就连着调模型"},
			{"k": "memory_summary_every", "t": "int", "label": "每几轮更新工作记忆",
				"min": 1.0, "max": 50.0, "step": 1.0,
				"hint": "工作记忆 = 整体了解 + 还没聊完的话题 + 你最近的心情"},
			{"k": "memory_observe", "t": "check", "label": "记她主动说的话",
				"hint": "主动搭话 / 偷看屏幕时说的内容也选择性记进来。关掉只记打字聊的"},
			{"k": "cmd_clear_memory", "t": "button", "label": "清空长期记忆",
				"confirm": true, "hint": "档案卡 + 工作记忆 + 所有记忆条目一起清掉，不能撤销"},
			{"k": "cmd_memory_folder", "t": "button", "label": "打开记忆文件所在文件夹",
				"hint": "想看看她到底记了些什么，直接打开那个文件夹里的 pet_memory.json"},
		],
	},
	{
		"title": "说话",
		"items": [
			{"k": "proactive_on", "t": "check", "label": "主动说话",
				"hint": "她主动开口的总闸。关掉之后既不自己找话题，也不生闷气"},
			{"k": "talk_rate", "t": "choice", "label": "主动说话的频率",
				"options": ["很少（十几分钟一次）", "普通（5~15 分钟）", "频繁（2~5 分钟）", "很频繁（半分钟左右）"],
				"hint": "没人理她的时候，隔多久自己开口一次"},
			{"k": "self_talk_enabled", "t": "check", "label": "闲了就自己开口",
				"hint": "本地计时触发，不依赖后端推送"},
			{"k": "chat_log_lines", "t": "int", "label": "聊天框显示几行（记录可上下翻）",
				"min": 1.0, "max": 8.0, "step": 1.0,
				"hint": "输入框上面那块历史，只影响显示"},
			{"k": "quick_enabled", "t": "check", "label": "快速回答按钮",
				"hint": "她说完话后，气泡下面给几个“主人可能接着说”的按钮。点一下就等于你说了那句"},
			{"k": "quick_ai", "t": "check", "label": "按钮用 AI 现编",
				"hint": "让模型照她刚说的话现编三句（多一次很小的请求）。"
					+ "关掉只用本地那几组，秒出但翻来覆去就那几句"},
			{"k": "quick_model", "t": "text", "label": "按钮用哪个模型", "ph": "留空 = 跟聊天同一个",
				"hint": "这条要模型“先想一大段再回答”，用会思考的模型经常二十几秒才回来、"
					+ "回来时按钮已经收了 —— 换个快的（比如 deepseek-chat）才用得上"},
			{"k": "quick_chance", "t": "float", "label": "她主动开口时出现概率",
				"min": 0.0, "max": 1.0, "step": 0.05,
				"hint": "0 = 从不，1 = 每次都有。留一点随机才像随手递过来的话"},
			{"k": "quick_chance_chat", "t": "float", "label": "聊天时出现概率",
				"min": 0.0, "max": 1.0, "step": 0.05,
				"hint": "聊天也概率给一次。别给太高 —— 你正打字时按钮反而碍事"},
			{"k": "peek_on", "t": "check", "label": "定时偷看屏幕",
				"hint": "按间隔截一张屏发给视觉模型看一眼。**截图会发给模型服务商**"},
			{"k": "peek_every_min", "t": "float", "label": "偷看间隔（分钟）",
				"min": 1.0, "max": 60.0, "step": 0.5},
			{"k": "camera_on", "t": "check", "label": "定时看摄像头",
				"hint": "走 Godot 自带的 CameraServer 抓一张，不依赖外部程序"},
			{"k": "camera_every_min", "t": "float", "label": "看摄像头间隔（分钟）",
				"min": 1.0, "max": 60.0, "step": 0.5},
		],
	},
	{
		"title": "窗口与操作",
		"items": [
			{"k": "scale_percent", "t": "choice", "label": "大小",
				"options": ["小 75%", "中 100%", "大 135%"], "vals": [0.75, 1.0, 1.35]},
			{"k": "catch_padding", "t": "float", "label": "鼠标感应范围（像素）",
				"min": 2.0, "max": 30.0, "step": 1.0,
				"hint": "鼠标离她多远之内还算“碰到她”。调大更好点中，调小更好穿透到后面的窗口"},
			{"k": "double_click_ms", "t": "int", "label": "双击判定（毫秒）",
				"min": 150.0, "max": 600.0, "step": 10.0,
				"hint": "两次点击间隔小于它算双击 = 打开聊天框。手慢就调大一点"},
			{"k": "pet_cooldown", "t": "float", "label": "摸她之后的冷却（秒）",
				"min": 0.0, "max": 2.0, "step": 0.05,
				"hint": "这段时间内连点不再重复播放反应，免得动作一直在重头开始"},
			{"k": "move_chance", "t": "float", "label": "起身走一次的概率",
				"min": 0.0, "max": 1.0, "step": 0.05,
				"hint": "待机时间到了之后，这一次到底走不走。0 = 完全不动，就地待着"},
			{"k": "stay_nearby", "t": "check", "label": "只在小范围走动",
				"hint": "开着她只在“家”附近那一小块里转，不再满屏溜达（家 = 你拖她到的地方）"},
			{"k": "nearby_radius", "t": "float", "label": "小范围有多大（像素）",
				"min": 60.0, "max": 600.0, "step": 20.0,
				"hint": "上面那个开关的活动半径。别给太小，不然她像被钉住"},
			{"k": "drag_sets_home", "t": "check", "label": "拖到哪儿哪儿就是家",
				"hint": "关掉的话拖动只是临时挪一下，之后还会自己走回原来的位置"},
			{"k": "chat_enabled", "t": "check", "label": "聊天总开关",
				"hint": "关掉 = 完全不联网，退回纯本地桌宠（本地台词照常）"},
		],
	},
	{
		"title": "开机与系统",
		"items": [
			{"k": "quiet_fullscreen", "t": "check", "label": "全屏时保持安静",
				"hint": "看视频 / 玩游戏时只在家的附近小范围挪动。关掉就不再留那个后台检测进程"},
			{"k": "gpu_threshold", "t": "float", "label": "GPU 占用率透视阈值（%）",
				"min": 0.0, "max": 100.0, "step": 1.0,
				"hint": "GPU 占用率超过这个值（打游戏）她自动整窗穿透：不挡游戏、也不被误触。0 = 关掉自动透视"},
			{"k": "hide_taskbar", "t": "check", "label": "隐藏任务栏图标",
				"hint": "不在任务栏和 Alt+Tab 里出现，桌面上照常显示"},
			{"k": "tray_icon", "t": "check", "label": "托盘图标",
				"hint": "任务栏右下角「隐藏的图标」里放一个，右键能显示 / 隐藏她或退出"},
			{"k": "autostart", "t": "check", "label": "开机自启动",
				"hint": "登录 Windows 后自动启动（写用户级注册表，随时可关）"},
		],
	},
	{
		"title": "AI 服务",
		"items": [
			{"k": "harness_enabled", "t": "check", "label": "让她用 dsh 干活",
				"hint": "把简单的活交给本机的 DeepSeek Harness（dsh）：按任务大小自动挑推理档。"
					+ "开了之后会在你机器上真跑一个 node 进程、花你的额度"},
			{"k": "harness_max_effort", "t": "choice", "label": "最高推理档",
				"options": ["off（不开思考）", "low", "high", "max（想得最多）"],
				"vals": ["off", "low", "high", "max"],
				"hint": "天花板：任务再大也不会超过这一档。想让额度有上限就压低它"},
			{"k": "harness_timeout_sec", "t": "float", "label": "单件活最多等（秒）",
				"min": 60.0, "max": 3600.0, "step": 30.0,
				"hint": "超过就放弃等待、解锁聊天（dsh 进程杀不掉，随它去）。"
					+ "卡死的活多数是在等一个没人能答的确认"},
			{"k": "cmd_open_ai", "t": "button", "label": "打开 AI 服务设置…",
				"hint": "后端地址 / 访问密钥 / 模型。和右键菜单里那条是同一个面板"},
		],
	},
]

## ------------------------------------------------------------------ 状态

var _panel: PanelContainer = null
var _body: VBoxContainer = null
var _status: Label = null
var _font: Font = null
## 键 -> 控件（读值、灌值都靠它）
var _fields: Dictionary = {}
## 键 -> 控件类型（读值时要按类型取，见 values()）
var _kinds: Dictionary = {}
## 键 -> choice 的取值表
var _vals: Dictionary = {}
## 出厂默认值。由主脚本在**读存档之前**抓下来传进来 ——
## 读存档会把值写回那些变量，之后就分不清"改过的"和"出厂的"了
var _defaults: Dictionary = {}
## 需要点两下确认的按钮：键 -> 第一下的时刻（毫秒）
var _confirm_at: Dictionary = {}

## ------------------------------------------------------------------ 搭建

func build(layer: CanvasLayer, font: Font) -> void:
	if layer == null:
		return
	_font = font
	_panel = PetUi.panel()
	_panel.name = "Settings"
	_panel.visible = false
	# 占满整个窗口，而不是居中固定尺寸：窗口本身只有 330x470，
	# 而且缩放档还会把它变小 —— 固定尺寸在小档下会溢出到窗外去
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = MARGIN
	_panel.offset_top = MARGIN
	_panel.offset_right = -MARGIN
	_panel.offset_bottom = -MARGIN
	layer.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	var head := PetUi.hbox(6)
	head.add_child(PetUi.title("设置", _font))
	head.add_child(PetUi.spacer())
	vb.add_child(head)

	# 设置项有二十多条，一屏放不下 —— 中间这段可滚动，标题和按钮钉住不动
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 7)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)

	for sec in SECTIONS:
		_add_section(sec)

	_status = PetUi.hint("", _font)
	vb.add_child(_status)
	vb.add_child(_build_footer())

func _add_section(sec: Dictionary) -> void:
	var items: Array = sec["items"]
	if not items.is_empty() and _body.get_child_count() > 0:
		_body.add_child(HSeparator.new())
	_body.add_child(PetUi.section(String(sec["title"]), _font))
	for it in items:
		_add_item(it)

## 每个设置项长什么样。**hint 一律做成鼠标提示**（tooltip），不占一行版面 ——
## 二十多条都带一行灰字说明的话，滚一屏都看不完
func _add_item(it: Dictionary) -> void:
	var k := String(it["k"])
	var kind := String(it["t"])
	var label := String(it["label"])
	var hint := String(it.get("hint", ""))
	_kinds[k] = kind
	var c: Control = null
	match kind:
		"check":
			c = PetUi.check(label, false, _font)
		"text":
			_body.add_child(PetUi.label(label, _font))
			# 占位文字用 ph，不用 hint：hint 是给人"想细看"的长句，
			# 塞进输入框会被截成一截半截（实测）
			c = PetUi.edit(String(it.get("ph", "")), _font)
		"int", "float":
			# 一行：[名字] …… [数字框]。初值给 min，真值由 _fill() 灌进来
			var row := PetUi.hbox(6)
			row.add_child(PetUi.label(label, _font))
			row.add_child(PetUi.spacer())
			c = PetUi.spin(float(it.get("min", 0.0)), float(it.get("min", 0.0)),
				float(it.get("max", 0.0)), float(it.get("step", 1.0)), _font)
			row.add_child(c)
			_body.add_child(row)
		"choice":
			# 下拉框自己带标签（独占一行），也得自己加进 _body ——
			# 下面那段"要不要补 add_child"是按类型分的，choice 不归它管
			_body.add_child(PetUi.label(label, _font))
			var opts: Array = it.get("options", [])
			c = PetUi.option(opts, 0, _font)
			_vals[k] = it.get("vals", [])
			_body.add_child(c)
		"button":
			var b := PetUi.button(label, _font)
			b.pressed.connect(_on_pressed.bind(k))
			c = b
		_:
			return
	if hint != "":
		c.tooltip_text = hint
	_fields[k] = c
	# int / float 是"标签 + 控件"拼成一行的，早就进 _body 了；choice 上面也加过了。
	# 剩下的（勾选框 / 输入框 / 按钮）在这儿统一补上
	if kind != "int" and kind != "float" and kind != "choice":
		_body.add_child(c)

func _build_footer() -> HBoxContainer:
	var row := PetUi.hbox(6)
	var reset := PetUi.button("恢复默认", _font)
	reset.tooltip_text = "把面板里的值填回检查器里的出厂值。点「保存」才生效"
	reset.pressed.connect(_on_restore_defaults)
	row.add_child(reset)
	row.add_child(PetUi.spacer())
	var cancel := PetUi.button("取消", _font)
	cancel.pressed.connect(close)
	row.add_child(cancel)
	var save := PetUi.button("保存", _font)
	save.tooltip_text = "存下来并立刻生效"
	save.pressed.connect(_on_save)
	row.add_child(save)
	return row

## ------------------------------------------------------------------ 开关

## 打开面板：把当前值和出厂值灌进去。
## values 由主脚本给（它才是"当前值"的出处），defaults 用于「恢复默认」
func open(values: Dictionary, defaults: Dictionary, status: String = "") -> void:
	if _panel == null:
		return
	_defaults = sanitize(defaults)
	_fill(sanitize(values))
	_status.text = status
	_status.visible = status != ""
	_clear_confirm()
	_panel.visible = true

func close() -> void:
	if _panel == null or not _panel.visible:
		return
	_panel.visible = false
	_clear_confirm()
	closed.emit()

func is_open() -> bool:
	return _panel != null and _panel.visible

func point_inside(pos: Vector2) -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(pos)

func set_status(text: String) -> void:
	if _status == null:
		return
	_status.text = text
	_status.visible = text != ""

## 把所有需要确认的按钮的文字还原（关面板 / 重新打开时都要）
func _clear_confirm() -> void:
	_confirm_at.clear()
	for sec in SECTIONS:
		for it in sec["items"]:
			if String(it["t"]) == "button" and bool(it.get("confirm", false)):
				var b: Button = _fields.get(String(it["k"]), null)
				if b != null:
					b.text = String(it["label"])

## ------------------------------------------------------------------ 读值 / 灌值

## 把控件里的值收上来。**收上来就 sanitize**：控件的类型和按键名约定不完全一致
## （SpinBox 一律吐 float，choice 吐的是下标），钳制和转换只在 sanitize 一处做
func values() -> Dictionary:
	var out: Dictionary = {}
	for k in _fields.keys():
		var c: Control = _fields[k]
		match String(_kinds[k]):
			"check":
				out[k] = (c as CheckButton).button_pressed
			"text":
				out[k] = (c as LineEdit).text.strip_edges()
			"choice":
				var vals: Array = _vals.get(k, [])
				var idx: int = (c as OptionButton).selected
				out[k] = vals[idx] if idx >= 0 and idx < vals.size() else idx
			"int", "float":
				out[k] = (c as SpinBox).value
			_:
				pass
	return sanitize(out)

func _fill(v: Dictionary) -> void:
	for k in _fields.keys():
		var c: Control = _fields[k]
		if not v.has(k):
			continue
		var val: Variant = v[k]
		match String(_kinds[k]):
			"check":
				(c as CheckButton).button_pressed = bool(val)
			"text":
				(c as LineEdit).text = String(val)
			"choice":
				var vals: Array = _vals.get(k, [])
				var idx: int = int(val)
				if not vals.is_empty():
					idx = vals.find(val)      # vals 里找不到就退回当"下标"用
				(c as OptionButton).selected = clampi(idx, 0, maxi(0, (c as OptionButton).item_count - 1))
			"int", "float":
				(c as SpinBox).value = float(val)
			_:
				pass

## ------------------------------------------------------------------ 按钮

func _on_pressed(k: String) -> void:
	var spec := _spec_of(k)
	if spec.is_empty():
		return
	if not bool(spec.get("confirm", false)):
		command.emit(k)
		return
	# 点两下才算。第二下要在 CONFIRM_MS 内，超时就退回去重新点
	var now := Time.get_ticks_msec()
	var armed: int = int(_confirm_at.get(k, 0))
	var b: Button = _fields[k]
	if now - armed > CONFIRM_MS:
		_confirm_at[k] = now
		b.text = "再点一下确认：%s" % String(spec["label"])
		set_status("这一步不能撤销。%d 秒内再点一下才真的执行" % int(CONFIRM_MS / 1000))
		return
	_confirm_at.erase(k)
	b.text = String(spec["label"])
	set_status("")
	command.emit(k)

func _on_restore_defaults() -> void:
	if _defaults.is_empty():
		set_status("没记下出厂值，恢复不了（这个不该发生）")
		return
	_fill(_defaults)
	set_status("已填回出厂值，点「保存」才生效")

func _on_save() -> void:
	var v := values()
	close()
	saved.emit(v)

func _spec_of(k: String) -> Dictionary:
	for sec in SECTIONS:
		for it in sec["items"]:
			if String(it["k"]) == k:
				return it
	return {}

## ------------------------------------------------------------------ 校验

## 按表把值钳到合法范围、整成对的类型。**存档读回来也要过这一道** ——
## 配置文件是纯文本，手改过、或者老版本留下的值都可能越界
## （比如把间隔改成 0，那她就会一直偷看屏幕）。
static func sanitize(values: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for sec in SECTIONS:
		for it in sec["items"]:
			var k := String(it["k"])
			var t := String(it["t"])
			if t == "button" or not values.has(k):
				continue
			var v: Variant = values[k]
			match t:
				"check":
					out[k] = bool(v)
				"text":
					out[k] = String(v).strip_edges()
				"int", "float":
					var f := clampf(float(v), float(it.get("min", 0.0)), float(it.get("max", 1.0)))
					out[k] = int(round(f)) if t == "int" else f
				"choice":
					# 带 vals 的（比如"大小"）存的是**值**不是下标，得先在 vals 里找它；
					# 不带 vals 的（比如频率档）存的就是下标本身
					var opts: Array = it.get("options", [])
					var idx := clampi(int(v), 0, maxi(0, opts.size() - 1))
					var vals: Array = it.get("vals", [])
					if vals.is_empty():
						out[k] = idx
					else:
						var found := vals.find(v)
						out[k] = vals[found] if found >= 0 else vals[mini(idx, vals.size() - 1)]
				_:
					pass
	return out

## 这张表里有哪些键（探针拿它检查主脚本有没有漏认某个键）
static func keys() -> Array:
	var out: Array = []
	for sec in SECTIONS:
		for it in sec["items"]:
			out.append(String(it["k"]))
	return out
