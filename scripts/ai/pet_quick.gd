# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 快速回答：气泡下面那列"主人可能接着说"的按钮。
##
## 原来这堆东西散在 desktop_pet.gd 的 **6 个不相邻区间**（常量 / 静态解析 / 状态变量 /
## 建 UI / 显示隐藏 / AI 回填），改一处要在 2700 行里来回跳。现在整块搬到这里，
## 宿主只留 4 个设置和一个 `_offline()`。
##
## 为什么单独一块、不塞进聊天面板：它要能在"聊天框没开"时也能点 ——
## 那才是"快速回答"的意思（单独一块 UI，挂在 `UI/Anchor` 下）。
##
## 职责边界（拆出来的规矩，以后改动先看这几条）：
##   * **自己的状态自己拿**：第几代 / 待发请求 / 重试次数 / 上次的开头 / 自动收起时刻
##   * **自己的 UI 自己建**：那一列按钮，挂到宿主给的 anchor 上
##   * **自己的网络自己的**：`_client` 单开一条连接，不和记忆抽取抢（理由见下）
##   * **点了哪句 → 发 `picked` 信号**，由宿主决定"当主人说了这句话"送出去；
##     模块不直接调宿主的发送逻辑（这样它离线可测，也不必认识聊天那套）
##
## 对宿主的接口面（**只有这几项，别再加** —— 想加就说明这块该拆得更细）：
##   host.quick_enabled / quick_ai / quick_chance / quick_chance_chat  设置
##       （`@export` 必须留在宿主：检查器只认挂在场景上的脚本，而设置面板也是
##         `SETTING_VARS` → `set(变量名)` 打在宿主上）
##   host._offline()          离线时别发那个小请求（白花时间）
##   host._invalidate_passthrough()  按钮出现/消失后重算"可点区域"
##   picked(text)             点了哪一句 → 宿主送出去
##
## 对气泡（宿主传进来的 PetBubble + 气泡 Label）：只读它的位置和显示与否，
## 以及"按住 / 让它继续淡出"—— 按钮得挂在气泡下沿、跟着气泡走
##
## 两层的分工（这块最容易改错的地方，2026-09 修过一次"选项不对"）：
##   **本地那组**：秒出，但**不可能知道她问了什么** —— 所以它只给"打好太极、
##                 任何场合都接得住"的话，绝不给"答非所问"的话（见 quick_options_for）
##   **模型那组**：带着最近几轮对话现编（见 after_reply 的 context），
##                 回来得早就换上去；回不来就一直用本地那组（按钮不会消失）
##
## 验证：`tools/probe_memory.gd` 的离线段直接试 `quick_options_for` /
## `parse_quick_options`（两个都写成 static 就是为了能脱离场景验）

## 点了某句候选 = 主人说了这句话。宿主接到后走正常发送链路（所以它也会进记忆）
signal picked(text: String)

# ------------------------------------------------------------------ 常量

## 按钮显示多久后自动收起（毫秒）
const HIDE_MS := 25000
## 正在等模型编候选时，最多再多挂多久（毫秒）。
## **这条是"选项不对"的另一半原因**：模型要十几秒才回来，而按钮 25 秒就收了 ——
## 它回来时已经没人看得见，用户看到的永远只有本地那组。多挂这一会儿，它才有机会换上去
const AI_GRACE_MS := 25000
## 等后台连接空出来的最长时间（毫秒）
const AI_WAIT_MS := 20000
## 让模型现编"主人可能接着说什么"的提示词。
## 要求只吐 JSON 数组 —— 解析不出来就继续用本地那几组（见 parse_quick_options），
## **按钮不会因为模型乱答而消失**
## 系统提示词写得**短**：要求就一句话。
## "要接住她刚说的那句"这类说明写在 AI_PROMPT 的正文里就够了，不必在系统提示再说一遍
const AI_SYS := "只输出 JSON 数组，不要解释。内容必须是主人接她的话能说的三句。"
const AI_PROMPT := "刚才的对话：\n%s\n她刚说：「%s」\n（场景：%s）\n" \
	+ "给主人想 3 句最可能的下一句话：每句不超过 14 个字，口气随意、像随手打字，" \
	+ "彼此不要雷同，也别都写成提问。**要能接住她刚说的那句**。" \
	+ "只输出 JSON 数组，例如 [\"句子一\",\"句子二\",\"句子三\"]"
