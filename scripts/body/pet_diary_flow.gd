extends RefCounted
## 日记的**每天那一趟**：跨天检测、拍子积攒、到点（或你点了）让她写今天的日记。
##
## 和邻居的分工：
##   `pet_diary.gd`         数据与判定（拍子 / 本地合成 / 连续天数）—— 纯逻辑，离线可测
##   `pet_diary_prompt.gd`  提示词与回信清洗 —— 只出字，不发请求
##   **本文件**             什么时候写、让谁写、写完了往哪放
##   `pet_diary_ui.gd`      那一屏日记长什么样
##
## ── 为什么它自己开一条连接 ────────────────────────────────────────────────
## `ask_once` 那条链路**靠一个 `_task` 字符串认领结果**（见 pet_memory_flow.gd 的
## task_done）—— 那是记忆抽取 / 摘要 / 观察三件事共用的槽位。日记要是借那条路发，
## 两边的 `_task` 会互相覆盖，**表现是"她好像没记住"或者"日记一直是模板写的"**，
## 而且完全看不出是谁踩了谁。
##
## 所以照 `pet_quick.gd` 的先例**单开一条**：一天最多一个请求，
## 代价可以忽略，换来的是和记忆那条彻底不打架。
##
## ── 对宿主的接口面（只列真正用到的）────────────────────────────────────────
##   host.diary_enabled / diary_ai / diary_ready_beats   设置（@export 必须留宿主）
##   host._diary        日记数据模块（宿主持有，界面也读它）
##   host._chat         借它拿"后端通不通"（`backend_reachable()`）
##   host._offline()    离线时别发请求
##   host.chat_url / chat_access_key / chat_model   配自己的客户端
##
## 验证：`tools/probe_diary.gd` 的离线段试 `want_write()` / `is_new_day()`（都是 static）

## 配自己的客户端要用到 PetChat（和宿主同一个类）。
## 这里 preload 的是**纯编排层**，它不会回头依赖本模块 —— 没有循环风险
## （宪法第三节说的是模块之间别互相 preload，不是别依赖更下层的公共件）
const PetChat := preload("res://scripts/ai/pet_chat.gd")
const PetDiary := preload("res://scripts/body/pet_diary.gd")
const DiaryPrompt := preload("res://scripts/body/pet_diary_prompt.gd")

## 拍子攒够之后，等多久再写（秒）。**不立刻写**：她正被摸着 / 正聊着，
## 这时候突然去写日记，写出来的只有半截；而且刚发生的事还没沉淀下来。
## 十分钟之后再看一眼，那天基本定性了
const WRITE_AFTER_SEC := 600.0

var _host = null
## 日记那条自己的连接（理由见文件头）
var _client: PetChat = null
var _configured := false
## 要发的那条：素材文本（空 = 没有待发）
var _want_material: String = ""
## 什么时候可以发（攒够 + 隔一会儿）
var _try_ms: int = 0
## 最晚等到什么时候（超过就不写了，宁可留着明天用本地模板）
var _deadline_ms: int = 0
## 这一轮请求属于哪一天（回来时认领：翻天了就不要了）
var _want_day: String = ""
var _busy: bool = false
## 今天是不是已经"问过模型"了（一天最多问一次，别反复打扰）
var _asked_day: String = ""
## 上一次"想写"是什么时候（用来算 WRITE_AFTER_SEC）
var _ready_since_ms: int = 0

func setup(host) -> void:
	_host = host
	_client = PetChat.new()
	_client.no_think = true          # 写日记不需要思考，快一点
	_client.max_history = 0          # 每次都是干净的一轮，上下文我们自己给
	_client.once_done.connect(_on_done)
	_client.once_failed.connect(_on_failed)

