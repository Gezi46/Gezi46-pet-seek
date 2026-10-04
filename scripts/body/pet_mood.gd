# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 情绪：委屈度（"生闷气"）+ 被摸到的反应。
##
## **只放状态和判定，不开口说话**。她说什么、第一次要不要截图偷看一眼、动作怎么播 ——
## 那些要窗口 / 视觉 / 流式气泡，本该留在主控，这里只发信号让它去做。
## 这条边界是拆这块时定下来的：想往本文件里加"说话"的代码，先想想它是不是该留在宿主。
##
## 为什么两块（生闷气 / 被摸）放一起：它们是**同一条情绪线** ——
## 反复手欠会累积成生闷气，委屈度又进人设的【现在】。分成两个文件会立刻开始互相同步。
##
## 对主控的接口面（只列真正用到的）：
##   host._offline()   离线不算被冷落（她等的本来就是"你回她话"）
##   host._rng         随机源跟宿主共用一个，行为才一致（台词 / 动作的选择）
##   三个信号（宿主接了以后自己去开口）：
##     sulk_timeup(first)                    该生闷气了
##     touch_line(line, attack, worth_noting) 摸到了：说什么 / 播不播"被欺负" / 要不要记一笔
##     touch_overflow                        摸太频繁 → 走"她主动开口喊停"那条
##   宿主还要调：level()（写进人设）、start_waiting()、soothe()、
##              should_store_sulk() / should_store_touch()（记忆那边判该不该记）
##
## 验证：`touch_burst_hit()` 写成 static，probe_memory.gd 直接试；
##      probe_offline.gd 模拟"等超时"看会不会生闷气

## 该生闷气了。first = 这一轮里第一次被冷落（宿主会先偷看一眼屏幕再让她开口）
signal sulk_timeup(first: bool)
## 连续被冷落到 SULK_MAX 次：她**决定不主动开口了**（2026-09-27 用户要求"连续不搭理
## 四次之后就生气不说话了需要哄"）。宿主说最后一句话，然后由 is_muted() 把主动开口关掉
signal giving_up
## 闭嘴之后超过 SULK_RECONCILE_SEC 还没被哄：她偷偷看一眼主人在忙什么 ——
## 在忙就自我和解（宿主去窥屏判断，见宿主的 _on_reconcile_check）
signal reconcile_check
## 摸到了：line 是要说的话；attack = 播"被欺负"那个动作；worth_noting = 值得记一笔
signal touch_line(line: String, attack: bool, worth_noting: bool)
## 摸得太频繁：宿主去走"她主动开口让你停手"那条（要流式气泡 + 记忆）
signal touch_overflow
## 心情变了（生气/伤心/开心/平常心/坏心眼之间切换）——
## 宿主拿它去播"能体现这个情绪的动作"（2026-10-01 用户要求）
signal mood_changed(mood: int)

# ------------------------------------------------------------------ 心情（2026-10-01 用户要求）

## 她的心情。原来只有"生气"一种（委屈度），现在扩成五种：
## 生气 / 伤心 / 开心 / 平常心 / 坏心眼。**当前心情 = `mood()`**，写进人设的【现在】，
## 所以她的口气会自然跟着变（判定归这里，说话在人设、行为在宿主那边）。
## 约定：负面心情（伤心 / 生气）会盖过往开心 —— 她正委屈着，不会因为被摸一下就立刻乐。
enum Mood { NEUTRAL, HAPPY, ANGRY, SAD, MISCHIEF }

## 开心 / 坏心眼随时间回落的速度（每秒）——"一阵子"的情绪会自己淡下去。
## **每个情绪最多维持 1 小时**（2026-10-01 用户要求），所以按 1 小时从满到没算。
## （被冷落攒的委屈度不这样衰减，它归 soothe 清）
const MOOD_DECAY_PER_SEC := 1.0 / 3600.0
## 坏心眼每秒冒出来的概率。她平静着的时候才会来（见 _tick_mood）——0.001 ≈ 十几分钟一次
const MISCHIEF_CHANCE_PER_SEC := 0.001
## 开心 / 坏心眼的度超过它就"算这个心情"（度是 0~1）
const MOOD_THRESHOLD := 0.5

