# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 测「前缀缓存命中率」——把响应里的 usage 打出来。跑四发请求：
##
##     1. **人设单独一发**：量出人设到底多少 token（据此判断 64 token 块的对齐）
##     2~4. 三轮对话：看命中数怎么走
##
##     godot --headless --path . --script res://tools/probe_cache.gd
##
## 为什么不用应用的聊天链路测：`pet_chat.gd` 只管正文（它不靠 usage 干活）。
## 这里自己发 POST，但 messages **和真实请求一模一样** —— 用 `pet_chat.compose_messages`
## 加 `pet_persona.build / build_context` 组装，所以量到的就是线上真实形状。
##
## 看结果时记住三条：
##   1. 第一发必然大面积未命中 —— 缓存得先有人写进去
##   2. 命中数**按 64 token 一块**跳（640 / 768 …），不是线性增长
##   3. 缓存是**服务商侧**的：换后端（比如本机 deepseek-web-api）就没有这套机制，
##      这时看不到 prompt_cache_* 字段，说明它不做前缀缓存
##
## 对齐那件事：稳定块（人设）的尾巴会和「第一句会变的东西」**共用一个 64 token 块**，
## 那个块永远不给命中。所以人设的 token 数最好**正好是 64 的倍数** ——
## 下面会把人设单独量出来，跟命中数对着看（差得多就说明尾部白扔了几十 token）

const PERSONA := "res://scripts/ai/memory/pet_persona.gd"
const CHAT := "res://scripts/ai/pet_chat.gd"
## 两发之间隔多久（秒）。太短可能赶不上服务商写缓存
const GAP_SEC := 5.0
const BLOCK := 64
const ASKS: Array[String] = ["我今天加班到十点，好累", "嗯，你困不困？", "那你早点睡吧"]

var _req: HTTPRequest = null
var _url := ""
var _key := ""
var _model := ""
var _sys := ""
## 待发的队列：{kind: "persona"|"turn", user: String}
var _queue: Array = []
## 0 待发 / 1 等回复 / 2 汇总
var _stage := 0
var _t := 0.0
var _fired_at := 0
var _pending: Dictionary = {}
var _hist: Array = []
var _rows: Array = []
## 人设单独量出来的 token 数（-1 = 还没量到）
var _persona_tokens := -1
var _persona_chars := 0

func _initialize() -> void:
	_url = _cfg("url").strip_edges().trim_suffix("/")
	_key = _cfg("key")
	_model = _cfg("model")
	if _url == "":
		print("读不到 user://pet_chat.cfg（先在桌宠里配一次 AI 服务）")
		quit()
		return
	# 和运行时同一份人设：同样的参数 → 逐字相同的那一半
	_sys = String((load(PERSONA) as GDScript).build({"name": "小蓝", "extra": ""}))
	_req = HTTPRequest.new()
	root.add_child(_req)
	_req.request_completed.connect(_on_done)
	_queue.append({"kind": "persona", "user": "你好"})
	for a in ASKS:
		_queue.append({"kind": "turn", "user": a})
	print("后端=%s  模型=%s  人设=%d 字\n" % [_url, _model, _sys.length()])

