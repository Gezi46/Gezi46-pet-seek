# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 聊天输入面板的**样子与开关**：搭 UI、开 / 收、送出一句话、记录与滚动。
##
## 和邻居的分工：
##   `pet_chat.gd`        **客户端**：连接 / 请求 / 状态机
##   `pet_chat_flow.gd`   **接线与流式**：每帧推进、收流、拆候选、收尾回执
##   `pet_quick.gd`       气泡下那一列候选按钮
##   **本文件**           人看得见的那一面：面板、输入框、聊天记录
##
## 为什么留壳在宿主：`_open_chat` 被 pet_pointer（双击）和菜单调用，
## `_push_chat_line` 被 pet_chat_flow / pet_harness 调用 —— 都是按老名字来的。
##
## 对宿主的接口面（只列真正用到的）：
##   host._chat_panel / _chat_log_label / _chat_scroll / _chat_input   面板零件（宿主持有）
##   host._chat_log / host._chat_open / host._cjk_font / host._bubble  记录与字体
##   host.chat_log_lines / host.chat_enabled / host.mouse_passthrough_enabled
##   host._chat / host.harness / host._quick                           三条链路
##   host._ai_busy() / host._offline() / host._say() / host._soothe()
##   host._close_panels() / host._refresh_persona() / host._begin_stream_bubble()
##   host._begin_harness() / host.harness_task_of()
##   host._memory_flow / host._last_origin / host._chat_streaming
##   host._passthrough_set                                             穿透区标记

## 宿主（desktop_pet.gd）。弱类型：它 preload 本模块，标上就成循环 preload
var _host = null

func setup(host) -> void:
	_host = host

# ------------------------------------------------------------------ 搭界面

## 搭输入面板。挂在 UI 这个 CanvasLayer 底下，锚点相对视口
## （Control 的父节点不是 Control 时，锚点就按视口算）。
## 面板是运行时建的，不写进 pet.tscn —— 和眨眼叠加层一个道理，
## 场景文件里塞这些只会让 .tscn 越来越难读。
func build() -> void:
	_host._cjk_font = SystemFont.new()
	_host._cjk_font.font_names = PackedStringArray(
		["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"])
	# 气泡的字体也补上：项目里没配中文字体，默认字体渲染汉字会掉字
	_host._bubble.add_theme_font_override("font", _host._cjk_font)

	var layer := _host.get_node_or_null("UI") as CanvasLayer
	if layer == null:
		return

	_host._chat_panel = PanelContainer.new()
	_host._chat_panel.name = "ChatPanel"
	_host._chat_panel.visible = false
	_host._chat_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_host._chat_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_host._chat_panel.offset_left = 10.0
	_host._chat_panel.offset_right = -10.0
	_host._chat_panel.offset_top = -104.0
	_host._chat_panel.offset_bottom = -8.0
	# 透明窗口里默认面板是半透明深色，字看不清；换成浅色卡片
	var card := StyleBoxFlat.new()
	card.bg_color = Color(1.0, 1.0, 1.0, 0.9)
	card.set_corner_radius_all(8)
	card.set_content_margin_all(6)
	_host._chat_panel.add_theme_stylebox_override("panel", card)
	layer.add_child(_host._chat_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_host._chat_panel.add_child(vb)

	_host._chat_log_label = Label.new()
	_host._chat_log_label.add_theme_font_override("font", _host._cjk_font)
	_host._chat_log_label.add_theme_font_size_override("font_size", 12)
	_host._chat_log_label.add_theme_color_override("font_color", Color(0.12, 0.13, 0.2))
	# 一行放不下时折行（记录是**滚动**的，所以折行是好事 —— 能看到完整的话）
	_host._chat_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 宽度跟着容器走（不然 autowrap 没有参照，文字会横着撑开）
	_host._chat_log_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 滚轮事件要让**滚动容器**收到，别被标签吃掉
	_host._chat_log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host._chat_log_label.text = "（双击我就能说话～）"

	# 聊天记录放进滚动容器：面板高度固定（见上面 offset_top），但记录可以有很多行 ——
	# 上下拖动 / 滚轮就能往回翻（2026-09-27 用户要求）。
	# 高度按设置的"显示几行"给（chat_log_lines），这也是原来那个设置的用途
	_host._chat_scroll = ScrollContainer.new()
	_host._chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_host._chat_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_host._chat_scroll.custom_minimum_size = Vector2(
		0.0, float(maxi(1, _host.chat_log_lines)) * 16.0)
	_host._chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host._chat_scroll.add_child(_host._chat_log_label)
	vb.add_child(_host._chat_scroll)

	_host._chat_input = LineEdit.new()
	_host._chat_input.add_theme_font_override("font", _host._cjk_font)
	_host._chat_input.add_theme_font_size_override("font_size", 13)
	_host._chat_input.add_theme_color_override("font_color", Color(0.1, 0.11, 0.18))
	_host._chat_input.add_theme_color_override("font_placeholder_color", Color(0.48, 0.5, 0.58))
	var field := StyleBoxFlat.new()
	field.bg_color = Color(1, 1, 1, 0.95)
	field.border_color = Color(0.62, 0.64, 0.74)
	field.set_border_width_all(1)
	field.set_corner_radius_all(5)
	field.set_content_margin_all(4)
	_host._chat_input.add_theme_stylebox_override("normal", field)
	_host._chat_input.add_theme_stylebox_override("focus", field)
	_host._chat_input.placeholder_text = "说点什么…（回车发送，Esc 收起）"
	_host._chat_input.max_length = 2000
	# 信号连宿主的壳（壳再转进来）—— 保持"谁连的"一眼能看出来
	_host._chat_input.text_submitted.connect(_host._on_chat_submitted)
	vb.add_child(_host._chat_input)

# ------------------------------------------------------------------ 开 / 收

func open() -> void:
	if not _host.chat_enabled:
		_host._say("聊天功能还没打开哦～")
		return
	if _host._chat_panel == null:
		return
	_host._close_panels()      # 两个面板共用一块地方，先收掉另一个
	_host._chat_open = true
	_host._chat_panel.visible = true
	if _host.mouse_passthrough_enabled:
		# 整窗收点击，别把面板自己挖成穿透区
		DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
		_host._passthrough_set = true
	refresh_log()
	set_focus(true)
	_host._chat_input.clear()
	_host._chat_input.grab_focus()

func close() -> void:
	if not _host._chat_open:
		return
	_host._chat_open = false
	if _host._chat_panel != null:
		_host._chat_panel.visible = false
	set_focus(false)
	# 让穿透区下一帧重算：聊天时被清成整窗了，不重算就一直不穿透
	_host._passthrough_set = false

## 窗口平时是 no_focus 的（project.godot 里设的），这样点桌面不会把它顶到前面。
## 但 no_focus 的窗口收不到键盘 —— 要打字就得临时把它摘掉，再主动抢一次前台。
## 收起输入框时务必还原，不然桌宠会一直抢键盘焦点。
func set_focus(on: bool) -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, not on)
	if on:
		DisplayServer.window_move_to_foreground()

