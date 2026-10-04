# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 短期记忆 —— "她主动说的话，主人没接" 那一类（2026-09-29 用户要求，第②条）。
##
## 为什么必须和长期记忆分家：
##   长期记忆是**跨天**的东西（"主人养了一只猫"），主动对话是**当下**的东西
##   （"你屏幕上那是啥呀"）。两者混在一个池子里就会出事 —— 她会拿自己以前说过的话
##   当"主人的事"反复念（2026-09-29 报的"没有不理他，他说才理我"就是这个形态）。
##   所以从这条起：**被接住了** → 照旧走长期记忆那条（pet_memory_flow）；
##   **没人接** → 进这里当短期，过期就地忘掉。
##
## 规矩（用户原话的落地）：
##   1. 她主动开口、主人**回复了或点了候选按钮** → 不算短期，正常走记忆模块；
##   2. 没人接 → 挂进这里；**一半概率**下一次她主动开口时**再提一次**；
##      另一半概率**直接忘掉**；
##   3. 提了还是没人接 → 忘掉；
##   4. 忘掉时**只留情绪化内容** —— 写一条 kind=mood 的长期记忆：
##      她记得"那天有点失落"，但记不住当时具体说了什么，也不会拿它当话题重念一遍。
##
## 只活在内存里：短期本来就是"当下"的东西，重启就该过去（该留的情绪已经落进长期记忆了）。
##
## 验证：tools/probe_memory.gd 里那几条 —— 每个方法都能**指定 roll**（= 那一次的骰子），
## 所以 50/50 这两条路都能离线跑出来，不用碰真随机

extends RefCounted

const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")

## 最多同时挂几条。她一口气说好几轮都没人理时别无限攒
const MAX_PENDING := 3
## "再提一次"的概率（用户定的一半）
const RETRY_CHANCE := 0.5
## 再提一次时塞进提示词的那段。%s = 她上回说的那句
const PROMPT_RETRY := "（你上回想跟主人说一件事，当时他没接话 —— 你当时说的是：%s\n" \
	+ "现在你正好想开口：可以自然地再提一次，也可以换个说法。**别提“上次说过”这种**，" \
	+ "也别抱怨他没理你，就当刚想起来。）"

## 每条：{text, origin, created, mood, intensity, retried}
var entries: Array = []

var _host: Node = null

func setup(host: Node) -> void:
	_host = host
	entries.clear()

## 她说完一句、且这轮是**她自己开的口**：先挂着，等主人接
## （origin 只用来记来源；mood/intensity 来自 analyze_mood，忘掉时只留它们）
func hold(text: String, origin: String, mood: int, intensity: float) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	entries.append({
		"text": t, "origin": origin, "created": int(Time.get_unix_time_from_system()),
		"mood": mood, "intensity": intensity, "retried": false,
	})
	while entries.size() > MAX_PENDING:
		entries.pop_front()

## 主人接住了（打字聊天 / 点了候选按钮 / 摸她 / 喂她 / 点「哄哄她」都算 ——
## 这些地方都会走宿主的 _soothe）：短期里那些不必再提，直接清掉
func answered() -> void:
	entries.clear()

## 她又要主动开口了：**一半概率**把上一回没接住的话再提一次。
## 返回要塞进提示词的那段（不用重提就返回 ""）。每条**只重提一次**（试过还不行就等忘）
func retry_prompt(roll: float = -1.0) -> String:
	if entries.is_empty():
		return ""
	if roll < 0.0:
		roll = _randf()
	if roll >= RETRY_CHANCE:
		return ""
	for e in entries:
		if not bool(e["retried"]):
			e["retried"] = true
			return PROMPT_RETRY % String(e["text"])
	return ""

## 主人还是没反应（生闷气那条等超时了）：按规矩处理这批。
## 返回忘掉了几条。记忆对象传 null（没开记忆）时只清内存，不写档
func settle_ignored(memory, roll: float = -1.0) -> int:
	var forgotten := 0
	var kept: Array = []
	for e in entries:
		var drop := bool(e["retried"])     # 提过一次还是没人理 → 忘
		if not drop:
			var r := roll
			if r < 0.0:
				r = _randf()
			drop = r >= RETRY_CHANCE       # 一半概率当场忘
		if drop:
			_forget(e, memory)
			forgotten += 1
		else:
			kept.append(e)
	entries = kept
	return forgotten

## 忘掉一条：**只留情绪**。文字里不带她当时说了什么（那是内容，内容该过去），
## 只带"哪天 + 当时心情"—— 见 pet_memory.KIND_MOOD 和【你自己的心情】那一栏
func _forget(e: Dictionary, memory) -> void:
	if memory == null:
		return
	var mood := int(e["mood"])
	var dt := Time.get_datetime_dict_from_system()
	var when := "%d月%d日" % [int(dt["month"]), int(dt["day"])]
	var line := "她 %s 主动找主人说话，没等到回应（当时心情：%s）" % [
		when, PetMemory.mood_name(mood)]
	if mood == PetMemory.Mood.NEUTRAL:
		line = "她 %s 主动找主人说话，没等到回应" % when
	memory.add(line, 0.0, PetMemory.KIND_MOOD)
	memory.save()

func _randf() -> float:
	if _host != null:
		return float(_host._rng.randf())
	return randf()

# ------------------------------------------------------------------ 给探针/调试看

func size() -> int:
	return entries.size()

func pending_text() -> String:
	return "" if entries.is_empty() else String(entries[0]["text"])
