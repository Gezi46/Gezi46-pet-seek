extends RefCounted
## 她自己的日记 —— 记"她和你之间发生了什么"，给你看的，不是给模型用的。
##
## ── 为什么要有它（和长期记忆的分工）───────────────────────────────────────
## 长期记忆（`pet_memory.gd`）是**机器数据**：条目 + 重要性 + 遗忘曲线，
## 它的唯一用途是被检索出来塞进提示词。**你永远看不到她"怎么想你的"**。
##
## 日记是另一条线：**同一批事件的另一种呈现**。它不参与检索、不进提示词、
## 不会被遗忘曲线删掉 —— 它是"关系本身"的载体，翻开来能看到日子是一天天过下去的。
##
## 一句话区分：记忆是**给模型用的**，日记是**给你看的**。
##
## ── 三层（这是这个模块的核心设计）─────────────────────────────────────────
##   ① **拍子（beat）**：每次值得留一笔的事，本地规则判定 + 零成本记下来。
##      这是机器视角的流水（"被摸了摸头"），**不直接给人看**。
##   ② **当天的日记**：一天结束时（或你手动点），把这天的拍子**合成一段话**。
##      合成要么走本地模板（零成本、离线可用），要么让模型照着她的口气写一段。
##   ③ **档案统计**：认识多少天、连续多少天、被摸过多少次 —— 界面顶上那一行。
##
## 为什么不"每个事件写一行日记"：那会变成流水账（"14:03 被摸了摸头"），
## 不是日记。**一天一段、有起承转合**才像她写的。
##
## ── 对宿主的接口面（只列真正用到的）────────────────────────────────────────
##   host._rng          随机源（和宿主共用一个，行为才一致 —— 和 pet_mood 同一条理由）
##   宿主还要调：load() / save() / note() / write_today() / set_today_ai()
##              stats_line() / relation_text() / days_known() / streak() /
##              today_text() / today_title() / entries() / date_label() / clear_all()
##   AI 那条：宿主用 prompt 自己发（见 pet_diary_prompt.gd），回来调 set_today_ai()
##
## ── 体量豁免（目标：把「拼句子」那几块拆去 pet_diary_text.gd）──────────────
## 2026-10-10 加了标题（T5）和关系感知（T1）之后到了 530 行出头。**暂时不拆**，
## 理由是这台机器还没停：BEAT_* 常量 / BEAT_TEXT / summarize() / title_of() /
## relation_text() 是**同一套口径的五个面**（"这天发生了什么 → 一段话 + 一行标题 + 关系"），
## 而且 summarize 和 title_of 的优先级必须逐条对齐（不一致就会出现"标题说被摸头、
## 正文说在闹别扭"）。真要拆，接缝是**纯文本生成**那一块 → pet_diary_text.gd，
## 数据与判定（读写 / 拍子 / 连续天数）留这儿。等下次改到这块再动。
##
## 验证：`tools/probe_diary.gd`（数据与判定 + 标题 + 关系，全离线）
##       `tools/probe_diary_live.gd`（接线，真跑一只桌宠）—— 两个都不用起窗口

## 日记落盘的位置。**单独一个文件**：它是"她自己"的东西，
## 混进 pet_memory.json（机器记忆）或 pet_chat.cfg（配置）都不属于它的边界
const SAVE_PATH := "user://pet_diary.json"

## 最多留多少天。**不是无限攒**：翻到一年前的日记是有仪式感的事，
## 翻到第 3000 条就是负担了。超了从**最旧**的丢（丢的是日子，不是统计）
const MAX_DAYS := 400

## 一天里最多留几个拍子（再多也合不出更丰富的一段话，只是白占地方）
const MAX_BEATS_PER_DAY := 12
## 同一个 beat 一天内最多记几次（摸头摸 50 下不需要 50 条）
const MAX_SAME_BEAT := 4

