# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 长期记忆系统 —— 从 giftia 的 backend/memory_manager.py 移植过来的那套机制的 GDScript 版。
##
## 为什么值得移植：原来"记忆"就是内存里的 20 条对话历史，重启没、聊长了也被截断。
## giftia 那套是同一件事的成熟做法，核心就四件事：
##   1. **遗忘曲线**（艾宾浩斯）：R = e^(-t / (S*24+1))，S 由重要性 + 复习次数决定 ——
##      所以"被反复提起的事"记得牢，"提过一次的小事"会自然淡掉
##   2. **记忆分层**：核心（几乎不忘）/ 重要 / 常规，按重要性 + 情感强度自动分配
##   3. **混合检索 + 重排**：两路召回做 RRF 融合，再按"检索质量 / 时间 / 情感匹配 /
##      重要性 / 层级权重"五项加权排序，取最相关的几条注入提示词
##   4. **工作记忆**：跨对话的整体摘要 + 还没聊完的话题 + 主人最近的情绪
##
## 移植时降级的两处（不是偷懒，是环境里真没有）：
##   - 语义向量 → **中文 n-gram 子串匹配**。giftia 用的是智谱 embedding，
##     而桌宠直连 DeepSeek，它没有 embeddings 接口。好在 giftia 的 `_match_score`
##     本来就写了"向量不可用时降级到字符级匹配"，这里用的就是那套算法。
##   - SQLite / LangChain / mem0 → **JSON 文件**。不为记忆重新引入 Python 后端。
##
## 记住一条：**这个模块只负责"记住/想起来"，不管怎么说话**。
## 怎么把记忆说出口是 pet_persona.gd 的事。

extends RefCounted

## 存盘路径。是变量不是常量：探针要指到临时文件上跑，免得把真记忆当成实验品
var file_path: String = "user://pet_memory.json"
## 常规记忆超过这个数就开始按遗忘曲线清理
const MAX_ITEMS := 60
## 一次注入提示词的记忆条数
const RECALL_LIMIT := 5
## 档案卡里每类喜好的上限
const MAX_PREF := 8

## 分层与遗忘（分层枚举 / 遗忘强度 / 艾宾浩斯曲线 / 清理与巩固）全在
## **pet_memory_forget.gd** —— 作业单 B4.2 搬的，那边是那套公式的真源
const MemForget := preload("res://scripts/ai/memory/pet_memory_forget.gd")
## 记忆的"管理与整理"（近义去重 / 合并），见 pet_memory_organize.gd
const MemOrganize := preload("res://scripts/ai/memory/pet_memory_organize.gd")

## 分层枚举。**层号从那边派生**（单一真源），但枚举本身还得在这儿声明：
## `PetMemory.Layer.CORE` 是探针在用的写法（tools/probe_memory.gd），不能断
enum Layer {
	CORE = MemForget.Layer.CORE,
	IMPORTANT = MemForget.Layer.IMPORTANT,
	REGULAR = MemForget.Layer.REGULAR,
}

## 按重要性和情感强度自动分层（阈值与说明见 pet_memory_forget.gd）
static func layer_of(importance: float, intensity: float) -> int:
	return MemForget.layer_of(importance, intensity)

## 遗忘强度系数：核心层忘了 10 倍慢
static func forgetting_strength(layer: int) -> float:
	return MemForget.forgetting_strength(layer)

## 检索时的权重：核心层的事优先被想起来
static func retrieval_weight(layer: int) -> float:
	return MemForget.retrieval_weight(layer)

## 当前保留率 0~1（艾宾浩斯曲线，口径见 pet_memory_forget.gd）
static func retention(created: float, last_access: float, importance: float,
		access_count: int) -> float:
	return MemForget.retention(created, last_access, importance, access_count)

# ================================================================
# 情感分析（关键词版，照搬 giftia 的表）
# ================================================================

enum Mood { NEUTRAL, HAPPY, SAD, ANXIOUS, ANGRY, EXCITED, FEARFUL, GRATEFUL, LONELY, HOPEFUL, STRESSED, RELIEVED }

const MOOD_NAMES := ["平静", "开心", "难过", "焦虑", "生气", "兴奋", "害怕", "感激", "孤单", "期待", "有压力", "松了口气"]

const MOOD_KEYWORDS: Dictionary = {
	Mood.HAPPY: ["开心", "快乐", "高兴", "愉快", "幸福", "满足", "太好了", "棒", "爽", "笑", "好玩", "有趣", "惊喜", "顺利", "成功"],
	Mood.SAD: ["难过", "悲伤", "伤心", "失落", "沮丧", "哭", "痛苦", "绝望", "无奈", "失望", "心碎", "眼泪", "不开心", "郁闷", "低落", "失败", "挫败", "遗憾", "错过", "被拒", "碰壁", "落空", "没戏", "泡汤", "完了", "凉了"],
	Mood.ANXIOUS: ["焦虑", "紧张", "担心", "害怕", "不安", "惶恐", "压力", "喘不过气", "忐忑", "忧虑", "发愁", "纠结"],
	Mood.ANGRY: ["生气", "愤怒", "恼火", "烦躁", "烦", "讨厌", "恨", "不爽", "发火", "暴躁"],
	Mood.EXCITED: ["兴奋", "激动", "迫不及待", "振奋", "狂热"],
	Mood.FEARFUL: ["害怕", "恐惧", "恐慌", "吓死", "不敢", "畏惧", "胆怯"],
	Mood.GRATEFUL: ["感谢", "谢谢", "感恩", "感激", "多亏", "幸好"],
	Mood.LONELY: ["孤独", "寂寞", "孤单", "一个人", "没人陪", "冷落"],
	Mood.HOPEFUL: ["希望", "相信", "会好的", "未来"],
	Mood.STRESSED: ["压力", "累", "疲惫", "受不了", "崩溃", "撑不住", "加班", "考试"],
	Mood.RELIEVED: ["放心", "安心", "松了一口气", "还好", "总算", "解脱"],
}

