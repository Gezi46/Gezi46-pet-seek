extends SceneTree
## 把模型里的**静态姿势动画**逐个渲出来，确认它们到底摆成什么样。
##
## ── 为什么需要它（2026-10-10 立的）──────────────────────────────────────────
## 这个模型的动画名**不能信**：`sit` / `sneaking` / `extra1` 三个动画
## **播出来和站立一模一样**（不改变姿势），而代码里原来把 `extra1` 当成"悲伤：蜷缩"用。
## 我是渲图才发现的 —— 光看动画名、光看代码，会以为"坐下"已经做好了。
##
## 所以：**要用某个姿势动画之前，先跑这个看一眼**。它输出的 PNG 直接能看。
##
## 用法:
##   godot --path . --script res://tools/probe_pose_dump.gd
##   → 项目根目录出现 _pose_<动画名>.png，并在控制台打出每个动画的长度 / 轨道数
##
## 想加一个候选：改下面的 SHOTS。**要带窗口跑**（无头模式下拿不到画面）
##
## 看门狗必须有（`--script` 模式下不调 quit 进程就一直挂着）

## 值得看一眼的姿势候选。加名字就行 —— 不在模型里的会自动跳过并提示
const SHOTS: Array[String] = [
	"sit", "sleep", "sneaking", "climbing", "extra1",
	"idle", "walk",
]

var _f := 0
var _pet: Node = null

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_f += 1
	if _f > 2000:
		printerr("看门狗触发：探针超时")
		quit(2)
		return true
	return false

func _run() -> void:
	print("=== 姿势动画速览 ===")
	var packed: PackedScene = load("res://scenes/pet.tscn")
	if packed == null:
		printerr("加载 pet.tscn 失败")
		quit(1)
		return
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 40:
		await process_frame

	# 冻结桌宠自己的逻辑：不然它会自己切动画，截到的不是我们要的那个姿势
	_pet.set_process(false)
	var player: AnimationPlayer = _pet.get_node("Character/Pivot/Model/AnimationPlayer")

	for name in SHOTS:
		if not _pet._has.has(name):
			print("  （模型里没有 %s，跳过）" % name)
			continue
		player.play(name)
		# 少等几帧让混合（blend）走完，否则截到的是上一个动画的残余
		for i in 8:
			await process_frame
		var img: Image = get_root().get_texture().get_image()
		var out := "res://_pose_%s.png" % name
		img.save_png(out)
		print("  %-12s 长度=%.3f 轨道=%d → %s" % [
			name, player.current_animation_length,
			player.get_animation(name).get_track_count(), out])

	print("")
	print("把那些 PNG 挨个打开看一眼：**名字说「坐着」的很可能其实站着**。")
	print("挑好之后把结论写进 pet_walk.gd 的 REST_POSE 那段注释里。")
	quit(0)