## 拍子的种类 —— **文案在 BEAT_TEXT 里**，这里只列种类。
## 加一种 = 这里加一行 + BEAT_TEXT 加一条 + `note()` 的调用点加一处
const BEAT_PET := "pet"            ## 被摸（头 / 手 / 腿）
const BEAT_TOUCH_ANNOY := "annoy"  ## 摸太频繁，她喊停
const BEAT_FEED := "feed"          ## 被喂
const BEAT_TALK := "talk"          ## 主人跟她说了话
const BEAT_CHAT_LONG := "chat_long" ## 聊得比较久
const BEAT_SOOTHE := "soothe"      ## 被哄好
const BEAT_IGNORED := "ignored"    ## 她说完没人理，生闷气
const BEAT_RECONCILE := "reconcile" ## 气久了偷看一眼，自己消气
const BEAT_HAPPY := "happy"        ## 心情转成开心
const BEAT_SAD := "sad"            ## 心情转成悲伤
const BEAT_ANGRY := "angry"        ## 心情转成生气
const BEAT_SLEEP := "sleep"        ## 睡了 / 醒了
const BEAT_CARE := "care"          ## 她观察到主人过得不太健康

## 拍子 → 写进日记的那句话（**机器视角的短句**，不是她说的台词。
## 合成成篇的时候模型/模板会把它当素材，不会照抄）。
## 第一人称、过去式、短。别写"主人"两个字太多次，读起来会像报告
const BEAT_TEXT: Dictionary = {
	BEAT_PET: "被摸了摸头，挺舒服的",
	BEAT_TOUCH_ANNOY: "被摸得太频繁了，我凶了他两句",
	BEAT_FEED: "被喂了点东西，好吃",
	BEAT_TALK: "主人跟我说话了",
	BEAT_CHAT_LONG: "和主人聊了好一会儿",
	BEAT_SOOTHE: "被哄好了，气消了",
	BEAT_IGNORED: "我主动说话，他没接，有点闷",
	BEAT_RECONCILE: "偷偷看了一眼，他在忙，我就自己消气了",
	BEAT_HAPPY: "心情莫名其妙地好",
	BEAT_SAD: "有点难过，说不上来为什么",
	BEAT_ANGRY: "在生闷气",
	BEAT_SLEEP: "睡了一觉",
	BEAT_CARE: "看主人好像挺累的，有点担心",
}

var _host: Node = null

## 已记下的日子（**新的在前**，界面直接按顺序画）：
##   { "date": "2026-10-09", "beats": [{t, kind, hour}], "text": "", "ai": false, "n": {} }
var days: Array = []
## 第一次见面那天（"认识多少天"从这里算）
var first_day: String = ""
## 累计被摸次数、累计聊天轮数（界面顶上那行的数字）
var total_pets: int = 0
var total_talks: int = 0
## 今天已经落过盘没有（避免每记一个拍子就写一次文件）
var _dirty: bool = false

func setup(host: Node) -> void:
	_host = host

# ------------------------------------------------------------------ 存 / 读

## 读回日记。**读失败就当新的**：日记读不出来不该挡着她起来
func load() -> void:
	days.clear()
	first_day = ""
	total_pets = 0
	total_talks = 0
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed
	first_day = String(d.get("first_day", ""))
	total_pets = int(d.get("total_pets", 0))
	total_talks = int(d.get("total_talks", 0))
	var arr: Variant = d.get("days", [])
	if typeof(arr) == TYPE_ARRAY:
		for it in arr:
			if typeof(it) == TYPE_DICTIONARY:
				days.append(_sanitize_day(it))

func save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"first_day": first_day,
		"total_pets": total_pets,
		"total_talks": total_talks,
		"days": days,
	}, "  "))
	f.close()
	_dirty = false

## 把从磁盘读回来的一条洗成"一定长得对"的形状 —— 文件可能被手改过。
## 缺字段就补、类型不对就丢（**宁可少一条也不能让界面崩**）
func _sanitize_day(it: Dictionary) -> Dictionary:
	var beats: Array = []
	var bs: Variant = it.get("beats", [])
	if typeof(bs) == TYPE_ARRAY:
		for b in bs:
			if typeof(b) == TYPE_DICTIONARY:
				beats.append({
					"t": int(b.get("t", 0)),
					"kind": String(b.get("kind", "")),
					"hour": int(b.get("hour", -1)),
				})
	return {
		"date": String(it.get("date", "")),
		"beats": beats,
		"title": String(it.get("title", "")),
		"text": String(it.get("text", "")),
		"ai": bool(it.get("ai", false)),
		"n": it.get("n", {}),
	}

# ------------------------------------------------------------------ 拍子

