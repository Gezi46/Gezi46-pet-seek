# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 记忆与模型之间的**进出口**：
##   - 三个提示词模板：抽事实 / 她的观察 / 更新工作记忆
##   - 出口：把记忆变成给模型看的文字（`context_block` / `profile_lines` / …）
##   - 入口：把模型回的文字解析回结构化数据（`parse_json_*`，模型经常不照格式写）
##
## 从 pet_memory.gd 搬出来（作业单 B4.1）。为什么值得独立：改提示词是这里最常动的事，
## 而它**不碰存盘**（存盘留在 pet_memory.gd）；解析那几支本来就是一整套兜底逻辑。
##
## 全是 **static**，记忆对象当参数传进来。`mem` **故意不标类型**：它属于 pet_memory.gd，
## 标上就成循环 preload（见 CONVENTIONS.md）。本模块只**读** mem 的档案卡 / 工作记忆 /
## 记忆列表，不写它的任何状态。
##
## 接口面：读 `mem` 的几个字段与查询接口；不碰文件、不碰网络、不发信号
extends RefCounted

const MemForget := preload("res://scripts/ai/memory/pet_memory_forget.gd")

# ------------------------------------------------------------------ 时间口径（写/读两头）

## 今天的日期，给提示词用。**写记忆时必须拿它把"今天/昨天"换算成绝对日期**：
## 不换算的话，那条事实会带着"写进去那天"的"今天"活很久 —— 用户 2026-09-27 报的
## "好几天前的事她记成昨天"就是这么来的（当时存档里 12 条都写着"今天"）。
static func today_text() -> String:
	var dt := Time.get_datetime_dict_from_system()
	# 显式标类型：数组下标取出来是 Variant，`:=` 推不出来（踩过一次）
	var wd: String = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][
		clampi(int(dt["weekday"]), 0, 6)]
	return "%d年%d月%d日（%s）" % [int(dt["year"]), int(dt["month"]), int(dt["day"]), wd]

## 一条记忆是"什么时候记下的"，给模型一个短标签（"9月24日"）。
## 为什么需要：**已经存进去的旧记忆**文字里写的还是"今天/刚才"，模型只能猜，
## 而最常见的一种猜法就是"昨天"。标上日期它才读得对。
## 当天记的不标（省 token —— 那段有 MEM_BLOCK_MAX_CHARS 预算）
static func _date_tag(created: float) -> String:
	# 分档逻辑在 **pet_memory_forget.rough_age** —— 它和遗忘曲线、检索重排的时间分
	# 共用同一个时钟（hours_since），所以"她读到的年龄"不会和打分口径打架。
	# 这里只负责包成括号；"刚刚"不标（她本来就知道是刚说的）
	var rough := MemForget.rough_age(created)
	if rough == "" or rough == "刚刚":
		return ""
	return "（%s）" % rough

# ------------------------------------------------------------------ 出口：变成文字

