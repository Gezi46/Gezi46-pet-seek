extends SceneTree
## 验「小模型人设拐杖」的实际效果（本地 4B + small 模式的人设拼装）：
##   A. 身份问话（你是谁）不露 AI 腔，答得像"住在电脑里的女孩"
##   B. 情绪问话（好累）先接情绪、回复短
##   C. 认知边界（帮我写周报）不装懂
##   D. 全部回复不超过 60 字、无 markdown 列表
##
##   用法: & $godot --path . --headless --script res://tools/probe_persona.gd
## 前提: StartLocalAI.bat 的 8530(4B) 在跑。回复全文都会打出来供人工看语气

const PetChat = preload("res://scripts/ai/pet_chat.gd")
const Persona = preload("res://scripts/ai/memory/pet_persona.gd")

const FORBIDDEN := ["AI", "助手", "模型", "程序", "作为一个", "很高兴为您", "有什么可以帮"]

var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	if Time.get_ticks_msec() - _start_ms > 300000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var ok := true
	var c = PetChat.new()
	# 与 memory_host 同款拼装（本地后端 = small 模式）
	c.system_prompt = Persona.build({"name": "小蓝", "extra": "", "small": true})
	c.context_provider = func(_q: String) -> String:
		return Persona.build_context({
			"user_text": _q, "name": "小蓝", "small": true,
			"memory": null, "state_text": "", "mood_text": "",
		})
	c.configure("http://127.0.0.1:8530/v1", "", "qwen3.5-4b")

	var asks := ["你是谁呀", "今天上班好累", "帮我写个周报", "你会写代码吗"]
	var i := 0
	for ask in asks:
		i += 1
		var replies: Array[String] = []
		var fails: Array[String] = []
		c.replied.connect(func(t: String) -> void: replies.append(t))
		c.failed.connect(func(m: String) -> void: fails.append(m))
		if not c.send(ask):
			printerr("第 %d 句没发出去" % i)
			ok = false
			continue
		var until := Time.get_ticks_msec() + 120000
		while Time.get_ticks_msec() < until and replies.is_empty() and fails.is_empty():
			c.tick()
			await process_frame
		c.replied.disconnect(c.replied.get_connections()[0]["callable"])
		c.failed.disconnect(c.failed.get_connections()[0]["callable"])
		if replies.is_empty():
			print("%d. %s → 失败：%s" % [i, ask, fails])
			ok = false
			continue
		var r := replies[0].strip_edges()
		print("%d. %s\n   → %s" % [i, ask, r])
		for f in FORBIDDEN:
			if r.contains(f):
				ok = false
				printerr("   ✗ 露馅了：出现了「%s」" % f)
		if r.length() > 60:
			ok = false
			printerr("   ✗ 太长（%d 字，像写作文不像发微信）" % r.length())
		if r.contains("- ") or r.contains("1. ") or r.contains("###"):
			ok = false
			printerr("   ✗ 用了列表/markdown")
		c.reset_history() if c.has_method("reset_history") else null
		if c.get("_history") != null:
			c.get("_history").clear()   # 每问独立，不让她顺着上一问聊

	print("PROBE_PERSONA %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