## 注意这条请求**走流式**（`send()`），不走 `ask_once()`：
## 它和聊天是同一条路（这条路在无头模式 / 各种后端下都验过），而且
## **不接 token 信号** —— 只有 replied 会到我们这儿，气泡完全不受影响。
## 代价是没有 max_tokens 可给（流式那条不带它），所以提示词里写死了"只输出 JSON 数组"
##
## 另外：客户端的状态机要每帧推（见本文件 tick()）—— 漏了那一行的话，
## 请求发出去也没人收结果，表现成"这一组从来不出现"

# ------------------------------------------------------------------ 本地候选（static，可离线验）

## 快速回答的候选：**本地按口气挑，不走模型**。两个原因：
##   1. 要"立刻"能点 —— 等模型一秒多才出按钮就不叫快速回答了；
##   2. 主动搭话/偷看本来已经产生一次请求，再为按钮加一次不划算。
## 返回的是"点了就当她收到的、主人说的话"。
##
## **本地这组不可能知道她问了什么**，所以规矩是：宁可给"打太极"的话，
## 也绝不给"答非所问"的话 —— 她问"吃饭了没"你回"在呢，你说"，那看着就是坏的。
## 真正接得上的答案交给模型那条（它带着最近几轮对话，见 after_reply 的 context）。
## 写成 static 是为了能脱离场景验证（tools/probe_memory.gd 会检查它）
static func quick_options_for(kind: String, line: String) -> Array[String]:
	if kind == "sulk":
		return ["好啦，我在呢，别生气～", "抱歉抱歉，刚在忙", "摸摸头，等会儿陪你"]
	# 她被摸烦了的时候，"摸摸头，等会儿陪你"就很讽刺了 —— 那是又摸她一下。
	# 单独给一组"手放好了"的选项，也顺便说明按钮本来就能认口气
	if kind == "touch":
		return ["好啦不摸了", "手放好了，别生气", "那陪你聊会儿？"]
	var ask := line.find("？") >= 0 or line.find("?") >= 0 or line.find("吗") >= 0
	# 真聊天里的问句：她可能问"吃饭了没"，也可能问"你还记得昨天那个吗" ——
	# 本地答不出来，所以给三句"任何问句都接得住、又不会说错话"的
	if kind == "chat" and ask:
		return ["嗯…让我想想", "这个一会儿跟你说", "嘿嘿，你怎么突然问这个"]
	if ask:
		# 她主动搭话 / 偷看屏幕问的那几句，基本都在问"你在忙什么""你在干嘛" ——
		# 这组就是照那个写的，别拿去当通用答话
		return ["在呢，你说", "刚在忙，怎么啦？", "嗯嗯，然后呢"]
	if kind == "peek" or kind == "camera":
		return ["哈哈被你发现了", "嗯，正忙着呢", "看够没？"]
	return ["嗯嗯，在听", "哈哈", "等我一下下"]

