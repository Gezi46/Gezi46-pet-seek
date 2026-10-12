extends RefCounted
## 情绪：三维心态（开心 / 生气 / 悲伤）+ 被摸到的反应。
##
## **只放状态和判定，不开口说话**。她说什么、动作怎么播、要不要记一笔 ——
## 那些要窗口 / 视觉 / 流式气泡，本该留在主控，这里只发信号让它去做。
##
## ── 三维模型（2026-10-07 用户要求）────────────────────────────────────
## 内部存三个**强度**：`_happy` / `_angry` / `_sad`（各自 0~1、各自半衰期）。
## 对外一律按**占比**表达 —— "开心 60% / 生气 30% / 悲伤 10%"，有情绪时三者恒为 100%。
## 占比由 shares() 算，是**算出来的**不是存下来的（原因见下）。
##
## **为什么不直接存占比**：占比在"三个都很小"时会失真 —— 0.01 和 0.01 一归一就是
## 50% / 50%，她明明什么都没发生却显得"又开心又生气"。所以必须另有一个"总量"才能回答
## "她到底有没有情绪"。总量 < CALM_TOTAL 就叫**平常**：不注入任何情绪句、所有门禁都不触发。
## （用户要的是"三者相加恒为 100%"，这条落在**占比**上；内部多存一层强度只是为了不丢总量。）
##
## ── 和旧模型（单标签 + 委屈度 `_sulk`）的对应 ─────────────────────────
##   委屈度          → **生气占比**（`is_muted` / `is_upset` / `bump` 都改判占比）
##   坏心眼          → **并进开心**（tease() 现在加的是开心；调皮的味道留在描述句里）
##   怨气满分生气/伤心 → **删掉**：三维之后两种情绪本来就能并存，不需要二选一
##
## 对主控的接口面（只列真正用到的）：
##   host._offline()   离线不算被冷落（她等的本来就是"你回她话"）
##   host._rng         随机源跟宿主共用一个，行为才一致（台词 / 动作的选择）
##   六个信号（宿主接了以后自己去开口）：
##     sulk_timeup(first)                    该生闷气了
##     giving_up                             气到不主动开口了（要哄）
##     reconcile_check                       闭嘴够久：偷看一眼主人在忙什么
##     touch_line(line, attack, worth_noting) 摸到了
##     touch_overflow                        摸太频繁
##     mood_changed(mood)                    主导情绪变了（宿主去播对应动作）
##   宿主还要调：describe()（写进人设）、shares()/share()（设置面板显示）、
##              start_waiting()、soothe()、say_about_master()（悲伤入口）
##
## 验证：`touch_burst_hit()` / `share_of()` 写成 static，探针直接试；
##      probe_offline.gd 模拟"等超时"看会不会生闷气

## 该生闷气了。first = 这一轮里第一次被冷落（宿主会先偷看一眼屏幕再让她开口）
signal sulk_timeup(first: bool)
## 气到不愿主动开口了：宿主说最后一句，然后由 is_muted() 把主动开口关掉，直到被哄
signal giving_up
## 闭嘴之后过一阵还没被哄：她偷偷看一眼主人在忙什么 —— 在忙就自我和解
signal reconcile_check
## 摸到了：line 是要说的话；attack = 播"被欺负"那个动作；worth_noting = 值得记一笔
signal touch_line(line: String, attack: bool, worth_noting: bool)
## 摸得太频繁：宿主去走"她主动开口让你停手"那条（要流式气泡 + 记忆）
signal touch_overflow
## 主导情绪变了 —— 宿主拿它去播"能体现这个情绪的动作"
signal mood_changed(mood: int)

# ------------------------------------------------------------------ 心情

## 她的心态。**四个值，顺序别动**（宿主的动作表按下标取值）：
## 平常 / 开心 / 生气 / 悲伤。坏心眼已经并进开心（2026-10-07）
enum Mood { NEUTRAL, HAPPY, ANGRY, SAD }