## 拼给模型看的记忆段落。这是"想起来"的唯一出口 ——
## 档案卡（稳定事实）+ 工作记忆（整体了解）+ 检索到的相关记忆（这一句用得上）
static func context_block(mem, query: String) -> String:
	var lines: Array[String] = []
	var prof := profile_lines(mem)
	for p in prof:
		lines.append("- " + p)
	var w := working_lines(mem)
	for p in w:
		lines.append(p)
	# 注意 mem 是**弱类型**（故意不标，避免循环 preload）→ 这里不能写 `:=` 让它推断
	var recalled: Array = mem.retrieve(query)
	var seen := {}
	for it in recalled:
		if seen.has(it.text):
			continue
		seen[it.text] = true
		# 核心层/被反复提起的事，着重标一下，模型会更愿意自然地用
		var mark := "（你印象很深）" if it.layer == MemForget.Layer.CORE or it.access_count >= 3 else ""
		# 记下的日期：旧记忆的文字里可能还写着"今天"，标上日期它才读得对（见 _date_tag）
		lines.append("- " + it.text + _date_tag(it.created) + mark)
	if lines.is_empty():
		return ""
	var since := since_text(mem)
	var head := "【关于主人（你记得的事）】\n"
	if since != "":
		head += since + "\n"
	var block := head + "\n".join(lines) \
		+ "\n（这些是你以前听主人说的。聊天时自然用上就行，别生硬地复述，也别一次全说出来；" \
		+ "括号里的日期只是让你知道那事过去多久了，**别把日期念出来**。" \
		+ "**同一件旧事别翻来覆去地提** —— 提过一次就够了，别每句都绕回它" \
		+ "（2026-09-27：记忆检索每轮都会捞出同一批，她就反复念同一件事）。" \
		+ "更要紧的：**这里写的都是过去的事，不代表他现在正在做什么** —— " \
		+ "要聊他现在在干嘛，只有「偷看屏幕」那一眼算数；没看过就别猜他在忙什么。" \
		+ "**这里没写的事不要编** —— 不确定就说“我不记得了”，别自己添细节。）"
	# 【你自己的心情】：短期记忆过期后**只留下情绪**（见 pet_memory.retrieve_mood / KIND_MOOD）。
	# 单独一栏、和【关于主人】分开 —— 那是她自己的感受，不是主人的事；
	# 混在一起她就会把它当"主人的事"讲出来（2026-09-29 那个"才理我"的 bug 就是这个形态）
	var moods: Array = mem.retrieve_mood(2)
	if not moods.is_empty():
		var ml: Array[String] = []
		for it in moods:
			ml.append("- " + String(it.text) + _date_tag(float(it.created)))
		block += "\n\n【你自己的心情】\n" + "\n".join(ml) \
			+ "\n（这是**你自己**的感受，不是主人的事。心里有数就行 —— " \
			+ "顶多顺口提一句，别翻来覆去地说，也别拿它当话题。）"
	return block

## 档案卡 → 给人看的几行
static func profile_lines(mem) -> Array[String]:
	var out: Array[String] = []
	for key in ["name", "age", "occupation", "location", "birthday"]:
		var v := String(mem._identity().get(key, ""))
		if v != "":
			out.append(mem._identity_line(key, v))
	for key in ["likes", "dislikes", "pets", "notes"]:
		for v in mem._pref_list(key):
			out.append(mem._pref_line(key, v))
	return out

## 工作记忆 → 给人看的几行
static func working_lines(mem) -> Array[String]:
	var out: Array[String] = []
	var s := String(mem.working.get("summary", "")).strip_edges()
	if s != "":
		out.append("最近大概：%s" % s)
	var t: Array = mem._working_list("open_topics")
	if not t.is_empty():
		out.append("还没聊完的话题：%s" % "、".join(t))
	var m := String(mem.working.get("mood", "")).strip_edges()
	if m != "" and m != "平静":
		out.append("主人最近的情绪：%s" % m)
	return out

static func profile_text(mem) -> String:
	return "\n".join(profile_lines(mem))

## "多久没聊了"那一句。刚聊过或没聊过都返回空串（不说废话）。
##
## 数字走 `pet_memory_forget.gap_phrase`（和遗忘曲线、年龄分档同一个时钟）——
## 以前这里自己算 gap、自己拼"小时前/天前"，而人设那边另有一套（来源还是会话计时 ✗），
## 同一段提示词里两个数会打架（2026-09-27 审出来的）
static func since_text(mem) -> String:
	if mem.last_chat <= 0:
		return ""
	var hours := MemForget.hours_since(float(mem.last_chat))
	if hours < 1.0:
		return ""
	if hours < 24.0:
		return "上次和主人说话是 %s前。" % MemForget.gap_phrase(hours)
	return "上次和主人说话是 %s前，好久没聊了。" % MemForget.gap_phrase(hours)

# ================================================================
# 提示词（照搬 giftia 的 _llm_extract_facts 和 WORKING_MEMORY_UPDATE_PROMPT）
# ================================================================