## 记一个拍子。**这是唯一的外部入口** —— 宿主在各个事件点上调它。
## kind 用上面那些 BEAT_*；同一天同一个 kind 超过 MAX_SAME_BEAT 就不再记。
## 返回 true = 真记下了（宿主不用关心，返回值是给探针和日志用的）
func note(kind: String) -> bool:
	if kind == "" or not BEAT_TEXT.has(kind):
		return false
	var day := _today()
	var d := _day_or_create(day)
	var beats: Array = d["beats"]
	# 同类拍子一天最多几条
	var same := 0
	for b in beats:
		if String(b["kind"]) == kind:
			same += 1
	if same >= MAX_SAME_BEAT:
		return false
	if beats.size() >= MAX_BEATS_PER_DAY:
		return false
	var dt := Time.get_datetime_dict_from_system()
	beats.append({"t": int(Time.get_unix_time_from_system()), "kind": kind, "hour": int(dt["hour"])})
	_dirty = true
	# 累计数（只统计两种最直观的）
	if kind == BEAT_PET:
		total_pets += 1
	elif kind == BEAT_TALK or kind == BEAT_CHAT_LONG:
		total_talks += 1
	return true

## 今天有没有留下任何东西（没拍子也没正文 = 这天她没写）
func has_today() -> bool:
	for d in days:
		if String(d["date"]) == _today():
			return not (d["beats"] as Array).is_empty() or String(d["text"]) != ""
	return false

## 今天有拍子但还没合成成篇 —— 该写日记了
func needs_write() -> bool:
	for d in days:
		if String(d["date"]) == _today():
			return not (d["beats"] as Array).is_empty() and String(d["text"]) == ""
	return false

## 今天的正文（没有就是空串）
func today_text() -> String:
	for d in days:
		if String(d["date"]) == _today():
			return String(d["text"])
	return ""

## 今天的标题（没有就是空串）
func today_title() -> String:
	for d in days:
		if String(d["date"]) == _today():
			return String(d.get("title", ""))
	return ""

# ------------------------------------------------------------------ 合成成篇

## 把今天的拍子合成一段话（**本地模板**，零成本、离线可用）。
## 返回 "" = 今天没拍子，没什么好写的。
##
## 用模板掉不掉价：这个模型的日记本来就该是**淡淡的口语**，不是文学。
## 真要更自然的那版，让宿主走 AI 那条（`pet_diary_prompt.gd`），回来调 set_today_ai()。
func write_today() -> String:
	var d := _day_or_create(_today())
	var beats: Array = d["beats"]
	if beats.is_empty():
		return ""
	var kinds := _beats_to_kinds(beats)
	var text := summarize(kinds, _host)
	d["text"] = text
	d["ai"] = false
	# 本地那版也给个标题（模型没回来 / 关掉 AI 时列表上也是一行像样的话）。
	# **只在还没有标题时写** —— 模型写过的标题比这个好，别覆盖掉
	if String(d.get("title", "")) == "":
		d["title"] = title_of(kinds)
	_dirty = true
	return text

## 模型写回来的那版正文（+ 可选标题）。**认领**：只有"今天"才收
## （迟到的回复不该把已经写好的覆盖掉 —— 和 pet_quick 那边"认领第几代"同一条理由）。
## title 为空时退回本地兜底标题（模型没照格式写也有一行能看）
func set_today_ai(text: String, title: String = "") -> bool:
	var t := text.strip_edges()
	if t == "":
		return false
	# 洗掉模型爱加的前后缀（"日记：" / 引号 / 括号里的说明）
	t = clean_ai_text(t)
	if t == "":
		return false
	var d := _day_or_create(_today())
	d["text"] = t
	d["ai"] = true
	var tt := title.strip_edges()
	if tt != "":
		d["title"] = tt
	elif String(d.get("title", "")) == "":
		d["title"] = title_of(_beats_to_kinds(d["beats"]))
	_dirty = true
	return true

## 从拍子推一句话标题（**本地兜底**，也用在"模型没给标题"时）。
## 标题列的是**那天最重的那件事**，和 summarize 的开场同一个优先级 ——
## 两处口径要一致，否则会出现"标题说被摸头、正文说在闹别扭"
static func title_of(kinds: Array) -> String:
	var has := {}
	for k in kinds:
		has[String(k)] = true
	if has.has(BEAT_IGNORED) and has.has(BEAT_SOOTHE):
		return "闹别扭又和好了"
	if has.has(BEAT_IGNORED):
		return "他没理我"
	if has.has(BEAT_SOOTHE):
		return "被哄好了"
	if has.has(BEAT_CHAT_LONG):
		return "聊了很久"
	if has.has(BEAT_TALK):
		return "说了几句话"
	if has.has(BEAT_PET):
		return "被摸了摸头"
	if has.has(BEAT_FEED):
		return "被喂了东西"
	if has.has(BEAT_SAD):
		return "有点难过"
	if has.has(BEAT_ANGRY):
		return "在生闷气"
	return "平常的一天"

