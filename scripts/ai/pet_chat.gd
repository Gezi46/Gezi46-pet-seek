# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 桌宠的对话客户端 —— **编排层**（OpenAI 兼容协议）
##
## 一句话：本文件只管"什么时候发、收到之后怎么办"；连接的实现、分片解析、地址拼装
## 都在旁边那几个模块里。2026-09-23 按作业单 B1 拆过一次（850 → 496 行），
## 拆出来的每一块都能**离线测**（这既是目的，也是"这块拆得值不值"的判据，见 CONVENTIONS.md）：
##
##   pet_conn.gd    一条连接的生命周期：连 → 发 → 收（HTTPClient 状态机）
##   pet_sse.gd     流式分片解析：`data:` 行 → 正文 / 思考 / usage / 错误
##   pet_once.gd    一次性（非流式）请求：记忆抽取 / 摘要 / 候选那条
##   pet_retry.gd   429（模型太挤）自动重试：只决定"重发哪条、什么时候"
##   pet_net.gd     地址解析 / 请求头 / 请求体 / messages 拼装（纯 static）
##   pet_probe.gd   探活：`{base}/models` 那条 + 超时 + 可达值
##   pet_usage.gd   token 账的取值与打印（纯 static）
##
## 接口（官方 API 和本机 deepseek-web-api 都是这套）：
##   请求   POST {url}/chat/completions   url 形如 https://api.deepseek.com 或 http://127.0.0.1:8520/v1
##   鉴权   Authorization: Bearer <key>（本机那些不要 key 的后端留空即可）
##   流式   text/event-stream，每行 `data: {...}`，最后一行 `data: [DONE]`
##   分片   choices[0].delta.content（正文）/ .reasoning_content（思考）
##   探活   GET {base}/models —— 两个后端都有它（/healthz 是 deepseek-web-api 专有的，
##          换官方 API 之后那边是 404，会被判成"服务不可用" → 她永远退回本地台词，踩过）
##
## 为什么不用 HTTPRequest：它只在请求**结束**时一次性给出完整 body，
## SSE 就没法边收边显示 —— 所以用 HTTPClient 自己推状态机、每帧由 _process 调 tick()
## 推进（不 await、不起线程；_process 里 await 会让本帧提前返回、状态机重入）
##
## 四条互不排队的通道（都在本文件里编排，连接各自在模块里）：
##   _sse 流式对话（5~30 秒）｜_bg 后台一次性请求｜_probe 探活｜_retry 429 待重发
##
## 历史：原来接 giftia 后端的私有 SSE 协议，那段早没了 —— 上下文由本类按 messages 维护

extends RefCounted

## 增量文本（每个 token 一次），用来做"逐字冒出来"的效果
signal token(text: String)
## 完整回复，结束时只会发一次
signal replied(text: String)
## 出错（网络失败 / 后端返回 error / 上游令牌失效）
signal failed(msg: String)
## 一轮对话收尾（无论成功、失败还是被 cancel），用来收掉"正在输入"状态
signal stream_ended()
## 思考内容增量（deepseek-reasoner / 开了深度思考时才有），给日志面板显示用
signal thought(text: String)
## 后端可达性变化，用来提示"AI 服务没起来"
signal reachable(ok: bool)
## 一次性请求（ask_once）成功，给出模型返回的正文
signal once_done(text: String)
## 一次性请求失败
signal once_failed(msg: String)

## 连接 + 首字节超时（服务没起时会很快 CANT_CONNECT，这个主要防半死不活）
const TIMEOUT_CONNECT_MS := 10000
## 空闲超时：深度思考模式可能闷头想十几秒，别误杀
const TIMEOUT_IDLE_MS := 90000
## 探活间隔
## （探活的间隔挪进了 pet_probe.gd 的 INTERVAL_MS —— 它和那条连接的超时是一对）

## 上游令牌失效时，服务端会把错误当成普通正文吐出来。识别它并给出可操作的提示 ——
## 否则桌宠会把一段报错当回复念出来（实测就是这么回事）
## 那个标记（`[代理错误]`）现在定义在 **pet_sse.gd** 里 —— 认它的地方是解析那一层。
## GDScript 的常量不能跨脚本引用，所以这里在用到处写全名 `Sse.UPSTREAM_ERR_MARK`（见 _finish）
const HINT_TOKEN := "（我的网页端令牌好像过期了，去 deepseek-web-api 的管理页重新粘贴一下 userToken 吧）"

