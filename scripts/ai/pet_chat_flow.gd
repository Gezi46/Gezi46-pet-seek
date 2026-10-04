# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 聊天那条链的**接线与流式**：每帧推进、收流、拆「她的话 + %%[候选]」、
## 收尾回执、失败/断连、菜单那行 AI 状态。
##
## 和邻居的分工：
##   `pet_chat.gd`        **客户端**：连接 / 请求 / 状态机（一次 await 都没有）
##   `pet_quick.gd`       候选按钮那一列（它自带一条独立连接）
##   `pet_memory_flow.gd` 记忆的收尾与筛选
##   **本文件**           把上面几样接到宿主上：信号怎么接、流怎么进气泡、
##                        失败时说什么、菜单那行状态怎么填
##
## 为什么留壳在宿主：`_on_chat_token` / `_on_chat_replied` 这些是**信号回调**，
## 在 `_setup_chat` 里按老名字连的；`split_options` 还被 tools/probe_memory.gd 直接试。
## 壳挪走会让"信号连到哪"更难查（和 pet_pointer / pet_window 一个道理）。
##
## 对宿主的接口面（只列真正用到的）：
##   host._chat / host._vision / host.harness     三个客户端
##   host._quick                                  候选按钮
##   host.bubble / host._begin_stream_bubble()    气泡（流式那两块）
##   host._say() / host._say_local()              说话
##   host._push_chat_line(who, text)              聊天记录
##   host._note_reply(text, given)                记忆收尾
##   host._check_peek / _check_camera / _check_self_talk   每帧另外三条
##   host._reply_raw / _stream_shown / _reply_opts_mode / _opts_kind_override
##   host._chat_streaming / _last_origin / _offline_said   会话状态
##   host._menu_mod / chat_enabled / chat_url / hibernate_when_offline
##   host._rng / host.LINES_OFFLINE / host.OPTIONS_MARK
##   host._gpu_passthrough                        打游戏时不递候选

## 宿主（desktop_pet.gd）。弱类型：它 preload 本模块，标上就成循环 preload
var _host = null

const PetQuick := preload("res://scripts/ai/pet_quick.gd")

func setup(host) -> void:
	_host = host

# ------------------------------------------------------------------ 每帧

## 每帧推进：先喂客户端（网络状态机），再看要不要主动开口。
## 客户端全程同步、不 await —— _process 里 await 会让本帧提前返回、
## 状态机被重入，所以 pet_chat.gd 里一次 await 都没有。
func tick(delta: float) -> void:
	if _host._chat != null:
		_host._chat.tick()
	if _host._vision != null:
		_host._vision.tick()
	# dsh 那条在自己的线程里跑，这里每帧问一次"回来了没"
	if _host.harness != null:
		_host.harness.poll()
	# 快速回答：到点自动收起 + 把"让模型编候选"那条排出去（两件事都在模块里，
	# 顺序就是原来那两行代码的顺序，别挪到生闷气检查后面去）
	_host._quick.tick()
	_host._mood.tick()      # 生闷气：等主人回话超时了就发信号（原来叫 _check_sulk）
	if not _host.chat_enabled:
		return
	_host._check_peek(delta)
	_host._check_camera(delta)
	_host._check_self_talk(delta)

# ------------------------------------------------------------------ 收流

func on_token(t: String) -> void:
	# 正文后面可能跟着 "%% [候选…]"：她自己先开口那条**一定**有，普通打字聊天也**可能**有
	# （模型照着历史学的，见 pet_chat._strip_options）。这里**只把 %% 之前那段冒进气泡** ——
	# 不这么办的话，中括号和引号会跟着冒出来。最后两个字符先憋住：
	# 它可能正好是分隔符的一半（"%"）。
	#
	# ⚠️ 这一层原来**只在 _reply_opts_mode 下生效** ✗ —— 于是普通聊天里的候选直接冒了出来，
	# 一路漏进气泡和聊天框（用户 2026-09-27 报的"聊天框会卡丢"，截图里那行 `%% [...]` 就是它）。
	# 现在不管哪条路都切：`%%` 出现在行首本来就不可能是她正常说话。
	_host._reply_raw += t
	var cut: int = _host._reply_raw.find(_host.OPTIONS_MARK)
	var visible_part: String = _host._reply_raw if cut < 0 \
		else _host._reply_raw.substr(0, cut)
	if cut < 0 and visible_part.length() > 2:
		visible_part = visible_part.substr(0, visible_part.length() - 2)
	if visible_part.length() > _host._stream_shown.length():
		if not _host._chat_streaming:
			_host._begin_stream_bubble()
		_host.bubble.append_token(visible_part.substr(_host._stream_shown.length()))
		_host._stream_shown = visible_part

# ------------------------------------------------------------------ 收尾