## 把模型吐回来的候选洗干净。
##
## 模型很少老实只给 JSON：编号、圆点、书名号引号、尾巴的解释、markdown 代码块
## 都会混进来。这里一律削掉；**洗不出东西就返回空数组**，调用方继续用本地那组 ——
## 也就是说这条链路坏了，按钮照样在，只是句子普通一点。
## 写成 static 是为了能脱离场景验证（tools/probe_memory.gd 会试它）
static func parse_quick_options(text: String) -> Array[String]:
	var out: Array[String] = []
	for v in PetMemory.parse_json_array(text):
		var s := String(v).strip_edges()
		# 开头的 "-" "•" "1." "2、" 这类编号
		while s.begins_with("-") or s.begins_with("•") or s.begins_with("·"):
			s = s.substr(1).strip_edges()
		if s.length() >= 2 and s[0].is_valid_int() and (s[1] == "." or s[1] == ")"
				or s[1] == "、" or s[1] == " "):
			s = s.substr(2).strip_edges()
		# 两头的引号 / 书名号
		s = s.trim_prefix("\"").trim_suffix("\"")
		s = s.trim_prefix("「").trim_suffix("」")
		s = s.trim_prefix("“").trim_suffix("”")
		s = s.strip_edges()
		if s == "" or s.length() > 24 or s.find("\n") >= 0:
			continue          # 空的 / 太长 / 多行的都不要（按钮只有一行能放）
		out.append(s)
		if out.size() >= 3:
			break             # 只要三句，多了气泡底下放不下
	return out

## 从文本里抠 JSON 数组这一步在记忆模块里（它干这个最熟）。
## 单独引一下是为了：这个类只依赖"能抠 JSON"这一件事，不拉进整个记忆模块
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")
const PetChat := preload("res://scripts/ai/pet_chat.gd")

# ------------------------------------------------------------------ 状态（都是自己的）

var _host: Node = null                  # 只为上面那张接口面
var _label: Label = null                # 气泡 Label（读位置 / 文字）
var _bubble: RefCounted = null          # PetBubble：按住 / 让它淡出
var _box: VBoxContainer = null
var _btns: Array[Button] = []
var _font: Font = null
var _rng := RandomNumberGenerator.new()
## 自动收起的时刻（0 = 没在显示）
var _hide_ms: int = 0
## 上一次那组的头一句。本地那组只有三条，连着两次一模一样会很假
var _last_first: String = ""
## 第几代：模型那组是**异步**回来的，回来晚了可能已经翻篇 ——
## 靠这个号码认领，别把上一轮的候选贴到这一轮上
var _gen: int = 0
## 等着发的"让模型编候选"请求：{kind, line, context, gen}；空 = 没有待发的
var _want: Dictionary = {}
## 上面那个请求：什么时候可以试着发 / 最晚等到什么时候
var _try_ms: int = 0
var _deadline_ms: int = 0
## 正在路上的那条请求属于第几代（-1 = 没有）
var _ai_gen: int = -1
## 失败后要重排的那份（同一轮最多试两次），空 = 不重试
var _retry: Dictionary = {}
var _tries: int = 0
## 专门问候选的小客户端。**单开一条连接是必须的**：
## 后台那条（_chat 的 once）会被记忆抽取占着 —— 每轮聊完"抽事实 + 更新摘要"能占十几秒，
## 挤在一条上就得排队，实测结果就是"聊天那条路上永远轮不到"（按钮一直停在本地那组）。
## 它只发一次很小的非流式请求，不碰气泡、也不进宿主的 _ai_busy()：那只是编几句候选，
## 不该挡着她说话
var _client: PetChat = null
var _configured: bool = false

# ------------------------------------------------------------------ 建 / 配 / 推进

## 建那一列按钮并挂到 anchor 下。font 是宿主的中文字体（按钮上全是中文）
func setup(host: Node, anchor: Control, label: Label, bubble_mod: RefCounted,
		font: Font) -> void:
	_host = host
	_label = label
	_bubble = bubble_mod
	_font = font
	_rng.randomize()
	if anchor != null:
		_box = VBoxContainer.new()
		_box.name = "QuickReplies"
		_box.visible = false
		_box.add_theme_constant_override("separation", 3)
		_box.alignment = BoxContainer.ALIGNMENT_CENTER
		anchor.add_child(_box)
	# **走流式那条路（send + replied），不用 ask_once** —— 理由见文件头那条注意。
	# 它自己一条连接，系统提示词就是 AI_SYS；max_history = 0 让它每轮都是干净的，
	# 上下文由我们自己在提示词里给（不然它会把自己的历史也一起发过去，越滚越大）
	_client = PetChat.new()
	_client.system_prompt = AI_SYS
	_client.max_history = 0
	_client.replied.connect(_on_ai_done)
	_client.failed.connect(_on_ai_failed)

