extends SceneTree
## 宣传图素材渲染：透明底 + 高分辨率，输出用来合成的角色姿势帧。
## 用法:
##   godot --resolution 1320x1880 --path <项目> --script res://tools/preview_promo.gd [-- 输出目录]
##
## 与 preview_moods.gd 的两点不同：
##   1) 只为宣传挑姿势，输出的是**宣传用大图**（项目已设 viewport/transparent_background=true，
##      拿到的纹理自带 alpha，合成时能自由摆位）
##   2) 靠 --resolution 把渲染分辨率拉高 —— 330x470 的原生视口做 1080 高的宣传图会糊
##
## 同样**不能 --headless**（那样拿不到渲染纹理）。姿势按 check_effect.gd 那套"显式钉死"：
## 停逻辑 -> 藏假阴影 -> 固定朝向 -> play 之后 advance 到固定相位再 pause。

var _frames := 0
var _out_dir := "res://检查输出/宣传素材"

## 宣传图渲染分辨率。桌宠原生视口只有 330x470（窗口尺寸），拉高 4 倍才有做 1080 级图的清晰度。
## 与 330:470 同比例，所以 stretch=canvas_items + aspect=expand 不会改变取景，只是像素变多。
const RES := Vector2i(1320, 1880)

## 宣传用姿势。anim 为空 = 用 _idle_anim。phase 是动画长度比例
const POSES: Array = [
	{"name": "stand",    "anim": "",                 "phase": 0.50},
	{"name": "wave",     "anim": "swing_hand",       "phase": 0.50},
	{"name": "happy",    "anim": "riptide",          "phase": 0.55},
	{"name": "sleep",    "anim": "sleep",            "phase": 0.50},
	{"name": "jump",     "anim": "jump",             "phase": 0.55},
	{"name": "sneak",    "anim": "sneak",            "phase": 0.50},
	{"name": "attacked", "anim": "attacked",         "phase": 0.50},
	{"name": "eat",      "anim": "use_mainhand_eat", "phase": 0.50},
	{"name": "fly",      "anim": "fly",              "phase": 0.50},
	{"name": "climb",    "anim": "climb",            "phase": 0.50},
	{"name": "extra0",   "anim": "extra0",           "phase": 0.50},
	{"name": "extra1",   "anim": "extra1",           "phase": 0.50},
	{"name": "extra2",   "anim": "extra2",           "phase": 0.50},
	{"name": "extra3",   "anim": "extra3",           "phase": 0.50},
	{"name": "extra4",   "anim": "extra4",           "phase": 0.50},
	{"name": "extra5",   "anim": "extra5",           "phase": 0.50},
	{"name": "extra6",   "anim": "extra6",           "phase": 0.50},
	{"name": "extra7",   "anim": "extra7",           "phase": 0.50},
]

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 8000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		_out_dir = a[0]
	var abs_dir := ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var gi := FileAccess.open(abs_dir.path_join(".gdignore"), FileAccess.WRITE)
	if gi != null:
		gi.close()

	var packed: PackedScene = load("res://scenes/pet.tscn")
	if packed == null:
		printerr("加载 res://scenes/pet.tscn 失败")
		quit(1)
		return
	var pet: Node = packed.instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame

	# 拉高渲染分辨率：桌宠原生视口只有 330x470，直接做 1080 级宣传图会糊。
	# --resolution 在脚本模式下不生效（实测仍是 330x470），所以这里直接改窗口尺寸，
	# 并等几帧让相机的自适应逻辑先按新尺寸跑完（它在 _process 里，下面才 set_process(false)）。
	get_root().size = RES
	for i in 4:
		await process_frame
	print("窗口 %s ｜ 渲染纹理 %s" % [str(get_root().size), str(get_root().get_texture().get_size())])

	# 停状态机 + 藏假阴影：不然它会自己走动，各帧取景对不上
	pet.set_process(false)
	var shadow: Node3D = pet.get_node_or_null("Shadow")
	if shadow != null:
		shadow.visible = false
	# 藏掉整个 UI 层：上面挂着聊天气泡（$UI/Anchor/Bubble）和快速回答按钮，
	# 是运行时的"HUD"，宣传图只要角色本体。用 set() 是为了兼容 UI 可能是
	# CanvasLayer 也可能被改成 Control 两种情况（两者都有 visible）。
	var ui: Node = pet.get_node_or_null("UI")
	if ui != null:
		ui.set("visible", false)
	pet.call("_update_facing", 10.0)

	var ap: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	var face: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer2")
	if ap == null:
		printerr("找不到 Character/Pivot/Model/AnimationPlayer")
		quit(1)
		return

	var sz: Vector2i = get_root().get_texture().get_size()
	print("渲染分辨率 %s ｜ 模型里共 %d 个动画" % [str(sz), ap.get_animation_list().size()])
	var idle_anim: String = String(pet.get("_idle_anim"))
	print("_idle_anim = %s" % idle_anim)

	for pose in POSES:
		var anim: String = String(pose["anim"])
		if anim == "":
			anim = idle_anim
		if not ap.has_animation(anim):
			printerr("! 跳过 %s：模型里没有 %s" % [pose["name"], anim])
			continue
		var length: float = ap.get_animation(anim).length
		var t: float = maxf(0.03, length * float(pose["phase"]))
		await _shoot(ap, face, anim, t, abs_dir.path_join("promo_%s.png" % pose["name"]))
		print("%-13s <- %-14s @ %.2fs / %.2fs" % [pose["name"], anim, t, length])

	print("全部完成，输出目录: %s" % abs_dir)
	quit(0)

## 播一个动画、推到固定时刻、暂停、抓一帧存盘（透明底）
func _shoot(ap: AnimationPlayer, face: AnimationPlayer, anim: String, t: float, out: String) -> void:
	ap.stop()
	ap.play(anim)
	ap.advance(t)
	ap.pause()
	if face != null:
		face.stop()
		face.play("idle_face")
		face.advance(0.05)
		face.pause()
	for i in 2:
		await process_frame
	var img: Image = get_root().get_texture().get_image()
	img.decompress()
	img.save_png(out)
