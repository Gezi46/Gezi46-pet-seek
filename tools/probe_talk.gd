extends SceneTree
## 临时探针：像真主人那样连聊五句，把她每一句回复原样打出来 ——
## 用户要求"自己改完自己点开测一测回复内容"，这就是那个测试。
## 复用 probe_desktop_e2e 的生产链路（真实 pet.tscn + _submit_chat），
## 记忆照旧关掉（探针台词不许进她的记忆）

const SCENE := "res://scenes/pet.tscn"
const LINES := [
	"在干嘛呢",
	"今天上班好累啊",
	"你是谁呀",
	"我上一句说的什么？",
	"晚上吃什么好",
]
const WAIT_ROUND_MS := 120000

var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	if Time.get_ticks_msec() - _start_ms > 600000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _wait_until(fn: Callable, ms: int) -> bool:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		if fn.call():
			return true
		await process_frame
	return fn.call()

func _run() -> void:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		printerr("加载 %s 失败" % SCENE)
		quit(1)
		return
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	pet.memory_enabled = false   # 探针台词不进记忆（教训见 probe_desktop_e2e 头注）
	# 等 _ready / _setup_chat 灌完配置（固定等几帧在无头模式是赌运气，二跑就翻车了）
	if not await _wait_until(func() -> bool:
		return pet.get("_chat") != null, 10000):
		printerr("失败：_chat 十秒内没建起来（chat_enabled 是不是关了？）")
		quit(1)
		return

	var chat: Variant = pet.get("_chat")
	if chat == null:
		printerr("失败：场景里没有 _chat")
		quit(1)
		return
	if not await _wait_until(func() -> bool:
		return bool(chat.call("backend_reachable")), 20000):
		printerr("失败：探活没变绿 —— 先起 StartLocalAI.bat")
		quit(1)
		return

	var all_ok := true
	for msg in LINES:
		var replied: Array[String] = []
		var fails: Array[String] = []
		chat.connect("replied", func(t: String) -> void: replied.append(t))
		chat.connect("failed", func(m: String) -> void: fails.append(m))
		pet.call("_submit_chat", msg)
		var got := await _wait_until(func() -> bool:
			return replied.size() > 0 or fails.size() > 0, WAIT_ROUND_MS)
		if not got or replied.size() == 0:
			all_ok = false
			print("Q：%s\nA：（没回上：%s）" % [msg,
				fails[0].split("\n")[0] if fails.size() > 0 else "超时"])
		else:
			print("Q：%s\nA：%s" % [msg, replied[0].replace("\n", " ")])
		# 下一句前等气泡收尾那口气（生产里主人打字也要几秒）
		var until := Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < until:
			await process_frame

	print("PROBE_TALK %s" % ("OK" if all_ok else "FAILED"))
	quit(0 if all_ok else 1)