## 宿主换 AI 服务设置时调它（和聊天那个客户端同一份地址 / 密钥 / 文本模型）
func configure(url: String, key: String, model: String) -> void:
	if _client == null:
		return
	_client.configure(url, key, model)
	_configured = url.strip_edges() != ""

## 每帧推进：自动收起 + 把"让模型编候选"那条排出去。
## 宿主在 _tick_chat 里调（位置和"她主动说话"的检查挨着，顺序别乱动）
func tick() -> void:
	# **这条千万不能漏**：客户端的状态机每帧要推一下，不然请求发出去就没人管了 ——
	# 回复永远回不来、is_busy() 永远是 true（拆模块那次就是漏了这一行，
	# 表现成"AI 那组从来不出现"，查了半天）
	if _client != null:
		_client.tick()
	if _hide_ms > 0 and Time.get_ticks_msec() > _hide_ms:
		# 还在等模型：多挂一会儿（最多 AI_GRACE_MS）—— 不让它回来时按钮已经收了。
		# "选项不对"有一半就是这么来的：用户看到的永远只有本地那组
		var waiting := _ai_gen >= 0 and _ai_gen == _gen
		if not (waiting and Time.get_ticks_msec() < _hide_ms + AI_GRACE_MS):
			hide()
	_tick_ai()

# ------------------------------------------------------------------ 显示 / 收起

## 她说完了 → 可能给按钮。
## kind = "chat" 走"聊天"那条概率，其余（她主动开口 / 偷看 / 生闷气 / 被摸烦）走另一条。
## context = 最近几轮对话（喂给模型那条，让它编得出接得上的话；本地那组用不到）。
## 返回 true = 本地那组已经摆出来了（模型那组可能随后覆盖上来）
func after_reply(kind: String, line: String, context: String = "") -> bool:
	if _host == null or _box == null:
		return false
	# GPU 自动透视中（打游戏）：不递候选。宿主那层也拦了，这是第二道 ——
	# 以后新加一条"她说完了"的路子，忘了在宿主加判断也不会漏出按钮
	if bool(_host._gpu_passthrough):
		return false
	if not bool(_host.quick_enabled) or not _bubble.is_visible():
		return false
	var text := line.strip_edges()
	if text == "":
		return false
	var chance := float(_host.quick_chance_chat) if kind == "chat" else float(_host.quick_chance)
	if _rng.randf() > chance:
		return false       # 概率没中：这一轮不给按钮（有时有、有时没有才像随手递过来）
	_gen += 1
	_show_buttons(_shuffled(kind, text))
	# 再问模型要一组更像样的。本地那组**先顶上**：等模型一秒多才出按钮就不叫快速回答了
	if bool(_host.quick_ai) and _configured and not bool(_host._offline()):
		_want = {"kind": kind, "line": text, "context": context.strip_edges(), "gen": _gen}
		var now := Time.get_ticks_msec()
		_try_ms = now + 400              # 让记忆那条先占 —— 它更该被记住
		_deadline_ms = now + AI_WAIT_MS
	return true