# ------------------------------------------------------------------ 单条连接

## 一条连接的生命周期（连 → 发 → 收）搬去了 **scripts/pet_conn.gd**（作业单 B1.1）——
## 它是纯叶子：不认识宿主、也不认识 PetChat，只认 HTTPClient。
##
## 这里用 preload 常量顶替原来的内部类，所以下面 `Conn.new()` / `Conn.DONE` / `Conn.busy()`
## 那 40 多处调用**一行都没改** —— 这也是当初把它挑出来当第一条的原因：接缝够干净、
## 行为零变化
const Conn := preload("res://scripts/ai/net/pet_conn.gd")

# ------------------------------------------------------------------ 对外状态

## 后端地址（形如 http://127.0.0.1:8520/v1，可带路径前缀）
var url: String = "http://127.0.0.1:8520/v1"
## 本地访问密钥（deepseek-web-api 管理页第 ② 栏那串，或直接填 userToken）
var access_key: String = ""
## 模型名：deepseek-chat（快速）/ deepseek-reasoner（深度思考）/ deepseek-search（联网）
var model: String = "deepseek-chat"
var enabled: bool = true
## 带上历史消息发给后端。网页端接口是"每次独立上下文"，
## 多轮记忆全靠这里把历史一起给过去，所以别设得太小
var max_history: int = 20
## 系统提示词（人格设定）。空字符串 = 不发 system 消息
var system_prompt: String = ""
## 宿主给的一个**可选**回调：这一轮要附在"历史之后、这一句之前"的上下文
## （记忆 / 现在 / 常识 —— 见 pet_persona.build_context）。
##
## 为什么不塞进 system_prompt：那几样每轮都变，塞进去的话**服务商的前缀缓存
## 从它那儿就断了**，后面的历史全部按原价算。附在历史后面的话，
## 前缀 = 人设 + 历史，一路命中，只有最后这一小段按原价。
## 回调收这一句消息、返回上下文文本；没设就当作没有上下文
var context_provider: Callable = Callable()

var _host := "127.0.0.1"
var _port := 8520
var _tls := false
var _base_path := ""

var _sse := Conn.new()
## 本文件用到的几块都在这里（作业单 B1.4 之后 pet_chat 只剩编排）：
##   pet_net    地址 / 请求头（纯 static）
##   pet_probe  探活那条连接（自带超时 + 可达值）
##   pet_usage  token 账的取值与打印（纯 static）
const Net := preload("res://scripts/ai/net/pet_net.gd")
const Probe := preload("res://scripts/ai/pet_probe.gd")
const Usage := preload("res://scripts/ai/pet_usage.gd")
var _probe := Probe.new()
## 一次性请求（记忆抽取 / 摘要）。单独一条连接，所以后台跑它不会挡住正在流的对话
## 一次性请求（记忆抽取 / 摘要 / 候选）那条整块在 **scripts/pet_once.gd**（作业单 B1.3）：
## 它自带一条连接，只负责"发出去 + 把响应原样交回来"；
## **怎么解释响应**（429 要不要原样重发、正文怎么抠）留在本文件（见 _on_bg_got）——
## 放模块里的话，重试会被信号时序绕过（先报了失败，调用方已经把任务名清掉了）
const Once := preload("res://scripts/ai/net/pet_once.gd")
var _bg := Once.new()

func _init() -> void:
	_bg.got.connect(_on_bg_got)
	_bg.failed.connect(_on_bg_failed)
	# 探活那块的"可达值变了"转成自己的 reachable 信号 —— **对外接口一个字不变**
	# （漏了这一句的话：探活照样跑、backend_reachable() 也对，但宿主的托盘 / 菜单那行
	#   "AI 服务：联系不上"永远不刷新。probe_offline 就是专门抓这个的，实测抓到过）
	_probe.reachable_changed.connect(_on_probe_reachable)

func _on_probe_reachable(ok: bool) -> void:
	reachable.emit(ok)

