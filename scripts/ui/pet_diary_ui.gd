extends RefCounted
## 「我们的日记」那一屏 —— 按日期倒着翻她记下的日子。
##
## 这是整个日记功能**唯一给你看的地方**。前面几个文件（`pet_diary.gd` /
## `pet_diary_prompt.gd` / `pet_diary_flow.gd`）都是数据、提示词、调度，
## 你真正能感知到的就是这一屏。
##
## 版面：**占满整窗**（和设置面板 / 工作台一致）—— 窗口本体只有 330×470，
## 缩放档还会把它变小，居中固定尺寸在小档下会溢出到窗外（设置面板踩过这个）
##
## 它不自己写日记：按「让她补写今天」只是把请求交给 `pet_diary_flow`，
## 写完由 flow 回调和宿主刷新（见 `refresh()`）。**面板不碰网络**。

const PetUi := preload("res://scripts/ui/pet_ui.gd")

const MARGIN := 4.0
## 正文最多显示多少行（一条日记最多 3 句，再多就是模型没照要求写了）
const BODY_MAX_LINES := 4
## 列表里最多画多少天（面板要能一秒打开，不做分页）
const LIST_MAX := 60

signal closed()
## 点了「让她补写今天」——宿主转给 diary_flow.write_now_with_ai()
signal write_requested()

var _panel: PanelContainer = null
var _font: Font = null
var _stats: Label = null
var _status: Label = null
var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _write_btn: Button = null
var _diary = null

# ------------------------------------------------------------------ 搭

## 搭面板。diary = `pet_diary.gd` 的实例（数据模块），font 是宿主的中文字体
## （项目里没配全局中文字体，不挂的话中文会掉字）
func build(layer: CanvasLayer, diary, font: Font) -> void:
	if layer == null:
		return
	_diary = diary
	_font = font
	_panel = PetUi.panel()
	_panel.name = "Diary"
	_panel.visible = false
	# **面板底必须完全不透明**：共用那张卡片是 0.96，在透明窗口里会把身后的
	# 气泡 / 桌面透进来 —— 实测截图里能清楚看到她那句话浮在日记上面。
	# 只覆盖这一个面板，不动 PetUi.card()（那个是给不透明场景用的）
	var opaque := PetUi.card()
	opaque.bg_color = Color(1, 1, 1, 1.0)
	_panel.add_theme_stylebox_override("panel", opaque)
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = MARGIN
	_panel.offset_top = MARGIN
	_panel.offset_right = -MARGIN
	_panel.offset_bottom = -MARGIN
	layer.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	_panel.add_child(vb)

	vb.add_child(PetUi.title("我们的日记", _font))
	# 统计那一行。**别塞进"标题 + 弹簧"那一行** —— hint() 带 autowrap，
	# 在 HBox 里会被压成竖排一条、把下面全顶出窗口（工作台踩过）
	_stats = PetUi.hint("", _font)
	vb.add_child(_stats)
	# 状态行：只在她补写 / 出错时才有字
	_status = PetUi.hint("", _font)
	vb.add_child(_status)

	# ---- 日记列表（可滚）
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	_scroll.add_child(_list)

	# ---- 底部按钮
	var row := PetUi.hbox(6)
	_write_btn = PetUi.button("让她补写今天", _font)
	_write_btn.tooltip_text = "用模型把今天的拍子写成一段更自然的话（一天一次；失败了就继续用现在这版）"
	_write_btn.pressed.connect(func() -> void: write_requested.emit())
	row.add_child(_write_btn)
	row.add_child(PetUi.spacer())
	# 变量名别叫 close —— 它会**遮蔽 Object 自带的 close()**，
	# 于是 `close.pressed.connect(close)` 里的 close 变成那个 Button，
	# 报 "argument 1 should be Callable but is Button"（正是这一处踩到的）
	var close_btn := PetUi.button("关闭", _font)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	vb.add_child(row)

# ------------------------------------------------------------------ 开关 / 刷新

func is_open() -> bool:
	return _panel != null and _panel.visible

func open() -> void:
	if _panel == null:
		return
	_status.text = ""
	refresh()
	_panel.visible = true
	# 滚到最新那条（新的在最上面，所以是滚回顶部）
	if _scroll != null:
		_scroll.scroll_vertical = 0
func close() -> void:
	if _panel != null:
		_panel.visible = false
	closed.emit()

func toggle() -> void:
	if is_open():
		close()
	else:
		open()

## 重画。**写完日记 / 数据变了之后要调它**（宿主在 flow 回调里调）
func refresh() -> void:
	if _panel == null or _diary == null:
		return
	_stats.text = _diary.stats_line()
	for c in _list.get_children():
		# 先摘再 free：queue_free 要帧末才删，同帧新旧并存会画重
		_list.remove_child(c)
		c.queue_free()
	var items: Array = _diary.entries()
	if items.is_empty():
		_list.add_child(PetUi.hint("还没有日记。\n\n多陪她一会儿 —— 被摸、聊天、喂东西都算，" \
			+ "攒够几条她就会记下这一天。", _font))
		_write_btn.disabled = true
		return
	_write_btn.disabled = false
	var n := 0
	for it in items:
		if n >= LIST_MAX:
			break
		n += 1
		_list.add_child(_entry_block(it))

## 一条日记：**标题**（有就用它，没有退回日期）+ 正文摘要
func _entry_block(it: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)

	var head := PetUi.hbox(4)
	var title := String(it.get("title", "")).strip_edges()
	var date_text: String = _diary.date_label(String(it["date"]))
	# 标题是主角（列表扫一眼就看它）；日期退到后面当小字
	if title != "":
		head.add_child(PetUi.section(title, _font))
		head.add_child(PetUi.label(date_text, _font, 10, PetUi.TEXT_SUB))
	else:
		head.add_child(PetUi.section(date_text, _font))
	if bool(it["ai"]):
		head.add_child(PetUi.label("她写的", _font, 10, PetUi.TEXT_SUB))
	head.add_child(PetUi.spacer())
	# 那天记了几个拍子 —— 小字，让你知道这句话是从多少件小事里来的
	head.add_child(PetUi.label("%d 件事" % int(it["beats"]), _font, 10, PetUi.TEXT_SUB))
	col.add_child(head)

	var body := PetUi.label(String(it["text"]), _font, 12, PetUi.TEXT_MAIN)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.max_lines_visible = BODY_MAX_LINES
	col.add_child(body)
	return col

# ------------------------------------------------------------------ 状态提示

## 上面那行小字（她补写时 / 写失败时）。宿主和 flow 都往这儿写一句
func set_status(text: String) -> void:
	if _status != null:
		_status.text = text

func point_inside(pos: Vector2) -> bool:
	return _panel != null and _panel.visible and _panel.get_global_rect().has_point(pos)