## 事实抽取的提示词。严格规则是重点 —— giftia 那一版专门写了"禁止推测""禁止把 AI 的建议
## 当成用户的事实"，因为抽错的记忆会一直留在档案里反复影响后面所有对话
const FACT_PROMPT := """你是一个记忆提取模块。从下面的对话里提取值得长期记住的信息。

对话：
用户：%s
AI（她）：%s

今天的日期：%s

严格规则：
0. 这条事实要留很久，所以下面两件事必须做到：
   ① **不要写"今天""昨天""前天""前几天"这类相对时间** —— 一律照上面的日期换算成
      具体某一天（写着"今天"过几天就会被读成"昨天"）；
   ② **也别写成"他现在正在做什么"的口气** —— 记的是**那会儿**的事：写
      "9 月 26 日主人在挑壁纸"，**不要**写"主人正在挑壁纸"
      （过几小时她自己会把后者当成"主人此刻在做的事"，然后主动搭话时说得驴唇不对马嘴）
1. 只能提取用户**明确说出**的事实，禁止任何推测或引申
2. 如果用户没有表达任何值得记住的信息，返回 []
3. 禁止把 AI 的建议当成用户的事（除非用户明确表示采纳）
4. 禁止提取用户"可能想做"的事，只提取明确说的
5. 寒暄、通用知识、与用户无关的内容一律不要

值得提取的：用户的情感状态、具体事件、人际关系、偏好（喜欢/讨厌什么）、担忧困扰。
**不要**提取"他此刻正在做什么"这种一时的事（"他在挑壁纸""他在看文档"）——
它第二天就过期，而她会一直照着它说，听上去像在说现在（见 OBSERVE_PROMPT 第 5 条）。
每条写成完整的陈述句，主语用"主人"，例如：["主人 9 月 26 日加班到很晚，很累"]。

只返回 JSON 数组，不要任何解释："""

## "她的观察/她主动聊的内容"里挑出值得记的。
## 和 FACT_PROMPT 的区别：那边是从**主人说的话**里抽事实；这边是从**她自己说的**里抽 ——
## 比如她偷看屏幕后说"你在忙活呀，挺赶的样子"，值得记住的其实是
## "主人当时在赶一个活儿"，而不是她这句感慨本身。
##
## 这一条就是"选择性"的关键：宁少勿滥，拿不准就返回 [] ——
## 主动搭话和偷看屏幕每天都产生好几条，全塞进记忆会把档案冲成流水账。
const OBSERVE_PROMPT := """你是一个记忆整理模块。下面是她（住在主人电脑桌面上的女孩）刚说的一句话，以及说这句话的情境。

情境：%s
她说：%s

今天的日期：%s

从里面挑出**值得长期记住的、关于主人**的信息（她在做什么、在意什么、最近什么状态）。

严格规则：
0. 这条要留很久（**她是隔一阵才会想起这些事的**），所以两件事必须做到：
   ① **不要写"今天""刚才""最近"这类相对时间** —— 照上面的日期换算成具体某一天；
   ② **别写成"他现在正在做什么"的口气** —— 写"9 月 27 日主人在挑壁纸"，
      **不要**写"主人正在挑壁纸"（2026-09-27 实测：那批"正在…"的事实让她
      主动搭话时说的是几小时前的事，和主人当时在干的完全不搭）
1. 只提取她确实看到或听到的，禁止推测和补全
2. 她自己的感慨、撒娇、口头禅、和她张罗的事，一律不要
3. 寒暄、玩笑、没有信息量的内容，返回 []
4. 每条写成完整的陈述句，主语用"主人"，例如：["主人 9 月 26 日在赶一个活儿，好像很赶"]
5. **别记"他此时此刻正在做什么"这种一时的事**（"主人在挑壁纸""他在看文档"）——
   它第二天就过期，而她会一直照着它说，听上去像在说现在（2026-09-27 实测过）。
6. ⚠️ **凡是只能靠"看屏幕"得知的内容，一律返回 []**（2026-10-03 用户报的 bug）：
   她看到屏幕上在打僵尸 / 在玩某个游戏 / 在看某个视频，那**未必是主人自己在做** ——
   可能是视频、直播、别人分享的画面。之前这里写成"主人在玩植物大战僵尸""进度到第 34 天"，
   存进档案后她下次就当成现实发生的事提起（档案里攒了一串"主人在玩 X"就是这么来的）✗。
   关卡进度、战绩、画面里的东西、正在放什么视频 —— 全部不要。
   真正留得住的只有**从主人嘴里说出来的**：他在意什么、最近什么状态、长期的习惯。

只返回 JSON 数组，不要任何解释："""