# ---------------------------------------------------------------- 429 自动重试

## 「撞上 429 就等会儿原样重发」这件事整块搬去 **scripts/pet_retry.gd**（作业单 B1.3）：
## 那边只管**决定**（重发哪条、还剩几次、什么时候），真正 `start()` 请求的动作留在本文件
## （`_step_retry` 里那几行）—— 那是连接层的事，搬过去反而要把它变成一个"会发请求"的重试器。
##
## 下面留了 `_remember_request` / `_schedule_retry` / `_looks_busy` 三个**薄壳**，
## 所以原来那些调用点（发请求 / 429 判断 / 收尾）一行都没改 —— 和搬 `Conn` 时同一个手法
const Retry := preload("res://scripts/ai/net/pet_retry.gd")
var _retry := Retry.new()

## 薄壳（作业单 B1.3）：真正的记账在 pet_retry.gd，这里保留原函数名，
## 所以 send / ask_once / 收尾那几处调用点一行都不用改
func _remember_request(kind: String, path: String, headers: PackedStringArray,
		body: PackedByteArray, tls: bool) -> void:
	_retry.remember(kind, path, headers, body)

func _schedule_retry(what: String) -> bool:
	return _retry.schedule(what)

## 到点了就把那条请求原样重发（宿主每帧调 tick() 时顺带推进）。
## 决定"该不该重发"在 pet_retry.gd，**真正 start() 在这里** —— 那是连接层的事
func _step_retry() -> void:
	if not _retry.due():
		return
	if _sse.busy() or _bg.busy():
		return                     # 有别的还在跑，等它
	var req := _retry.take()
	var path := String(req.get("path", ""))
	var headers: PackedStringArray = req.get("headers", PackedStringArray())
	var body: PackedByteArray = req.get("body", PackedByteArray())
	var kind := String(req.get("kind", ""))
	if kind == "once":
		_bg.start(_host, _port, path, headers, body, _tls)
	else:
		# 流式重发：把这一轮的流状态清干净（上次那半截正文不要了）
		_parser.reset()
		_stream_error = ""
		_sse.start(_host, _port, path, headers, body, _tls)
	if OS.is_debug_build():
		print("[PetDeek] 重发（%s）" % kind)

## 后端不认"关思考"这个参数（回 400）→ 把它摘掉，**之后所有请求都不再带它**。
## 这样换到别的模型（比如 glm-5.3-flashx 不认 thinking）不会因为这一项卡死，
## 代价是后面这一条请求白失败一次（错误照旧会报给用户看）
## 后端不认"关思考"这个参数（回 400）→ 把它摘掉，**之后所有请求都不再带它**。
## 这样换到别的模型（比如 glm-5.3-flashx 不认 thinking）不会因为这一项卡死，
## 代价是后面这一条请求白失败一次（错误照旧会报给用户看）
##
## 同理还有 `stream_options.include_usage`（让流式也带 token 账）：主流服务商都认
## （OpenAI 2024 起，国内几家的兼容端点也都跟了），但**少数小众 / 老后端会回 400**。
## 两个按顺序逐个摘 —— 一次 400 摘一个，都摘完还 400 那就是别的问题了（照常报错）。
func _note_unsupported(code: int, body_text: String) -> void:
	if code != 400:
		return
	if no_think:
		no_think = false
		if OS.is_debug_build():
			print("[PetDeek] 这个后端不认『关思考』（400），之后不再发它：%s"
				% body_text.substr(0, 120))
		return
	if send_usage:
		send_usage = false
		if OS.is_debug_build():
			print("[PetDeek] 这个后端不认『流式带 usage』（400），之后不再发它：%s"
				% body_text.substr(0, 120))
		return

## 薄壳：判断本身在 pet_retry.gd（那边能离线测）。**保留成 static** 是因为
## tools/probe_memory.gd 直接拿这个类来调它 —— 起窗口才能测的判断就不是好判断
static func _looks_busy(code: int, body_text: String) -> bool:
	return Retry.looks_busy(code, body_text)