## 洗模型吐的日记正文。**只做最小清洗**，别把她的口气也洗掉：
## 去掉包裹的引号、行首的"日记：""今天："这类标签、以及独占一行的舞台说明（（…））
## static：探针直接试
static func clean_ai_text(raw: String) -> String:
	var t := raw.strip_edges()
	# 去掉行首标签（"日记：" / "今天的日记：" / "# 日记"）
	for tag in ["日记：", "日记:", "今天的日记：", "今天的日记:", "# 日记", "#日记"]:
		if t.begins_with(tag):
			t = t.substr(tag.length()).strip_edges()
	# 去掉包裹的引号（中英文都要，模型很爱加）
	while t.length() >= 2:
		var a := t.substr(0, 1)
		var b := t.substr(t.length() - 1, 1)
		if (a == "\"" and b == "\"") or (a == "「" and b == "」") or (a == "“" and b == "”"):
			t = t.substr(1, t.length() - 2).strip_edges()
		else:
			break
	# 丢掉整行都是括号说明的那种（（…）—— 舞台说明不该进日记）
	var keep: Array[String] = []
	for line in Array(t.split("\n")):
		var s := String(line).strip_edges()
		if s == "":
			continue
		if s.begins_with("（") and s.ends_with("）"):
			continue
		keep.append(s)
	return "\n".join(keep).strip_edges()

## 拍子列表 → 一段日记（**核心的合成规则，写成 static 好离线验**）。
## host 只用来拿随机源（挑开场白 / 收尾句）；传 null 就用全局随机
##
## 标点的接法是这里的重点：**开场单独成句时才带句号**，要接中段就用**无句号**的那一版 ——
## 否则会拼出"……几句话。，还被喂了点东西。"这种（第一版就是这么错的）
static func summarize(kinds: Array, host = null) -> String:
	if kinds.is_empty():
		return ""
	var has := {}
	for k in kinds:
		has[String(k)] = true

	# 开场：按"这天最重的那件事"定调子。顺序就是优先级 —— 吵架 > 被哄 > 聊天 > 亲昵。
	# opening_done = 这一版自带句号、后面不能再接中段
	var opening := ""
	var opening_done := false
	if has.has(BEAT_IGNORED) and has.has(BEAT_SOOTHE):
		opening = "今天有点小别扭，后来和好了。"
		opening_done = true
	elif has.has(BEAT_IGNORED):
		opening = "今天有点闷。"
		opening_done = true
	elif has.has(BEAT_SOOTHE):
		opening = "今天他哄我了"
	elif has.has(BEAT_CHAT_LONG):
		opening = "今天和主人聊了挺久"
	elif has.has(BEAT_TALK):
		opening = "今天主人跟我说了几句话"
	elif has.has(BEAT_PET):
		opening = "今天被摸了摸头"
	else:
		opening = "今天也挺平常的"
		opening_done = true

	# 中段：把她做过的、和被对待的事各挑一句（**不逐条列**，列出来就是流水账了）
	var did: Array[String] = []
	if has.has(BEAT_TALK):
		did.append("聊的时候我挺高兴的")
	if has.has(BEAT_PET):
		did.append("被摸头的时候我没躲")
	if has.has(BEAT_FEED):
		did.append("还被喂了点东西")
	if has.has(BEAT_TOUCH_ANNOY):
		did.append("他手太欠的时候我凶了他")
	if has.has(BEAT_RECONCILE):
		did.append("偷看了一眼，他在忙，那就算了")
	if has.has(BEAT_HAPPY):
		did.append("心情不知道怎么就变好了")
	if has.has(BEAT_CARE):
		did.append("看他好像挺累的，有点担心")
	if has.has(BEAT_SLEEP):
		did.append("中间睡了一觉")

	var out := opening
	if not opening_done and not did.is_empty():
		out += "，" + _join_some(did, host) + "。"

	# 收尾：有情绪就点一句，没有就留白（**不是每天都要有结论**）
	if has.has(BEAT_SAD):
		out += "有点说不上来的难过。"
	elif has.has(BEAT_ANGRY) and not has.has(BEAT_SOOTHE):
		out += "哼。"
	return out

