# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 记忆 / 人设 / 上下文的**宿主侧**：建记忆、拼人设、每轮的上下文、
## 「这句话该不该记」的总谱，以及几个"客户端现在能不能用"的小判定。
##
## 三个邻居的分工（别混）：
##   `pet_memory.gd`       **记忆本身**：档案卡 / 遗忘曲线 / 分层 / 检索 / 存档
##   `pet_memory_flow.gd`  **什么时候记、记哪条**：一轮收尾、她主动说话时的筛选、
##                         后台"抽事实 / 更新摘要"的节奏与认领
##   **本文件**            把它们接到宿主上：读哪几个开关、拼进哪个客户端、
##                         这一轮的话该从哪条路记下去
##
## 为什么要留在宿主留一层壳：`pet_touch` / `pet_peek` / `pet_mood_ui` / `pet_quick`
## 都是按 `host._refresh_persona(...)` / `host._ai_busy()` 这类**老名字**调进来的，
## 壳挪走只会让"谁在调谁"更难追（和 pet_pointer / pet_window 同一个道理）。
##
## 对宿主的接口面（只列真正用到的）：
##   host.memory / host.memory_enabled / host.memory_observe      记忆对象与开关
##   host._memory_flow                                            收尾 / 筛选
##   host._chat / host._vision / host.harness                     三个客户端
##   host.chat_persona_name / host.chat_system_prompt             人设参数
##   host._mood / host._state / host._chat_streaming              当前状态
##   host._quick / host._gpu_passthrough                          候选按钮
##   host._shortterm                                              短期记忆
##   host._last_origin / host._last_talk_ms / host._opts_kind_override  会话状态
##   host.vision_model / host.vision_access_key / host.chat_access_key   看图判定
##   host._clip() / host._quick_context()                         宿主留着的工具

## 宿主（desktop_pet.gd）。弱类型：它 preload 本模块，标上就成循环 preload
var _host = null

## 这两个是"数据 + 纯函数"型的邻居，preload 它们不会绕回宿主（没有循环依赖）
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")
const PetPersona := preload("res://scripts/ai/memory/pet_persona.gd")

func setup(host) -> void:
	_host = host

# ------------------------------------------------------------------ 建 / 读

## 建记忆并在开局把它读回来。**必须在 _setup_chat 之前调** ——
## 拼人设时要拿它往里塞记忆
func setup_memory() -> void:
	if not _host.memory_enabled:
		return
	_host.memory = PetMemory.new()
	_host.memory.load_from_disk()
	if _host.memory.last_error != "" and OS.is_debug_build():
		print("[PetDeek] 记忆：%s" % _host.memory.last_error)
	if OS.is_debug_build():
		var st: Dictionary = _host.memory.stats()
		print("[PetDeek] 记忆：%d 条（核心 %d / 重要 %d / 常规 %d），档案 %d 项" % [
			int(st["total"]), int(st["core"]), int(st["important"]),
			int(st["regular"]), int(st["profile"])])

# ------------------------------------------------------------------ 人设

## 重新拼她的人设（系统提示词）。**只拼"她是谁"这一半** ——
## 记忆 / 现在 / 常识归 context_for()，附在历史后面。
##
## 为什么不在这儿一次拼完：那几样每轮都变，混进来这个系统提示词就每轮都变，
## 而**服务商的前缀缓存是按"逐字相同的最长前缀"算的** —— 它一变，后面的历史全部按原价。
## 所以这里必须逐字稳定：同样的人设参数拼出来的字节永远一样。
## （`_user_text` 参数留着兼容调用点，已经不再参与拼装 —— 检索挪到每轮的上下文里了）
func refresh_persona(_user_text: String = "") -> void:
	if _host._chat == null and _host._vision == null:
		return
	var text: String = PetPersona.build({
		"name": _host.chat_persona_name,
		"extra": _host.chat_system_prompt,
	})
	if _host._chat != null:
		_host._chat.system_prompt = text
	if _host._vision != null:
		_host._vision.system_prompt = text

# ------------------------------------------------------------------ 每轮的上下文