## 三个强度加起来小于它 = 平常（不注入情绪句、门禁全不触发）
const CALM_TOTAL := 0.15
## 情绪落盘的位置。**单独一个文件**：它是"她自己"的东西，
## 混进 pet_chat.cfg（配置）或 pet_memory.json（记忆）都不属于它的边界
const SAVE_PATH := "user://pet_mood.cfg"

# ── 衰减：各自的半衰期（秒）。生气最慢 —— 生气要哄，和时间没关系（2026-10-07 用户要求）
const HALF_LIFE_HAPPY := 25.0 * 60.0
const HALF_LIFE_ANGRY := 60.0 * 60.0
const HALF_LIFE_SAD := 120.0 * 60.0

# ── 生气攒成委屈：生气占主导连续这么久还没被哄 → 之后每 ANGRY_TO_SAD_PERIOD 转一次
const ANGRY_TO_SAD_AFTER_MS := 30 * 60 * 1000
const ANGRY_TO_SAD_PERIOD_MS := 5 * 60 * 1000
const ANGRY_TO_SAD_RATIO := 0.25

# ── 门禁阈值（**按占比**，也就是"占了几成"）
## 生气+悲伤占比 ≥ 它 → 点她不给摸头，改弹「哄她」框（2026-10-07 用户定的 0.7）
const UPSET_SHARE := 0.7
## 生气占比 ≥ 它 → 不主动开口，要哄才回来（原来是"委屈攒满 4.0"）
const MUTE_SHARE := 0.6
## 生气占比 ≥ 它 → 这次闹脾气值得记进长期记忆（原来是"委屈 ≥ 2.0"）
const NOTE_SHARE := 0.5

# ── 事件强度（一次加多少）
const ADD_PET := 0.22          ## 摸头 / 牵手 / 摸腿
const ADD_PET_SOOTHE := 0.05   ## 顺手压一点生气（被摸一下就缓和一点）
const ADD_CHEST := 0.20        ## 摸到不该摸的地方
const ADD_CHEST_AGAIN := 0.35  ## 20 秒内第二次 = 屡教不改
const ADD_OVERFLOW := 0.12     ## 摸太频繁（她已经在喊停的那条路）
const ADD_IGNORED := 0.25      ## 被冷落（她说完话你没理）
const ADD_FEED := 0.30         ## 被喂
const ADD_TEASE := 0.18        ## 淘气（原"坏心眼"）
const ADD_UNHEALTHY := 0.12    ## 观察到主人的生活不健康 / 不开心（悲伤入口）
## 同类"不健康"事件至少隔这么久才再算一次（秒表不该为一条消息连加）
const UNHEALTHY_GAP_MS := 60000

# ── 被哄 / 被理时怎么变
const SOOTHE_ANGRY_KEEP := 0.15   ## 生气只留 15%
const SOOTHE_SAD_KEEP := 0.45     ## 悲伤留 45%（难过比生气难消）
const SOOTHE_HAPPY_ADD := 0.35    ## 顺手开心一点

# ── 落盘后重开：生气高于它就大部分转成悲伤（"气了一晚上，第二天变成委屈"）
const RELOAD_ANGRY_MIN := 0.35
const RELOAD_ANGRY_TO_SAD := 0.75

