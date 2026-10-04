# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 记忆流程：把"记什么、什么时候叫模型、回来了怎么落库"这一摊从主控里搬出来。
##
## 和 pet_memory.gd 的分工（别混）：
##   pet_memory.gd   —— **记忆本身**：档案卡 / 遗忘曲线 / 分层 / 检索 / 存档 / 提示词模板。
##                      它是个纯数据的模块，不认识桌宠
##   本文件          —— **什么时候记、记哪条**：一轮聊完的收尾、她主动说话时的筛选、
##                      后台那条"抽事实 / 更新摘要"的节奏与认领
## 因此 `memory`（那个对象）**仍然由主控持有**（拼人设、状态显示都要用）——
## 主控把它递进来，本模块只负责按规则调用它
##
## 对主控的接口面（只列真正用到的，加之前先想清楚）：
##   host.memory / memory_enabled / memory_ai_extract / memory_ai_every_sec
##   host.memory_summary_every / memory_observe      设置
##   host._chat                                      后台那条非流式请求走它
##   host._offline()                                 离线时别发注定失败的请求
##   host._mood.should_store_sulk(origin)            生闷气那条该不该记
##                                                   （"委屈度"是情绪模块的状态，判据也就归它）
## 主控要把 `_chat.once_done / once_failed` 接到本模块的 task_done / task_failed
##
## 验证：`should_extract()` 写成 static，probe_memory.gd 的离线段直接试它

## 后台任务的 system 提示词。抽事实/摘要都要求它只吐 JSON，
## 解析失败也不影响聊天（见 task_failed）
const SYS := "你是记忆整理模块，只输出 JSON，不要任何解释。"

## 抽事实最少要有几个字。太短（"在吗""嗯"）没什么好记的，别浪费一次请求
const MIN_USER_CHARS := 4

## 叫模型来抽事实之前，先过这一道：时间到了没 + 这句话值不值得。
## **写成 static 是为了能离线验**（probe_memory.gd 拿几个数字直接试，不起窗口）
static func should_extract(user_msg: String, now_ms: int, next_ms: int) -> bool:
	if now_ms < next_ms:
		return false
	return user_msg.strip_edges().length() >= MIN_USER_CHARS

var _host: Node = null
## 这一轮主人说了什么（收尾时配套用）。空 = 这轮不是打字聊的（视觉/主动搭话那条）
var _last_user_msg: String = ""
## 她上一轮回了什么（日志/调试用）
var _last_reply: String = ""
## 聊了几轮（决定要不要排一次摘要）
var _exchange_count: int = 0
## 下次允许叫模型抽事实的时刻（毫秒）
var _next_ai_ms: int = 0
## 后台那条请求现在是干什么的：facts / summary / observe / 空 = 没有
var _task: String = ""
## 排着的摘要（后台只有一条连接，两件事不能并发）
var _summary_pending: bool = false

func setup(host: Node) -> void:
	_host = host

func task_busy() -> bool:
	return _task != ""

## 记忆的现状，给设置面板显示（也是"清空记忆"之后刷新的那行）
func status() -> String:
	var memory = _host.memory
	if not bool(_host.memory_enabled) or memory == null:
		return "长期记忆是关着的：她每次都像第一次见你"
	var st: Dictionary = memory.stats()
	return "记忆：%d 条（核心 %d / 重要 %d / 常规 %d），档案 %d 项" % [
		int(st["total"]), int(st["core"]), int(st["important"]),
		int(st["regular"]), int(st["profile"])]

# ------------------------------------------------------------------ 记进来

## 主人发了一句话：本地规则先抓一遍（零成本、立刻生效），
## 同时把它记成"这一轮主人说的话"——收尾时 `note_exchange` 要配套用
func note_user_message(msg: String) -> void:
	_last_user_msg = msg
	var memory = _host.memory
	if not bool(_host.memory_enabled) or memory == null:
		return
	var added: Array = memory.learn(msg)
	if not added.is_empty() and OS.is_debug_build():
		print("[桌宠] 记住了：%s" % "；".join(added))

## 一轮对话结束后收进记忆：更新工作记忆 + 让记忆衰减一次。
## 视觉/主动搭话那条不记 —— 它们没有"主人说的话"，靠 _last_user_msg 区分
func note_exchange(reply: String) -> void:
	var memory = _host.memory
	if not bool(_host.memory_enabled) or memory == null:
		return
	var user_msg := _last_user_msg
	_last_user_msg = ""
	if user_msg == "":
		return
	_last_reply = reply
	memory.note_exchange(user_msg, reply)
	_maybe_extract(user_msg, reply)