## 候选**已经跟着她那句话一起**给出来了（见宿主的 _send_first）→ 这一轮不再发请求。
##
## 为什么要有这条路：原来她主动开口之后，还要再单独问一次模型编候选 ——
## 多一次请求（多一份 token、多几千毫秒），按钮要等好几秒才出现。
## 现在候选和那句话在同一次回答里，她说完按钮就到位。
##
## 洗不出候选（模型没照格式写 / 只有一条）就**退回 after_reply** ——
## 那条会先摆本地那组，再决定要不要问模型。按钮在任何情况下都不会消失
func show_given(kind: String, line: String, opts: Array) -> bool:
	if _host != null and bool(_host._gpu_passthrough):
		return false       # GPU 自动透视中（打游戏）：候选跟着那句话一起给的也别摆
	var clean: Array[String] = []
	for v in opts:
		var s := String(v).strip_edges()
		if s != "" and s.length() <= 24 and s.find("\n") < 0:
			clean.append(s)
	if clean.size() < 2:
		return after_reply(kind, line)
	if _host == null or _box == null:
		return false
	if not bool(_host.quick_enabled) or not _bubble.is_visible():
		return false
	var text := line.strip_edges()
	if text == "":
		return false
	# 概率照样管着它 —— "有时有、有时没有"这件事不该因为省了一次请求就变
	var chance := float(_host.quick_chance_chat) if kind == "chat" else float(_host.quick_chance)
	if _rng.randf() > chance:
		return false
	_gen += 1
	_show_buttons(clean)
	if OS.is_debug_build():
		print("[桌宠] 快速回答（和她那句话一起给出的，没多花一次请求）：%s" % str(clean))
	return true

func hide() -> void:
	var was_visible := _box != null and _box.visible
	if _box != null:
		_box.visible = false
	_hide_ms = 0
	# 待发的那条跟着作废：按钮都收了，编出来也没地方放
	_want.clear()
	_retry.clear()
	_tries = 0
	_host._invalidate_passthrough()
	# 按钮收起 = 不用再等她接话了：把刚才按住的淡出还回去（不然气泡会一直挂着）
	if was_visible and _bubble.is_visible():
		_bubble.say(_label.text)

## 按钮的屏幕矩形（没显示时是空的）。宿主的穿透区要把它算进去，见 pet_pointer.gd
func clickable_rect() -> Rect2:
	if _box == null or not _box.visible:
		return Rect2()
	return _box.get_global_rect()

func is_visible() -> bool:
	return _box != null and _box.visible

# ------------------------------------------------------------------ 内部：摆按钮

## 本地那组：**打乱顺序**，而且尽量别和上次同一个开头。
## 池子只有三四句，每次原样出现一眼就能看出是写死的
func _shuffled(kind: String, line: String) -> Array[String]:
	var out: Array[String] = []
	for v in quick_options_for(kind, line):
		out.append(v)
	out.shuffle()
	if out.size() > 1 and out[0] == _last_first:
		out.append(out.pop_front())       # 换个开头
	_last_first = out[0]
	return out

## 真的把按钮摆出来。本地那组和模型那组都走这一条，所以样式只有一份
func _show_buttons(opts: Array) -> void:
	if _box == null or opts.is_empty():
		return
	for b in _btns:
		# **必须先摘下来再 queue_free**：queue_free() 要等到帧末才真删，
		# 同一帧里新旧按钮会并存 —— 那一帧里 get_global_rect()（可点区域按它算）
		# 和"读到几个按钮"都会多出旧的（自检里读到 6 个才发现，实测踩过）
		if b.get_parent() != null:
			b.get_parent().remove_child(b)
		b.queue_free()
	_btns.clear()
	for text in opts:
		var b := Button.new()
		b.text = String(text)
		b.add_theme_font_override("font", _font)
		b.add_theme_font_size_override("font_size", 12)
		# 别抢键盘焦点：窗口平时是 no_focus 的，按钮一抢焦点就会把她顶到前面
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.pressed.connect(_on_pressed.bind(String(text)))
		_box.add_child(b)
		_btns.append(b)
	_place()
	_box.visible = true
	# 把气泡**按住**（掐掉淡出）再重贴一次位置：气泡原本 1.8 秒就淡、按钮跟着一起没了，
	# 而模型那组要几秒才回来 —— 不按住的话"换成 AI 那组"经常是她刚说完就看不见了。
	# 按钮收起时再让它淡出（见 hide）
	_bubble.hold_with(_label.text)
	_place()
	# 换上一组新的 = 重新给足阅读时间（模型回到时也能多看一会儿）
	_hide_ms = Time.get_ticks_msec() + HIDE_MS
	# 让穿透区下一帧重算，把按钮算进"可点区域" ——
	# 不重算的话按钮飘在角色轮廓外，点上去会直接穿到后面的窗口
	_host._invalidate_passthrough()