## 流式分片解析（正文 / 思考 / usage / 错误）整块在 **scripts/pet_sse.gd**（作业单 B1.2）——
## 那些状态（累计正文、思考、是否已开始冒字、行缓冲）全跟着它走了。
## 它只往队列里放增量，**信号由这里发**（见 _drain_parser），所以它不依赖任何场景
const Sse := preload("res://scripts/ai/net/pet_sse.gd")
var _parser := Sse.new()
## 流级别（连接级）的错误：超时、连不上、后端没返回内容……解析器内部的报错在 _parser.stream_error
var _stream_error := ""
## 上一次**聊天**的 usage 原样收下来（服务商给的 token 账）。应用本身不靠它干活，
## 但"前缀缓存到底命中了多少"只有这里能证明 —— 见 README 的"缓存命中率"一节。
## 字段各家不一样：DeepSeek 系给 prompt_cache_hit_tokens / prompt_cache_miss_tokens，
## OpenAI 系只给 prompt_tokens_details.cached_tokens。取值统一走 cache_hit_tokens()
## （值由 _drain_parser 每帧从解析器同步过来，外面照旧读这个变量）
var last_usage: Dictionary = {}
## ask_once（抽事实 / 摘要 / 快速回答）那条的 usage，**分开存**：
## 它和聊天那条不是一回事，混在一起会把两边的命中率互相污染
var last_once_usage: Dictionary = {}
var _history: Array = []
## 探活的间隔 / 可达值 / "有没有拿到过确定答案" 全在 scripts/pet_probe.gd 里
## （连它的超时也一起搬走了 —— 那两样必须住在一起，见该文件头部）

func configure(p_url: String, p_access_key: String, p_model: String = "") -> void:
	url = p_url if p_url.strip_edges() != "" else url
	access_key = p_access_key
	if p_model.strip_edges() != "":
		model = p_model.strip_edges()
	_parse_url()

## 要不要请后端**关掉思考**（GLM 系：`"thinking": {"type": "disabled"}`）。
##
## 为什么默认开着：实测同一个 glm-4.7-flash，"说一句十个字以内的话"
##   默认（带思考）  15.3 秒，思考 515 字，**正文 0 字**（预算全被思考吃了）
##   关掉思考         1.1 秒，正文正常
## 桌宠要的是"像在发微信"的一两句话，思考换不来质量，只换来十几秒的沉默。
##
## 后端不认这个参数会回 400 —— 那时自动关掉它（见 _note_unsupported）并重新来过，
## 所以换模型不会因为这一项卡死
var no_think: bool = true
## 流式请求里带不带 `stream_options.include_usage`（换来"这一轮用了多少 token、缓存命中多少"）。
## 不带就没有那两个数，但换服务商时不会被它挡在门外 —— 后端回 400 会自动摘掉（见 _note_unsupported）
var send_usage: bool = true

func is_busy() -> bool:
	# **待重发也算忙**（_retry.pending()）。429 之后旧连接已经被 cancel 掉了，
	# 那 2.5 秒里 _sse.busy() 是 false —— 不算忙的话：
	#   1. 定时器/菜单会插进来开一条新流（她正忙却不挡）
	#   2. 然后 _step_retry 等新流跑完，把**旧请求**重发出去 → 她过几秒又冒一句
	#      驴唇不对马嘴的话（踩过）
	return _sse.busy() or _retry.pending()

func backend_reachable() -> bool:
	return _probe.reachable

## 上一轮失败的原因（供气泡/日志用）
func last_error() -> String:
	return _stream_error if _stream_error != "" else _sse.error

## 上一轮的思考内容（deepseek-reasoner 才有）
func last_reasoning() -> String:
	return _parser.reasoning

# ------------------------------------------------------------------ 每帧推进

func tick() -> void:
	if not enabled:
		return
	_step_stream()
	_step_once()
	_step_retry()          # 429 之后那条待重发的（见 _schedule_retry）
	# 探活：推它那条连接 + 到点了自己发一发。
	# 间隔 / 超时 / 可达值都在 scripts/pet_probe.gd 里（那两样必须住在一起，见该文件头部）
	_probe.tick(_host, _port, _base_path, _probe_headers(), _tls)

## 立刻探一次后端（右键菜单/开局用，不等定时器）
func probe_now() -> void:
	_probe.probe_now(_host, _port, _base_path, _probe_headers(), _tls)