## 语境翻转：正向词撞上负面语境时要翻成"难过"。
## 没有这张表的话，"我努力了还是失败了"会被判成 HAPPY（命中"努力"？其实是命中"成功"里的字）
## —— giftia 专门为这类句子加了规则，照搬
const MOOD_FLIPS: Array = [
	{"pos": "喜欢", "neg": ["没牵", "没在一起", "不喜欢我", "拒绝", "没结果", "没回应", "单相思", "暗恋"], "mood": Mood.SAD},
	{"pos": "爱", "neg": ["不爱", "分手", "离开", "拒绝", "单相思", "没结果"], "mood": Mood.SAD},
	{"pos": "努力", "neg": ["失败", "没用", "白费", "不行", "被拒", "碰壁", "落空", "没结果", "还是没"], "mood": Mood.SAD},
	{"pos": "期待", "neg": ["落空", "失望", "没实现", "泡汤", "没了"], "mood": Mood.SAD},
	{"pos": "希望", "neg": ["破灭", "没了", "失望", "落空"], "mood": Mood.SAD},
	{"pos": "成功", "neg": ["没成功", "不成功", "失败"], "mood": Mood.SAD},
]

const INTENSIFIERS := ["非常", "特别", "超级", "极其", "万分", "太", "真的很", "格外", "十分"]
const NEGATORS := ["不", "没", "别", "没有", "并非", "并不"]

## 返回 [Mood, 强度 0~1]
static func analyze_mood(text: String) -> Array:
	for flip in MOOD_FLIPS:
		if text.find(String(flip["pos"])) >= 0:
			for neg in (flip["neg"] as Array):
				if text.find(String(neg)) >= 0:
					return [int(flip["mood"]), 0.6]
	var best := Mood.NEUTRAL
	var best_score := 0.0
	for mood in MOOD_KEYWORDS.keys():
		var score := 0.0
		for kw in (MOOD_KEYWORDS[mood] as Array):
			if text.find(String(kw)) < 0:
				continue
			score += 0.3
			for it in INTENSIFIERS:
				if text.find(String(it)) >= 0:
					score += 0.2
					break
			for ng in NEGATORS:
				if text.find(String(ng) + String(kw)) >= 0:
					score -= 0.2
					break
		if score > best_score:
			best_score = score
			best = int(mood)
	if best_score <= 0.0:
		return [Mood.NEUTRAL, 0.0]
	return [best, minf(1.0, best_score)]

static func mood_name(mood: int) -> String:
	return MOOD_NAMES[clampi(mood, 0, MOOD_NAMES.size() - 1)]

# ================================================================
# 重要性打分（照搬 giftia 的 ImportanceScorer）
# ================================================================

const INFO_INDICATORS := ["叫", "是", "喜欢", "讨厌", "工作", "住", "在", "有", "毕业", "来自",
	"年龄", "岁", "职业", "专业", "兴趣", "家人", "朋友", "同事", "同学", "生日"]

static func score_importance(content: String, intensity: float, access_count: int = 0) -> float:
	var emotion_score := intensity * 0.4                 # 情感越强越重要
	var info_score := 0.0
	for ind in INFO_INDICATORS:
		if content.find(ind) >= 0:
			info_score += 0.05
	info_score = minf(0.3, info_score)                   # 信息密度
	var access_score := minf(0.2, access_count * 0.04)   # 被想起过
	var length_score := minf(0.1, float(content.length()) / 200.0)
	return clampf(emotion_score + info_score + access_score + length_score, 0.0, 1.0)

# ================================================================
# 一条记忆
# ================================================================

## 记忆的**种类**。2026-09-29 加的：在那以前靠文字前缀（"她主动聊到：…"）去认
## "这是她自己的话"，前缀一漏（换说法、新来源）就出事 —— 现在每条自己带标记，
## 写入端显式给，读出端按它**分栏**（见 pet_memory_prompt.context_block）。
const KIND_FACT := "fact"            # 关于主人的事实 —— **唯一**会进【关于主人】的那种
const KIND_SELF_LINE := "self_line"  # 她自己的原话/撒娇：不删，但永远不当事实喂给她
const KIND_MOOD := "mood"            # 情绪化内容：短期记忆过期后只留这个（见 pet_shortterm）

class Item:
	var text: String = ""
	## 种类（KIND_*）。"" = 旧档案里还没有这个字段 —— 载入时由 `_ensure_kind()` 补 ✓。
	## **内部类看不到外层作用域**，所以这里只存字符串，认不了上面的常量
	var kind: String = ""
	var importance: float = 0.1
	var layer: int = 3
	var mood: int = 0
	var intensity: float = 0.0
	var created: float = 0.0
	var last_access: float = 0.0
	var access_count: int = 0
	var consolidated: bool = false

	func to_dict() -> Dictionary:
		return {
			"text": text, "kind": kind, "importance": importance, "layer": layer, "mood": mood,
			"intensity": intensity, "created": created, "last_access": last_access,
			"access_count": access_count, "consolidated": consolidated,
		}

	static func from_dict(d: Dictionary) -> Item:
		var it := Item.new()
		it.text = String(d.get("text", ""))
		# 旧档案没有 kind → 留空，由外层 _ensure_kind() 按前缀补上（惰性迁移：
		# 下一次 save() 就写回文件，不专门做一次"升级脚本"）
		it.kind = String(d.get("kind", ""))
		it.importance = float(d.get("importance", 0.1))
		it.layer = int(d.get("layer", 3))
		it.mood = int(d.get("mood", 0))
		it.intensity = float(d.get("intensity", 0.0))
		it.created = float(d.get("created", 0.0))
		it.last_access = float(d.get("last_access", 0.0))
		it.access_count = int(d.get("access_count", 0))
		it.consolidated = bool(d.get("consolidated", false))
		return it

	## 保留率。注意**不能**在这里调外层的 retention()：
	## GDScript 的内部类看不到外层作用域，只能由外层拿字段去算
	func fields() -> Array:
		return [created, last_access, importance, access_count]

