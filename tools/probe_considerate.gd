extends SceneTree
## 验「体谅」：`scripts/body/pet_considerate.gd`。
##
## 重点是**它和生闷气的边界** —— 那是这个功能唯一会坏的地方（退化成"第二个生闷气"）。
## 所以断言全围着那三条硬约束转：
##   1. 不进体谅就不清生闷气计时（否则把生闷气废掉）
##   2. 正在闹脾气（生气占比高）就不走体谅，交给 pet_mood
##   3. 回来之后有冷却，不重复进
##
## 全离线：时间用 `now_ms` 注入，不用等真时间；宿主用一个假节点（只提供 `_mood` / `_say`）。
##
## 用法: godot --headless --path . --script res://tools/probe_considerate.gd
## 看门狗必须有（`--script` 模式下不调 quit 进程就一直挂着）

const Considerate := preload("res://scripts/body/pet_considerate.gd")
const PetMood := preload("res://scripts/body/pet_mood.gd")

var _pass := 0
var _fail := 0
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 2000:
		printerr("看门狗触发：探针超时")
		quit(2)
		return true
	return false

func _run() -> void:
	print("=== 体谅自检 ===")
	_test_trigger()
	_test_mutex_with_mood()
	_test_cooldown()
	_test_answered()
	_test_return_line()
	print("")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ------------------------------------------------------------------ 断言

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

# ------------------------------------------------------------------ 造一个假宿主

## 造一个"弱类型宿主"：只挂 `_mood`（读生气占比）和 `_say`（进场那句）。
## 用**真** pet_mood 实例而不是打桩 —— 因为"生气占比"正是要验的那个判据
func _rig(angry: float = 0.0) -> Dictionary:
	return _rig_mixed(0.0, angry)

## happy / angry 可分别摆：`share()` 算的是**占比**，所以"生气 0.25 且没有别的情绪"
## 的占比其实是 1.0（算在闹脾气）；要造"不占绝对多数"的场景必须给开心也来一点
func _rig_mixed(happy: float, angry: float) -> Dictionary:
	var script := GDScript.new()
	script.source_code = "extends Node\nvar _mood = null\nvar said: Array = []\nfunc _say(t: String) -> void:\n\tsaid.append(t)\n"
	script.reload()
	var host := Node.new()
	host.set_script(script)
	var m = PetMood.new()
	m.setup(null)
	if happy > 0.0 or angry > 0.0:
		m.set_levels(happy, angry, 0.0)
	host._mood = m
	var c = Considerate.new()
	c.setup(host)
	return {"host": host, "c": c}

# ------------------------------------------------------------------ 触发

func _test_trigger() -> void:
	print("\n[1] 触发条件")
	var r := _rig()
	var c = r["c"]
	_eq(c.unanswered(), 0, "一开始 0 次没被接")
	_ok(not c.note_spoke(1000), "第 1 次开口没人接 → 还不进体谅（不够次数）")
	_eq(c.unanswered(), 1, "记下 1 次")
	_ok(c.note_spoke(2000), "第 2 次 → 进体谅")
	_ok(c.is_on(), "is_on() = true")
	_ok(c.is_on() and c.until_ms() == 2000 + int(Considerate.CONSIDERATE_SEC * 1000.0),
		"保持 %d 分钟（可预期）" % int(Considerate.CONSIDERATE_SEC / 60.0))
	# 在体谅里再开口不算（她本来就不该开口；真调到了也只是不重复进）
	_ok(not c.note_spoke(3000), "已经在体谅里 → 再调不重复进")
	_eq(c.unanswered(), 0, "进体谅后计数清零（回来重新数）")
	_ok((r["host"] as Node).said.size() >= 1, "进场说了一句")
	if (r["host"] as Node).said.size() >= 1:
		print("      她说的：%s" % String((r["host"] as Node).said[0]))
	(r["host"] as Node).free()

# ------------------------------------------------------------------ 和生闷气互斥

