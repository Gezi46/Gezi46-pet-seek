# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 情绪 / 触摸的「开口 + 哄她选择框」层（2026-10-01 从 desktop_pet.gd 拆出）。
##
## 状态与判定在 pet_mood.gd / pet_touch.gd，这里只负责「她因此说了什么、弹了什么」——
## 那些要窗口、截图、流式气泡、记忆，全是宿主的活（和 pet_mood.gd 头部那条边界一致）。
##
## 对宿主的接口面（只列真正用到的）：
##   host._mood / host._shortterm / host._peek / host._touch   情绪、短期记忆、窥屏、被摸
##   host.memory / host.memory_enabled                         记忆存档
##   host._rng                                                 随机源（和宿主共用一个）
##   host._say()                                               说一句
##   host._vision / host._chat / host._vision_ready() / host._ai_busy()  两条聊天链路
##   host._peek_screen() / host._begin_stream_bubble() / host._refresh_persona() / host._send_first()
##   host._last_origin / host._chat_streaming                  读写
##   host._cjk_font / host._bubble                             选择框 UI
##   host._invalidate_passthrough() / host.get_node_or_null("UI/Anchor")
##
## 宿主要留的壳（外部 / 菜单 / pet_pointer / pet_touch 按老名字调）：
##   _touch_react / _soothe / _soothe_her / _pick_line —— 都转到这里

const PetMood := preload("res://scripts/body/pet_mood.gd")
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")

## 生闷气时用的提示词。**别写成"责怪"** —— 她要的是小小地别扭一下，
## 写狠了会变成真生气，那就不像 18 岁的女孩子了
const PROMPT_SULK := "（主人好一会儿没理你了。用你自己的口气小小地生个闷气，一两句就好，" \
	+ "别扭一点没关系，但别真的凶他，也别长篇大论）"
## 生闷气第一次被冷落时、偷看一眼屏幕再开口用的提示词
const PROMPT_SULK_PEEK := "（主人好久没理你了。你自己偷看了一眼屏幕，看看他到底在忙什么。" \
	+ "看到什么就照实说一句，然后按你自己的想法决定要不要闹、闹到什么程度 ——" \
	+ "想懂事一点也行，想小小地闹一下也行，一两句话，别长篇大论）"

## 生闷气时点击她：随机弹「哄她」选择框的概率；没弹中的那几下冷冷一句（不给互动）
const SULK_COMFORT_CHANCE := 0.7
## 哄她的选项（每次随机挑 3 条）
const SULK_COMFORT_OPTIONS: Array[String] = [
	"摸摸头", "请你喝奶茶", "抱抱你", "陪你打游戏", "夸你好看", "带你出去玩",
]
## 她正生闷气、又不肯开选择框时说的冷话
const SULK_COLD_LINES: Array[String] = [
	"哼，别碰我。", "……别理我。", "烦着呢，走开。", "现在不想理你。",
]

## 每种心情对应一个动作（都用 EMOTE_NAMES 里那些 extra，或 jump / attacked 之类）。
## **哪个 extra 是"开心"要你自己对着模型看** —— 这张表就是给这个用的；
## 模型里没有那个动作会自动跳过（host._has.has），所以填错了也不会出事
## （2026-10-04 从 desktop_pet.gd 搬来）
const MOOD_ACTIONS: Dictionary = {
	PetMood.Mood.HAPPY: "riptide",       # 高兴：转圈（用户指定，模型里 ✓）
	PetMood.Mood.ANGRY: "swing_offhand", # 生气：摇头（⚠️ 模型里没找到"摇头"，先拿挥手顶着，待确认）
	PetMood.Mood.SAD: "extra1",          # 伤心：蜷缩（用户指定，静态姿势 → 循环保持，见 host._play_pose_loop）
	PetMood.Mood.MISCHIEF: "extra7",     # 坏心眼
}