## 把"她自己说的"选择性收进记忆。四道筛子，逐层收紧：
##   1. 太短 / 中文实字太少（"嗯嗯""嘿嘿"）直接不记 —— 也省掉后面的模型调用
##   2. 同一句说过就不再重复记（pet_memory.add() 里按文本比对）
##   3. 重要度 + 遗忘曲线：信息量低的会自己淡掉、被清掉。这是最后一道，
##      也是"选择性"真正落地的地方（直接把 giftia 那套机制用在这儿）
##   4. AI 二次筛选（memory_ai_extract 开着时）：只挑"关于主人的事实"，
##      挑不出来返回 [] —— 撒娇、感慨、玩笑就是在这一层被挡掉的
func note_observation(origin: String, reply: String) -> void:
	var memory = _host.memory
	if memory == null:
		return
	# 生闷气这条要更严一点：偶尔一句话没人接太常见了，头一次就记进记忆反而奇怪。
	# 连着被冷落（委屈度 >= 2）才值得记，而且半小时内不重复记 ——
	# 这就是"生闷气也可以选择性加入记忆"里的那个"选择性"
	if origin == "touch":
		# "被摸烦了"不在这里记：她喊停的那一刻就已经用本地规则记了一笔
		# （见主控的 _touch_complain，那句是写死的、不依赖 AI 也不花一次请求）。
		# 这里再记一遍就是同一件事存两条
		return
	if origin == "sulk" or origin == "sulk_peek":
		# 判据在情绪模块里（半小时内不重复记 + 单纯闹脾气要连着被冷落两次才记）——
		# "委屈度"是它的状态，规则跟着状态走才不会两边各存一份
		if not _host._mood.should_store_sulk(origin):
			return
	var line := reply.strip_edges()
	if not PetMemory.worth_remembering(line):
		return
	var prefix := "她偷看屏幕时看到："
	if origin == "camera":
		prefix = "她看摄像头时看到："
	elif origin == "proactive":
		prefix = "她主动聊到："
	elif origin == "harness":
		prefix = "她替主人跑了趟活，回来讲："
	elif origin == "sulk":
		prefix = "她生闷气时说："
	elif origin == "sulk_peek":
		prefix = "她看屏幕时看到："
	# **只在没有 AI 整理时才把她的原话存下来兜底**。有 AI 整理时不要存原话，两个原因：
	#   1. 那是"她自己的撒娇 / 感慨"，不是关于主人的事实 —— 存进【关于主人】会让档案变味
	#      （存档里那些"她主动聊到：喂，你今天气压好低哦……"就是这么来的）；
	#   2. 原话带着"今天 / 刚才"这种**相对时间**，存下来过几天就会被读成"昨天"
	#      （用户 2026-09-27 报的"好几天前的事记成昨天"，当时 12 条里有 11 条是这种原话）。
	# 真正该记的交给下面的 OBSERVE_PROMPT 挑（见 task_done 的 "observe" 分支，它只存挑出来的事实）
	if not bool(_host.memory_ai_extract) or _host._chat == null:
		# 种类写死 self_line：她自己的话**永远**只算"她说过什么"，不当主人的事
		# （2026-09-29 起按 kind 判，不再靠前缀猜 —— 见 pet_memory 的 KIND_* 说明）
		memory.add(prefix + line, 0.0, PetMemory.KIND_SELF_LINE)
	# **看图那几条到此为止，不抽"事实"**（2026-10-03 用户报的 bug）：截图里的内容不一定是
	# 主人真在做的事 —— 可能是视频 / 直播 / 游戏画面。之前让 OBSERVE_PROMPT 从里面抽事实，
	# 于是档案里攒了一堆"主人 9 月 X 日在玩植物大战僵尸"，她下次就当现实发生的事提起来 ✗
	# 她那句感慨仍留 self_line（上面），只是不再往上"抬"成关于主人的事实
	if origin == "peek" or origin == "sulk_peek" or origin == "camera":
		return
	if not bool(_host.memory_ai_extract) or _host._chat == null or _host._chat.once_busy():
		return
	var now := Time.get_ticks_msec()
	if now < _next_ai_ms:
		return          # 和聊天那条共用节流：不能因为她多看了几眼屏幕就多花钱
	_next_ai_ms = now + int(float(_host.memory_ai_every_sec) * 1000.0)
	var scene := "她主动找主人说话"
	if origin == "peek":
		scene = "她偷看了主人的屏幕"
	elif origin == "camera":
		scene = "她用摄像头看了主人这边"
	elif origin == "sulk":
		scene = "她主动找主人说话之后，主人很久没理她，她正在生闷气"
	elif origin == "sulk_peek":
		scene = "主人很久没理她，她偷看了一眼屏幕，看看他到底在忙什么"
	elif origin == "harness":
		scene = "主人派了件活给她，她跑完了把结论讲给主人听"
	_task = "observe"
	# 预算是**白给的**：带思考的模型（GLM 的 flash 系、deepseek-reasoner）会把预算先花在
	# reasoning_content 上，给小了正文就是空的（实测 300 就是这样，报"模型返回是空的"）。
	# 反正这几个模型不按量收费，直接给宽一点
	if not _host._chat.ask_once(SYS, PetMemory.OBSERVE_PROMPT % [
			scene, _clip(line, 400), PetMemory.today_text()], 1500):
		_task = ""