## 探活那条请求的头（和普通请求一样，只是不流式）
func _probe_headers() -> PackedStringArray:
	return _headers("application/json", "application/json")

# ------------------------------------------------------------------ 发一句话

## 开始一轮对话。image_data 传 data URL（偷看屏幕时用），空字符串表示纯文字。
## 返回 false 表示上一轮还没结束（调用方该忽略这次输入）。
func send(message: String, image_data: String = "") -> bool:
	if not enabled or is_busy():
		return false
	var ctx := ""
	if context_provider.is_valid():
		ctx = String(context_provider.call(message))
	var msgs := compose_messages(system_prompt, _history, ctx, message, image_data)
	# 请求体的形状（含"让流式也带 usage""关思考"两处刻意的）在 pet_net.gd 里
	var body := Net.chat_body(model, msgs, no_think, send_usage)
	# JSON.stringify().to_utf8_buffer()：千万别用 to_ascii_buffer，中文会变成 ?
	var payload: PackedByteArray = JSON.stringify(body).to_utf8_buffer()
	# 记一份原样请求：撞上 429 要原样重发（见 _remember_request）
	_remember_request("chat", _base_path + "/chat/completions",
		_headers("application/json", "text/event-stream"), payload, _tls)
	_parser.reset()
	_stream_error = ""
	_sse.start(_host, _port, _base_path + "/chat/completions",
		_headers("application/json", "text/event-stream"), payload, _tls)
	_history.append({"role": "user", "content": message})
	_trim_history()
	return true

## 拼 messages 那套（顺序 / 上下文不进历史 / 带图的多模态格式）搬去了 **pet_net.gd**——
## 那边全是 static，能**离线量两轮之间前缀有多长**（前缀越长，前缀缓存命中越多；
## tools/probe_memory.gd 会量这个数）。这里留个同名 static 壳，
## 因为探针一直是拿 `PetChat.compose_messages()` 来量的
static func compose_messages(system_prompt: String, history: Array, context: String,
		message: String, image_data: String) -> Array:
	return Net.messages(system_prompt, history, context, message, image_data)

## 用户中途关掉聊天框就调它：把连接掐掉，状态清干净
func cancel() -> void:
	if not _sse.busy():
		return
	_sse.cancel()
	_parser.reset()
	stream_ended.emit()

# ------------------------------------------------------------------ 一次性请求

## 非流式的一次性请求：给"记忆抽取 / 摘要"这类后台小任务用。
## 连接、超时、收字节都在 **scripts/pet_once.gd** 里（作业单 B1.3）；
## 这里只做两件只有宿主才知道的事：**拼 body** 和 **解释响应**。
##
## max_tokens 默认给 2000 是**有意的**：带思考的模型会把预算先花在 reasoning_content 上，
## 给小了正文就是空的（调用方会收到"模型返回是空的"）。反正这些都是免费/不计量的模型，
## 上限给宽一点，真正花钱的是**输入**（前缀缓存那里）
func ask_once(system: String, user: String, max_tokens: int = 2000) -> bool:
	if not enabled or _bg.busy():
		return false
	var payload := Once.build_body(model, system, user, max_tokens, no_think)
	# 记一份原样请求：撞上 429 要原样重发（见 _remember_request）
	_remember_request("once", _base_path + "/chat/completions",
		_headers("application/json", "application/json"), payload, _tls)
	return _bg.start(_host, _port, _base_path + "/chat/completions",
		_headers("application/json", "application/json"), payload, _tls)

func once_busy() -> bool:
	return _bg.busy()

func _step_once() -> void:
	_bg.tick()          # 连接 / 超时 / 收字节都在模块里

## 响应回来了：**先看是不是"模型太挤"** —— 是的话原样重发，不能先报失败：
## 调用方一收到失败就把任务名清掉了，重试回来的结果就没人要了（所以这段留在这儿，
## 没跟着连接一起搬进 pet_once.gd）
func _on_bg_got(code: int, body: String) -> void:
	_note_unsupported(code, body)
	if _looks_busy(code, body) and _schedule_retry("后台"):
		return
	var r := Once.parse(body)
	if bool(r["ok"]):
		last_once_usage = r["usage"]
		once_done.emit(String(r["text"]))
		log_usage("后台", true)      # 后台那条的 token 账，和聊天那条分开看
	else:
		once_failed.emit(String(r["msg"]))

