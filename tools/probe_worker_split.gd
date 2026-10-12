extends SceneTree
## 验「后台杂活工位」（记忆/日记/编候选 → 小模型第二实例）的分流：
##   A. 配了工位：ask_once 走 8531（0.8B），once_done 拿到正文
##   B. 聊天那条不受影响：send 流式仍走 8530（4B），replied 正常
##   C. 没配工位：ask_once 落回聊天后端（云 API 用户的原有行为不回归）
##   D. 快速回答编候选（2026-10-11 起）：客户端重指向 8531，
##      用生产同款提示词（pet_quick.AI_SYS / AI_PROMPT + max_reply_tokens=90），
##      0.8B 得编出 ≥2 句洗得干净的候选
##
##   用法: & $godot --path . --headless --script res://tools/probe_worker_split.gd
## 前提: StartLocalAI.bat 已把 8530(4B+vision) 和 8531(0.8B CPU) 都拉起来

const PetChat = preload("res://scripts/ai/pet_chat.gd")
const Quick = preload("res://scripts/ai/pet_quick.gd")

var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	if Time.get_ticks_msec() - _start_ms > 180000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _pump(c, ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		c.tick()
		await process_frame

func _run() -> void:
	var ok := true

	# ---------------- A. 工位分流
	var w = PetChat.new()
	var done: Array[String] = []
	var fails: Array[String] = []
	w.once_done.connect(func(t: String) -> void: done.append(t))
	w.once_failed.connect(func(m: String) -> void: fails.append(m))
	w.configure("http://127.0.0.1:8530/v1", "", "qwen3.5-4b")
	w.configure_worker("http://127.0.0.1:8531/v1", "qwen3.5-0.8b")
	print("A 工位已配=%s" % w.has_worker())
	if not w.has_worker():
		ok = false
		printerr("A 失败：configure_worker 没生效")
	if not w.ask_once("从下面的句子里抽人名，只输出名字，没有就输出：无",
			"今天和小蓝在公园散步，遇到了老王。", 100):
		ok = false
		printerr("A 失败：ask_once 没发出去")
	var until := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < until and done.is_empty() and fails.is_empty():
		w.tick()
		await process_frame
	print("A 工位回复=%s 失败=%s" % [done, fails])
	if done.is_empty():
		ok = false
		printerr("A 失败：工位 60 秒没回（8531 起了吗？看 local_ai\\aux.log）")

	# ---------------- B. 聊天通道不受影响
	var c = PetChat.new()
	var replies: Array[String] = []
	c.replied.connect(func(t: String) -> void: replies.append(t))
	c.configure("http://127.0.0.1:8530/v1", "", "qwen3.5-4b")
	c.configure_worker("http://127.0.0.1:8531/v1", "qwen3.5-0.8b")
	c.send("回我两个字就行")
	var b_until := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < b_until and replies.is_empty():
		c.tick()
		await process_frame
	print("B 聊天回复=%s" % (replies[0] if replies.size() > 0 else "（无）"))
	if replies.is_empty():
		ok = false
		printerr("B 失败：配了工位后聊天通道坏了")

	# ---------------- C. 没配工位 = 原行为（落回聊天后端）
	var p = PetChat.new()
	p.configure("http://127.0.0.1:8530/v1", "", "qwen3.5-4b")
	print("C 未配工位=%s（应为 false）" % p.has_worker())
	if p.has_worker():
		ok = false
		printerr("C 失败：默认不该有工位")

	# ---------------- D. 编候选走工位（生产同款：AI_SYS / AI_PROMPT / 硬顶 90）
	var q = PetChat.new()
	var q_replies: Array[String] = []
	q.replied.connect(func(t: String) -> void: q_replies.append(t))
	q.system_prompt = Quick.AI_SYS
	q.max_history = 0
	q.max_reply_tokens = 90
	q.configure("http://127.0.0.1:8531/v1", "", "qwen3.5-0.8b")
	q.send(Quick.AI_PROMPT % ["（没有更早的对话）",
		"哼，今天没空理你，自己去忙吧。", "主人刚跟她聊完一轮"])
	var d_until := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < d_until and q_replies.is_empty():
		q.tick()
		await process_frame
	var opts: Array[String] = Quick.parse_quick_options(
		q_replies[0] if q_replies.size() > 0 else "")
	print("D 工位候选=%s 原始=%s" % [opts,
		q_replies[0] if q_replies.size() > 0 else "（无）"])
	if opts.size() < 2:
		ok = false
		printerr("D 失败：工位编不出 2 句能用的候选（0.8B 不胜任这活就得撤）")

	print("PROBE_WORKER_SPLIT %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