## 心情变了 → 播一个"能体现这个情绪"的动作（用户 2026-10-01 要求"从模型里调用其他动作"）
func on_mood_changed(m: int) -> void:
	var act := String(MOOD_ACTIONS.get(m, ""))
	if act == "" or not _host._has.has(act):
		return
	# 伤心：**保持**蜷缩（extra1 是静态姿势，循环播 = 一直蜷着，不瞬间闪回待机）
	if m == PetMood.Mood.SAD:
		_host._play_pose_loop(act)
		return
	_host._play_action(act, 0.2)

var _host: Node = null
## 选择框状态（模块自持）
var _box: VBoxContainer = null
var _btns: Array = []
var _hide_ms: int = 0

func setup(host: Node) -> void:
	_host = host
	# 情绪模块的信号接回这里（它只发信号，不许自己去说话 —— 见 pet_mood.gd 头部）
	_host._mood.sulk_timeup.connect(on_sulk_timeup)
	_host._mood.giving_up.connect(on_mood_giving_up)
	_host._mood.reconcile_check.connect(on_reconcile_check)
	_host._mood.touch_line.connect(on_touch_line)
	_host._mood.touch_overflow.connect(on_touch_overflow)

## 每帧：选择框 8 秒没点就自己收掉
func tick() -> void:
	if _box != null and _box.visible and _hide_ms > 0 and Time.get_ticks_msec() > _hide_ms:
		_hide_comfort()

# -------------------------------------------------- 被理 / 被摸的入口（宿主壳转发到这）

## 被摸到了（部位判定见 pet_pointer 的 classify_touch / 分寸见 pet_mood.gd）
func touch_react(part: String) -> void:
	# 生气 / 伤心（在闹情绪）时点击她：不给正常互动，要哄（2026-10-01 用户要求"生气的时候不给点击"）。
	# 随机弹「哄她」选择框；没弹中的那几下冷冷一句，还是不给互动。
	# **开心 / 平常心时点击 = 正常摸头**（用户要求"开心时不给选择框、只是普通互动"）
	var r: String = sulk_click_reaction(_host._mood.is_upset(), _host._rng.randf())
	if r == "comfort":
		_show_comfort()
		return
	if r == "cold":
		_host._say(pick_line(SULK_COLD_LINES))
		return
	_host._touch.react(part)

## 她正在闹情绪（生气 / 伤心）时点她，这一下该给什么反应。static：探针直接试（不依赖场景/随机）。
## dice < 0 = 不掷骰子、直接判成"弹选择框"
static func sulk_click_reaction(upset: bool, dice: float) -> String:
	if not upset:
		return "pet"
	if dice >= 0.0 and dice >= SULK_COMFORT_CHANCE:
		return "cold"
	return "comfort"

## 被理了就消气。聊天、摸头、喂食都算 —— 别让她记仇记到没人愿意搭理她
func soothe() -> void:
	_host._mood.soothe()
	_host._shortterm.answered()

## 菜单「哄哄她」：走和"被理了"同一条路 + 一句软话
func soothe_her() -> void:
	var was_muted: bool = _host._mood.is_muted()
	soothe()
	if was_muted:
		_host._say(pick_line(PetMood.LINES_SOOTHED))
	else:
		_host._say("……我没生气呀。")

## 从一串台词里随手挑一句（pet_touch 也通过 _host._pick_line 走到这里）
func pick_line(lines: Array) -> String:
	return String(lines[_host._rng.randi_range(0, lines.size() - 1)])

# -------------------------------------------------- 情绪信号回调

## 连着被冷落到顶：她**不主动开口了**，这里只说最后一句
func on_mood_giving_up() -> void:
	_host._say(pick_line(PetMood.LINES_GIVE_UP))

## 闭嘴超过 30 分钟还没哄她：偷偷看一眼你在忙什么，在忙就自我和解 + 存情绪记忆
func on_reconcile_check() -> void:
	var fg: String = _host._peek.foreground_text()
	if fg == "":
		_host._mood.restart_muted_wait()
		return
	_host._mood.soothe()
	_host._shortterm.answered()
	_host._say(pick_line(PetMood.LINES_RECONCILED))
	if _host.memory_enabled and _host.memory != null:
		var dt := Time.get_datetime_dict_from_system()
		var when := "%d月%d日" % [int(dt["month"]), int(dt["day"])]
		_host.memory.add("她 %s 看到主人忙着「%s」，本来在生闷气，就自己消了气、不闹了。" % [when, fg],
			0.0, PetMemory.KIND_MOOD)
		_host.memory.save()