# ------------------------------------------------------------------ 台词（这块自己的内容）

## 摸头的台词。原来在主控的 LINES_PET 里，现在归这块 —— 它只在这儿用
const LINES_PET: Array[String] = [
	"嘿嘿…再摸摸～", "谁、谁准你摸我头的！", "诶…好舒服。", "唔，有点痒啦。",
]
## 摸不同部位的反应。**分寸是写这段的重点**：头 / 手 / 腿 是亲昵，摸到胸得明确不乐意 ——
## 一个 18 岁的女孩子不会笑嘻嘻地接受，写软了这个人物立刻就假了。
## 部位由 scripts/pet_pointer.gd 的 classify_touch 判出来（它知道点击落在哪儿）
const TOUCH_LINES: Dictionary = {
	"chest": ["喂！你摸哪儿呢！", "色狼！手拿开！", "你、你干嘛啦！", "再乱摸我咬你啊。"],
	"hand": ["…牵手就牵手嘛。", "诶，你手好凉。", "干嘛突然牵我手啦。", "唔…就一下啊。"],
	"leg": ["别、别挠！痒…", "喂，腿也不行啦！", "哈哈…别闹！", "那里不能碰！"],
	"body": ["唔…干嘛。", "嘿嘿～", "别闹啦。", "诶，怎么了？"],
}
## 同一个地方被连着摸时的升级台词（摸胸专用）
const LINES_STOP: Array[String] = [
	"你再这样我真生气了啊。", "手拿开！说了不行就是不行。", "哼，不理你了。",
]
## 被冷落时她说的本地台词（AI 不可用时用）
const LINES_SULK: Array[String] = [
	"哼。", "不理我就算了…", "……我自己玩。", "喂，看我一眼嘛。",
]
## 连续被冷落到 SULK_MAX 次、她决定闭嘴时说的**最后一句**。
## 之后她不再主动开口，直到被哄（见 is_muted / soothe）——
## 所以这句要写"我不想说了"的味，别写成还想让你接话
const LINES_GIVE_UP: Array[String] = [
	"……哼，不说了。", "算了，你自己忙吧。", "……不理你了。",
]
## 被哄好了她说的一句（菜单「哄哄她」/ 你主动跟她说话之后）
const LINES_SOOTHED: Array[String] = [
	"……好啦，我没生气了。", "嗯…这还差不多。", "哼，看在你哄我的份上。",
]
## 自我和解（闭嘴久了偷看到你在忙、自己消气）时她说的一句
const LINES_RECONCILED: Array[String] = [
	"……看到你在忙，我就不闹你了。", "哼，算了，你忙你的吧。", "……原来你在忙啊，那我不打扰了。",
]
## 被摸烦了时的本地台词（AI 不可用时用）
const LINES_TOUCH_STOP: Array[String] = [
	"喂！别摸了！", "你手怎么这么闲啊…", "再摸我咬人了！", "够了吧，烦不烦。",
]
## 摸太频繁这一笔要写进记忆的那句话
const NOTE_TOUCH := "主人手欠，会一直摸她戳她；摸太频繁她会不耐烦（她不喜欢被一直摸）"
## 摸到不该摸的地方、还屡教不改时记的那句
const NOTE_CHEST := "主人手欠，乱摸她会挨凶；她不乐意被碰那里"

# ------------------------------------------------------------------ 节奏参数