## 把几句用顿号串起来，最多留 2 句（开场已经交代了这天，再多就是流水账）。
## **返回不带句号** —— 句号由 summarize 统一收尾加，这样不会拼出"。，"
## 顺序打乱：不加的话每天都是同一个顺序，一眼能看出是模板
static func _join_some(items: Array, _host = null) -> String:
	var picked := items.duplicate()
	picked.shuffle()
	if picked.size() > 2:
		picked = picked.slice(0, 2)
	var out := ""
	for i in picked.size():
		if i > 0:
			out += "，"
		out += String(picked[i])
	return out

## 拍子数组 → kind 列表
static func _beats_to_kinds(beats: Array) -> Array:
	var out: Array = []
	for b in beats:
		out.append(String(b["kind"]))
	return out

# ------------------------------------------------------------------ 档案统计

## 认识多少天（从 first_day 算到今天，含头含尾）。没记录就是 1
func days_known() -> int:
	if first_day == "":
		return 1
	var a := _date_to_unix(first_day)
	var b := _date_to_unix(_today())
	if a <= 0 or b <= 0:
		return 1
	return int((b - a) / 86400.0) + 1

## 连续多少天有记录（**从今天往回数**；今天还没写就从前一天开始数，
## 这样"今天刚打开还没互动"不会把连续天数打断）
func streak() -> int:
	return streak_of(days, _today())

## 界面顶上那一行。**给人看的**，所以用口语不用数字堆
func stats_line() -> String:
	var s := streak()
	var base := "认识 %d 天" % days_known()
	if s >= 2:
		base += "，连着 %d 天见面" % s
	if total_pets > 0:
		base += "，被摸过 %d 次" % total_pets
	return base

## 拼一段"我们的关系到哪一步了"，写进人设的【现在】—— 见 pet_persona.build_context。
##
## ── 为什么要有它（和 gap_min 的区别）────────────────────────────────────────
## `gap_min` 只回答"距上次说话多久"，而且**门槛 30 分钟**（低于它一个字都不提，
## 因为动不动报时间最像机器）。它答不了的是**规模感**：我们认识多久了、连着见了几天、
## 今天这是第几次打开。
##
## 这段话的作用是让**她已经会说的那些话**有分寸 —— 同样一句"你在忙吗"，
## "认识 1 天第 1 次打开"和"认识 200 天、连着 9 天见面、今天第 3 次"该完全不一样。
##
## ── 为什么放这儿 ──────────────────────────────────────────────────────────
## "认识多少天 / 连着多少天"是**日记算出来的**（它才是关系那条线的主人）。
## 让 pet_persona 自己算会变成第二份口径 —— 这个仓在时间口径上已经栽过一次
## （2026-09-27："2 小时前"和"5 小时"打架），别再犯。
##
## counts = pet_memory 的会话计数（sessions_total / sessions_today / chats_today）。
## 传空字典就只给日记那部分。
## weekday：0~6（0 = 周日），-1 = 取当天。**可注入是为了能离线验**
##
## 返回 "" = 没什么可说的（第一次打开、又还没聊过），调用方别把它拼进去
func relation_text(counts: Dictionary = {}, weekday: int = -1) -> String:
	var bits: Array[String] = []
	var sessions_total := int(counts.get("sessions_total", 0))
	var sessions_today := int(counts.get("sessions_today", 0))
	var chats_today := int(counts.get("chats_today", 0))

	# 规模感：认识多久 + 连着见了几天。**连着 2 天才提**，1 天不值得说
	var known := days_known()
	if known >= 2:
		var s := streak()
		if s >= 2:
			bits.append("你已经认识主人 %d 天，最近连着 %d 天都见面了" % [known, s])
		else:
			bits.append("你已经认识主人 %d 天了" % known)
	# 见面次数：只在"不止这一次"时提
	if sessions_total >= 2:
		if sessions_today >= 2:
			bits.append("今天是他第 %d 次打开你" % sessions_today)
		else:
			bits.append("这是他第 %d 次打开你" % sessions_total)
	# 今天聊了多少：只在真聊过几轮时提
	if chats_today >= 3:
		bits.append("今天你们已经聊了 %d 轮" % chats_today)
	if bits.is_empty():
		return ""

	# 工作日 / 周末：决定"又上班啊"还是"周末好好休息"。
	# **weekday 可注入**（-1 = 取当天）—— 探针不能只靠"今天恰好是星期几"
	if bits.is_empty():
		return ""
	var wd := weekday
	if wd < 0:
		wd = int(Time.get_datetime_dict_from_system()["weekday"])
	var day_kind := "今天是工作日" if (wd >= 1 and wd <= 5) else "今天是周末"
	# 最后那句约束是**必须的**（照抄 pet_persona 处理「现在」那段的做法）：
	# 不给的话模型会把这些数字一个个念出来（"我们已经认识 200 天 3 小时了"），最像机器。
	# 用中文引号 —— GDScript 的字符串里别再套一层英文引号
	return "【你和主人的关系】" + "；".join(bits) + "。" + day_kind \
		+ "（这是背景，用来定你说话的分寸 —— **别报数字、别说「我们认识多少天了」这类话**，" \
		+ "就像你也不会每天数着日子说话一样）"

