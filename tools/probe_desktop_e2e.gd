extends SceneTree
## 端到端探针：把**真实主场景**跑起来，走主人打字那条生产链路给本地小模型发一句话。
##
##   用法: & $godot --path . --headless --script res://tools/probe_desktop_e2e.gd
##
## 和 probe_chat_stream 的区别：那个只测 PetChat 客户端本身；这个从 pet.tscn
## 实例化整个桌宠（desktop_pet + chat_panel + chat_flow + memory 全接线），
## 调的是 `_submit_chat` —— 主人在输入框里敲字回车走的那条路，一模一样。
##
## 覆盖：
##   A. 场景起来后探活变绿（backend_reachable=true）
##   B. 生产链路一轮：_submit_chat → panel.submit → _chat.send → SSE → replied
##   C. 回复进了对话日志（_chat_log），气泡/记忆钩子没炸

const SCENE := "res://scenes/pet.tscn"
## 探活等待上限 / 一轮对话等待上限（毫秒）
const WAIT_PROBE_MS := 20000
const WAIT_ROUND_MS := 120000

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

func _pump(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await process_frame

## 等条件成立，返回是否等到
func _wait_until(fn: Callable, ms: int) -> bool:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		if fn.call():
			return true
		await process_frame
	return fn.call()

func _run() -> void:
	var ok := true
	var packed: PackedScene = load(SCENE)
	if packed == null:
		printerr("加载 %s 失败" % SCENE)
		quit(1)
		return
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	# 探针的话**不许进她的记忆**：上次跑探针把「桌宠端到端探针：回我两个字就行」
	# 写进了工作记忆的话题列表，她之后一直惦记这个鬼影话题（2026-10-11 实测）。
	# memory_flow 全线吃 memory_enabled（note_exchange / observe / extract 都查它）
	pet.memory_enabled = false
	await _pump(1500)   # 等 _ready / _setup_chat 灌完配置、探活发出去

	var chat: Variant = pet.get("_chat")
	if chat == null:
		printerr("失败：场景里没有 _chat（chat_enabled 是不是关了？）")
		quit(1)
		return

	# ------------------------------------------------ A. 探活
	var reach_ok := await _wait_until(func() -> bool:
		return bool(chat.call("backend_reachable")), WAIT_PROBE_MS)
	print("A backend_reachable=%s url=%s model=%s" % [
		chat.get("backend_reachable") if chat.get("backend_reachable") != null else chat.call("backend_reachable"),
		chat.get("url"), chat.get("model")])
	if not reach_ok:
		ok = false
		printerr("A 失败：%d 秒内探活没变绿 —— 先起 StartLocalAI.bat" % (WAIT_PROBE_MS / 1000))

	# ------------------------------------------------ B. 生产链路一轮
	var replied: Array[String] = []
	var fails: Array[String] = []
	chat.connect("replied", func(t: String) -> void: replied.append(t))
	chat.connect("failed", func(m: String) -> void: fails.append(m))
	if reach_ok:
		pet.call("_submit_chat", "桌宠端到端探针：回我两个字就行")
		var round_ok := await _wait_until(func() -> bool:
			return replied.size() > 0 or fails.size() > 0, WAIT_ROUND_MS)
		print("B 回复=%s" % (replied[0] if replied.size() > 0 else "（无）"))
		print("B 失败=%s" % (fails[0].split("\n")[0] if fails.size() > 0 else "（无）"))
		if not round_ok or replied.size() == 0:
			ok = false
			printerr("B 失败：生产链路没拿到回复")

		# ------------------------------------------------ C. 落进对话日志
		var log_arr: Array = pet.get("_chat_log")
		var tail := ""
		if log_arr.size() > 0:
			tail = String(log_arr[log_arr.size() - 1])
		print("C 日志行数=%d 最后一行=%s" % [log_arr.size(), tail])
		if not tail.contains("她：") or tail.length() <= 2:
			ok = false
			printerr("C 失败：回复没进 _chat_log（接线断了？）")

	print("PROBE_DESKTOP_E2E %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