# ================================================================
# 存储
# ================================================================

## 结构化档案卡：字段级的事实，比重排后的记忆更稳定（对应 giftia 的 user_profile.py）
var profile: Dictionary = {}
## 工作记忆：整体了解 + 待跟进话题 + 最近情绪（对应 giftia 的 working_memory.py）
var working: Dictionary = {}
var items: Array = []
var last_chat: int = 0
var last_error: String = ""

## 抽取规则：第 1 个捕获组是要记住的那句话。
## 顺序有讲究：先具体的（生日、名字），后宽泛的（喜欢），否则"我生日是 3 月"会被"我是…"吃掉
const RULES: Array[Dictionary] = [
	{"re": "记住[，,:：]?\\s*([^。！？!?\\n]{1,30})", "path": "notes", "tpl": "主人让我记住：%s"},
	{"re": "我(?:的)?生日(?:是|在)?([^，。！？,.!?、\\s]{1,12})", "path": "identity.birthday", "tpl": "主人生日是 %s"},
	{"re": "我(?:叫|的名字是|名字叫)([^，。！？,.!?、\\s]{1,12})", "path": "identity.name", "tpl": "主人的名字是「%s」"},
	{"re": "我(?:今年)?\\s*(\\d{1,2})\\s*岁", "path": "identity.age", "tpl": "主人今年 %s 岁"},
	{"re": "我(?:住在|老家在)([^，。！？,.!?、\\s]{2,12})", "path": "identity.location", "tpl": "主人住在 %s"},
	{"re": "我在([^，。！？,.!?、\\s]{2,16})(?:上班|工作|上学|读书)", "path": "identity.occupation", "tpl": "主人在 %s 上班/上学"},
	{"re": "我(?:养了|家有)(?:一只|一个|条|只)?([^，。！？,.!?、\\s]{1,10})", "path": "pets", "tpl": "主人有 %s"},
	{"re": "我(?:最|很|超|特别|挺)?(?:喜欢|爱玩|爱吃|爱喝)([^，。！？,.!?、\\s]{1,16})", "path": "likes", "tpl": "主人喜欢 %s"},
	{"re": "我(?:不(?:太)?喜欢|讨厌|受不了|不吃|不喝)([^，。！？,.!?、\\s]{1,16})", "path": "dislikes", "tpl": "主人不喜欢 %s"},
]

# ------------------------------------------------------------------ 读写

func load_from_disk() -> void:
	profile.clear()
	working.clear()
	items.clear()
	last_chat = 0
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		last_error = "记忆文件打不开"
		return
	var raw := f.get_as_text()
	f.close()
	var j: Variant = JSON.parse_string(raw)
	if typeof(j) != TYPE_DICTIONARY:
		# 文件坏了就当没有记忆 —— 宁可重新开始，也别让她说胡话
		last_error = "记忆文件格式不对，已忽略"
		return
	var d := j as Dictionary
	if typeof(d.get("profile")) == TYPE_DICTIONARY:
		profile = d["profile"]
	if typeof(d.get("working")) == TYPE_DICTIONARY:
		working = d["working"]
	if typeof(d.get("items")) == TYPE_ARRAY:
		for x in (d["items"] as Array):
			if typeof(x) == TYPE_DICTIONARY:
				var it := Item.from_dict(x)
				if it.text != "":
					_ensure_kind(it)     # 旧档案没 kind：载入时按前缀补（见 _ensure_kind）
					items.append(it)
	last_chat = int(d.get("last_chat", 0))

func save() -> void:
	var arr: Array = []
	for it in items:
		arr.append((it as Item).to_dict())
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		last_error = "记忆文件写不了（%s）" % file_path
		return
	f.store_string(JSON.stringify({
		"profile": profile,
		"working": working,
		"items": arr,
		"last_chat": last_chat,
	}, "  "))
	f.close()

func clear() -> void:
	profile.clear()
	working.clear()
	items.clear()
	last_chat = 0
	save()

func is_empty() -> bool:
	return items.is_empty() and profile.is_empty() and working.is_empty()

# ------------------------------------------------------------------ 记下来

## 加一条记忆。同一句话已经记过就只"复习"它（access_count+1、刷新时间）——
## 这正是遗忘曲线里"复习让记忆更牢"的那一环，也顺手去重。
##
## `kind` 是**种类**（见 KIND_*，2026-09-29 加）：默认 fact（关于主人的事实）。
## 她自己说的话给 KIND_SELF_LINE、情绪化内容给 KIND_MOOD ——
## 后两种**永远不会**进【关于主人】，各走各的那一栏（这是"记忆和主动对话分家"的地基）
func add(text: String, importance_boost: float = 0.0, kind: String = KIND_FACT) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	var mood_pair := analyze_mood(t)
	var existing := _find_same(t)
	if existing != null:
		_ensure_kind(existing)     # 旧条目补上种类（新条目本来就有）
		existing.access_count += 1
		existing.last_access = Time.get_unix_time_from_system()
		existing.consolidated = true
		if importance_boost > 0.0:
			existing.importance = clampf(existing.importance + importance_boost, 0.0, 1.0)
			existing.layer = layer_of(existing.importance, existing.intensity)
		return
	var it := Item.new()
	it.text = t
	it.kind = _normalize_kind(kind)
	it.mood = int(mood_pair[0])
	it.intensity = float(mood_pair[1])
	it.importance = clampf(score_importance(t, it.intensity) + importance_boost, 0.0, 1.0)
	it.layer = layer_of(it.importance, it.intensity)
	it.created = Time.get_unix_time_from_system()
	it.last_access = it.created
	items.append(it)
	if items.size() > MAX_ITEMS:
		prune()