## 工作记忆更新的提示词（对应 giftia 的 WORKING_MEMORY_UPDATE_PROMPT）：
## 它维护的是"整体了解 + 还没聊完的话题 + 最近情绪"，跟逐条事实是两回事
const WORKING_PROMPT := """你是一个记忆更新模块。根据最近的对话更新"工作记忆"。

工作记忆是跨对话保存的，用来让她在不同对话之间都记得主人在意什么。

当前工作记忆：
%s

最近对话（今天是 %s）：
用户：%s
她：%s

规则：
1. 保留仍然有效的信息
2. 加入新出现的重要信息（用户明确说过的）
3. 删掉已经过时或互相矛盾的信息
4. summary 控制在 200 字以内，只留最重要的
5. open_topics 只留**还没聊完的话题**（最多 5 个）。判定标准是"以后还要接着说"，
   所以不要写：她自己的撒娇 / 感慨、一句问答（"现在几点了"这种）、已经聊完的结论
   （2026-09-27 排查时看到存档里 open_topics 全是"别生气了嘛""现在几点了"这种，就是这个原因）
6. 禁止编造或推测任何信息
7. summary 和 open_topics 里提到时间一律写具体日期，**不要写"今天/昨天/前几天"** ——
   这份工作记忆会跨很多天留着，写着"今天"后面几天就全读错了

只返回 JSON，不要任何解释：
{"summary": "更新后的整体了解", "open_topics": ["话题"], "current_emotion": "情绪标签"}"""

## 当前工作记忆的文本形式，喂给 WORKING_PROMPT
static func working_text(mem) -> String:
	var s := String(mem.working.get("summary", "")).strip_edges()
	var t: Array = mem._working_list("open_topics")
	if not t.is_empty():
		s += "\n待跟进：%s" % "、".join(t)
	if s.strip_edges() == "":
		return "（空，这是第一次对话）"
	return s

# ------------------------------------------------------------------ 入口：解析回来

## **安静地**解析 JSON。别用 JSON.parse_string()：文本不合法时它会往控制台打一条
## `Parse JSON failed` 的 ERROR —— 而这里"不合法"是**正常情况**（模型经常多写一句话、
## 或者干脆不吐 JSON，我们本来就设计了兜底）。那条红字会让人以为出 bug 了（自检时抓到过）。
## JSON.new().parse() 只返回错误码，什么都不打
static func parse_json_quiet(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data

## 从模型返回的文本里抠出 JSON 数组（模型经常裹一层 ```json）
static func parse_json_array(text: String) -> Array:
	var t := _strip_fence(text)
	var j: Variant = parse_json_quiet(t)
	return j if typeof(j) == TYPE_ARRAY else []

static func parse_json_object(text: String) -> Dictionary:
	var t := _strip_fence(text)
	var j: Variant = parse_json_quiet(t)
	return j if typeof(j) == TYPE_DICTIONARY else {}

static func _strip_fence(text: String) -> String:
	var t := text.strip_edges()
	if t.find("```json") >= 0:
		t = t.split("```json")[1].split("```")[0].strip_edges()
	elif t.find("```") >= 0:
		t = t.split("```")[1].split("```")[0].strip_edges()
	# 兜底：模型可能在 JSON 前后多写一句话
	var a := t.find("[")
	var b := t.rfind("]")
	if a >= 0 and b > a:
		var as_arr := t.substr(a, b - a + 1)
		if parse_json_quiet(as_arr) != null:
			return as_arr
	var c := t.find("{")
	var d := t.rfind("}")
	if c >= 0 and d > c:
		return t.substr(c, d - c + 1)
	return t