# ------------------------------------------------------------------ 叫模型干活

## 抽事实 / 更新工作记忆。走 `_chat.ask_once`（单开一条非流式连接），
## 所以**不会打断正在流的对话**。两层节奏控制：时间间隔 + 每 N 轮一次摘要
func _maybe_extract(user_msg: String, reply: String) -> void:
	var memory = _host.memory
	if not bool(_host.memory_enabled) or not bool(_host.memory_ai_extract):
		return
	if _host._chat == null or memory == null:
		return
	# 假死：离线时别发那些注定失败的抽取请求（白花时间，运气差还白花钱）
	if bool(_host._offline()):
		return
	if _host._chat.once_busy():
		return
	_exchange_count += 1
	# 先结算上轮排下的摘要：后台只有一条连接，两件事不能并发
	if _summary_pending:
		_summary_pending = false
		_task = "summary"
		if _host._chat.ask_once(SYS, PetMemory.WORKING_PROMPT % [
				memory.working_text(), PetMemory.today_text(),
				_clip(user_msg, 400), _clip(reply, 400)], 2000):
			return
		_task = ""
	if not should_extract(user_msg, Time.get_ticks_msec(), _next_ai_ms):
		return
	_next_ai_ms = Time.get_ticks_msec() + int(float(_host.memory_ai_every_sec) * 1000.0)
	_task = "facts"
	# 预算是白给的 —— 理由见上面 observe 那条的注释（带思考的模型会先吃掉它）
	if not _host._chat.ask_once(SYS, PetMemory.FACT_PROMPT % [
			_clip(user_msg, 400), _clip(reply, 400), PetMemory.today_text()], 2000):
		_task = ""
		return
	if int(_host.memory_summary_every) > 0 \
			and _exchange_count % int(_host.memory_summary_every) == 0:
		_summary_pending = true

## 后台那条回来了：按 `_task` 认出这是哪一件事
func task_done(text: String) -> void:
	var memory = _host.memory
	if memory == null:
		_task = ""
		return
	if _task == "facts":
		var n: int = memory.apply_extracted_facts(PetMemory.parse_json_array(text))
		if n > 0 and OS.is_debug_build():
			print("[桌宠] AI 记忆抽取：存了 %d 条" % n)
	elif _task == "summary":
		var d := PetMemory.parse_json_object(text)
		var topics: Array = []
		if typeof(d.get("open_topics")) == TYPE_ARRAY:
			topics = d["open_topics"]
		memory.apply_working_summary(String(d.get("summary", "")), topics,
			String(d.get("current_emotion", "")))
		if OS.is_debug_build():
			print("[桌宠] 工作记忆已更新")
	elif _task == "observe":
		# 从她"主动搭话 / 偷看屏幕"那句话里，只挑出关于主人的事实；
		# 模型觉得没东西可记就返回 []，那就是这一轮什么都没留下（正常）
		var n: int = memory.apply_extracted_facts(PetMemory.parse_json_array(text))
		if OS.is_debug_build():
			print("[桌宠] 观察进记忆：模型挑出 %d 条" % n)
	_task = ""

## 后台任务失败只打日志：聊天本身不受影响，也不该弹提示打扰主人
func task_failed(msg: String) -> void:
	_task = ""
	if OS.is_debug_build():
		print("[桌宠] 记忆后台任务失败（不影响聊天）：%s" % msg)

## 提示词里塞原话就行，但别把一整篇长文丢进去
func _clip(s: String, n: int) -> String:
	var t := s.strip_edges()
	return t.substr(0, n) if t.length() > n else t

const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")