## 从主人这句话里抽取值得长期记住的事（本地规则，零成本、立刻生效）。
## 返回新学到的条目，用来打日志。抽不到是常态 —— 只有自述式的话才值得进档案
func learn(user_text: String) -> Array:
	var added: Array = []
	var text := user_text.strip_edges()
	if text == "":
		return added
	for r in RULES:
		var re := RegEx.new()
		if re.compile(String(r["re"])) != OK:
			continue
		var m := re.search(text)
		if m == null:
			continue
		var val := _tidy(m.get_string(1))
		if val.length() < 2:
			continue
		if _bad_value(val):
			continue
		# "我不喜欢香菜"会同时命中下面"喜欢"那条宽规则，必须挡掉 ——
		# 否则档案里会同时留下"喜欢 香菜"和"不喜欢 香菜"两条自相矛盾的记忆。
		# 判据是捕获到的词前面三个字里有没有否定词，有就交给"不喜欢"那条规则处理
		if String(r["path"]) == "likes" and _negated_before(text, m.get_start(1)):
			continue
		var line := String(r["tpl"]) % val
		if not _profile_has(line):
			_set_profile(String(r["path"]), val)
			added.append(line)
		add(line, 0.05)
		# 进了档案的事实就长期留着：档案卡本身不受遗忘曲线影响，
		# 但重排用的那条记忆条目得标成"已巩固"，否则它掉到常规层会被清理掉
		var note := _find_same(line)
		if note != null:
			note.consolidated = true
	if not added.is_empty():
		save()
	return added

## 记一轮对话：更新工作记忆、时间戳、并让她的记忆自然衰减一次。
## 每轮都调用，但**不做 LLM 调用** —— LLM 摘要由上层按节奏触发（见 ai_working_prompt）
func note_exchange(user_text: String, reply: String) -> void:
	var mood_pair := analyze_mood(user_text)
	var mood := int(mood_pair[0])
	if mood != Mood.NEUTRAL:
		_set_working("mood", mood_name(mood))
	var topics := _working_list("open_topics")
	var topic := _topic_of(user_text)
	if topic != "":
		topics.erase(topic)
		topics.append(topic)
		while topics.size() > 5:
			topics.pop_front()
		working["open_topics"] = topics
	if reply.strip_edges() != "":
		# 本地兜底摘要：只留最近两句。好版本由上层叫模型写（apply_working_summary），
		# 本地这份只是它没回来时的占位 —— 堆太多反而会把提示词占满
		var bits: Array = []
		var s := String(working.get("summary", "")).strip_edges()
		if s != "":
			for b in s.split("；"):
				if String(b).strip_edges() != "":
					bits.append(String(b))
		var bit := user_text.strip_edges()
		if not bits.has(bit):
			bits.append(bit)
		while bits.size() > 2:
			bits.pop_front()
		_set_working("summary", "；".join(bits))
	last_chat = int(Time.get_unix_time_from_system())
	decay()
	save()

## 用模型返回的摘要覆盖工作记忆（叫 AI 干活的是上层，这里只管存）
func apply_working_summary(summary: String, topics: Array, mood: String) -> void:
	if summary.strip_edges() != "":
		_set_working("summary", summary.strip_edges().substr(0, 300))
	var kept: Array = []
	for t in topics:
		var s := String(t).strip_edges()
		if s != "" and kept.size() < 5:
			kept.append(s)
	if not kept.is_empty():
		working["open_topics"] = kept
	if mood.strip_edges() != "":
		_set_working("mood", mood.strip_edges())
	save()

# ------------------------------------------------------------------ 想起来

## 最近几轮**已经送出去过**的记忆（key 字符串）。只活在内存里，重启就清空。
##
## 为什么需要（用户 2026-09-27 报的"她一直在反复强调看壁纸那一瞬间"）：
##   1. 兜底那条路是"固定取最重要的几条"—— 每轮都是同一批；
##   2. 每条被想起来一次就 access_count += 1、last_access 刷新 → 保留率变高 →
##      下轮排得更靠前。这是个**越滚越牢**的循环，最后她张口就是那件事。
## 光给"刚送过的"打个折不管用（分高的那条打完折还是第一，自检抓到过），
## 所以做法是：**弱命中/没命中的那一路按"没刚送过的优先"取，并且条数限死 1 条**
## （见 retrieve 的 strong 和 _top_by_importance 的 recent 参数）。
var _recent_shown: Array = []
## ≈ 两轮的 recall 量：一件旧事歇 2~3 轮才会重新出现
const RECENT_SHOWN_MAX := 10
## "刚送出去过的"在重排里打的折。**不扔掉**（没别的可捞时它还得顶上），
## 但要狠到能换人：0.25 那种轻折扣不管用 —— 分高的那条打完折还是第一（自检抓到过）
const RECENT_SHOWN_DEMOTE := 0.05
## 一句话**没真对上**时，最多塞几条记忆（"真对上"= 0.8 那一档，见 retrieve 里的 strong）。
##
## 原来是 5（照搬 giftia 的 min_importance 兜底），但那正是用户 2026-09-27 报的
## "她一直在反复强调看壁纸那一瞬间"的来源：主人随便说声"在吗"，也照样摆 5 条旧事，
## 而最新最显眼的那条天天在。降到 1 条 + 轮换（见 _recent_shown）就够她"记得点什么"了 ——
## "主人是谁"那部分本来就不靠这里：档案卡和工作记忆每轮都在（见 context_block）。
## 真觉得她还是太爱翻旧事，把这个数改成 0 即可
const FALLBACK_RECALL := 1

## 她**自己的原话**被存下来时带的前缀（由 pet_memory_flow.gd 决定，改那边要同步这里）。
##
## 为什么检索时要认这几个前缀（用户 2026-09-29 报的"没有不理她，她却说才理我"）：
##   这些条目记的是"她说过什么"，**不是关于主人的事实** —— 可拼给模型的表头写着
##   【关于主人（你记得的事）】，于是她的撒娇抱怨被当成主人的事读进去 ✗。
##   而 16 条里最扎眼的正是"诶你终于理我了，我刚在你屏幕边上走了八百圈了都"
##   "连我都不理了""都没理我" ⇒ 每轮捞出来 ⇒ 她就照着重说一遍 ✗✗。
## 注意：**条目本身不动**（用户要求"一条都不删"），只是不再当事实喂给她；
## 以后也不会有新的：AI 整理开着时她的原话根本不入库（见 pet_memory_flow 里那段说明）。
const SELF_PREFIXES: Array[String] = [
	"她主动聊到：", "她偷看屏幕时看到：", "她看屏幕时看到：", "她看摄像头时看到：",
	"她生闷气时说：", "她替主人跑了趟活，回来讲：",
]