## 她说完话之后，等主人回话最多等多久（秒）——超了就生闷气
const IGNORE_AFTER_SEC := 90.0
## 闹脾气这条路记进记忆的最小间隔（毫秒）。半小时
const SULK_STORE_GAP_MS := 1800000
## 闭嘴够久就偷看一眼主人在忙什么（秒）。半小时
const RECONCILE_SEC := 1800.0
## 摸太频繁：多久以内的几下算"同一波"（毫秒）
const TOUCH_BURST_WINDOW_MS := 60000
## 一波里被摸几下她就受不了（**摸胸算两下**，所以摸胸 4 次就到线）
const TOUCH_BURST_LIMIT := 8
## 两次"喊你停手"之间至少隔多久（毫秒）
const TOUCH_COMPLAIN_GAP_MS := 60000
## 摸到胸：多短时间内的第二次算"屡教不改"（毫秒）
const CHEST_AGAIN_MS := 20000
## 摸完一次开心 / 悲伤各自要扣掉多少（"被摸就开心"顺带压一点负面）
const TOUCH_CALM_BOTH := 0.05

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
## 气到不主动开口时说的**最后一句**。之后她不再主动开口，直到被哄（见 is_muted / soothe）——
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

## 观察主人："不健康 / 不开心"的关键词。命中了就往悲伤加一笔（2026-10-07 用户要求：
## "悲伤自主积攒的条件是观察主人的生活是不是健康开心"）。
## 两类混在一张表里：**作息**（熬夜、通宵、没睡）和**状态/情绪**（累、难受、疼、烦、压力）。
## 不写"病"这种笼统词 —— 它会把"我有病吧哈哈哈"也命中
const UNHEALTHY_WORDS: Array[String] = [
	"熬夜", "通宵", "没睡", "失眠", "睡不着", "凌晨", "三点", "四点",
	"好累", "累死", "累炸", "撑不住", "顶不住", "加不动", "加班", "赶工",
	"头疼", "头痛", "胃疼", "胃痛", "难受", "不舒服", "眼睛疼", "腰疼",
	"烦死", "烦透", "压力", "喘不过气", "emo", "心情不好", "不开心", "没胃口",
]

var _host: Node = null
## 三个强度（0~1）。对外不直接给这三个数，一律走 shares() / share()
var _happy: float = 0.0
var _angry: float = 0.0
var _sad: float = 0.0
## 上次算衰减的时刻（毫秒）。tick() 不带 delta，所以自己记时间差
var _last_tick_ms: int = 0
## 上一帧的主导情绪：只在**真的变了**时发 mood_changed
var _last_mood: int = Mood.NEUTRAL
## 她在等主人回话的截止时刻（毫秒）。0 = 没在等
var _wait_ms: int = 0
## 不主动开口之后仍在等主人哄的截止时刻（毫秒）。0 = 没在等
var _muted_wait_ms: int = 0
## 生气开始"占主导"的时刻（毫秒）。0 = 现在没在生气主导
## 用它算"气了 30 分钟还没人哄" → 开始转成悲伤（见 _tick_mood）
var _angry_since_ms: int = 0
## 下一次"生气转悲伤"的时刻（毫秒）
var _next_angry_to_sad_ms: int = 0
## 上次把"闹脾气"记进记忆的时刻（毫秒），防半小时内重复记
var _next_sulk_store_ms: int = 0
## 上次被摸到不该摸的地方的时刻（毫秒）。短时间内再来一次 = "屡教不改"
var _chest_again_ms: int = 0
## 最近一分钟内被摸的时刻（毫秒）。摸太频繁她会主动喊停，见 touch_burst_hit
var _touch_times: Array = []
## 下次允许"喊你停手"的时刻（毫秒）
var _next_complain_ms: int = 0
## 下次允许把"被摸烦了"记进记忆的时刻（毫秒）
var _next_touch_store_ms: int = 0
## 下一次"观察到主人不健康"能加悲伤的时刻（毫秒）
var _next_unhealthy_ms: int = 0

func setup(host: Node) -> void:
	_host = host

# ------------------------------------------------------------------ 占比（对外的唯一说法）