## 连续天数（static 好离线验）。today 传进来 = 可测，不必等真到明天
static func streak_of(day_list: Array, today: String) -> int:
	var have := {}
	for d in day_list:
		have[String(d.get("date", ""))] = true
	var t := today
	# 今天没记录就从昨天起算（理由见 streak() 的说明）
	if not have.has(t):
		t = _shift_day(t, -1)
	var n := 0
	while have.has(t) and n < 10000:
		n += 1
		t = _shift_day(t, -1)
	return n

## "YYYY-MM-DD" 平移若干天。**自己算**，不走 Time（它没有"日期加减"）
static func _shift_day(date: String, delta: int) -> String:
	var u := _date_to_unix(date)
	if u <= 0:
		return date
	var dt := Time.get_datetime_dict_from_unix_time(int(u) + delta * 86400)
	return "%04d-%02d-%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]

static func _date_to_unix(date: String) -> int:
	var parts := date.split("-")
	if parts.size() != 3:
		return 0
	var y := int(parts[0])
	var m := int(parts[1])
	var d := int(parts[2])
	if y <= 0 or m < 1 or m > 12 or d < 1 or d > 31:
		return 0
	return int(Time.get_unix_time_from_datetime_dict({
		"year": y, "month": m, "day": d, "hour": 0, "minute": 0, "second": 0,
	}))

func _today() -> String:
	return day_stamp()

## 今天的日期串（"YYYY-MM-DD"）。**static + 公开**：探针要按"今天"摆数据，
## 而它不该自己再算一套日期格式（那就成了第二份口径）。做成 static 是因为它
## 不依赖实例状态 —— 和 `_shift_day` / `streak_of` 那组一样，能脱离场景验
static func day_stamp() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]

## 取今天那一条，没有就建一条空的（并顺手维护 first_day / 上限）
func _day_or_create(date: String) -> Dictionary:
	if first_day == "":
		first_day = date
	for d in days:
		if String(d["date"]) == date:
			return d
	var fresh := {"date": date, "beats": [], "title": "", "text": "", "ai": false, "n": {}}
	days.push_front(fresh)          # 新的在前
	while days.size() > MAX_DAYS:
		days.pop_back()             # 丢最旧的（统计不受影响）
	return fresh

# ------------------------------------------------------------------ 给界面用

## 按"日期 + 正文 + 那天记了几个拍子"给界面，新的在前。
## 只返回**已经有正文**的那些天（没写的不显示 —— 界面不该出现空白条目）
func entries() -> Array:
	var out: Array = []
	for d in days:
		var t := String(d["text"])
		if t == "":
			continue
		out.append({
			"date": String(d["date"]),
			"title": String(d.get("title", "")),
			"text": t,
			"ai": bool(d["ai"]),
			"beats": (d["beats"] as Array).size(),
		})
	return out

## 日期 → 给人看的短写法（今天 / 昨天 / 10月9日）
func date_label(date: String) -> String:
	var today := _today()
	if date == today:
		return "今天"
	if date == _shift_day(today, -1):
		return "昨天"
	var parts := date.split("-")
	if parts.size() != 3:
		return date
	return "%d月%d日" % [int(parts[1]), int(parts[2])]

## 清空（设置面板里那个"点两下"的按钮用）。**不可回退**，所以调用方要二次确认
func clear_all() -> void:
	days.clear()
	first_day = _today()
	total_pets = 0
	total_talks = 0
	save()