## 这条记忆是不是"她自己的话"（见 SELF_PREFIXES）。static：探针直接试它
static func is_self_line(text: String) -> bool:
	var t := text.strip_edges()
	for p in SELF_PREFIXES:
		if t.begins_with(p):
			return true
	return false

## 写入端给的种类先过一道：认不出来的（拼错 / 以后新加的值）当"事实"处理 ——
## 宁可它按老规矩进来，也别因为一个字符串拼错就悄悄不生效
static func _normalize_kind(kind: String) -> String:
	if kind == KIND_SELF_LINE or kind == KIND_MOOD:
		return kind
	return KIND_FACT

## 一条记忆的种类。**旧档案里这个字段是空的** —— 按前缀补上（惰性迁移）：
##   "她主动聊到：/她看屏幕时看到：…" → self_line
##   其余 → fact
## 触发点在 load_from_disk（载入时算好放内存），下一次 save() 自然写回文件 ——
## 所以不用专门做一次"升级脚本"，也不会在载入时偷偷改你的文件
func _ensure_kind(it: Item) -> String:
	if it.kind == KIND_FACT or it.kind == KIND_SELF_LINE or it.kind == KIND_MOOD:
		return it.kind
	it.kind = KIND_SELF_LINE if is_self_line(String(it.text)) else KIND_FACT
	return it.kind

## 混合检索 + 重排，返回最相关的几条（会顺手"复习"它们）
func retrieve(query: String, limit: int = RECALL_LIMIT) -> Array:
	if items.is_empty():
		return []
	var query_mood := int(analyze_mood(query)[0])
	# 先做话题扩展：没有语义向量时，这一步决定"换个说法还找不找得到"
	var q := expand_query(query)
	# 刚送出去过的先记下来（见 _recent_shown 的说明）
	var recent: Dictionary = {}
	for rs in _recent_shown:
		recent[rs] = true
	# RRF 融合：两路召回各给一个排名分，1/(60+rank+1)，再相加
	var rrf: Dictionary = {}
	var semantic := _rank_by_match(q)     # 字面/字符匹配路
	var keyword := _rank_by_tags(q)       # 标签/关键词路
	# **这一句算不算"真有东西对上"**：整串包含那一档（0.8）才算"真"。
	# 只有零散 n-gram / 标签命中时算"弱"（主人随便说声"在吗"就会这样）——
	# 弱的时候**不掐召回、只限条数**（给 1 条够用，别摆一堆旧事）。
	# ⚠️ 别用"弱就不召回"来做：那会把**换个说法也能找到**这条命根子掐死 ——
	#    「我平时爱喝什么」→「冰美式」正是靠弱匹配找到的（2026-09-27 试过，自检当场抓到）
	var strong := false
	if not semantic.is_empty():
		# 注意 `_rank_by_match` 返回的是 **Item 列表**（不是 {score,item} 字典）——
		# 所以这里要重算一次分，不能写 semantic[0]["score"]（2026-09-27 踩过：
		# 那句话直接运行时报错，retrieve 中断返回空，两个探针当场抓到）
		var top: Item = semantic[0]
		strong = match_score(top.text, q, top.importance) >= 0.8
	for i in range(semantic.size()):
		var it: Item = semantic[i]
		rrf[_key(it)] = float(rrf.get(_key(it), 0.0)) + 1.0 / (60.0 + i + 1.0)
	for i in range(keyword.size()):
		var it: Item = keyword[i]
		rrf[_key(it)] = float(rrf.get(_key(it), 0.0)) + 1.0 / (60.0 + i + 1.0)
	if rrf.is_empty():
		# 一个字都没对上：退回"最重要 + 最不容易忘"的**一条**（对应 giftia 的 min_importance 兜底）。
		# 条数限死在 FALLBACK_RECALL（不是 limit）：原因见那个常量的说明。
		# 带上 recent 是为了**轮换** —— 不然每轮都摆出同一条，她就会反复念同一件事
		return _top_by_importance(mini(limit, FALLBACK_RECALL), recent)
	# 弱命中只给 FALLBACK_RECALL 条，真匹配才给满 limit
	var want: int = limit if strong else mini(limit, FALLBACK_RECALL)
	var max_rrf := 0.0
	for k in rrf.keys():
		max_rrf = maxf(max_rrf, float(rrf[k]))
	if max_rrf <= 0.0:
		max_rrf = 1.0
	# 重排：权重照搬 giftia（检索质量 .50 / 时间 .20 / 情感 .15 / 重要性 .10 / 层级 .05）
	var scored: Array = []
	for it in items:
		var k := _key(it)
		if not rrf.has(k):
			continue
		# **只有"关于主人的事实"能进这里**（2026-09-29 起按 kind 判，不再靠文字前缀猜）：
		# 她自己说的话（self_line）和情绪（mood）各有各的去处 ——
		# 混进来她就会照着重说（"诶你终于理我了"就是这么念出来的）
		if _ensure_kind(it) != KIND_FACT:
			continue
		var norm_rrf := float(rrf[k]) / max_rrf
		var strength := forgetting_strength(it.layer)
		# 注：循环变量 it 是无类型的，成员访问回来都是 Variant，
		# 所以下面凡是拿它算出来的量都得显式标类型（:= 推断不出来）
		# "多久以前"全仓只算一处：pet_memory_forget.hours_since（遗忘曲线和
		# "大概是什么时候"那套都走它）。别在这儿再手写一遍 —— 2026-09-27 就是
		# 因为两处口径不一致，同一天记的事被读出"他现在正在做"的味道
		var elapsed_hours: float = MemForget.hours_since(
			float(it.last_access) if float(it.last_access) > 0.0 else float(it.created))
		var time_score := exp(-elapsed_hours / (strength * 24.0 + 1.0))
		var emo := 0.0
		if query_mood != Mood.NEUTRAL and it.mood == query_mood:
			emo = 1.0
		elif query_mood != Mood.NEUTRAL and it.mood != Mood.NEUTRAL:
			emo = 0.3
		var final: float = norm_rrf * 0.50 + time_score * 0.20 + emo * 0.15 \
			+ float(it.importance) * 0.10 + retrieval_weight(it.layer) * 0.05
		# 刚送出去过的**狠狠打折**：让她不至于每句都念同一件事（原因见 _recent_shown）
		if recent.has(k):
			final *= RECENT_SHOWN_DEMOTE
		scored.append({"score": final, "item": it})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	var out: Array = []
	for i in range(mini(want, scored.size())):
		var it: Item = scored[i]["item"]
		it.access_count += 1               # 被想起来 = 复习一次，忘得更慢
		it.last_access = Time.get_unix_time_from_system()
		_recent_shown.append(_key(it))     # 记下"这轮摆出去过"，下轮让它先让位
		out.append(it)
	while _recent_shown.size() > RECENT_SHOWN_MAX:
		_recent_shown.pop_front()
	save()
	return out