func _test_mutex_with_mood() -> void:
	print("\n[2] 和生闷气的边界（这个功能唯一会坏的地方）")
	# 生气占比已经到 0.4 → 不走体谅，交给 pet_mood 正常闹
	var r1 := _rig(0.5)
	var c1 = r1["c"]
	c1.note_spoke(1000)
	_ok(not c1.note_spoke(2000), "生气占比 0.5（≥0.4）→ 不进体谅")
	_ok(not c1.is_on(), "is_on() 仍是 false —— 交给生闷气那条路")
	(r1["host"] as Node).free()
	# 有点小别扭但还没到线（0.25，正是"第一次没被接"之后的真实值）→ 仍然可以懂事
	# ⚠️ 注意 `share()` 返回的是**占比**：只有生气 0.25 时它的占比是 1.0（>0.4）⇒ 其实算"在闹"。
	# 现实里要到"开心和生气都有一些、生气不占绝对多数"才轮得到体谅，
	# 所以这条用一个**混合心态**来摆（开心 0.6 / 生气 0.3 → 生气占比 1/3 < 0.4）
	var r2 := _rig_mixed(0.6, 0.3)
	var c2 = r2["c"]
	c2.note_spoke(1000)
	_ok(c2.note_spoke(2000), "生气占比 1/3（<0.4）→ 可以进体谅（先小别扭、再懂事）")
	(r2["host"] as Node).free()
	# 关键：**体谅这条路不生气** —— 它只读 mood，不写
	var r3 := _rig()
	var c3 = r3["c"]
	var before: float = float((r3["host"] as Node)._mood._angry)
	c3.note_spoke(1000)
	c3.note_spoke(2000)
	var after: float = float((r3["host"] as Node)._mood._angry)
	_eq(after, before, "走体谅**一点生气都不加**（它和生闷气的根本区别）")
	(r3["host"] as Node).free()

# ------------------------------------------------------------------ 冷却

func _test_cooldown() -> void:
	print("\n[3] 冷却：回来之后不立刻再进")
	var r := _rig()
	var c = r["c"]
	c.note_spoke(1000)
	c.note_spoke(2000)
	_ok(c.is_on(), "进了体谅")
	# 保持期结束 → 自己回来
	c.tick(2000 + int(Considerate.CONSIDERATE_SEC * 1000.0))
	_ok(not c.is_on(), "保持期到 → 自己回来（**不用哄**，这是和生闷气的分界）")
	# 冷却期内又两次没人接 → 不再进
	c.note_spoke(3000)
	_ok(not c.note_spoke(4000), "冷却期内又没人接 → 不重复进体谅（否则节奏假得像机器）")
	_ok(not c.is_on(), "仍在正常状态")
	# 冷却过后又可以进（注意：`_unanswered` 在测试里已经被推到 2，所以**第一次调用就会进**，
	# 而进的时候计数会清零 —— 所以下面这行读到的 0 是"刚进过"，不是"没记上"）
	const KEEP_MS := int(Considerate.CONSIDERATE_SEC * 1000.0)
	const COOL_MS := int(Considerate.COOLDOWN_SEC * 1000.0)
	var base := 2000 + KEEP_MS + COOL_MS + 10000      # 保持期和冷却都过了之后
	_ok(c.note_spoke(base) and c.is_on(),
		"冷却过了 → 又能进体谅（这次一调就进，因为上次的计数还留着）")
	(r["host"] as Node).free()

# ------------------------------------------------------------------ 被理了

func _test_answered() -> void:
	print("\n[4] 主人理她了 → 立刻回来，不记仇")
	var r := _rig()
	var c = r["c"]
	c.note_spoke(1000)
	c.note_spoke(2000)
	_ok(c.is_on(), "先进体谅")
	c.note_answered()
	_ok(not c.is_on(), "她一被理就立刻回来")
	_eq(c.unanswered(), 0, "计数清零")
	# 被打断的体谅**不进冷却**：他是真有事才应一声，不该罚她等。
	# 注意：被打断时计数也清零了，所以要**重新攒够两次**才轮到门槛
	_ok(not c.note_spoke(3000), "打断后第 1 次开口 → 只是重新计数（不立刻进）")
	_ok(c.note_spoke(3100), "第 2 次 → 又能进体谅（没被罚冷却，这条是重点）")
	_ok(c.is_on(), "is_on() = true")
	(r["host"] as Node).free()

# ------------------------------------------------------------------ 回来那句

func _test_return_line() -> void:
	print("\n[5] 回来那句")
	var r := _rig()
	var c = r["c"]
	_ok(not c.take_back_line(), "没回来过 → 没有待说的话")
	c.note_spoke(1000)
	c.note_spoke(2000)
	_ok(not c.take_back_line(), "进了体谅但还没到点 → 没有待说的话")
	c.tick(2000 + int(Considerate.CONSIDERATE_SEC * 1000.0))
	_ok(c.take_back_line(), "到点回来 → 有待说的话（宿主负责 _say 出去）")
	_ok(not c.take_back_line(), "取过一次就清掉（不会重复说）")
	_ok(c.back_line() != "", "回来那句文案非空")
	(r["host"] as Node).free()
