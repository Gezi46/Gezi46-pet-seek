extends SceneTree
## 情绪 → 动作 预览渲染（**不能 --headless**，那样拿不到渲染纹理，同 check_effect.gd）。
##
## 用法:
##   godot --path <项目> --script res://tools/preview_moods.gd [-- 输出目录]
##
## 产出两类帧：
##   1. 五种心情 × 4 个相位  —— 核对 scripts/body/pet_mood_ui.gd 的 MOOD_ACTIONS 映射
##   2. 候选动作总览          —— 模型里全部"可能当情绪动作用"的动画，各一帧，供挑替代
##
## 姿势按 check_effect.gd 那套"显式钉死"：停逻辑 → 藏假阴影 → 固定朝向 →
## play 之后 advance 到固定相位再 pause（靠"等 N 帧"会因帧长抖动落在不同相位）。

var _frames := 0
var _out_dir := "res://检查输出/情绪预览"

## 和 pet_mood_ui.gd 的 MOOD_ACTIONS 一一对应。anim 为空 = 平常心，用 _idle_anim
const MOODS: Array = [
	{"mood": "平常",   "anim": "",               "tag": "NEUTRAL"},
	{"mood": "开心",   "anim": "riptide",        "tag": "HAPPY"},
	{"mood": "生气",   "anim": "swing_offhand",  "tag": "ANGRY"},
	{"mood": "伤心",   "anim": "extra1",         "tag": "SAD"},
	{"mood": "坏心眼", "anim": "extra7",         "tag": "MISCHIEF"},
]

## 取哪几个相位（按动画长度比例）。静态姿势给多少都一样
const PHASES: Array = [0.15, 0.40, 0.65, 0.90]

## 候选动作：模型里能当"情绪表现"用的（移动类 walk/run 不列，那是走路的）
const CANDIDATES: Array = [
	"attacked", "swing_hand", "swing_offhand", "use_mainhand", "use_offhand",
	"use_mainhand_eat", "jump", "sit", "sleep", "death", "fly", "climb",
	"swim_stand", "sneak", "extra0", "extra1", "extra2", "extra3",
	"extra4", "extra5", "extra6", "extra7",
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

	# 停状态机 + 藏假阴影：不然它会自己走动，各帧之间取景对不上
	pet.set_process(false)
	var shadow: Node3D = pet.get_node_or_null("Shadow")
	if shadow != null:
		shadow.visible = false
	pet.call("_update_facing", 10.0)

	var ap: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer")
	var face: AnimationPlayer = pet.get_node_or_null("Character/Pivot/Model/AnimationPlayer2")
	if ap == null:
		printerr("找不到 Character/Pivot/Model/AnimationPlayer")
		quit(1)
		return

	print("视口 %s ｜ 模型里共 %d 个动画" % [str(get_root().get_texture().get_size()), ap.get_animation_list().size()])
	var idle_anim: String = String(pet.get("_idle_anim"))
	print("_idle_anim = %s" % idle_anim)

	# ---- 1) 五种心情 × 4 相位 ----
	for cell in MOODS:
		var anim: String = String(cell["anim"])
		if anim == "":
			anim = idle_anim
		if not ap.has_animation(anim):
			printerr("! 跳过「%s」：模型里没有 %s" % [cell["mood"], anim])
			continue
		var length: float = ap.get_animation(anim).length
		for i in PHASES.size():
			var t: float = maxf(0.03, length * float(PHASES[i]))
			await _shoot(ap, face, anim, t, abs_dir.path_join("mood_%s_%d.png" % [cell["tag"], i]))
		print("「%s」%s 全长 %.2fs" % [cell["mood"], anim, length])

	# ---- 2) 候选动作总览（各一帧，取动作区中段）----
	for anim in CANDIDATES:
		if not ap.has_animation(anim):
			printerr("! 候选里模型没有 %s，跳过" % anim)
			continue
		var length: float = ap.get_animation(anim).length
		var t: float = maxf(0.03, length * 0.55)
		await _shoot(ap, face, anim, t, abs_dir.path_join("cand_%s.png" % anim))
		print("候选 %s 全长 %.2fs 取 %.2fs" % [anim, length, t])

	print("全部完成，输出目录: %s" % abs_dir)
	quit(0)

## 播一个动画、推到固定时刻、暂停、抓一帧存盘
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