## 三个强度各占多少（0~1，三者相加 = 1）。**平常时返回 ZERO**（三者都为 0）——
## 那一刻"占比"没有意义，调用方请先问 is_calm()
func shares() -> Vector3:
	# 平常时直接给 0：那会儿"占比"没有意义 —— 0.05 和 0.05 一归一就是 50% / 50%，
	# 她明明什么都没发生却显得"又开心又生气"。调用方拿到 0 就知道该显示"平常"。
	# （2026-10-07 探针抓到的：原来只在总量≈0 时才返回 0，和这里写的第一句不符）
	if is_calm():
		return Vector3.ZERO
	var total := _happy + _angry + _sad
	if total <= 0.0001:
		return Vector3.ZERO
	return Vector3(_happy / total, _angry / total, _sad / total)

## 某一维的占比。kind 用 Mood 枚举（HAPPY / ANGRY / SAD）
func share(kind: int) -> float:
	var s := shares()
	match kind:
		Mood.HAPPY: return s.x
		Mood.ANGRY: return s.y
		Mood.SAD: return s.z
	return 0.0

## 平常：三个强度加起来太小，谈不上"有情绪"
func is_calm() -> bool:
	return _happy + _angry + _sad < CALM_TOTAL

## 当前主导情绪（平常 → NEUTRAL）。**只看占比**，不看绝对量 ——
## "有没有情绪"由 is_calm() 回答，这两件事分开问
func mood() -> int:
	if is_calm():
		return Mood.NEUTRAL
	var s := shares()
	if s.y >= s.z and s.y >= s.x:
		return Mood.ANGRY
	if s.z >= s.x:
		return Mood.SAD
	return Mood.HAPPY

## 抽成 static：探针能脱离场景试（占比怎么落在哪一维）
static func dominant_of(happy: float, angry: float, sad: float) -> int:
	var total := happy + angry + sad
	if total < CALM_TOTAL:
		return Mood.NEUTRAL
	var h := happy / total
	var a := angry / total
	var s := sad / total
	if a >= s and a >= h:
		return Mood.ANGRY
	if s >= h:
		return Mood.SAD
	return Mood.HAPPY

## 心情的名字（设置面板 / 日志用）。static：探针直接试
static func mood_name(m: int) -> String:
	match m:
		Mood.HAPPY: return "开心"
		Mood.ANGRY: return "生气"
		Mood.SAD: return "悲伤"
	return "平常"

## 一键名（人设那边用 "开心 60% / 生气 30% / 悲伤 10%"，或"平常"）
func describe_short() -> String:
	if is_calm():
		return "平常"
	var s := shares()
	return "开心 %d%% / 生气 %d%% / 悲伤 %d%%" % [
		int(round(s.x * 100.0)), int(round(s.y * 100.0)), int(round(s.z * 100.0))]

## 主导演的强度（0~1）—— 老接口 level() 还活着（宿主/记忆那边在调）
func level() -> float:
	return maxf(_happy, maxf(_angry, _sad))

# ------------------------------------------------------------------ 给提示词的那段话（★ 主接口）

## 拼一段"她现在什么心情"写进人设的【现在】。
##
## **为什么拼成整段话而不是把三个数丢给模型**：模型对裸数字不敏感，而且极容易
## 把"开心 60%"直接念出来（"我现在 60% 开心"这种话一出人设就破了）。所以这里：
##   主导维一句 + 次要维一句（有就加）+ **一句"别报数值"的约束**（2026-10-07 用户选的 b 方案）
##
## 平常（is_calm）返回空串 —— 【现在】那一行就不会多出任何情绪描述
func describe() -> String:
	if is_calm():
		return ""
	var s := shares()
	var parts: Array[String] = []
	# 主导维：谁占比最大就说谁，语气按"这个情绪该怎么说话"写
	var main := mood()
	var second := _second_of(s, main)
	parts.append(_main_sentence(main, s))
	if second != Mood.NEUTRAL:
		parts.append(_second_sentence(second))
	parts.append("（上面这些是你**现在的心情**，自然地体现在口气里就行 —— "
		+ "别把它当台词念出来，也别报数字 / 百分比，一个字都别提情绪本身）")
	return "\n".join(parts)