## 只取"情绪化内容"（KIND_MOOD）—— 给【你自己的心情】那一栏用（见 pet_memory_prompt）。
##
## 这是**短期记忆过期后唯一保留**的东西（用户 2026-09-29 定的规矩：
## "还没有任何反应则遗忘，仅保留情绪化内容"）—— 也就是她记得"那天有点失落"，
## 但记不住当时具体说了什么、更不会拿它当话题重念一遍。
## 按时间倒序、只给最近几条：心情这东西越旧越不该提
func retrieve_mood(limit: int = 2) -> Array:
	var out: Array = []
	for it in items:
		if _ensure_kind(it) == KIND_MOOD:
			out.append(it)
	out.sort_custom(func(a: Item, b: Item) -> bool: return a.created > b.created)
	if out.size() > limit:
		out = out.slice(0, limit)
	return out

## 一次匹配度打分（照搬 giftia 的 _match_score）：
## 整串包含 → 0.8；否则按 2~4 字 n-gram 命中的比例算
static func match_score(content: String, query: String, importance: float = 0.5) -> float:
	var cq := _clean(query)
	var cc := _clean(content)
	if cq.length() >= 2 and cc.find(cq) >= 0:
		return 0.8
	if cc.length() >= 2 and cq.find(cc) >= 0:
		return 0.8
	var common := 0
	for word_len in range(2, mini(5, cq.length() + 1)):
		for i in range(cq.length() - word_len + 1):
			if cc.find(cq.substr(i, word_len)) >= 0:
				common += 1
	if common > 0:
		return (float(common) / maxf(float(cq.length()), 1.0)) * (0.6 + importance * 0.4)
	return 0.0

## 比对前要清掉的标点空白。写死一张表而不是靠 is_valid_identifier() 之类的分类判断 ——
## 中文和全角标点在各种分类里的归属不一定一致，写死最稳
const PUNCT := " ，。！？、,.!?;:：；\n\r\t　“”‘’()（）<>《》[]【】-—…~～·\"'"

## 捕获到的值如果明显是"问句零件"就丢掉。
## "你还记得我叫什么吗"会命中"我叫…"那条规则，抓回"什么吗" ——
## 存进档案就成了"主人的名字是什么吗"，而且会一直污染后面所有对话
const BAD_VALUES := ["什么", "啥", "谁", "哪里", "哪儿", "哪", "多少", "几", "怎么", "怎样", "何时", "哪儿个"]

## 值不值得记：太短、或者中文实字太少的，一律不记。
## 这是"选择性"里最便宜的一道筛子 —— 主动搭话和偷看的回复里有相当一部分
## 就是"嗯嗯～""嘿嘿"这种，先在这里挡掉，后面的模型调用也就不用发了。
##
## 放在记忆模块里（而不是主脚本）是因为它属于"记忆该记什么"的规则，
## 和档案/遗忘曲线是一类东西 —— 以后调门槛只动这一处
static func worth_remembering(line: String) -> bool:
	var t := line.strip_edges()
	if t.length() < 8:
		return false
	var cjk := 0
	for ch in t:
		if ch >= "\u4e00" and ch <= "\u9fff":
			cjk += 1
	return cjk >= 4

## 口语查询的话题扩展表。
## 为什么需要它：移植时没了语义向量，只剩字面匹配 —— 于是"我平时爱喝什么"
## 跟记忆里的"主人喜欢 冰美式"**一个字都对不上**。命中左边的口气词就往查询里
## 补上右边的联想词，让字面匹配够得着。左边写人实际会问的说法，右边写记忆里可能出现的词
const TOPIC_HINTS: Dictionary = {
	"喝": "奶茶 咖啡 美式 拿铁 可乐 饮料 酒",
	"吃": "辣 香菜 外卖 泡面 火锅 甜 饭",
	"玩": "游戏 手游 番 剧 电影 音乐 歌",
	"累": "加班 熬夜 压力 疲惫 忙",
	"睡": "熬夜 失眠 早起 困",
	"上班": "工作 公司 加班 同事 老板",
	"家": "家人 妈妈 爸爸 宠物 猫 狗",
	"心情": "开心 难过 焦虑 压力 崩溃 累",
	"喜欢": "喜欢 爱 讨厌",
}

## 把口语问法扩成更容易被字面匹配命中的样子
static func expand_query(query: String) -> String:
	var all: Array[String] = []
	for k in TOPIC_HINTS.keys():
		if query.find(String(k)) >= 0:
			all.append(String(TOPIC_HINTS[k]))
	if all.is_empty():
		return query
	return query + " " + " ".join(all)

