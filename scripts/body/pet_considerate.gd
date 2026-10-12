extends RefCounted
## 体谅 —— "你在忙吧，我先不吵你"（2026-10-10）。##
## ── 它解决什么（先说清它**不是**什么）──────────────────────────────────────
## 这个仓原来只有两个选择：**生气**，或者**闭嘴**（而闭嘴也是生气的产物，见 pet_mood 的
## is_muted）。也就是说"主人连着几次没接话"这件事，她**只会往闹脾气那条路上走**。
##
## 但一个 18 岁的女孩子还有第三种反应：**懂事**。不是不高兴，是"他大概在忙"。
## 所以这个模块补的是**另一条轴**，不是第五种情绪：
##
##   pet_mood.gd        管**情绪强度**（开心 / 生气 / 悲伤三档，各自半衰期）
##   pet_considerate.gd 管**怎么解读主人的沉默**（他忙 vs 他不在乎）
##
## ── 和生闷气的边界（这段是设计核心，改动前先读完）────────────────────────
## 两条路的触发条件和后果**故意不同**：
##
##   |          | 生闷气（pet_mood）      | 体谅（本模块）            |
##   | 触发     | 说完话 90 秒没人理      | 主动开口**连续 N 次**没被接 |
##   | 前提     | 无条件（除非正开心）    | **生气占比还得低**（还没气起来）|
##   | 情绪后果 | 生气 +0.25              | **不生气**（这是关键）    |
##   | 状态     | is_muted，**要哄**      | 安静一段可预期的时间，**不用哄** |
##   | 解除     | 只能 soothe()（被哄）   | 你一说话/摸她，**立刻**回来，不记仇 |
##
## 三条硬约束，缺一条就会退化成"第二个生闷气"：
##   1. **不进体谅的就不清计时** —— 只有真进了才清 `_wait_ms`，
##      否则"开两次口"就把 90 秒的生闷气计时抹掉，等于把生闷气废掉
##   2. **正在闹情绪（生气占比 ≥ tolerate）就不走这条** —— 交给 pet_mood，
##      她会正常地闹。这条保证"生气和体谅互斥"，不会两条一起攒
##   3. **回来了有一小段冷却** —— 不留冷却的话，一开口没人接就立刻再进体谅，
##      节奏上会变成"每隔 15 分钟固定说一句我不吵你"，比生闷气还假
##
## ── 真实对话里怎么触发（没那么容易）──────────────────────────────────────
## 主动开口之间至少隔几分钟，而**她说完之后 90 秒没人理就会生闷气**
## （生气 +0.25，两次就 ≥60% 进 is_muted）。所以现实中：
##   第一次没被接 → 生闷气，生气 0.25
##   第二次没被接 → 生气 0.5，still < 0.6，**这时候才是体谅的窗口**
## 也就是说她通常先小别扭一下、再懂事 —— 顺序是对的，不是设计失误。
##
## ── 对宿主的接口面（只列真正用到的）────────────────────────────────────────
##   host._mood           问"他现在多生气"（share(Mood.ANGRY)）—— 只读
##   host._rng            随机源（和宿主共用一个，行为才一致，同 pet_mood 的理由）
##   host._say()          进场那句
##
## 验证：`tools/probe_considerate.gd` —— 触发条件 / 互斥 / 冷却 / 解除
##      全写成可注入 now_ms，所以不用等真时间

## 连体谅的门槛：主动开口连着这么多次没被接
const UNANSWERED_LIMIT := 2
## 体谅状态保持多久（秒）。**可预期**是这个状态的意义：她会真的安静这一段时间，
## 而不是"一直不理你"（那是生闷气）。到点自己回来，不需要哄
const CONSIDERATE_SEC := 15.0 * 60.0
## 回来之后的冷却（秒）：这段时间内即使又没人接，也不重复进体谅（见文件头第 3 条）
const COOLDOWN_SEC := 5.0 * 60.0
## 生气占比到这儿就不走体谅了 —— 她已经在闹脾气，交给 pet_mood（文件头第 2 条）。
## 取值和 pet_mood 的 MUTE_SHARE(0.6) 之间留出空隙：0.4~0.6 这段是"有点小别扭但还没闭嘴"，
## 那时候她**可以**懂事一下
const TOLERATE_ANGRY_SHARE := 0.4

## 进场说的那几句。**别写成委屈话**（那正是生闷气）——
## 语气是"体谅"，落点在"我在"：让她听起来是让路，不是赌气
const LINES_ENTER: Array[String] = [
	"你好像挺忙的，那我先不打扰啦。",
	"唔，你先忙吧～我在这儿等着。",
	"那我安静一会儿，忙完再叫我。",
]
## 回来时说的（保持期结束）。**轻**，别搞得像等了很久
const LINES_BACK: Array[String] = [
	"忙完了吗？我回来啦。",
	"诶，你忙完了呀。",
]