## 她主动说完话之后，等主人回话最多等多久（秒）——超了就生闷气
const SULK_WAIT_SEC := 90.0
## 生闷气这条路记进记忆的最小间隔（毫秒）。半小时
const SULK_STORE_GAP_MS := 1800000
## 摸太频繁：多久以内的几下算"同一波"（毫秒）
const TOUCH_BURST_WINDOW_MS := 60000
## 一波里被摸几下她就受不了（**摸胸算两下**，所以摸胸 4 次就到线）
const TOUCH_BURST_LIMIT := 8
## 两次"喊你停手"之间至少隔多久（毫秒）
const TOUCH_COMPLAIN_GAP_MS := 60000
## 摸到胸：多短时间内的第二次算"屡教不改"（毫秒）
const CHEST_AGAIN_MS := 20000
## 委屈度到这儿，"屡教不改"才值得记进记忆
const CHEST_NOTE_LEVEL := 1.5
## 连续被冷落到这个次数：她**不主动开口了**（生气），要哄才回来。
## 2026-09-27 用户要求"连续不搭理四次之后就生气不说话了需要哄"。
## 原来是 3 封顶、且只影响口气 —— 现在第 4 次是个明确的台阶：闭嘴
const SULK_MAX := 4.0
## 闭嘴之后，超过这么久（秒）还没被哄：她偷偷看一眼你在忙什么，在忙就自我和解。
## 2026-09-30 用户要求"生闷气后不主动说话，超过半小时触发窥屏" —— 半小时
const SULK_RECONCILE_SEC := 1800.0

var _host: Node = null
## 委屈度。**写进人设的【现在】**，所以之后几轮她的口气自己就带出来了
var _sulk: float = 0.0
## 开心度 / 坏心眼度（0~1，随时间回落，见 MOOD_DECAY_PER_SEC）
var _happy: float = 0.0
var _mischief: float = 0.0
## 怨气满（闭嘴）之后她落在生气还是伤心 —— **50/50**（2026-10-01 用户要求）。
## 闭嘴那一刻掷一次（见 tick 的 giving_up 分支），默认生气
var _full_kind: int = Mood.ANGRY
## 上次算心情衰减的时刻（毫秒）。tick() 不带 delta，所以自己记时间差
var _last_mood_ms: int = 0
## 上一帧的心情：只在**真的变了**时发 mood_changed（见 _tick_mood）
var _last_mood: int = Mood.NEUTRAL
## 她在等主人回话的截止时刻（毫秒）。0 = 没在等
## 用"截止时刻"判断而不是每帧累加：中途主人一说话就会把它清掉（见 soothe）
var _wait_ms: int = 0
## 闭嘴后仍在等主人哄的截止时刻（毫秒）。0 = 没在等（还没闭嘴 / 已经被哄 / 刚触发过）
var _muted_wait_ms: int = 0
## 上次把"生闷气"记进记忆的时刻（毫秒），用来防止半小时内重复记
var _next_sulk_store_ms: int = 0
## 上次被摸到不该摸的地方的时刻（毫秒）。短时间内再来一次 = "屡教不改"，反应要升级
var _chest_again_ms: int = 0
## 最近一分钟内被摸的时刻（毫秒）。摸太频繁她会主动喊停，见 touch_burst_hit
var _touch_times: Array = []
## 下次允许"喊你停手"的时刻（毫秒）
var _next_complain_ms: int = 0
## 下次允许把"被摸烦了"记进记忆的时刻（毫秒）
var _next_touch_store_ms: int = 0

func setup(host: Node) -> void:
	_host = host

# ------------------------------------------------------------------ 心情

## 当前心情。判定顺序就是"谁压过谁"：
##   生气到顶（闭嘴）→ 伤心（闹累了，低落）
##   有点委屈（_sulk ≥ 1）→ 生气
##   坏心眼度够 → 坏心眼
##   开心度够 → 开心
##   都不是 → 平常心
func mood() -> int:
	if is_muted():
		return _full_kind      # 怨气满 → 对半下来的生气/伤心（见 full_mood_pick）
	if _sulk >= 1.0:
		return Mood.ANGRY
	if _mischief >= MOOD_THRESHOLD:
		return Mood.MISCHIEF
	if _happy >= MOOD_THRESHOLD:
		return Mood.HAPPY
	return Mood.NEUTRAL

## 在闹情绪、要哄的那种（生气 / 伤心）—— 宿主用它决定"点击给不给正常互动"。
## **开心 / 平常心时点击 = 正常摸头**（用户 2026-10-01 要求"开心时不给选择框、只是普通互动"）
func is_upset() -> bool:
	var m := mood()
	return m == Mood.ANGRY or m == Mood.SAD

## 怨气满时落在生气还是伤心：**对半**（2026-10-01 用户要求）。
## 抽成 static 是为了探针能验（骰子由外面传进来）
static func full_mood_pick(dice: float) -> int:
	return Mood.SAD if dice < 0.5 else Mood.ANGRY