## 该生闷气了（pet_mood.gd 判出来的）：委屈度它已经加过，这里只负责**开口**
func on_sulk_timeup(first: bool) -> void:
	# 短期记忆在这儿结算：提过还是没人理的 → 忘；没提过的 → 一半概率留着再提、一半当场忘
	var missed: int = _host._shortterm.settle_ignored(
		_host.memory if (_host.memory_enabled and _host.memory != null) else null)
	if missed > 0 and OS.is_debug_build():
		print("[PetDeek] 短期记忆：%d 句没人接的话忘掉了（只留情绪）" % missed)
	# 第一次被冷落时先偷看一眼屏幕，然后让她自己看着办（后面几次就不看了，白花一次请求）
	if first and _host._vision_ready() and _host._vision.backend_reachable() and not _host._ai_busy():
		var shot: String = _host._peek_screen()
		if shot != "":
			_host._begin_stream_bubble()
			_host._last_origin = "sulk_peek"
			_host._refresh_persona(PROMPT_SULK_PEEK)
			if _host._send_first(PROMPT_SULK_PEEK, shot):
				return
			_host._chat_streaming = false
	if _host._chat != null and _host._chat.backend_reachable() and not _host._ai_busy():
		_host._begin_stream_bubble()
		_host._last_origin = "sulk"
		_host._refresh_persona(PROMPT_SULK)
		if _host._send_first(PROMPT_SULK):
			return
		_host._chat_streaming = false
	_host._say(pick_line(PetMood.LINES_SULK))

## 摸到了要说一句（attack = 摆脸色，worth_noting = 值得记一笔）
func on_touch_line(line: String, attack: bool, worth_noting: bool) -> void:
	_host._touch.on_line(line, attack, worth_noting)

## 摸得太频繁 → 她主动开口喊停（为什么走"她自己开口"那条路，见 pet_touch.gd）
func on_touch_overflow() -> void:
	_host._touch.on_overflow()

# -------------------------------------------------- 哄她选择框

func _show_comfort() -> void:
	var anchor := _host.get_node_or_null("UI/Anchor") as Control
	if anchor == null:
		return
	if _box == null:
		_box = VBoxContainer.new()
		_box.name = "SulkComfort"
		_box.add_theme_constant_override("separation", 3)
		_box.alignment = BoxContainer.ALIGNMENT_CENTER
		anchor.add_child(_box)
	for b in _btns:
		# 先摘下来再 free：queue_free 要帧末才删，同帧新旧并存会多出旧按钮
		if b.get_parent() != null:
			b.get_parent().remove_child(b)
		b.queue_free()
	_btns.clear()
	var opts := SULK_COMFORT_OPTIONS.duplicate()
	opts.shuffle()
	opts = opts.slice(0, 3)
	for text in opts:
		var b := Button.new()
		b.text = String(text)
		b.add_theme_font_override("font", _host._cjk_font)
		b.add_theme_font_size_override("font_size", 12)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.pressed.connect(_on_comfort_picked.bind(String(text)))
		_box.add_child(b)
		_btns.append(b)
	# 贴在气泡下沿（气泡高度随文字变，所以每次现算）
	_box.position = Vector2(2.0, _host._bubble.position.y + _host._bubble.size.y + 2.0)
	_box.visible = true
	_hide_ms = Time.get_ticks_msec() + 8000
	_host._invalidate_passthrough()

func _on_comfort_picked(_text: String) -> void:
	_hide_comfort()
	soothe_her()

func _hide_comfort() -> void:
	if _box != null:
		_box.visible = false
	_hide_ms = 0
	_host._invalidate_passthrough()