## 宿主换 AI 服务设置时调它（和聊天 / 快速回答同一套地址、密钥、模型）
func configure(url: String, key: String, model: String,
		p_worker_url: String = "", p_worker_model: String = "") -> void:
	if _client == null:
		return
	# enabled=false 时 ask_once 直接返回 false（不连），正好是我们离线时想要的
	_client.enabled = true
	_client.configure(url, key, model)
	# 后台杂活工位（记忆/日记分工给小模型）；空 = 跟聊天同一个后端
	_client.configure_worker(p_worker_url, p_worker_model)
	_configured = url.strip_edges() != ""

# ------------------------------------------------------------------ 每帧

## 每帧：跨天检查 + 到点就写。宿主在 `_process` 里跟着 `_mood_ui.tick()` 一起调。
## **顺序无所谓**（它不依赖 mood 那一帧的状态），放在那儿只是"每帧一次的地方只有一处"
func tick() -> void:
	if _client != null:
		_client.tick()
	if not bool(_host.diary_enabled):
		return
	var today := _today()
	# 攒够拍子了？记下"从什么时候开始够的"
	if _ready_since_ms == 0 and _beats_today() >= int(_host.diary_ready_beats):
		_ready_since_ms = Time.get_ticks_msec()
	if _ready_since_ms == 0:
		return
	# 本地那版先落上 —— **保证"日记一定有内容"**。
	# 模型那版回来会覆盖它（见 _on_done）。这样断网 / 关掉 AI 也翻得到东西
	# （`_host` 是弱类型 → 这里必须显式标类型，`:=` 会报 Cannot infer，见 CONVENTIONS 附录）
	if _host._diary.needs_write():
		var text: String = _host._diary.write_today()
		_host._diary.save()
		if OS.is_debug_build():
			print("[PetDeek] 日记（本地模板）：%s" % text)
	# 再问模型要不要写得更自然一点（一天一次）
	_tick_ai(today)

func _tick_ai(today: String) -> void:
	if _want_material == "":
		# 还没排上队：现在排队
		if not _maybe_queue(today):
			return
	if Time.get_ticks_msec() < _try_ms:
		return
	if Time.get_ticks_msec() > _deadline_ms:
		_want_material = ""
		_busy = false
		return
	if _client == null or not _configured or bool(_host._offline()):
		_want_material = ""
		return
	if _client.once_busy():
		_try_ms = Time.get_ticks_msec() + 1000
		return
	var material := _want_material
	_want_material = ""
	if _client.ask_once(DiaryPrompt.SYS, DiaryPrompt.build(material), 800):
		_busy = true
		if OS.is_debug_build():
			print("[PetDeek] 日记：已经让她用模型重写今天的")

## 该不该排队让模型写今天的。返回 true = 已经排上了
func _maybe_queue(today: String) -> bool:
	if not bool(_host.diary_ai):
		return false
	if _asked_day == today:
		return false                    # 一天只问一次
	# 攒够之后还要再等一会儿（见 WRITE_AFTER_SEC）
	if _ready_since_ms == 0:
		return false
	if Time.get_ticks_msec() - _ready_since_ms < int(WRITE_AFTER_SEC * 1000.0):
		return false
	var d := _day_entry(today)
	if d.is_empty():
		return false
	var kinds: Array = []
	for b in (d["beats"] as Array):
		kinds.append(String(b["kind"]))
	if kinds.is_empty():
		return false
	_asked_day = today
	_want_day = today
	_want_material = DiaryPrompt.material_of(kinds, _mood_text(),
		{"total_pets": _host._diary.total_pets, "total_talks": _host._diary.total_talks})
	_try_ms = Time.get_ticks_msec() + 2000   # 缓两秒，别和刚发生的事抢
	_deadline_ms = Time.get_ticks_msec() + 120000
	if OS.is_debug_build():
		print("[PetDeek] 日记：攒够 %d 个拍子，准备让她写今天的" % kinds.size())
	return true