## 现在受不受"被冷落"影响 —— **开心的时候不受**（心情好，不计较，用户 2026-10-01）。
## 抽出来是为了能离线验（tick 本身要 host，这条不用）
func _immune_to_sulk() -> bool:
	return _happy >= MOOD_THRESHOLD and not is_muted()

## 心情的名字（写进人设【现在】用）。static：探针直接试
static func mood_name(m: int) -> String:
	match m:
		Mood.HAPPY: return "开心"
		Mood.ANGRY: return "生气"
		Mood.SAD: return "伤心"
		Mood.MISCHIEF: return "坏心眼"
	return "平常"

## 开心：摸头 / 喂食 / 被哄好。amount 0~1
func cheer(amount: float = 1.0) -> void:
	_happy = minf(1.0, _happy + amount)

## 坏心眼：随机冒出来的那种（宿主/菜单也可以手动戳一下）
func tease(amount: float = 1.0) -> void:
	_mischief = minf(1.0, _mischief + amount)

## 每帧：开心 / 坏心眼随时间回落；她平静着的时候偶尔冒一次坏心眼
func _tick_mood() -> void:
	var now := Time.get_ticks_msec()
	if _last_mood_ms == 0:
		_last_mood_ms = now
		return
	var dt := float(now - _last_mood_ms) / 1000.0
	_last_mood_ms = now
	if dt <= 0.0:
		return
	_happy = maxf(0.0, _happy - dt * MOOD_DECAY_PER_SEC)
	_mischief = maxf(0.0, _mischief - dt * MOOD_DECAY_PER_SEC)
	# 坏心眼只在"平平静静"时冒（正委屈着 / 正开心着就别来添乱）
	if _sulk < 0.5 and _happy < 0.1 and _mischief < 0.1 \
			and _host != null and _host._rng.randf() < MISCHIEF_CHANCE_PER_SEC * dt:
		_mischief = 1.0
	# 心情变了就发一句（宿主拿它去播"能体现这个情绪的动作"）
	var m := mood()
	if m != _last_mood:
		_last_mood = m
		mood_changed.emit(m)

# ------------------------------------------------------------------ 生闷气

## 每帧调：看"等她回话"的时间到了没。到点就发 sulk_timeup，由宿主去开口
func tick() -> void:
	_tick_mood()      # 心情衰减 + 偶尔冒坏心眼（2026-10-01）
	# 闭嘴后的"持续冷落"计时：她不主动说话了，但主人一直没哄她。
	# 超过 SULK_RECONCILE_SEC 还没哄回来 → reconcile_check（宿主去偷看一眼，在忙就自我和解）
	if _muted_wait_ms > 0:
		if Time.get_ticks_msec() >= _muted_wait_ms:
			_muted_wait_ms = 0
			if OS.is_debug_build():
				print("[PetDeek] 闭嘴超过 %d 分钟没被哄：去看看主人在忙什么" % int(SULK_RECONCILE_SEC / 60.0))
			reconcile_check.emit()
		return
	if _wait_ms <= 0:
		return
	if Time.get_ticks_msec() < _wait_ms:
		return
	# 假死：离线时不生闷气 —— 她等的本来就是"你回她话"，断网不算被冷落
	if bool(_host._offline()):
		_wait_ms = 0
		return
	_wait_ms = 0
	# 心情好的时候不计较：开心着被冷落也不攒委屈度（用户 2026-10-01 要求"开心时不记录生气值"）
	if _immune_to_sulk():
		return
	var first := _sulk < 0.5      # 这一轮里的第一次被冷落
	_sulk = minf(SULK_MAX, _sulk + 1.0)
	if _sulk >= SULK_MAX:
		# 连着被冷落 SULK_MAX 次：这一次不是"再闹一句"，而是**彻底闭嘴** ——
		# 由宿主说最后一句，然后 is_muted() 把主动开口关掉（要哄才回来）。
		# 怨气满 → 生气 / 伤心**对半**（2026-10-01 用户要求）
		_full_kind = full_mood_pick(_host._rng.randf())
		if OS.is_debug_build():
			print("[PetDeek] 连着被冷落 %d 次：她不主动开口了（%s，等哄）" % [
				int(SULK_MAX), mood_name(_full_kind)])
		# 闭嘴后开始计时：超过 SULK_RECONCILE_SEC 还没被哄 → reconcile_check（见 tick 开头）
		_muted_wait_ms = Time.get_ticks_msec() + int(SULK_RECONCILE_SEC * 1000.0)
		giving_up.emit()
		return
	sulk_timeup.emit(first)

