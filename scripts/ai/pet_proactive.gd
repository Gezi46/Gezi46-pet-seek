# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 「她自己开口」那一条 —— 计时、四档频率、开口前的门禁、以及真正把话说出去。
## （2026-09-29 第③条：用户要"主动对话单做模块"，顺带把短期记忆的消费点收进来）
##
## 为什么值得单独一块：它是**唯一不由主人输入驱动**的说话路径
## （打字聊天 / 摸她 / 派活都是你先动手）。所以它自带一套节奏和门禁：
##   节奏：倒计时（基准 self_talk_after，四档频率按它缩放；抽法见 rand_delay）
##   门禁：主动说话总闸 / 生气闭嘴（pet_mood.is_muted）/ 离线 / 正忙 / 面板开着 / 气泡还在
##   内容：概率性"先瞥一眼屏幕"拿着画面找话题（pet_peek）；
##         另外消费短期记忆 —— 上一回没人接住的那句，一半概率在这儿再提一次（pet_shortterm）
##
## 宿主留的壳（菜单 / 设置面板 / 探针都按老名字调）：
##   talk_span_for / talk_span / _ask_proactive / _check_self_talk / _proactive_due_now
##
## 模块只碰宿主这些成员（**全是动态访问**，宿主里改名之前先看这一行）：
##   self_talk_enabled / self_talk_after / _proactive_on / _proactive_peek_on / _chat /
##   _chat_streaming / _camera_busy / bubble / _peek / _shortterm / _mood / _offline() /
##   _ai_busy() / _ui_panel_open() / _say() / _say_local() / _begin_stream_bubble() /
##   _refresh_persona() / _send_first() / _last_origin / _opts_kind_override / _rng

extends RefCounted

## 主动搭话的提示词。后端把它当普通用户消息，交给 LLM 自己找话题。
## 注意写的是"别回答我这句话"—— 不写清楚的话，她会把括号里的说明当问题来答
const PROMPT_PROACTIVE := "（别回答我这句话，自己找个话题跟主人说一句，一两句就好，像随口聊天）"

## 频率档上限（0 很少 / 1 普通 / 2 频繁 / 3 很频繁）。
## 档位的**名字**留在宿主（TALK_RATE_NAMES，菜单和设置面板在用），这里只管时长
const RATE_MAX := 3
## 高峰时段主动开口的间隔乘这个系数（"大幅度减少"，2026-09-29 用户要的开关）。
## 普通档 5~15 分钟 → 高峰 25~75 分钟；很频繁档 40 秒~1.5 分钟 → 高峰 3~7.5 分钟
const PEAK_SCALE := 5.0

## 高峰判定（纯函数，static 供探针直接验）：**DeepSeek API 官方峰谷定价的高峰时段**
## （2026-08-17 起，北京时间）—— 工作日 9:00–12:00 和 14:00–18:00；周末全天低谷
## （2026-08-23 起周六日统一按低谷价）。weekday 口径同 Godot：0=周日 … 6=周六。
## 参考：深度求索调价公告（空闲时段价格为高峰一半）+ 8月22日"周末统一低谷价"调整
static func peak_active(hour: int, weekday: int, enabled: bool) -> bool:
	if not enabled:
		return false
	if weekday < 1 or weekday > 5:      # 周六日全天不算高峰
		return false
	return (hour >= 9 and hour < 12) or (hour >= 14 and hour < 18)

var host: Node = null
## 当前档位
var rate: int = 1
## 距离"她闲得慌自己开口"还有多久（秒）
var timer: float = 0.0
## 取"现在"本地时间的函数。做成变量是给探针换固定时刻用的（高峰那段不这样没法离线验）
var clock: Callable

func setup(h: Node) -> void:
	host = h
	clock = func() -> Dictionary: return Time.get_datetime_dict_from_system()
	timer = rand_delay()

## 换档。**重数倒计时由调用方决定**（菜单 / 设置面板两处的时序不一样，见宿主）
func set_rate(idx: int) -> void:
	rate = clampi(idx, 0, RATE_MAX)

## 重新数一份倒计时。关掉再打开、换档、改设置之后都要重数 ——
## 不重数的话，停用期间攒下的时间会在打开的瞬间就触发
func reschedule() -> void:
	timer = rand_delay()

## 档位 → 间隔区间（秒）。"普通"就用检查器里的 self_talk_after 当基准，
## 其余三档按它缩放 —— 这样在检查器里改了基准，四档会一起跟着变。
##
## 写成 static 是为了能**脱离场景**验证：tools/probe_memory_prompt.gd 直接拿它
## 检查四档是不是单调变短，不用去实例化整个桌宠（宿主的 talk_span_for 就转发到这儿）
static func span_for(idx: int, base: Vector2) -> Vector2:
	match idx:
		0: return Vector2(base.x * 3.0, base.y * 2.0)      # 约 15~30 分钟
		2: return Vector2(base.x / 2.0, base.y / 3.0)      # 约 2.5~5 分钟
		3: return Vector2(maxf(20.0, base.x / 8.0),
			maxf(60.0, base.y / 10.0))                     # 约 40 秒~1.5 分钟
	return base                                            # 普通

func span() -> Vector2:
	# 还没接线就给厂区间：宿主里 _apply_settings 可能**早于** setup 调到这里
	# （踩过：host=null 直接运行时崩，见 2026-09-29 冒烟）
	if host == null:
		return span_for(rate, Vector2(300.0, 900.0))
	return span_for(rate, host.self_talk_after)