var _host = null
var _rng := RandomNumberGenerator.new()

## 情绪那条的枚举（判"他现在多生气"要用）。**preload 平级模块是允许的** ——
## pet_mood 不会再依赖回来，不构成循环（宪法第三节禁的是互相 preload）。
## 先例：pet_touch.gd 也是这么 preload pet_mood 拿来用 NOTE_CHEST
const PetMood := preload("res://scripts/body/pet_mood.gd")

## 连续几次主动开口没被接
var _unanswered: int = 0
## 在体谅状态里吗
var _on: bool = false
## 体谅到什么时候结束（ms，0 = 没在体谅）
var _until_ms: int = 0
## 冷却到什么时候（ms）
var _cooldown_until_ms: int = 0
## 上一次"回到正常"是不是该说一句（宿主在 tick 里取走并清掉）
var _pending_back_line: bool = false

func setup(host) -> void:
	_host = host
	_rng.randomize()

# ------------------------------------------------------------------ 对外状态

## 现在在体谅吗。宿主拿它当**第二道主动开口门禁**（第一道是 pet_mood.is_muted）
func is_on() -> bool:
	return _on

func unanswered() -> int:
	return _unanswered

## 给探针/调试看
func until_ms() -> int:
	return _until_ms

## 她现在算不算"在闹情绪"（生气占比够高）—— 高了就不走体谅（文件头第 2 条）。
## 宿主是弱类型，所以这里要把 `_mood` 判空
func _too_angry() -> bool:
	if _host == null or _host._mood == null:
		return false
	return float(_host._mood.share(PetMood.Mood.ANGRY)) >= TOLERATE_ANGRY_SHARE

# ------------------------------------------------------------------ 事件

## 她刚刚主动开口说了一句（**说出去之后**才调 —— 后端连不上那种不算"开口"）。
## 返回 true = 这一次就把她推进了体谅状态（宿主据此决定要不要顺手清掉生闷气计时）
func note_spoke(now_ms: int) -> bool:
	if _on:
		return false
	_unanswered += 1
	if _unanswered < UNANSWERED_LIMIT:
		return false
	# 还在冷却里：不重复进（文件头第 3 条）
	if now_ms < _cooldown_until_ms:
		return false
	# 已经在闹脾气了：交给 pet_mood，别抢它的戏（文件头第 2 条）
	if _too_angry():
		return false
	_enter(now_ms)
	return true

## 主人理她了（打字 / 摸头 / 喂食 / 哄 / 点候选 —— 宿主在 _soothe 里调）。
## **立刻回来，不记仇**：这正是它和生闷气的分界（那条要哄，这条不用）
func note_answered() -> void:
	_unanswered = 0
	if not _on:
		return
	_on = false
	_until_ms = 0
	# 被打断的体谅**不进冷却**：他是真有事才应一声，不该罚她等 5 分钟
	_cooldown_until_ms = 0
	if OS.is_debug_build():
		print("[PetDeek] 体谅结束：主人理她了")

## 每帧：保持期到了就自己回来。now_ms 可注入（探针要造"时间到了"）
func tick(now_ms: int = -1) -> void:
	if not _on:
		return
	var now := now_ms
	if now < 0:
		now = Time.get_ticks_msec()
	if now < _until_ms:
		return
	_on = false
	_until_ms = 0
	_cooldown_until_ms = now + int(COOLDOWN_SEC * 1000.0)
	_unanswered = 0
	_pending_back_line = true
	if OS.is_debug_build():
		print("[PetDeek] 体谅到点了：她自己回来（冷却 %.0f 分钟）" % (COOLDOWN_SEC / 60.0))

## 取走"该说一句我回来了"这个标记（取一次就清）
func take_back_line() -> bool:
	var v := _pending_back_line
	_pending_back_line = false
	return v

# ------------------------------------------------------------------ 内部

func _enter(now_ms: int) -> void:
	_on = true
	_until_ms = now_ms + int(CONSIDERATE_SEC * 1000.0)
	_unanswered = 0
	if _host != null and _host.has_method("_say"):
		_host._say(_pick(LINES_ENTER))
	if OS.is_debug_build():
		print("[PetDeek] 连着 %d 次开口没人接，又没生气 → 她决定先不打扰" % UNANSWERED_LIMIT)

func _pick(lines: Array) -> String:
	if lines.is_empty():
		return ""
	return String(lines[_rng.randi_range(0, lines.size() - 1)])

## 回来那句（宿主在 tick 里看到 take_back_line() 为真时用）
func back_line() -> String:
	return _pick(LINES_BACK)

# ------------------------------------------------------------------ 给探针用

## 直接摆状态（探针要造"已经体谅了一会儿"这种场景，不用等真时间）
func debug_set(answering: int, on: bool, until_ms: int, cooldown_until_ms: int) -> void:
	_unanswered = answering
	_on = on
	_until_ms = until_ms
	_cooldown_until_ms = cooldown_until_ms