func _cfg(k: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://pet_chat.cfg") != OK:
		return ""
	return String(cfg.get_value("ai", k, ""))

func _process(delta: float) -> bool:
	_t += delta
	if _stage == 0:
		if _queue.is_empty():
			if _t > 1.0:
				_report()
				return true
			return false
		# 第一发不用等（缓存是空的，等也没用）；后面每发隔一会儿，让服务商把缓存写完
		if _t > (1.0 if _persona_tokens < 0 else GAP_SEC):
			_fire(_queue.pop_front())
			_stage = 1
	return false

func _fire(job: Dictionary) -> void:
	var Persona: GDScript = load(PERSONA)
	var msgs: Array = []
	if String(job["kind"]) == "persona":
		# 只有人设 + 一句最短的用户话：这样 prompt_tokens 基本就是人设的 token 数
		msgs = [{"role": "system", "content": _sys}, {"role": "user", "content": "你好"}]
		print("--- 人设单独量一次 ---")
	else:
		var user_msg := String(job["user"])
		var ctx := String(Persona.build_context({
			"user_text": user_msg, "state_text": "趴在桌面上发呆"}))
		msgs = (load(CHAT) as GDScript).compose_messages(_sys, _hist, ctx, user_msg, "")
		var cacheable := _sys.length()
		for h in _hist:
			cacheable += String(h["content"]).length()
		var all_chars := 0
		for m in msgs:
			all_chars += String(m["content"]).length()
		print("--- 第 %d 轮：%d 条消息，共 %d 字（可被下轮命中的前缀 %d 字）---" % [
			_rows.size(), msgs.size(), all_chars, cacheable])
	_pending = job
	_fired_at = Time.get_ticks_msec()
	var headers := ["Content-Type: application/json"]
	if _key.strip_edges() != "":
		headers.append("Authorization: Bearer " + _key)
	var body := JSON.stringify({"model": _model, "stream": false, "temperature": 0.0,
		"max_tokens": 2000, "messages": msgs})
	if _req.request(_url + "/chat/completions", headers, HTTPClient.METHOD_POST, body) != OK:
		print("  请求发出失败")
		_stage = 0

func _on_done(_result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var ms := (Time.get_ticks_msec() - _fired_at) / 1000.0
	var text := body.get_string_from_utf8()
	var is_persona := String(_pending.get("kind", "")) == "persona"
	if code != 200:
		print("  HTTP %d（%.1f 秒）：%s" % [code, ms, text.substr(0, 200)])
	else:
		var d: Variant = JSON.parse_string(text)
		if typeof(d) != TYPE_DICTIONARY:
			print("  返回不是 JSON：%s" % text.substr(0, 200))
		else:
			var usage: Dictionary = {}
			if typeof((d as Dictionary).get("usage")) == TYPE_DICTIONARY:
				usage = (d as Dictionary)["usage"]
			var hit := int(usage.get("prompt_cache_hit_tokens", -1))
			var miss := int(usage.get("prompt_cache_miss_tokens", -1))
			var total := int(usage.get("prompt_tokens", 0))
			if is_persona:
				# 「你好」加协议模板大约几个 token，量的是人设的量级，够判断对齐了
				_persona_tokens = total - 6
				_persona_chars = _sys.length()
				print("  人设 ≈ %d token（%d 字）→ 占 %.1f 个 %d 块" % [
					_persona_tokens, _persona_chars,
					float(_persona_tokens) / float(BLOCK), BLOCK])
			var reply := ""
			var choices: Variant = (d as Dictionary).get("choices")
			if typeof(choices) == TYPE_ARRAY and not (choices as Array).is_empty():
				var msg: Variant = ((choices as Array)[0] as Dictionary).get("message", {})
				if typeof(msg) == TYPE_DICTIONARY:
					reply = String((msg as Dictionary).get("content", "")).strip_edges()
			print("  她：%s" % reply.substr(0, 40))
			if hit < 0:
				print("  **这个后端没回 prompt_cache_hit_tokens** —— 它不做前缀缓存" \
					+ "（或者不告诉你）。usage：%s" % str(usage))
			else:
				print("  命中 %d / 未命中 %d（提示共 %d）→ 命中率 %.1f%%" % [
					hit, miss, total, 100.0 * float(hit) / maxf(1.0, float(hit + miss))])
			_rows.append({"hit": hit, "miss": miss, "persona": is_persona})
			if not is_persona and reply != "":
				_hist.append({"role": "user", "content": String(_pending.get("user", ""))})
				_hist.append({"role": "assistant", "content": reply})
	_t = 0.0
	_stage = 0

func _report() -> void:
	print("")
	print("=== 汇总 ===")
	var any := false
	for i in _rows.size():
		var h := int(_rows[i]["hit"])
		if h < 0:
			continue
		any = true
		var m := int(_rows[i]["miss"])
		var tag := "人设单独" if bool(_rows[i]["persona"]) else "第 %d 轮" % i
		print("  %s：命中 %d / 未命中 %d → %.1f%%" % [
			tag, h, m, 100.0 * float(h) / maxf(1.0, float(h + m))])
	if not any:
		print("  这个后端一次都没报缓存命中 —— 大概率它不做前缀缓存（本机 web-api 就是这样）")
		quit()
		return
	print("")
	if _persona_tokens <= 0:
		print("  （人设那一发没量到，跳过对齐检查）")
		quit()
		return
	var blocks := int(_persona_tokens / float(BLOCK))
	var rest := _persona_tokens % BLOCK
	print("  对齐检查：人设 ≈ %d token = %d 块 + 余 %d token" % [_persona_tokens, blocks, rest])
	if rest == 0:
		print("    ✓ 正好落在块边界上")
	else:
		var per_tok := float(_persona_chars) / float(_persona_tokens)
		print("    人设不是 %d 的整数倍（余 %d token）。**但别急着去凑字数**：" % [BLOCK, rest])
		print("      实测无论对齐与否，服务商都会扣掉尾部约 160 token 不记命中" \
			+ "（大概是写缓存有延迟）。所以对齐能拿回的顶多几十 token，收益很小 ——")
		print("      真正管用的是把「每轮都变」的那一段压小（见 README 的缓存瘦身）")
		print("      真要凑：把字数往 %d 字前后调（实测 %.2f 字/token）" % [
			int(blocks * BLOCK * per_tok), per_tok])
	print("  注：命中数按 %d token 一块跳，不会随历史线性增长 —— 稳定命中的是人设那一块" % BLOCK)
	quit()