## 她说完话了，开始算"主人多久不理我"。到点还没反应就生闷气（见 tick）
func start_waiting() -> void:
	_wait_ms = Time.get_ticks_msec() + int(SULK_WAIT_SEC * 1000.0)

## 被理了就消气。聊天、摸头、喂食、菜单「哄哄她」都算 ——
## 别让她记仇记到没人愿意搭理她（这也是"需要哄"的解法：哄 = soothe）
func soothe() -> void:
	var was_upset := _sulk >= 1.0
	if _sulk > 0.0 and OS.is_debug_build():
		print("[PetDeek] 消气了（之前委屈度 %.1f）" % _sulk)
	_sulk = 0.0
	_wait_ms = 0
	_muted_wait_ms = 0
	# 哄好 → 变开心（用户 2026-10-01 要求"哄完变回开心"）；
	# 本来没在闹情绪的就小幅开心一下（被摸头 / 被喂也算）
	_happy = 1.0 if was_upset else minf(1.0, _happy + 0.4)

## 她现在是"生气了、不主动开口"的状态吗 —— 宿主在 _check_self_talk 里问它。
## 只有 soothe()（被哄 / 被理）能解除
func is_muted() -> bool:
	return _sulk >= SULK_MAX

## 委屈度。人设要把"她在生闷气"写进【现在】，所以宿主每轮拼人设时来取
func level() -> float:
	return _sulk

## 直接加委屈度（"她主动喊停"那一下要 +1）。
## 封顶和 tick() 一样是 SULK_MAX —— 漏了这一处的后果：这条路上永远到不了"生气闭嘴"
## （2026-09-27 探针抓到的：bump 到不了 4，is_muted 一直是 false）
func bump(amount: float) -> void:
	_sulk = minf(SULK_MAX, _sulk + amount)

## 生闷气这条现在值不值得记进记忆（判完顺手标上时间，半小时内不重复记）
func should_store_sulk(origin: String) -> bool:
	var now := Time.get_ticks_msec()
	if now < _next_sulk_store_ms:
		return false
	# 单纯闹脾气要连着被冷落两次才值得记；而"偷看看到的东西"本身就有信息量
	# （他当时在忙什么），所以偷看那条只要过了时间间隔就记
	if origin == "sulk" and _sulk < 2.0:
		return false
	_next_sulk_store_ms = now + SULK_STORE_GAP_MS
	return true

## 被摸烦了这一笔值不值得记（同一句半小时内不重复记，否则一晚上能存十条同义句）
func should_store_touch() -> bool:
	var now := Time.get_ticks_msec()
	if now < _next_touch_store_ms:
		return false
	_next_touch_store_ms = now + SULK_STORE_GAP_MS
	return true

## 给探针/调试看：她还在等回话吗（截止时刻，0 = 没在等）
func wait_deadline() -> int:
	return _wait_ms

## 给探针用：直接摆一个"已经超时"的截止时刻，模拟被冷落
func set_wait_deadline(ms: int) -> void:
	_wait_ms = ms

## 偷看一眼发现主人没在忙 → 不算"他忙得顾不上"，她继续生闷气，重新等一轮（再来 30 分钟）
func restart_muted_wait() -> void:
	_muted_wait_ms = Time.get_ticks_msec() + int(SULK_RECONCILE_SEC * 1000.0)

## 给探针/调试看：闭嘴后还在等哄吗（截止时刻，0 = 没在等）
func muted_wait_deadline() -> int:
	return _muted_wait_ms