## 模型写回来了。**认领**：只有"还是那一天"才收 —— 跨天了 / 你没开 AI 就不收
func _on_done(text: String) -> void:
	_busy = false
	if _want_day == "" or _want_day != _today():
		return
	if not bool(_host.diary_enabled) or not bool(_host.diary_ai):
		return
	# 模型按"标题：…"换行"正文"两行写；没照格式写就整段当正文（见 split_title）
	var parts: Dictionary = DiaryPrompt.split_title(text)
	if _host._diary.set_today_ai(String(parts["body"]), String(parts["title"])):
		_host._diary.save()
		if OS.is_debug_build():
			print("[PetDeek] 日记（模型写的）：%s" % _host._diary.today_text())

func _on_failed(msg: String) -> void:
	_busy = false
	# 失败**不报给用户**：本地那版已经写好了，日记照样有内容。
	# 只在日志里留一笔 —— 不然"她写的一直是模板"这种问题查不出来
	if OS.is_debug_build():
		print("[PetDeek] 日记那条请求失败了：%s（继续用本地那版）" % msg)

func busy() -> bool:
	return _busy or _want_material != ""

# ------------------------------------------------------------------ 手动那一条（菜单 / 界面按钮）

## 现在立刻用模型写一遍今天的（忽略"攒够没 / 等多久"，但**不忽略开关和离线**）。
## 返回一段说明：给界面显示用（成功 / 为什么没法写）
func write_now_with_ai() -> String:
	if not bool(_host.diary_enabled):
		return "日记是关着的（设置面板 → 她这个人 → 她自己的日记）"
	if not bool(_host.diary_ai):
		return "「用模型写日记」关着 —— 现在这版是本地模板拼的"
	if _client == null or not _configured:
		return "还没配 AI 服务，只能拼本地那版"
	if bool(_host._offline()):
		return "现在联系不上 AI 服务，稍后再试"
	if _client.once_busy() or _busy:
		return "上一条还没回来，等一下"
	var today := _today()
	var d := _day_entry(today)
	if d.is_empty() or (d["beats"] as Array).is_empty():
		return "今天还没发生什么，没什么好写的"
	var kinds: Array = []
	for b in (d["beats"] as Array):
		kinds.append(String(b["kind"]))
	var material := DiaryPrompt.material_of(kinds, _mood_text(),
		{"total_pets": _host._diary.total_pets, "total_talks": _host._diary.total_talks})
	_want_day = today
	if _client.ask_once(DiaryPrompt.SYS, DiaryPrompt.build(material), 800):
		_busy = true
		return "正在写…（写完会自动更到上面）"
	return "没发出去（后端那条正忙）"

# ------------------------------------------------------------------ 小工具

func _today() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]

## 今天记了几个拍子
func _beats_today() -> int:
	var d := _day_entry(_today())
	return 0 if d.is_empty() else (d["beats"] as Array).size()

## 取今天那一条（没有就返回空字典）
func _day_entry(date: String) -> Dictionary:
	for d in _host._diary.days:
		if String(d["date"]) == date:
			return d
	return {}

## 她现在的情绪描述（写进日记素材）。**平常就返回空串** —— 素材里不该出现"平常"
func _mood_text() -> String:
	var m = _host._mood
	if m == null:
		return ""
	var s: String = m.describe_short()
	return "" if s == "平常" else s

# ------------------------------------------------------------------ 给探针用（static）

## 今天该不该写日记。写成 static 是为了能**脱离场景**验
## （beats = 今天已有的拍子数，ready = 阈值，wrote = 今天已经有正文了）
static func want_write(beats: int, ready: int, wrote: bool) -> bool:
	if wrote:
		return false
	return beats >= maxi(ready, 1)

## 跨天了没有（用来决定"该不该把跨天那句说出来"）。
## last = 上次记下的日期，today = 现在 —— 传进来 = 可测
static func is_new_day(last: String, today: String) -> bool:
	if last == "":
		return true
	return last != today
