# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends SceneTree
## 一键效果检查：渲染几个固定取景，导出 PNG 并打印可对比的量化指标。
## 用法: --script res://tools/check_effect.gd [-- 输出目录]
##
## 为什么要"一次进程跑完两个变体"：每个变体都得重新实例化宠物
## （UV 内缩是在 _ready 里做的，改完属性再跑才有效），
## 而拉起一次引擎要 5~10 秒 —— 一个个变体单开进程，检查一轮就要 40 秒起。
##
## 注意：不能用 --headless，那样拿不到渲染纹理。
##
## 能查出什么 / 查不出什么（实测边界，别指望它包打天下）：
##   ✔ 模型有没有渲染出来、几何有没有被改坏 —— 看"实心像素数"，
##     当前组和参照组应该几乎一致（差 0.2% 以内）。
##   ✔ 两次跑是不是落在同一个姿势 —— 姿势在 _spawn() 里是**显式钉死**的；
##     早先靠"等 40 帧"，帧长一抖就会一个背对、一个正对，实心像素差 22%，纯属误报。
##   ✘ **查不出"白边"这类毛病**：掠射角高光是视角相关的，在这个固定正脸姿势下
##     连"打开高光"的参照组都复现不出白边（实测只差 5 个亮像素）。
##     所以报告只在参照组明显更脏时才说"修复在起作用"，否则直接提示"别据此判断"。
##     真要确认白边，还是得在游戏里转视角用眼睛看。
var _frames := 0
var _out_dir := "res://检查输出"

## 固定取景。"鞋边"那一块就是白色小锯齿出现的位置，改动后主要看它。
const SHOTS: Array = [
	{"name": "全身", "x": 0, "y": 0, "w": 330, "h": 470, "zoom": 1},
	{"name": "鞋边", "x": 122, "y": 374, "w": 86, "h": 42, "zoom": 8},
]

## 参照变体：把"镜面高光"打开，复现那串白色小锯齿。
## 之所以拿它当参照而不是"关掉 UV 内缩"：高光一关之后，单关 UV 内缩已经复现不出白边了
## （实测鞋边 0 个亮像素），继续拿它对照会得出"改不改都一样"的错误结论。
const REF_TAG := "参照开高光"

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 4000:
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
	# 放一个 .gdignore，Godot 就不会去导入这里的 PNG（否则每张图都会多出一个 .import）
	var gi := FileAccess.open(abs_dir.path_join(".gdignore"), FileAccess.WRITE)
	if gi != null:
		gi.close()

	var report: Array = []
	# -1.0 表示"保持原样"。参照组把高光打开，用来确认修复真的还在起作用。
	for cfg in [
		{"tag": "当前", "inset": -1.0, "spec": -1},
		{"tag": REF_TAG, "inset": -1.0, "spec": 0},
	]:
		var pet: Node = await _spawn(cfg["inset"], cfg["spec"])
		for shot in SHOTS:
			report.append(_grab(shot, cfg["tag"]))
		pet.free()
		await process_frame
		await process_frame

	_report(report)
	quit(0)

## 造一个冻住姿势的宠物实例，两次跑出来的画面才可比
## inset / spec 传 -1 表示保持脚本里的默认值
func _spawn(inset: float, spec: int) -> Node:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	var pet: Node = packed.instantiate()
	# 这两个都在 _ready 里生效，必须在入树之前设置
	if inset >= 0.0:
		pet.set("uv_inset_texels", inset)
	if spec >= 0:
		pet.set("disable_specular", spec != 0)
	get_root().add_child(pet)
	await process_frame
	await process_frame

	# 停掉状态机 + 藏掉假阴影，避免它自己走动导致两次截图对不上
	pet.set_process(false)
	var shadow: Node3D = pet.get_node_or_null("Shadow")
	if shadow != null:
		shadow.visible = false

	# 姿势必须"显式钉死"，不能靠"跑 N 帧"：
	#   1) 朝向由 _update_facing() 在 _process 里平滑推进，set_process(false) 之后它就不动了，
	#      模型会停在初始的背对镜头的姿势；
	#   2) 而 _process 在关掉之前已经跑过几帧，那个"几帧"取决于帧长 ——
	#      第二次实例化时前面要拆建 567 个网格，某一帧变长就会让平滑因子饱和成 1
	#      一帧转到正面，于是两次跑出来一个背对、一个正对。
	# 动画相位同理（帧长抖动会让"等 40 帧"落在不同相位），所以用 advance() 推到固定时刻
	# —— seek() 不行，实测它不会立刻刷新 3D 变换。
	for n in ["Character/Pivot/Model/AnimationPlayer", "Character/Pivot/Model/AnimationPlayer2"]:
		var p: AnimationPlayer = pet.get_node_or_null(n)
		if p == null:
			continue
		p.stop()
		if String(n).ends_with("2"):
			p.play("idle_face")
		else:
			p.play(String(pet.get("_idle_anim")))
		p.advance(0.5)
		p.pause()
	# 直接落到"正对屏幕"的那个偏航，不依赖 _process
	pet.call("_update_facing", 10.0)
	for i in 3:
		await process_frame
	return pet