## 把「她的话 + %% [候选]」拆开。分隔符没出现 / 候选洗不出来 → 候选为空，
## 调用方会退回原来那条路（本地那组先顶上，必要时再问模型）—— 按钮不会消失。
## 用分隔符而不用 JSON 是有原因的：她的话里一出现引号（中文引号、书名号都算）
## 就会把 JSON 弄坏，而"她的话"恰恰是最不该被格式绑住的。
## 写成 static 是为了能离线验（tools/probe_memory.gd 会试它）
static func split_options(raw: String, mark: String) -> Dictionary:
	var i: int = raw.find(mark)
	if i < 0:
		return {"say": raw.strip_edges(), "options": []}
	var say: String = raw.substr(0, i).strip_edges()
	var tail: String = raw.substr(i + mark.length()).strip_edges()
	var opts: Array = PetQuick.parse_quick_options(tail)
	# 分隔符在最前（模型没说那句话）时别把 say 弄空，至少能说点什么
	return {"say": say if say != "" else raw.strip_edges(), "options": opts}

func on_replied(text: String) -> void:
	# "她自己先开口"那条：模型把「她的话 + 主人可能接着说的话」写在同一次回答里。
	# 这里拆开 —— 前半句进气泡，候选直接交给快速回答模块，**不再发第二次请求**
	#
	# ⚠️ **不管哪条路都拆**（原来只看 _reply_opts_mode ✗）：模型会照着**历史**学这个格式，
	# 普通打字聊天里也可能吐 "%% [候选…]" —— 不拆的话那段就一路漏进气泡和聊天框
	# （用户 2026-09-27 报的"聊天框会卡丢"，截图上那行 `%% [...]` 就是它）
	_host._reply_opts_mode = false
	var split: Dictionary = split_options(text, _host.OPTIONS_MARK)
	text = String(split["say"])
	var given: Array = split["options"]
	_host._stream_shown = ""
	_host._reply_raw = ""
	_host._push_chat_line("她", text)
	# 收尾才用 _say()：完整回复 + 1.8 秒后淡出
	_host._say(text)
	# 这条路是**共用**的：文本 / 偷看 / 摄像头都会进来，只有 origin 是 chat 的才叫"打字聊"。
	# _note_reply 会把 origin 消费掉，所以先记一份
	var was_chat: bool = _host._last_origin == "chat"
	_host._note_reply(text, given)     # 记忆：按"这轮是谁引出来的"决定怎么记
	# 聊天也**概率**给快速回答。概率比主动开口低：聊天时你多半正打着字，按钮反而碍事
	if was_chat:
		_host._quick.after_reply("chat", text.strip_edges(), _host._quick_context(text))

func on_failed(msg: String) -> void:
	var was_streaming: bool = _host._chat_streaming
	_host._chat_streaming = false
	# 这条路挂了就把"她自己先开口 + 候选"那个模式**清掉** —— 不清的话，下一轮
	# （比如你打字聊的那句）会被当成分隔符格式去拆，她的话就会被截断（踩过的边界）
	_host._reply_opts_mode = false
	_host._opts_kind_override = ""
	_host._reply_raw = ""
	_host._stream_shown = ""
	_host._push_chat_line("!", msg)
	# 上游令牌失效那种错误是"提示 + 上游原文"的多行长文本，气泡装不下 ——
	# 气泡只念第一行，完整内容留在聊天面板里看
	var line: String = msg.split("\n")[0]
	if was_streaming:
		_host._say(line)
	else:
		# 主动搭话失败就退回本地台词，别把报错怼到脸上
		_host._say_local()

func on_stream_ended() -> void:
	_host._chat_streaming = false

# ------------------------------------------------------------------ 联不联得上

## 她是不是"联系不上外面"。**假死状态就认这一个判据**：聊天总开关关着（= 本来就不联网），
## 或者后端探活失败。注意开局探活要一两秒才回来 —— 那一小会儿她也算离线，
## 保守方向是对的（宁可安静，别往死服务上撞）
func offline() -> bool:
	if not _host.chat_enabled:
		return true
	return _host._chat == null or not _host._chat.backend_reachable()

## 探活结果变了：更新菜单那行状态；断网时说一句（只说一次，别每次探活失败都念叨）
func on_reachable(ok: bool) -> void:
	sync_ai_status()
	if ok:
		if _host._offline_said:
			_host._offline_said = false
			_host._say("诶，好了！刚才像断线了一小会儿。")
		if OS.is_debug_build():
			print("[桌宠] AI 服务恢复：%s" % _host.chat_url)
		return
	if OS.is_debug_build():
		print("[桌宠] AI 服务不可达：%s（她进假死：只剩基础功能）" % _host.chat_url)
	if _host.hibernate_when_offline and not _host._offline_said and not _host.bubble.is_visible():
		_host._offline_said = true
		_host._say(_host.LINES_OFFLINE[_host._rng.randi_range(0, _host.LINES_OFFLINE.size() - 1)])

## 刷新菜单里那行"AI 服务：…"（开机 / 探活变化 / 改完设置之后都会走一遍）
func sync_ai_status() -> void:
	if _host._menu_mod == null:
		return
	if not _host.chat_enabled:
		_host._menu_mod.set_ai_status("聊天总开关关着")
	elif offline():
		_host._menu_mod.set_ai_status("联系不上（她先只做基础动作）")
	else:
		_host._menu_mod.set_ai_status("已连接")