## 去掉标点空白再比，这样“三分糖”和“三分糖！”能对上
static func _clean(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if PUNCT.find(ch) >= 0:
			continue
		out += ch
	return out

# ------------------------------------------------------------------ 遗忘与巩固

## 衰减 / 清理 / 巩固 / 统计的实现在 **pet_memory_forget.gd**（作业单 B4.2）。
## 这一组壳留着，是因为宿主（desktop_pet / pet_memory_flow）和探针都按老名字调它们
func decay() -> void:
	MemForget.decay(self)

## 清理：保留率低 + 层级低 + 没被想起来过的记忆，丢掉（判据见 pet_memory_forget.gd）
func prune() -> int:
	return MemForget.prune(self)

## 巩固：保留率掉到 0.3 以下但 importance 还高的，标成"已巩固"（不再参与清理）
func consolidate() -> int:
	return MemForget.consolidate(self)

func stats() -> Dictionary:
	return MemForget.stats(self)

# ------------------------------------------------------------------ 给提示词用

## 记忆 ↔ 模型的进出口（三个提示词模板 + "变成文字" + "把模型的回复解析回来"）都在
## **pet_memory_prompt.gd** —— 作业单 B4.1 搬的。下面这一组壳留着：
## pet_persona 拼人设、probe_memory 量提示词、pet_memory_flow 解析回复，都按老名字调
const MemPrompt := preload("res://scripts/ai/memory/pet_memory_prompt.gd")

## 拼给模型看的记忆段落。这是"想起来"的唯一出口（拼法见 pet_memory_prompt.gd）
func context_block(query: String) -> String:
	return MemPrompt.context_block(self, query)

## 档案卡 → 给人看的几行
func profile_lines() -> Array[String]:
	return MemPrompt.profile_lines(self)

## 工作记忆 → 给人看的几行
func working_lines() -> Array[String]:
	return MemPrompt.working_lines(self)

func profile_text() -> String:
	return MemPrompt.profile_text(self)

func is_fresh() -> bool:
	return profile.is_empty() and items.is_empty()

## "多久没聊了"那一句（口径见 pet_memory_prompt.gd）
func since_text() -> String:
	return MemPrompt.since_text(self)

# ------------------------------------------------------------------ 内部

func _key(it: Item) -> String:
	return "%d|%s" % [int(it.created), it.text]

func _find_same(text: String) -> Item:
	var a := _squash(text)
	for it in items:
		if _squash(it.text) == a:
			return it
	return null

func _rank_by_match(query: String) -> Array:
	var pairs: Array = []
	for it in items:
		var s := match_score(it.text, query, it.importance)
		if s > 0.0:
			pairs.append({"score": s, "item": it})
	pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	var out: Array = []
	for p in pairs:
		out.append(p["item"])
	return out

## 第二路召回：记忆里的标签词（情感词 + 信息指示词）出现在查询里就打一分。
## 语义向量那一路在 DeepSeek 上没法做（它不提供 embeddings 接口），
## 所以"两路召回"在这里 = 字面匹配路 + 标签路，RRF 融合和重排权重照旧
func _rank_by_tags(query: String) -> Array:
	var q := _clean(query)
	var pairs: Array = []
	for it in items:
		var hits := 0
		for tag in _tags_of(it.text):
			if q.find(_clean(tag)) >= 0:
				hits += 1
		if hits > 0:
			pairs.append({"score": float(hits) * (0.6 + it.importance * 0.4), "item": it})
	pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	var out: Array = []
	for p in pairs:
		out.append(p["item"])
	return out

func _tags_of(text: String) -> Array:
	var tags: Array = []
	for ind in INFO_INDICATORS:
		if text.find(ind) >= 0 and not tags.has(ind):
			tags.append(ind)
	for mood in MOOD_KEYWORDS.keys():
		for kw in (MOOD_KEYWORDS[mood] as Array):
			if text.find(String(kw)) >= 0 and not tags.has(String(kw)):
				tags.append(String(kw))
				break
	return tags

## 兜底：一个字都没对上时，至少让她还记得主人是谁。
## `recent` 里是**刚送出去过的** —— 排在最后（不是丢掉：实在没别的可捞时还得靠它们顶上），
## 这样连问同一句也不会每轮都摆出同一条（见 _recent_shown）
func _top_by_importance(limit: int, recent: Dictionary = {}) -> Array:
	var pairs: Array = []
	for it in items:
		# 兜底那条路也只摆"关于主人的事实"（原因见 retrieve 里那段说明）
		if _ensure_kind(it) != KIND_FACT:
			continue
		var fresh: float = 0.0 if recent.has(_key(it)) else 1.0
		pairs.append({
			"score": it.importance + retrieval_weight(it.layer) * 0.2,
			"fresh": fresh,
			"item": it,
		})
	# 主键 fresh、次键 score —— 合成一个数比写多行 lambda 稳（GDScript 的 lambda 里换行容易踩缩进）
	pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _rank_of(a) > _rank_of(b))
	var out: Array = []
	for i in range(mini(limit, pairs.size())):
		out.append(pairs[i]["item"])
	return out

func _rank_of(p: Dictionary) -> float:
	return float(p["fresh"]) * 100.0 + float(p["score"])

func _identity() -> Dictionary:
	return profile.get("identity", {}) if typeof(profile.get("identity")) == TYPE_DICTIONARY else {}

func _pref_list(key: String) -> Array:
	var v: Variant = profile.get(key)
	return v if typeof(v) == TYPE_ARRAY else []

func _identity_line(key: String, v: String) -> String:
	match key:
		"name": return "主人叫 %s" % v
		"age": return "主人今年 %s 岁" % v
		"occupation": return "主人在 %s 上班/上学" % v
		"location": return "主人住在 %s" % v
		"birthday": return "主人生日 %s" % v
	return v

func _pref_line(key: String, v: String) -> String:
	match key:
		"likes": return "主人喜欢 %s" % v
		"dislikes": return "主人不喜欢 %s" % v
		"pets": return "主人有 %s" % v
	return v