## 连不上 / 超时：这类没有"响应"可解释，直接报给调用方
func _on_bg_failed(msg: String) -> void:
	once_failed.emit(msg)

# ------------------------------------------------------------------ 流式解析

func _step_stream() -> void:
	if _sse.phase == Conn.IDLE:
		return
	_sse.poll()
	match _sse.phase:
		Conn.READING:
			_parser.feed(_sse.take())
			_drain_parser()
		Conn.DONE:
			_parser.feed(_sse.take())
			_drain_parser()
			# 模型太挤（429）：先重试，试完了才告诉她（见 _schedule_retry）
			_note_unsupported(_sse.code, "")
			if _looks_busy(_sse.code, "") and _schedule_retry("聊天"):
				_sse.cancel()
				return
			_parser.flush()          # 很短的那几句一直攒在解析器手里，收尾要补发
			_drain_parser()
			if _parser.text.strip_edges() == "":
				if _parser.stream_error != "":
					# 流里带的错（比如 GLM 的 1305）：原话比"没返回内容"有用得多
					_stream_error = _parser.stream_error
					_fail()
				elif _stream_error != "":
					_fail()          # 已经知道原因了（超时 / 连不上那种）
				else:
					# 状态码带上：401（key 不对）/ 404（地址不对）/ 429（太挤）一眼分得出来。
					# 原来那句光说"后端没返回内容"，换后端时完全没法排查
					if _sse.code == 429:
						_stream_error = "模型现在太挤了（免费额度高峰），过一会儿再跟我说一次吧"
					else:
						_stream_error = "后端没返回内容（HTTP %d）" % _sse.code
					_fail()
			else:
				_finish()
		Conn.FAILED:
			_stream_error = _sse.error
			_fail()
	if _sse.phase == Conn.READING and _sse.since_rx_ms() > TIMEOUT_IDLE_MS:
		_stream_error = "等后端回话超时"
		_sse.cancel()
		_fail()
	elif _sse.phase == Conn.CONNECTING and _sse.since_start_ms() > TIMEOUT_CONNECT_MS:
		_stream_error = "连不上 AI 服务（%s）" % url
		_sse.cancel()
		_fail()

## 把解析器攒下的增量交给信号。**信号只在这里发** —— pet_sse.gd 不认识信号，
## 只往队列里放增量（所以它能整段离线测：塞几段分片进去、看它吐出什么）
func _drain_parser() -> void:
	# 外面照旧读 last_usage（README 的"缓存命中率"那节写的就是它）
	last_usage = _parser.usage
	for t in _parser.take_tokens():
		token.emit(String(t))
	for r in _parser.take_thoughts():
		thought.emit(String(r))

## 逐行解析分片（正文 / 思考 / usage / 流里的错误 / `[DONE]`）整块搬去了
## **scripts/pet_sse.gd** 的 `_on_line()` —— 它只往队列里放增量，信号由上面的
## `_drain_parser()` 发。搬走之后 pet_chat 只剩「发请求 → 每帧推 → 收尾 / 重试」这条编排线

## 只把真正的字符串当文本；null / 数字 / 字典一律当空。
## 别用 String(v)：v 是 null 时它会抛异常（不是返回空串）。
func _as_text(v: Variant) -> String:
	return v if typeof(v) == TYPE_STRING else ""

## token 账的取值与打印都在 **scripts/pet_usage.gd** 里（纯 static，能离线测 —— 作业单 B1.4）。
## 这里留三个壳，调用点一行不用改。
## 两个 usage 变量**留在本对象**：它们是本对象的对外状态（README 的"缓存命中率"那节
## 写的就是它们），应用和探针都直接读

## 上一次聊天的**缓存命中** token（拿不到返回 -1）。字段名各家不一样，统一从这里取
func cache_hit_tokens() -> int:
	return Usage.hit(last_usage)

func cache_miss_tokens() -> int:
	return Usage.miss(last_usage)