## 这一轮的上下文（关于主人 + 现在 + 常识）—— 由 PetChat 的 context_provider 回调进来。
## 它被附在**历史之后、这一句之前**，所以前面那一大段（人设 + 历史）的缓存不会被动到。
## 两个客户端都用它：文本那条和看图那条（她偷看屏幕时也得记得主人是谁）
func context_for(query: String) -> String:
	var now_ms := Time.get_ticks_msec()
	# 距上次说话多少分钟。-1 = 还不知道（别给她这个数，免得她编"我们好久没聊了"）
	#
	# ⚠️ **来源只有一份**：记忆里那条 `last_chat`（持久、写在你跟她聊天时）——
	# 以前这里用的是本次运行的 `_last_talk_ms`，而记忆那边另有一句"上次和主人说话是…"，
	# 两个数会在同一段提示词里打架（"2 小时前" vs "5 小时"，2026-09-27 审出来的）。
	# 没开记忆 / 还没聊过时，才回落到会话计时（它重启就归零，所以只是兜底）。
	# "多久以前"的算法走 memory.hours_since（单一真源），宿主自己不写时间戳减法
	var gap_min := -1
	if _host.memory != null and _host.memory_enabled and int(_host.memory.last_chat) > 0:
		gap_min = int(_host.memory.hours_since(float(_host.memory.last_chat)) * 60.0)
	elif _host._last_talk_ms > 0:
		gap_min = int((now_ms - _host._last_talk_ms) / 60000)
	_host._last_talk_ms = now_ms
	return PetPersona.build_context({
		"user_text": query,
		"memory": _host.memory if _host.memory_enabled else null,
		"state_text": pet_state_text(),
		"mood": _host._mood.mood_name(_host._mood.mood()),  # 当前心情（生气/伤心/开心/坏心眼/平常）
		"sulk": _host._mood.level(),   # 生闷气也进上下文，她的口气才接得上（见 pet_persona）
		"gap_min": gap_min,            # 距上次说话多久 —— 配合 PetPersona.now_line() 的实时时间
		"started_at": _host._started_at,   # 几点启动的，让她对"启动"有概念
	})

## 她"刚在做什么"。写进人设的【现在】那一段，让回复带点当下的小动作，
## 而不是永远用同一副口气
func pet_state_text() -> String:
	if _host._chat_streaming:
		return "正在跟主人说话"
	match _host._state:
		_host.State.SLEEP: return "刚才在睡觉，刚醒或者正打盹"
		_host.State.DRAG: return "刚被主人拎起来挪了个地方"
		_host.State.WALK: return "刚在屏幕边上溜达"
	return "趴在桌面上发呆"

# ------------------------------------------------------------------ 一轮说完的收尾