# ------------------------------------------------------------------ 送出

func submit(text: String) -> void:
	var msg := text.strip_edges()
	if msg == "" or _host._chat == null:
		return
	if _host._ai_busy():
		# 跑活的时候提示要说得具体点：她可能在等 dsh，那比"上一句没说完"久得多
		_host._say("我还在弄那件活呢，稍等一下～" if (_host.harness != null and _host.harness.busy) \
			else "上一句我还没说完呢…")
		return
	# 假死：只收着，不往外发 —— 别让她卡在一个注定失败的请求上。
	# 输入框里的话不动（clear 在后面才发生），等连上了你重试就行
	if _host._offline():
		_host._say("我现在联系不上外面诶…等会儿再试试？")
		return
	# "干活：…" = 把活交给本机 dsh，不走聊天那条路（见 pet_harness.gd）
	var harness_task: String = _host.harness_task_of(msg)
	if harness_task != "":
		_host._begin_harness(harness_task)
		return
	push_line("我", msg)
	_host._chat_input.clear()
	_host._quick.hide()   # 主人自己开口了，快速回答就不必再摆着
	_host._soothe()       # 被理了就不生气了
	_host._last_origin = "chat"   # 记忆：这轮是打字聊的（和主动搭话/偷看分开处理）
	# 记忆：本地规则先抓一遍（零成本、立刻生效），并记下"这轮主人说了什么" ——
	# 收尾时 note_exchange 要拿它配套用
	_host._memory_flow.note_user_message(msg)
	_host._refresh_persona(msg)   # 再按这句话重拼人设：会检索出跟这句话相关的旧记忆
	_host._begin_stream_bubble()
	if not _host._chat.send(msg):
		_host._chat_streaming = false
		_host._say("发送失败，稍后再试～")

# ------------------------------------------------------------------ 记录

func push_line(who: String, text: String) -> void:
	_host._chat_log.append("%s：%s" % [who, text])
	while _host._chat_log.size() > _host.CHAT_LOG_KEEP:
		_host._chat_log.pop_front()
	refresh_log()

func refresh_log() -> void:
	if _host._chat_log_label == null:
		return
	if _host._chat_log.is_empty():
		_host._chat_log_label.text = "（双击我就能说话～）"
		return
	# 长消息**不再按字数截断加省略号**（2026-09-30 用户报"回得太多显示三个点"）——
	# 改成整句进标签，靠 autowrap 换行显示完全；面板本来就能滚动，换几行也翻得完
	var lines: Array[String] = []
	for i in range(_host._chat_log.size()):
		lines.append(String(_host._chat_log[i]).strip_edges())
	_host._chat_log_label.text = "\n".join(lines)
	# 新消息进来就滚到底（延迟一帧：文本刚变，容器要先把内容高度算完）
	scroll_to_bottom.call_deferred()

## 把聊天记录滚到最底下（最新那行）。用户往上翻的时候会被这条拽回来吗？——
## 只在**有新行**时调用（见 refresh_log），所以翻着看不会被打断
func scroll_to_bottom() -> void:
	if _host._chat_scroll == null:
		return
	_host._chat_scroll.scroll_vertical = int(_host._chat_scroll.get_v_scroll_bar().max_value)