func _working_list(key: String) -> Array:
	var v: Variant = working.get(key)
	return v if typeof(v) == TYPE_ARRAY else []

func _set_working(key: String, value: Variant) -> void:
	working[key] = value

## 把抽取到的事实写进档案卡。
## identity.* 是单值字段（后者覆盖前者），likes/dislikes/pets/notes 是列表（去重后追加）
func _set_profile(path: String, value: String) -> void:
	if path.begins_with("identity."):
		var sub := path.split(".")[1]
		var ident: Dictionary = _identity().duplicate()
		ident[sub] = value
		profile["identity"] = ident
		return
	var list := _pref_list(path).duplicate()
	if list.has(value):
		return
	list.append(value)
	while list.size() > MAX_PREF:
		list.pop_front()
	profile[path] = list

## 是否是"问句零件"而不是事实。见 BAD_VALUES 的注释
func _bad_value(val: String) -> bool:
	for bad in BAD_VALUES:
		if val.begins_with(bad) or val.ends_with(bad):
			return true
	# 以问句语气词结尾的一律不是事实（"阿哲吗"、"香菜呢"）
	for tail in ["吗", "呢", "吧", "么"]:
		if val.ends_with(tail):
			return true
	# 名字/喜好都不该是一长串，抓得太长的多半是句子碎片
	return val.length() > 8

## 捕获到的词前面几个字里有没有否定词。用来区分"喜欢 X"和"不喜欢 X"
func _negated_before(text: String, pos: int) -> bool:
	var from := maxi(0, pos - 3)
	var head := text.substr(from, pos - from)
	for ng in ["不", "没", "别", "免"]:
		if head.find(ng) >= 0:
			return true
	return false

func _profile_has(line: String) -> bool:
	for p in profile_lines():
		if _squash(p) == _squash(line):
			return true
	return false

func _topic_of(user_text: String) -> String:
	var t := user_text.strip_edges().replace("\n", " ")
	if t.length() > 16:
		t = t.substr(0, 16) + "…"
	return t

func _squash(s: String) -> String:
	return _clean(s)

## 去空白、去尾部语气词，超长截断。"我喜欢奶茶啊" → "奶茶"
func _tidy(s: String) -> String:
	var t := s.strip_edges().strip_escapes()
	for tail in ["。", "，", ",", ".", "！", "!", "？", "?", "～", "~", "啊", "吧", "呢", "了", "的"]:
		if t == tail:
			return ""
		while t.ends_with(tail):
			t = t.substr(0, t.length() - tail.length())
	t = t.strip_edges()
	if t.length() > 26:
		t = t.substr(0, 26)
	return t

# ================================================================
# 让模型干活：事实抽取 / 工作记忆更新
# 提示词照搬 giftia 的 _llm_extract_facts 和 WORKING_MEMORY_UPDATE_PROMPT
# ================================================================

## 三个提示词模板 + 工作记忆的文本形式 + "解析模型回复"那套，都在
## **pet_memory_prompt.gd**（作业单 B4.1 搬的）。常量在这儿只是**别名**，真源在那边 ——
## 而 pet_memory_flow / probe_memory 一直是按 `PetMemory.FACT_PROMPT` 这个写法用的
const FACT_PROMPT := MemPrompt.FACT_PROMPT
const OBSERVE_PROMPT := MemPrompt.OBSERVE_PROMPT
const WORKING_PROMPT := MemPrompt.WORKING_PROMPT

## 今天的日期（提示词里必须带上它，才能把"今天/昨天"换算成绝对日期）——
## 见 pet_memory_prompt.today_text 的说明：不换算的话，几天前的事会被读成"昨天"
static func today_text() -> String:
	return MemPrompt.today_text()

## "从某个时刻到现在过了多少小时" —— 实现在 **pet_memory_forget**（全仓唯一算这个的地方）。
## 留壳给宿主用（它要算"距上次说话多久"），免得宿主自己写一遍时间戳减法 ✗
static func hours_since(ts: float) -> float:
	return MemForget.hours_since(ts)

## 当前工作记忆的文本形式，喂给 WORKING_PROMPT
func working_text() -> String:
	return MemPrompt.working_text(self)

## 解析模型回复那三支（安静解析 / 抠数组 / 抠对象）—— 实现在 pet_memory_prompt.gd。
## 留成 static 壳是因为 pet_memory_flow / pet_quick / probe_memory 都直接调它们
static func parse_json_quiet(text: String) -> Variant:
	return MemPrompt.parse_json_quiet(text)

static func parse_json_array(text: String) -> Array:
	return MemPrompt.parse_json_array(text)

static func parse_json_object(text: String) -> Dictionary:
	return MemPrompt.parse_json_object(text)

## 把模型抽出来的事实存进去，返回实际存下的条数。
## 走整理模块的 merge_into：抽到的这条要是和已有 fact **近义**，就复习旧条、不新增
## （否则同一件事会被抽成"挑壁纸 / 挑洁尔佩塔相关的壁纸 / 2026年9月27日在挑壁纸"好几天条）
func apply_extracted_facts(facts: Array) -> int:
	var n := 0
	for f in facts:
		var s := String(f).strip_edges()
		if s.length() < 5:
			continue
		if s.begins_with("AI") or s.find("AI曾") >= 0 or s.find("AI建议") >= 0:
			continue                       # 禁掉"AI对用户的建议"，见 FACT_PROMPT 第 3 条
		var out := MemOrganize.merge_into(self, _tidy_sentence(s), 0.1, KIND_FACT)
		if out != MemOrganize.OUT_SKIPPED:
			n += 1
	if n > 0:
		save()
	return n

func _tidy_sentence(s: String) -> String:
	var t := s.strip_edges()
	if t.length() > 60:
		t = t.substr(0, 60)
	return t

# ================================================================
# 内部类看不到外层作用域，所以凡是要算保留率的地方都得由外层代劳
# ================================================================

func retention_of(it: Item) -> float:
	return MemForget.retention_of(self, it)