## 一轮回复收尾：按"这轮是谁引出来的"决定记忆怎么记。
## **这段是总谱，它同时要处置快速回答和"她在等你回话"的计时**，
## 不只记忆一件事（收尾 / 筛选规则在 pet_memory_flow.gd）：
##   打字聊天 → 整轮记下来
##   主动搭话 / 偷看屏幕 / 看摄像头 → **选择性**地记
## 为什么必须分开：后三条每天会产生好几条，而且大多没信息量（"嗯嗯～""嘿嘿"），
## 整轮存进去会把档案冲成流水账，反而把真正重要的事挤掉
func note_reply(reply: String, given: Array = []) -> void:
	var origin: String = _host._last_origin
	_host._last_origin = ""
	if origin == "" or origin == "chat":
		_host._memory_flow.note_exchange(reply)
		# 万一模型在普通聊天里也吐了候选（它照着历史学的）：别浪费，直接当按钮摆出来 ——
		# 顺带省掉一次"让模型编候选"的后台请求（见 _on_chat_replied 里那段说明）
		if not given.is_empty():
			_host._quick.show_given("chat", reply.strip_edges(), given)
		return
	# 她主动开的口（自己找话题 / 偷看 / 生闷气 / 被摸烦了）→ 给几个"快速回答"按钮。
	# 放在这儿而不是发送那一侧：要等她真说完、气泡撑好了，按钮才贴得住气泡下沿。
	# 生闷气和"偷看式生闷气"用的是同一套哄她的选项，所以对外都报 sulk；
	# 被摸烦了有它自己那一组（"好啦不摸了"）
	var kind := origin
	if origin.begins_with("sulk"):
		kind = "sulk"
	# ⚠️ `origin` 要伺候两个不同的消费者，别混：
	#   · 记忆：按 origin 给"情境"（"她偷看了主人的屏幕" vs "她主动找主人说话"）——见 pet_memory_flow
	#   · 按钮：按 kind 挑本地那组兜底（kind=="peek" → "哈哈被你发现了 / 看够没？"）
	# "主动开口时顺带瞥了一眼"那一轮两者会打架：记忆该按 peek 记（她确实看到了），
	# 可按钮要按"她主动搭话"给，否则模型没给候选时摆出"看够没？"（2026-09-27）
	if _host._opts_kind_override != "":
		kind = _host._opts_kind_override
	_host._opts_kind_override = ""
	# given 非空 = 候选已经**跟着那句话一起**给出来了（她自己先开口那条，见 _send_first）——
	# 那就直接用，不再为按钮多发一次请求
	# GPU 自动透视中（打游戏）：**一律不递候选按钮**（2026-10-03 用户要求）。
	# 判断放这一层：要不要给按钮本来就是宿主的决定。pet_quick 那边也留了一道
	# （after_reply / show_given 开头都看 _gpu_passthrough），双保险
	if not _host._gpu_passthrough:
		if not given.is_empty():
			_host._quick.show_given(kind, reply.strip_edges(), given)
		else:
			# 概率出现。她主动开口这条给得高一些 —— 那是"她在等你接话"的场合
			_host._quick.after_reply(kind, reply.strip_edges(), _host._quick_context(reply))
	# 露过脸了就开始算"主人多久不理我" —— 回头还没反应就生闷气（见 pet_mood.gd 的 tick）
	_host._mood.start_waiting()
	# 短期记忆：她这轮说的这句先**挂着**，等主人接（第②条）——
	#   接了（打字 / 点候选按钮 / 摸她 / 哄她）→ _soothe() 里清掉，一句话不留；
	#   没人接（_on_sulk_timeup）→ 一半概率下次再提一次、一半概率当场忘，忘也只留情绪
	var mp: Array = PetMemory.analyze_mood(reply)
	_host._shortterm.hold(reply, kind, int(mp[0]), float(mp[1]))
	# 偷看那条**不在这里改委屈度**了：看到什么、要不要消气，她自己那句话里已经交代了
	# （原委见 PROMPT_SULK_PEEK 那段注释）。委屈度就按"被冷落了几轮"继续累着 ——
	# 你哪次真回她了，_soothe() 会一次性清零
	if not _host.memory_enabled or not _host.memory_observe or _host.memory == null:
		return
	_host._memory_flow.note_observation(origin, reply)

# ------------------------------------------------------------------ 客户端能不能用

## 看图那条现在能不能用：客户端在 + **配了视觉模型**。
## `vision_model` 留空就是关掉看图（AI 面板里就是这么写的）—— 以前只判 `_vision != null`，
## 于是留空之后照样截屏、照样把图发出去：**截图白截、图还白算 token**
## （本地网页版后端压根看不到图，等于每次偷看都白花一笔）
func vision_ready() -> bool:
	return _host._vision != null and _host.vision_model.strip_edges() != ""

## 视觉那条的 key：没单独配就复用文本那条的
func vision_key() -> String:
	return _host.vision_access_key if _host.vision_access_key.strip_edges() != "" \
		else _host.chat_access_key

## 文本 / 视觉 / dsh 任一条在忙。三者共用同一个气泡，所以判断"她是不是正忙着"
## 必须一起看 —— 只看 _chat 的话，视觉那条正在出字时会被插话打断
func ai_busy() -> bool:
	return (_host._chat != null and _host._chat.is_busy()) \
		or (_host._vision != null and _host._vision.is_busy()) \
		or (_host.harness != null and _host.harness.busy)