## 占比第二大的那一维（低于 0.2 就算了，不值得提）
func _second_of(s: Vector3, main: int) -> int:
	var pairs := [[Mood.HAPPY, s.x], [Mood.ANGRY, s.y], [Mood.SAD, s.z]]
	var best := Mood.NEUTRAL
	var best_v := 0.2
	for p in pairs:
		if int(p[0]) == main:
			continue
		if float(p[1]) > best_v:
			best_v = float(p[1])
			best = int(p[0])
	return best

func _main_sentence(main: int, s: Vector3) -> String:
	match main:
		Mood.HAPPY:
			# 开心很高的时候顺带把"坏心眼"的味带出来（它已经并进开心了）
			var tail := "可以撒撒娇、冒点小得意。" if s.x < 0.8 \
				else "心情好得有点想逗他 —— 可以说点反话、卖个关子，但别真把他惹恼。"
			return "你现在心情不错：刚被主人摸过 / 喂过，说话轻快一点，" + tail
		Mood.ANGRY:
			return "你在生闷气：你主动找主人说话，他好一会儿没理你。语气可以冲一点、也可以酸他两句，" \
				+ "但别真的凶他 —— 他一理你，你其实很快就软下来。"
		Mood.SAD:
			return "你有点难过（不是闹脾气，是真的低落）：可以是因为等太久没人理，也可以是看到主人" \
				+ "过得不太健康、不太开心而替他难受。说话轻一点、低一点，别撒娇也别凶他。"
	return ""

func _second_sentence(second: int) -> String:
	match second:
		Mood.HAPPY: return "底下其实还有点高兴，别把话说死。"
		Mood.ANGRY: return "话里可以带点不顺气，但别盖过上面那层。"
		Mood.SAD: return "底下还压着一点委屈，说出来反而更真的那种。"
	return ""

## 在闹情绪、要哄的那种 —— 宿主用它决定"点击给不给正常互动"。
## **2026-10-07 用户定的门槛**：生气 + 悲伤的占比加起来 ≥ 70%
## （开心 / 平常时点击 = 正常摸头，开心不做任何门禁，只影响台词）
func is_upset() -> bool:
	if is_calm():
		return false
	var s := shares()
	return s.y + s.z >= UPSET_SHARE

## 现在是"气了、不主动开口"的状态吗 —— 宿主在 _check_self_talk 里问它。
## 只有 soothe()（被哄 / 被理）能解除。判据是**生气占比 ≥ 60%**（原来是委屈攒满 4.0）
func is_muted() -> bool:
	if is_calm():
		return false
	return share(Mood.ANGRY) >= MUTE_SHARE

## 现在受不受"被冷落"影响 —— **正开心的时候不受**（心情好，不计较）。
## 抽出来是为了能离线验（tick 本身要 host，这条不用）
func _immune_to_ignore() -> bool:
	if is_muted():
		return false
	if is_calm():
		return false
	return mood() == Mood.HAPPY

## 给探针用：直接摆三个强度（没法从外面一点点摸出来的场景）
func set_levels(happy: float, angry: float, sad: float) -> void:
	_happy = clampf(happy, 0.0, 1.0)
	_angry = clampf(angry, 0.0, 1.0)
	_sad = clampf(sad, 0.0, 1.0)

## 怨气满时落在生气还是伤心 —— **三维之后不再分**（两种情绪本来就能并存），
## 这个壳留着是因为旧探针还在调它，直接给生气
static func full_mood_pick(_dice: float) -> int:
	return Mood.ANGRY

## 开心：摸头 / 喂食 / 被哄好 / 淘气。amount 0~1
func cheer(amount: float = 1.0) -> void:
	_happy = clampf(_happy + amount, 0.0, 1.0)

## 淘气（原来的"坏心眼"）：**现在并进开心**，只是加得少、而且描述里会带出调皮的味道
func tease(amount: float = 1.0) -> void:
	cheer(ADD_TEASE * amount)