## 下一次"她想开口"要等多久。注意区间两端谁大谁小不保证（缩放后可能颠倒），
## 所以这里先比一下再取随机 —— 不然 randf_range 会报参数顺序错
func rand_delay() -> float:
	if host == null:
		return 300.0      # 还没接线（理由见 span）
	var s := span()
	var lo := minf(s.x, s.y)
	var hi := maxf(s.x, s.y)
	if hi <= lo:
		return lo
	# 2026-09-27 用户要求"主动聊天频率改得随机一点"：原来是**均匀分布** ——
	# 每次间隔都落在同一段里，久了能看出"平均 X 分钟一次"的机器味。
	# 现在两步：① pow(1.7) 偏斜抽样，短的更常见（她想起什么就马上说）；
	# ② 15% 的几率抽一次明显更长的（1~2 倍上界）—— 她"专心玩自己的去了"。
	# 于是长短交错，平均还是原来那段，但看起来像真在想事情
	var d := lerpf(lo, hi, pow(host._rng.randf(), 1.7))
	if host._rng.randf() < 0.15:
		d = lerpf(hi, hi * 2.0, host._rng.randf())
	# 高峰时段 + 开关开着 → 间隔 × PEAK_SCALE：少去撞限流、少等慢响应
	if _in_peak():
		d *= PEAK_SCALE
	return d

## 现在是"AI 高峰、又开了开关"吗（口径见 peak_active）。
## 开关由宿主给（运行时、菜单里切），时段是 DeepSeek 官方高峰表、写死在 peak_active 里
func _in_peak() -> bool:
	if host == null:
		return false
	var dt: Dictionary = clock.call()
	return peak_active(int(dt["hour"]), int(dt["weekday"]), bool(host._peak_reduce_on))

## 每帧调：到点就让她开口（原来叫宿主里的 _check_self_talk）
func tick(delta: float) -> void:
	if host == null:
		return
	if not host.self_talk_enabled or not host._proactive_on or host._chat == null:
		return
	# 生气闭嘴：连着被冷落 SULK_MAX 次之后，她**不主动开口了**（2026-09-27 用户要求）——
	# 这时候倒计时照常重数，但永远不等它到点，直到被哄（见 pet_mood.is_muted / soothe）
	if host._mood.is_muted():
		reschedule()
		return
	# 假死：联系不上时她不自己开口 —— 本来这条路也会退本地台词，
	# 但那样她等于一直在"假装聊天"，断网的时候还是安静点像话
	if host._offline():
		reschedule()
		return
	# 只在"没人理她"时计时：正在聊、正在冒字、在等摄像头、气泡还没消失都算有人在互动
	if host._ai_busy() or host._chat_streaming or host._camera_busy \
			or host.bubble.is_visible() or host._ui_panel_open():
		reschedule()
		return
	timer -= delta
	if timer > 0.0:
		return
	reschedule()
	ask()

## 让她主动说一句（原来叫宿主里的 _ask_proactive）。菜单「让她主动说一句」也走这儿
func ask() -> void:
	if host == null:
		return
	if host._chat == null:
		host._say_local()
		return
	if host._ai_busy():
		host._say("等我先把这句说完～")
		return
	if not host._chat.backend_reachable():
		# 后端没起（或开局那次探活还没回来）。原来这里退的是随机本地台词，
		# 但"让她想个话题"换来一句"诶你在忙什么呀"太驴唇不对马嘴 —— 离线就说离线的事
		host._chat.probe_now()
		host._say("我现在联系不上外面…连不上就不瞎想了。")
		return
	host._begin_stream_bubble()
	host._last_origin = "proactive"     # 记忆：这轮是她自己找的话
	# 概率性"先瞥一眼屏幕"（默认开）：拿着画面找话题，比凭记忆起话头靠谱得多 ——
	# 用户 2026-09-27 要求把偷看绑到主动说话上。抓不到图就退回纯文字那条，流程不变
	var prompt := PROMPT_PROACTIVE
	var shot := ""
	if host._peek.wants_proactive_peek():
		shot = host._peek.peek_screen()
		if shot != "":
			prompt = host._peek.proactive_peek_prompt()
			# 她这轮**看见了**：记忆按"观察"那条走（选择性抽取，见 pet_memory_flow 的 observe）。
			# 但**按钮**要按"她主动搭话"挑兜底那一组 —— 所以另开一个只给按钮用的覆盖，
			# 不然模型没给候选时会摆出"看够没？"（详见宿主 _note_reply 里的说明）
			host._last_origin = "peek"
			host._opts_kind_override = "proactive"
	# 短期记忆（第②条）：**一半概率**把上一回没接着说的话再提一次 ——
	# 提过就标上"试过了"，再没人理就由 _on_sulk_timeup 忘掉（规矩见 pet_shortterm）。
	# 放在两种提示词之后、_refresh_persona 之前：偷看那条也要能带上它
	# 注意：宿主那些成员是**动态访问**的，返回值拿不到类型 → 这里必须显式标 String，
	# 不能写 `:=`（踩过：Cannot infer the type of "retry"）
	var retry: String = String(host._shortterm.retry_prompt())
	if retry != "":
		prompt += "\n" + retry
	# 主动开口也要重拼人设：她现在的时间/刚在做的事/对你的记忆都该是新的
	host._refresh_persona(prompt)
	if not host._send_first(prompt, shot):
		host._chat_streaming = false
		host._say_local()