## 贴在气泡下沿（气泡高度是按文字量算出来的，所以每次都得重新放）
func _place() -> void:
	_box.position = Vector2(2.0, _label.position.y + _label.size.y + 2.0)

func _on_pressed(text: String) -> void:
	hide()
	picked.emit(text)

# ------------------------------------------------------------------ 内部：让模型编候选

## 等着发的那条。它有自己的客户端，所以**不必和记忆抽取排队** —— 只需要等这一小会儿：
## 让气泡先撑好、按钮先摆出来，再发请求。等太久或者按钮已经收了就算了：本地那组还在
func _tick_ai() -> void:
	if _want.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now < _try_ms:
		return
	if now > _deadline_ms or _box == null or not _box.visible:
		_want.clear()
		return
	if _client == null or not _configured or bool(_host._offline()):
		_want.clear()
		return
	if _client.is_busy():
		_try_ms = now + 500              # 上一条还没回来，过会儿再问
		return
	# **必须先 duplicate**：Dictionary 是引用类型，直接 `var want := _want`
	# 之后那句 clear() 会把 want 自己也清空 —— 再读 want["gen"] 就是"键不存在"（踩过）
	var want := _want.duplicate()
	_want.clear()
	_retry = want                        # 留着给"空返回"那次重试用
	_tries = 1
	_ai_gen = int(want["gen"])
	var scene := "主人刚跟她聊完一轮" if String(want["kind"]) == "chat" else "她主动开的口"
	# 上下文（最近几轮）—— 没有它，模型编出来的话经常接不上她刚说的那句
	var ctx := String(want.get("context", ""))
	if ctx == "":
		ctx = "（没有更早的对话）"
	if not _client.send(AI_PROMPT % [ctx, _clip(String(want["line"]), 120), scene]):
		_ai_gen = -1

## 模型现编的那组回来了。洗一洗，**这一轮还没翻篇、按钮还挂着**才换上去
func _on_ai_done(text: String) -> void:
	var gen := _ai_gen
	_ai_gen = -1
	if gen != _gen or _box == null or not _box.visible:
		return          # 已经翻篇了（她又说了别的 / 按钮收起来了）—— 迟到的候选丢掉
	var opts := parse_quick_options(text)
	if opts.size() < 2:
		return          # 洗不出两句像样的：继续用本地那组，按钮不会消失
	if OS.is_debug_build():
		print("[桌宠] 快速回答（模型编的）：%s" % str(opts))
	_retry.clear()      # 拿到了，不用再重试
	_show_buttons(opts)

func _on_ai_failed(msg: String) -> void:
	# 这个模型**偶尔只吐思考、正文是空的**（实测同一条提示词，1200 成功过、2000 也空过），
	# 所以同一轮再试一次 —— 按钮那边本来就回退到了本地那组，重试只为"拿到 AI 那组"概率高一点
	if _ai_gen == _gen and _tries < 2 and not _retry.is_empty():
		_want = _retry
		_try_ms = Time.get_ticks_msec() + 600
		_deadline_ms = _try_ms + AI_WAIT_MS
		if OS.is_debug_build():
			print("[桌宠] 快速回答：模型那条没成，再试一次（%s）" % msg)
		return
	_ai_gen = -1
	_retry.clear()
	if OS.is_debug_build():
		print("[桌宠] 快速回答：模型那条没成（继续用本地那组）：%s" % msg)

## 提示词里塞原话就行，但别把一整篇长文丢进去
func _clip(s: String, n: int) -> String:
	var t := s.strip_edges()
	return t.substr(0, n) if t.length() > n else t
