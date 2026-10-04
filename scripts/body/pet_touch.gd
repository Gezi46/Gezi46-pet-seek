# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 「被摸到的反应」：摸头 / 摸胸 / 摸手……她说什么、播什么动作、要不要记一笔。
##
## 从 desktop_pet.gd 搬出来（作业单 B6.1）。为什么值得独立：这是**一条完整的互动链** ——
## 判定全在 pet_mood.gd（哪句台词、生不升级、算不算太频繁），而"说出口 + 播动作 +
## 落进长期记忆 + 收不住时她自己开口喊停"这一段住在主脚本里，和装配/生命周期无关。
##
## 与宿主的分工（三样**跨不过来**的东西在 setup 时传进来）：
##   - `prompt` = 宿主那条 `PROMPT_TOUCH`、`emotes` = 宿主的 `EMOTE_NAMES`；
##     脚本常量在弱类型引用下取不到（见 CONVENTIONS.md），只能传
##   - 宿主的其余部分是普通字段和方法，直接读写：`_mood` / `_say` / `_play_action` /
##     `_begin_stream_bubble` / `_send_first` / `memory` …
##   - mood 模块的常量（`LINES_TOUCH_STOP` / `NOTE_TOUCH` / `TOUCH_BURST_LIMIT`）**直接
##     preload pet_mood.gd 取** —— 那是平级模块，不构成循环
##
## 接口面：说话、播动作、写长期记忆、开一次流式请求（"她自己开口"那条路）。
## 不碰文件、不碰网络、不发信号
extends RefCounted

const PetMood := preload("res://scripts/body/pet_mood.gd")

var _host = null
var _prompt := ""
var _emotes: Array = []

func setup(host, prompt: String, emotes: Array) -> void:
	_host = host
	_prompt = prompt
	_emotes = emotes

## 被摸到了。部位由 scripts/pet_pointer.gd 的 classify_touch 判出来：
## head / chest / hand / leg / body（菜单里的「摸摸头」没有坐标，默认就是 head）
##
## 分寸感是那块的重点（摸到胸要**明确地不乐意**，反复手欠会累积成生闷气），
## 但"哪句台词、升不升级、算不算太频繁"全在 pet_mood.gd —— 这里只是转手
func react(part: String) -> void:
	_host._mood.touch(part)

## 摸到了要说一句。attack = 摸到不该摸的地方（先摆脸色再说话）；
## worth_noting = 屡教不改，值得让她记一笔（以后她会自己防着点）
func on_line(line: String, attack: bool, worth_noting: bool) -> void:
	if attack:
		# add() 之后要自己 save()：这个 API 的约定是"调用方负责存"
		if worth_noting and _host.memory_enabled and _host.memory != null:
			_host.memory.add(PetMood.NOTE_CHEST)
			_host.memory.save()
		_host._play_action("attacked" if _host._has.has("attacked") else _host._idle_anim, 0.1)
		_host.go_idle()
		_host._say(line)
		return
	# 其他部位都算亲昵：随手播个动作（有一半概率什么都不播），然后说那句
	# 注意：宿主是弱类型 → 这两行都不能用 `:=` 让它推断（见 CONVENTIONS.md 那条规矩）
	var roll: float = _host._rng.randf()
	if roll < 0.5 and _host._has.has("swing_hand"):
		_host._play_action("swing_hand", 0.1)
	elif roll < 0.8:
		var em: String = _host._pick(_emotes, "")
		if em != "":
			_host._play_action(em, 0.15)
	_host.go_idle()
	_host._say(line)

## 摸得太频繁（pet_mood.gd 数出来的）：她**主动开口**让你停手，并把这事记进长期记忆。
##
## 为什么走"她自己开口"这条路（_last_origin = "touch"）而不是直接 _say 一句：
## 那样只是在气泡里闪一句、看完就没了。走这条路她会真的开一次口 ——
## 有快速回答按钮（"好啦不摸了"）、会被算进"主人多久不理我"（你还不理她就接着生闷气）、
## 记忆那边也按"她自己说的"来处置
func on_overflow() -> void:
	_host._play_action("attacked" if _host._has.has("attacked") else _host._idle_anim, 0.1)
	_host.go_idle()
	# 记忆这一笔用**本地规则**先落下：不管 AI 通不通、花不花那次请求，这事都得记住。
	# 半小时内不重复记（和生闷气共用同一条"烦了"的节流），否则一晚上能存十条同义句
	if _host.memory_enabled and _host.memory != null and _host._mood.should_store_touch():
		_host.memory.add(PetMood.NOTE_TOUCH, 0.15)
		_host.memory.save()
		if OS.is_debug_build():
			print("[PetDeek] 被摸烦了 → 已记进长期记忆")
	if OS.is_debug_build():
		print("[PetDeek] 摸得太频繁（一分钟内到 %d 下）→ 她主动开口（委屈度 %.1f）" % [
			PetMood.TOUCH_BURST_LIMIT, _host._mood.level()])
	# 后端不可用 / 正忙：退本地台词，但"开始等她回话"这一步不能少 ——
	# 和生闷气一个待遇，你还不理她就会接着闹
	if _host._chat == null or _host._ai_busy() or not _host._chat.backend_reachable():
		if _host._chat != null:
			_host._chat.probe_now()
		_host._say(_host._pick_line(PetMood.LINES_TOUCH_STOP))
		_host._mood.start_waiting()
		return
	_host._begin_stream_bubble()
	_host._last_origin = "touch"
	_host._refresh_persona(_prompt)
	if not _host._send_first(_prompt):
		_host._chat_streaming = false
		_host._say(_host._pick_line(PetMood.LINES_TOUCH_STOP))
		_host._mood.start_waiting()