## 截一块区域：放大存图（带 alpha + 叠深色底各一张），顺便统计可对比的指标
func _grab(shot: Dictionary, tag: String) -> Dictionary:
	var img: Image = get_root().get_texture().get_image()
	img.decompress()
	var vp := img.get_size()
	var x0: int = clampi(shot.x, 0, maxi(vp.x - 1, 0))
	var y0: int = clampi(shot.y, 0, maxi(vp.y - 1, 0))
	var w: int = mini(shot.w, vp.x - x0)
	var h: int = mini(shot.h, vp.y - y0)
	var crop: Image = img.get_region(Rect2i(x0, y0, w, h))

	var zoom: int = shot.zoom
	var big: Image = Image.create(w * zoom, h * zoom, false, Image.FORMAT_RGBA8)
	var over_dark: Image = Image.create(w * zoom, h * zoom, false, Image.FORMAT_RGBA8)
	var dark := Color(0.08, 0.09, 0.14)     # 近似深色桌面，白边在它上面最显眼
	var solid := 0
	var bright := 0
	for y in h:
		for x in w:
			var c := crop.get_pixel(x, y)
			if c.a > 0.5:
				solid += 1
			if (c.r + c.g + c.b) / 3.0 > 0.5:
				bright += 1
			var d := dark.lerp(c, c.a)
			for dy in zoom:
				for dx in zoom:
					big.set_pixel(x * zoom + dx, y * zoom + dy, c)
					over_dark.set_pixel(x * zoom + dx, y * zoom + dy, d)

	var base := ProjectSettings.globalize_path(_out_dir).path_join("%s_%s.png" % [shot["name"], tag])
	big.save_png(base)
	over_dark.save_png(base.replace(".png", "_深底.png"))
	return {"shot": shot["name"], "tag": tag, "solid": solid, "bright": bright, "file": base}

func _report(report: Array) -> void:
	print("")
	print("================ 检查结果 ================")
	print("%-10s %-12s %8s %8s" % ["取景", "变体", "实心像素", "亮像素"])
	var by_key := {}
	for r in report:
		by_key["%s|%s" % [r["shot"], r["tag"]]] = r
		print("%-10s %-12s %8d %8d" % [r["shot"], r["tag"], r["solid"], r["bright"]])
	print("------------------------------------------")
	for shot in SHOTS:
		var now: Dictionary = by_key["%s|当前" % shot["name"]]
		var ref: Dictionary = by_key["%s|%s" % [shot["name"], REF_TAG]]
		if now["solid"] <= 0:
			print("! %s 一个实心像素都没有 —— 取景坐标可能不对" % shot["name"])
			continue
		if ref["solid"] > 0 and absf(float(now["solid"] - ref["solid"])) / float(ref["solid"]) > 0.05:
			print("! %s 实心像素数差了 5%% 以上（%d vs %d）—— 两个变体的几何不一致，值得查" % [
				shot["name"], now["solid"], ref["solid"]])
		var gap: int = ref["bright"] - now["bright"]
		if now["bright"] > ref["bright"]:
			print("! %s 亮像素比 [%s] 还多（%d vs %d）" % [
				shot["name"], REF_TAG, now["bright"], ref["bright"]])
		elif gap >= 10:
			print("OK %s 亮像素 %d，%s %d —— 参照明显更脏，修复在起作用" % [
				shot["name"], now["bright"], REF_TAG, ref["bright"]])
		else:
			# 掠射角高光是视角相关的：这个固定姿势下参照组自己都复现不出白边，
			# 那么"两者一样"什么也不能说明 —— 不能据此下结论。
			print("-- %s 亮像素 %d，%s %d（只差 %d）：这个姿势复现不出白边，"
				% [shot["name"], now["bright"], REF_TAG, ref["bright"], gap]
				+ "别据此判断，要看白边请在游戏里转视角观察")
	print("==========================================")
	print("图已存到: %s" % ProjectSettings.globalize_path(_out_dir))
	print("  *_深底.png 是叠在深色桌面上的效果，白边在它上面最容易看出来")