## 给探针用：直接摆一个"已经超时"的截止时刻，模拟闭嘴后一直没被哄
func set_muted_wait_deadline(ms: int) -> void:
	_muted_wait_ms = ms

# ------------------------------------------------------------------ 被摸到

## 被摸到了。部位由 scripts/pet_pointer.gd 的 classify_touch 判出来：
## head / chest / hand / leg / body（菜单里的「摸摸头」没有坐标，默认就是 head）
##
## 分寸感是这段的重点：头 / 手 / 腿 是亲昵，摸到胸要**明确地不乐意**。
## 而且反复手欠会累积成生闷气 —— 和"被冷落"同一条情绪线
func touch(part: String) -> void:
	# 先看这一下是不是"摸得太频繁"了。是的话先别管摸的是哪儿 ——
	# 她会主动开口让你停手（那是宿主的事，见 touch_overflow）
	if _note_touch(part):
		bump(1.0)
		touch_overflow.emit()
		return
	var lines: Array = TOUCH_LINES.get(part, TOUCH_LINES["body"])
	if part == "head":
		lines = LINES_PET          # 头那一组就是原来的"摸头"台词，别维护两份
	var line := String(lines[_host._rng.randi_range(0, lines.size() - 1)])
	if part == "chest":
		# 20 秒内第二次 = 屡教不改：话变硬、气得更明显，而且**不消气**
		var now := Time.get_ticks_msec()
		var again: bool = now < _chest_again_ms
		_chest_again_ms = now + CHEST_AGAIN_MS
		# 被摸最多把她推到 3.0（**不推到"生气闭嘴"那条线** —— 摸她是理她，
		# 不该让她因此闭嘴），但用 maxf 兜住：不然她已经 3.5（被冷落攒的）时，
		# 摸一下反而把委屈度**拉低**（2026-09-27 顺出来的第二处旧封顶）
		_sulk = maxf(_sulk, minf(SULK_MAX - 1.0, _sulk + (1.0 if again else 0.5)))
		var worth := false
		if again:
			line = LINES_STOP[_host._rng.randi_range(0, LINES_STOP.size() - 1)]
			# 手欠到这份上，值得让她记一笔 —— 以后她会自己防着点
			worth = _sulk >= CHEST_NOTE_LEVEL
		if OS.is_debug_build():
			print("[PetDeek] 摸到胸：%s（委屈度 %.1f）" % [
				"屡教不改" if again else "第一次", _sulk])
		touch_line.emit(line, true, worth)
		return
	# 其他部位都算亲昵：先消气，再说那句话（动作由宿主随手挑，见 _on_touch_line）。
	# 顺手开心一下 —— 摸头 / 牵手 = 开心（2026-10-01）
	soothe()
	cheer(0.6)
	touch_line.emit(line, false, false)

## 这一下算不算"摸得太频繁"。顺手把窗口外的旧记录丢掉 ——
## Array 是引用类型，改的就是传进来的那个数组。
## 写成 static 是为了能**脱离场景**验证：tools/probe_memory.gd 直接拿它试，
## 不用去实例化整个桌宠（窗口 / 模型 / 相机那一套在无头模式里跑不起来）
static func touch_burst_hit(times: Array, now_ms: int, part: String) -> bool:
	while not times.is_empty() and now_ms - int(times[0]) > TOUCH_BURST_WINDOW_MS:
		times.pop_front()
	times.append(now_ms)
	if part == "chest":
		times.append(now_ms)   # 摸不该摸的地方算两下：摸胸 4 次就到线
	return times.size() >= TOUCH_BURST_LIMIT

## 记下这一下，并回答"该喊停了吗"。要过两道门：
##   1. 一分钟内到量（TOUCH_BURST_LIMIT）
##   2. 离上次喊停超过 TOUCH_COMPLAIN_GAP_MS —— 不然她会一句话接一句话地念
## 喊停之后把计数清空，重新数下一波
func _note_touch(part: String) -> bool:
	var now := Time.get_ticks_msec()
	if not touch_burst_hit(_touch_times, now, part):
		return false
	if now < _next_complain_ms:
		return false
	_next_complain_ms = now + TOUCH_COMPLAIN_GAP_MS
	_touch_times.clear()
	return true
