extends SceneTree
## 验「AI 服务设置 → 选『本地小模型』→ 保存」全链路（headless 可跑）：
##   A. 预设选中后表单填对（地址 / 文本模型 / 视觉模型 / 密钥全切到本地）
##   B. 保存落盘 user://pet_chat.cfg，宿主字段也换过来
##   C. 探活原本是红的 → 后台拉起 StartLocalAI.bat → 变绿，启动提示收尾
##
##   用法: & $godot --path . --headless --script res://tools/probe_local_switch.gd
##
## ⚠️ 会**真的**拉起 llama-server：跑之前先 taskkill /IM llama-server.exe /F，
## 否则 C 段可能因为"服务本来就在"而验不到启动那条路

const SCENE := "res://scenes/pet.tscn"
const CFG := "user://pet_chat.cfg"

var _start_ms := 0

func _initialize() -> void:
	_start_ms = Time.get_ticks_msec()
	_run.call_deferred()

func _process(_d: float) -> bool:
	if Time.get_ticks_msec() - _start_ms > 240000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _pump(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await process_frame

func _run() -> void:
	var ok := true
	var packed: PackedScene = load(SCENE)
	if packed == null:
		printerr("加载 %s 失败" % SCENE)
		quit(1)
		return
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await _pump(1500)

	var menu: Variant = pet.get("_menu_mod")
	var chat: Variant = pet.get("_chat")
	if menu == null or chat == null:
		printerr("失败：场景里没有菜单/聊天模块")
		quit(1)
		return

	# ---------------- A. 预设选中后表单填对
	pet.call("_open_ai_settings")          # 把面板建出来
	await _pump(200)
	menu.call("_on_provider_picked", 2)    # PROVIDERS[2] = 本地小模型
	var u := String(menu.get("_url_edit").get("text"))
	var m := String(menu.get("_model_edit").get("text"))
	var v := String(menu.get("_vision_edit").get("text"))
	var k := String(menu.get("_key_edit").get("text"))
	print("A 表单：url=%s model=%s vision=%s key空=%s" % [u, m, v, k == ""])
	if not u.contains("8530") or m != "qwen3.5-4b" or v != "qwen3.5-4b" or k != "":
		ok = false
		printerr("A 失败：预设没把表单填成本地")

	# ---------------- B. 保存 → 落盘 + 宿主字段
	menu.call("_on_save")
	await _pump(500)
	var cfg := ConfigFile.new()
	var cfg_ok := cfg.load(CFG) == OK \
		and String(cfg.get_value("ai", "url", "")).contains("8530") \
		and String(cfg.get_value("ai", "vision_url", "")).contains("8530") \
		and String(cfg.get_value("ai", "worker_url", "")).contains("8531") \
		and String(cfg.get_value("ai", "worker_model", "")) == "qwen3.5-0.8b"
	var host_vision := String(pet.get("vision_url"))
	print("B 落盘=%s 宿主vision_url=%s" % [cfg_ok, host_vision])
	if not cfg_ok or not host_vision.contains("8530"):
		ok = false
		printerr("B 失败：保存没把本地配置落盘/换上")

	# ---------------- C. 后台拉起 → 探活变绿 → 提示收尾
	var until := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until:
		if bool(chat.call("backend_reachable")):
			break
		await process_frame
	# 提示协程和本探针同帧醒来有先后：变绿后它还要再走到一帧才把启动状态收尾。
	# 特性代码里"确认已连上"有 1.5s 宽限等待，这里至少等 2s
	await _pump(2000)
	var green: bool = bool(chat.call("backend_reachable"))
	var done: bool = not bool(pet.get("_local_launching"))
	print("C 探活=%s 启动提示收尾=%s" % [green, done])
	if not green or not done:
		ok = false
		printerr("C 失败：后台启动没把探活变绿（或启动状态没收尾）")

	print("PROBE_LOCAL_SWITCH %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
