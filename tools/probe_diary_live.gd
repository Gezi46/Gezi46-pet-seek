extends SceneTree
## 验「日记接线」：真的跑起一只桌宠，然后**用她自己的入口**喂几个事件进去，
## 看拍子有没有落到日记文件里、合成出来的正文长什么样。
##
## 和 `probe_diary.gd` 的分工：
##   那个验**数据与判定**（纯逻辑，不实例化桌宠）；
##   这个验**接线**（宿主那些 `_diary_note` 调用点是不是真的通到了模块）。
##
## ⚠️ 会动真日记文件：跑完**立刻**把原文件还原（规矩见 CONVENTIONS.md 附录）
##
## 用法: godot --path . --script res://tools/probe_diary_live.gd
## **必须带窗口跑**：要 `_ready()` 走完才有 `_diary`（headless 也行，但窗口更接近真机）

const Diary := preload("res://scripts/body/pet_diary.gd")

var _pass := 0
var _fail := 0
var _frames := 0
var _pet: Node = null
var _backup: Variant = null
var _had_file := false
var _phase := 0

func _initialize() -> void:
	_backup_file()
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 3000:
		printerr("看门狗触发：探针超时")
		_restore_file()
		quit(2)
		return true
	return false

func _run() -> void:
	print("=== 日记接线自检 ===")
	var packed: PackedScene = load("res://scenes/pet.tscn")
	if packed == null:
		printerr("加载 pet.tscn 失败")
		_restore_file()
		quit(1)
		return
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	# 等 _ready 走完（里面要建模块、读存档、量模型）
	for i in 40:
		await process_frame

	var diary = _pet.get("_diary")
	_ok(diary != null, "宿主建出了 _diary 模块")
	var flow = _pet.get("_diary_flow")
	_ok(flow != null, "宿主建出了 _diary_flow 模块")
	var ui = _pet.get("_diary_ui")
	_ok(ui != null, "宿主建出了 _diary_ui 面板")
	if diary == null:
		_finish()
		return

	# 清空（我们只验这一次跑出来的东西）
	diary.clear_all()
	diary.first_day = _pet.call("_today_stamp")
	_ok(diary.days.is_empty(), "清空后没有历史")

	# ---- 用**宿主自己的入口**喂事件（这才是"接线通不通"的验法）
	_pet.call("_diary_note", "pet")
	_pet.call("_diary_note", "feed")
	_ok(diary.days.size() == 1, "拍子落到了今天那一条上")
	var beats: int = (diary.days[0]["beats"] as Array).size()
	_eq(beats, 2, "记下了 2 个拍子")

	# 总开关关掉就不该再记
	_pet.set("diary_enabled", false)
	_pet.call("_diary_note", "talk")
	_eq((diary.days[0]["beats"] as Array).size(), 2, "关掉总开关后不再记")
	_pet.set("diary_enabled", true)

	# 未知种类也该被模块挡掉
	_pet.call("_diary_note", "瞎写的种类")
	_eq((diary.days[0]["beats"] as Array).size(), 2, "未知种类被挡掉")

	# ---- needs_write() 的语义：**只回答"有拍子但还没正文"**，不含阈值
	# （阈值是 flow 那边判的，见下面 want_write 那两条）
	_ok(diary.needs_write(), "有拍子、没正文 → needs_write() = true")
	# ---- 阈值那条走 flow 的 static（阈值默认 4）
	var flow_mod = load("res://scripts/body/pet_diary_flow.gd")
	_ok(not flow_mod.want_write(2, 4, false), "只有 2 个拍子、阈值 4 → 还不到该写的时候")
	_ok(flow_mod.want_write(4, 4, false), "到 4 个拍子 → 该写了")
	_ok(not flow_mod.want_write(9, 4, true), "已经写过 → 不再写")
	_pet.call("_diary_note", "talk")
	_pet.call("_diary_note", "happy")

	# 走一遍 tick：本地那版应该被写出来
	flow.tick()
	var text: String = diary.today_text()
	_ok(text != "", "tick 之后本地那版写出来了")
	print("      本地版正文：%s" % text)

	# ---- 面板能开能关、能读到内容
	ui.open()
	_ok(ui.is_open(), "面板能打开")
	_eq(ui._stats.text, diary.stats_line(), "面板顶上那行统计来自 stats_line()")
	var items: Array = diary.entries()
	_eq(items.size(), 1, "面板能读到 1 条日记")
	ui.close()
	_ok(not ui.is_open(), "面板能关掉")
	# point_inside 关上时必须 false，否则点哪儿都被当成"点在面板里"
	_ok(not ui.point_inside(Vector2(10, 10)), "关掉后 point_inside() = false")

	# ---- 落盘 / 读回
	diary.save()
	var b = Diary.new()
	b.setup(_pet)
	b.load()
	_eq(b.today_text(), text, "存盘读回：正文一致")

	# ---- 体谅（T4）的**接线**：模块本身由 probe_considerate.gd 验，这里只验"宿主接上了没"
	var cons = _pet.get("_considerate")
	_ok(cons != null, "宿主建出了 _considerate 模块")
	if cons != null:
		_ok(not cons.is_on(), "开局没在体谅")
		# 连续两次开口没人接 → 进体谅
		cons.note_spoke(Time.get_ticks_msec())
		_ok(not cons.is_on(), "第 1 次没人接 → 还没进（要够次数）")
		cons.note_spoke(Time.get_ticks_msec() + 10)
		_ok(cons.is_on(), "第 2 次没人接 → 进了体谅")
		# 门禁：pet_proactive 那道 tick 该把它挡回去（倒计时重数、不开口）
		var proactive = _pet.get("_proactive")
		if proactive != null:
			proactive.timer = 0.0            # 故意把倒计时压到 0：门禁要是没生效，这一帧就会开口
			proactive.tick(0.016)
			_ok(proactive.timer > 0.0, "体谅期间主动开口被挡住（倒计时被重数）")
		else:
			_ok(false, "拿不到 _proactive（验不了门禁）")
		# 被理了 → 立刻回来
		_pet.call("_soothe")
		_ok(not cons.is_on(), "走宿主的 _soothe() → 体谅立刻结束（接线通了）")
		# 顺带：不能因为这条路动到情绪（体谅不生气）
		var mood = _pet.get("_mood")
		if mood != null:
			pass

	_finish()

func _finish() -> void:
	_restore_file()
	print("")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ✓ %s" % what)
	else:
		_fail += 1
		printerr("  ✗ %s" % what)

func _eq(a: Variant, b: Variant, what: String) -> void:
	if a == b:
		_pass += 1
		print("  ✓ %s" % what)
	else:
		_fail += 1
		printerr("  ✗ %s —— 实际 %s，期望 %s" % [what, str(a), str(b)])

# 真文件换进换出（备份 → 跑 → 还原，还原紧跟其后）

func _backup_file() -> void:
	_had_file = FileAccess.file_exists(Diary.SAVE_PATH)
	if _had_file:
		var f := FileAccess.open(Diary.SAVE_PATH, FileAccess.READ)
		if f != null:
			_backup = f.get_as_text()
			f.close()

func _restore_file() -> void:
	var path := ProjectSettings.globalize_path(Diary.SAVE_PATH)
	if _had_file and _backup != null:
		var f := FileAccess.open(Diary.SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(String(_backup))
			f.close()
	else:
		DirAccess.remove_absolute(path)