## 直接加悲伤。宿主在"她看到主人过得不好"那条路上调它（见 say_about_master）
func make_sad(amount: float) -> void:
	_sad = clampf(_sad + amount, 0.0, 1.0)

## 观察主人的生活健不健康 / 开不开心（2026-10-07 用户要求：悲伤这条要自主积攒）。
## 输入是**一段文本**：主人刚说的话，或者她偷看屏幕 / 摄像头时看到的那段描述。
## 命中"不健康"词表就往悲伤加一笔；同类事件隔一分钟才算一次，免得一条消息连加。
## 返回是否真的加了（宿主可以据此决定要不要多看她一眼）
func say_about_master(text: String) -> bool:
	if text.strip_edges() == "":
		return false
	var hit := false
	for w in UNHEALTHY_WORDS:
		if text.find(w) >= 0:
			hit = true
			break
	if not hit:
		return false
	var now := Time.get_ticks_msec()
	if now < _next_unhealthy_ms:
		return false
	_next_unhealthy_ms = now + UNHEALTHY_GAP_MS
	make_sad(ADD_UNHEALTHY)
	if OS.is_debug_build():
		print("[PetDeek] 看到主人过得不太健康：悲伤 +%.2f（%s）" % [ADD_UNHEALTHY, describe_short()])
	return true

# ------------------------------------------------------------------ 衰减与攒委屈

## 每帧：三个强度各自按半衰期往回落；生气占主导够久就攒成悲伤
func _tick_mood() -> void:
	var now := Time.get_ticks_msec()
	if _last_tick_ms == 0:
		_last_tick_ms = now
		return
	var dt := float(now - _last_tick_ms) / 1000.0
	_last_tick_ms = now
	if dt <= 0.0:
		return
	# 半衰期：x *= 0.5^(dt / half_life)
	_happy *= pow(0.5, dt / HALF_LIFE_HAPPY)
	_angry *= pow(0.5, dt / HALF_LIFE_ANGRY)
	_sad *= pow(0.5, dt / HALF_LIFE_SAD)
	_clamp_small()
	_tick_angry_to_sad(now)
	# 主导情绪变了就发一句（宿主拿它去播"能体现这个情绪的动作"）
	var m := mood()
	if m != _last_mood:
		_last_mood = m
		mood_changed.emit(m)

## 小到没意义的数值直接归零：不然她会"永远带着 0.0001 的悲伤"
func _clamp_small() -> void:
	if _happy < 0.005:
		_happy = 0.0
	if _angry < 0.005:
		_angry = 0.0
	if _sad < 0.005:
		_sad = 0.0

## 生气"攒成委屈"：生气占主导连续 ANGRY_TO_SAD_AFTER_MS 还没被哄 → 开始往悲伤转。
## 为什么要有这条（2026-10-07 用户要求"生气是 30 分钟后不哄积攒悲伤"）：
## 一直没人哄的生气会慢慢变成难过 —— 那才是"委屈"，比单纯生气更像真的
func _tick_angry_to_sad(now: int) -> void:
	if is_calm() or share(Mood.ANGRY) < MUTE_SHARE:
		# 不在"生气占主导"了：计时清零，下次重新数
		_angry_since_ms = 0
		_next_angry_to_sad_ms = 0
		return
	if _angry_since_ms == 0:
		_angry_since_ms = now
		_next_angry_to_sad_ms = now + ANGRY_TO_SAD_AFTER_MS
		return
	if now < _next_angry_to_sad_ms:
		return
	_next_angry_to_sad_ms = now + ANGRY_TO_SAD_PERIOD_MS
	var moved := _angry * ANGRY_TO_SAD_RATIO
	_angry -= moved
	_sad = clampf(_sad + moved, 0.0, 1.0)
	if OS.is_debug_build():
		print("[PetDeek] 气久了没人哄 → 转成委屈：%s" % describe_short())