## 把这轮的 token 账打进控制台。**只在编辑器 / 调试版里打**（正式版保持安静）。
## "命中缓存"那个数就是提示词吃到的前缀缓存 —— 排布提示词有没有效果，全看它。
## 想离线量化（不跑界面）用 tools/probe_cache.gd
func log_usage(tag: String, is_once: bool = false) -> void:
	if not OS.is_debug_build():
		return
	var line := Usage.line(tag, last_once_usage if is_once else last_usage)
	if line != "":
		print(line)      # 后端不报缓存账时 line 是空的，那就什么都不打

## 「她的话 + %% [候选…]」那个分隔符。**真源在这儿**（回复格式归客户端管），
## 宿主那边是别名（`const OPTIONS_MARK := PetChat.OPTIONS_MARK`）
const OPTIONS_MARK := "%%"

## 去掉回复里 "%% [候选…]" 那一段 —— **只给历史用**（气泡和聊天框那边另有拆分逻辑，
## 见 desktop_pet 的 _on_chat_token / _on_chat_replied）。
##
## 为什么必须去：历史是模型的**示范** ✗ —— 留着它，模型下一轮就会在普通打字聊天里
## 也吐 "%% [候选…]"，那段一路漏进气泡和聊天框
## （用户 2026-09-27 报的"聊天框会卡丢"就是这么来的）
static func _strip_options(raw: String) -> String:
	var i := raw.find(OPTIONS_MARK)
	if i < 0:
		return raw.strip_edges()
	var head := raw.substr(0, i).strip_edges()
	return head if head != "" else raw.strip_edges()

func _finish() -> void:
	if _sse.phase == Conn.IDLE and _parser.text == "":
		return
	# 还攒在解析器手里的那一小段补发掉：很短的回复（少于 [代理错误] 那个长度）会一直
	# 攒着不冒，不补的话气泡里什么都看不到（完整回复仍会走 replied，
	# 但"逐字冒"的那条路就断了）
	_parser.flush()
	_drain_parser()
	_sse.cancel()
	# 服务端把上游错误当正文吐出来（令牌过期就是这种），识别掉并给出可操作的提示。
	# 同样要去掉前导空白再判
	if _parser.text.strip_edges().begins_with(Sse.UPSTREAM_ERR_MARK):
		_stream_error = HINT_TOKEN + "\n" + _parser.text.strip_edges()
		_parser.reset()
		_fail()
		return
	if _parser.text.strip_edges() != "":
		_history.append({"role": "assistant", "content": _strip_options(_parser.text)})
		_trim_history()
		reachable_set(true)
		replied.emit(_parser.text)
		log_usage("这轮")          # 调试版里打一行 token 账（含缓存命中），正式版不打
	stream_ended.emit()

func _fail() -> void:
	_sse.cancel()
	var msg := _stream_error if _stream_error != "" else "聊天失败"
	# "连不上"这类是后端整体不可达，标记出来让上层提示
	if msg.contains("连不上") or msg.contains("连接失败"):
		reachable_set(false)
	failed.emit(msg)
	stream_ended.emit()

func _trim_history() -> void:
	while _history.size() > max_history:
		_history.pop_front()

# ------------------------------------------------------------------ 短请求

## 探活整套（它那条连接、探活的 URL、超时、间隔、可达值）都在 **scripts/pet_probe.gd** 里
## （作业单 B1.4）—— 见 tick() 里那一行。这个壳留给聊天 / 后台那两条路：
## 成功收完一轮时反过来告诉它"后端其实是通的"（这比探活本身可靠：
## 探活会被限流挡掉，"刚聊成功"不会说谎）
func reachable_set(ok: bool) -> void:
	_probe.set_reachable(ok)

## 请求头和地址解析都在 **scripts/pet_net.gd** 里（纯 static，能整段离线测 —— 作业单 B1.4）。
## 这里留两个壳，调用点一行都不用改
func _headers(content_type: String, accept: String) -> PackedStringArray:
	return Net.headers(access_key, content_type, accept)

## 拆 URL 落到本类的四个字段上（host / port / tls / base_path）
func _parse_url() -> void:
	var p := Net.parse_url(url)
	_host = String(p["host"])
	_port = int(p["port"])
	_tls = bool(p["tls"])
	_base_path = String(p["base_path"])