# ------------------------------------------------------------------ 生闷气（被冷落）

## 每帧调：看"等她回话"的时间到了没。到点就发 sulk_timeup，由宿主去开口
func tick() -> void:
	_tick_mood()
	# 不开口之后的"持续冷落"计时：她不理人了，但主人一直没哄她
	if _muted_wait_ms > 0:
		if Time.get_ticks_msec() >= _muted_wait_ms:
			_muted_wait_ms = 0
			if OS.is_debug_build():
				print("[PetDeek] 气了 %d 分钟没被哄：去看看主人在忙什么" % int(RECONCILE_SEC / 60.0))
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
	# 心情好的时候不计较：正开心着被冷落也不生气（用户 2026-10-01 要求）
	if _immune_to_ignore():
		return
	var first := _angry < 0.15
	_angry = clampf(_angry + ADD_IGNORED, 0.0, 1.0)
	if is_muted():
		# 气到不愿开口了：宿主说最后一句，然后 is_muted() 把主动开口关掉（要哄才回来）
		if OS.is_debug_build():
			print("[PetDeek] 气到不主动开口了：%s（等哄）" % describe_short())
		_muted_wait_ms = Time.get_ticks_msec() + int(RECONCILE_SEC * 1000.0)
		giving_up.emit()
		return
	sulk_timeup.emit(first)

## 她说完话了，开始算"主人多久不理我"。到点还没反应就生闷气（见 tick）
func start_waiting() -> void:
	_wait_ms = Time.get_ticks_msec() + int(IGNORE_AFTER_SEC * 1000.0)

## 被理了就消气。聊天、摸头、喂食、菜单「哄哄她」都算 ——
## 别让她记仇记到没人愿意搭理她（这也是"要哄"的解法：哄 = soothe）
## 生气几乎清零、悲伤留一半（难过比生气难消）、顺手开心一点
func soothe() -> void:
	var was_upset := is_upset()
	if not is_calm() and OS.is_debug_build():
		print("[PetDeek] 消气了（之前 %s）" % describe_short())
	_angry *= SOOTHE_ANGRY_KEEP
	_sad *= SOOTHE_SAD_KEEP
	# 本来在闹情绪 → 一股气高兴回来；没在闹（被摸头 / 被喂）→ 只小开心一下
	var gain := (1.0 - _happy) * SOOTHE_HAPPY_ADD if was_upset else SOOTHE_HAPPY_ADD
	_happy = clampf(_happy + gain, 0.0, 1.0)
	_clamp_small()
	_wait_ms = 0
	_muted_wait_ms = 0
	_angry_since_ms = 0
	_next_angry_to_sad_ms = 0

## 直接加生气（"她主动喊停"那一下要加；原来是 bump 委屈度）
func bump(amount: float) -> void:
	_angry = clampf(_angry + amount, 0.0, 1.0)

## 闹脾气这条现在值不值得记进记忆（判完顺手标上时间，半小时内不重复记）
func should_store_sulk(origin: String) -> bool:
	var now := Time.get_ticks_msec()
	if now < _next_sulk_store_ms:
		return false
	# 单纯闹脾气要生气占比过半才值得记；而"偷看看到的东西"本身就有信息量
	# （他当时在忙什么），所以偷看那条只要过了时间间隔就记
	if origin == "sulk" and share(Mood.ANGRY) < NOTE_SHARE:
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

## 偷看一眼发现主人没在忙 → 不算"他忙得顾不上"，她继续气着，重新等一轮（再来半小时）
func restart_muted_wait() -> void:
	_muted_wait_ms = Time.get_ticks_msec() + int(RECONCILE_SEC * 1000.0)

## 给探针/调试看：不开口之后还在等哄吗（截止时刻，0 = 没在等）
func muted_wait_deadline() -> int:
	return _muted_wait_ms

## 给探针用：直接摆一个"已经超时"的截止时刻，模拟气着一直没被哄
func set_muted_wait_deadline(ms: int) -> void:
	_muted_wait_ms = ms

# ------------------------------------------------------------------ 落盘（2026-10-07 用户要求）

## 情绪落盘：关掉再打开她还记得（原来是纯内存、重启清零）
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)     # 先读回来，别把别的东西冲掉
	cfg.set_value("mood", "happy", _happy)
	cfg.set_value("mood", "angry", _angry)
	cfg.set_value("mood", "sad", _sad)
	cfg.set_value("mood", "saved_at", Time.get_unix_time_from_system())
	cfg.save(SAVE_PATH)

## 读回落盘的情绪。**用户要求的一条**：上次气得很厉害的话，
## 再打开时大部分转成悲伤 —— "气了一晚上，第二天变成委屈"（2026-10-07）
func load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	_happy = clampf(float(cfg.get_value("mood", "happy", 0.0)), 0.0, 1.0)
	_angry = clampf(float(cfg.get_value("mood", "angry", 0.0)), 0.0, 1.0)
	_sad = clampf(float(cfg.get_value("mood", "sad", 0.0)), 0.0, 1.0)
	if _angry >= RELOAD_ANGRY_MIN:
		var moved := _angry * RELOAD_ANGRY_TO_SAD
		_angry -= moved
		_sad = clampf(_sad + moved, 0.0, 1.0)
		if OS.is_debug_build():
			print("[PetDeek] 上次气着关掉的 → 这次变成委屈：%s" % describe_short())
	_clamp_small()
	# 刚读回来的这几个值不该立刻被衰减吃掉：把计时基准对齐到"现在"
	_last_tick_ms = Time.get_ticks_msec()

# ------------------------------------------------------------------ 被摸到

## 被摸到了。部位由 scripts/pet_pointer.gd 的 classify_touch 判出来：
## head / chest / hand / leg / body（菜单里的「摸摸头」没有坐标，默认就是 head）
##
## 分寸感是这段的重点：头 / 手 / 腿 是亲昵（→ 开心），摸到胸要明确不乐意（→ 生气）。
func touch(part: String) -> void:
	# 先看这一下是不是"摸得太频繁"了。是的话先别管摸的是哪儿 ——
	# 她会主动开口让你停手（那是宿主的事，见 touch_overflow）
	if _note_touch(part):
		bump(ADD_OVERFLOW)
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
		bump(ADD_CHEST_AGAIN if again else ADD_CHEST)
		var worth := false
		if again:
			line = LINES_STOP[_host._rng.randi_range(0, LINES_STOP.size() - 1)]
			# 手欠到这份上，值得让她记一笔 —— 以后她会自己防着点
			worth = share(Mood.ANGRY) >= NOTE_SHARE
		if OS.is_debug_build():
			print("[PetDeek] 摸到胸：%s（%s）" % [
				"屡教不改" if again else "第一次", describe_short()])
		touch_line.emit(line, true, worth)
		return
	# 其他部位都算亲昵：先消气（生气/悲伤各压一点），再说那句话
	_angry = maxf(0.0, _angry - TOUCH_CALM_BOTH)
	_sad = maxf(0.0, _sad - TOUCH_CALM_BOTH)
	_wait_ms = 0
	_muted_wait_ms = 0
	cheer(ADD_PET)
	touch_line.emit(line, false, false)

## 这一下算不算"摸得太频繁"。顺手把窗口外的旧记录丢掉 ——
## Array 是引用类型，改的就是传进来的那个数组。
## 写成 static 是为了能**脱离场景**验证：tools 里的探针直接拿它试，
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
func _note_touch(part: String) -> bool:
	var now := Time.get_ticks_msec()
	if not touch_burst_hit(_touch_times, now, part):
		return false
	if now < _next_complain_ms:
		return false
	_next_complain_ms = now + TOUCH_COMPLAIN_GAP_MS
	_touch_times.clear()
	return true
