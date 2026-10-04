# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 记忆的"管理与整理"模块 —— 负责把同一件事的**近义条目**合并成一条（去重）。
## 2026-09-30 用户要求：专门给记忆加一个"整理"模块，解决"同一件事被抽成 N 条近义"的问题
## （就是"壁纸 / boss 被反复强化"的那把刀：存档里"挑壁纸"被存了 4 条、"boss"存了 2 条）。
##
## 为什么 `pet_memory.add()` 自己不去重这个：它的去重是**原文完全一致**才算重复
## （"主人挑壁纸，挑得很认真"和"主人在挑洁尔佩塔相关的壁纸"文本不同，就各存一条）。
## 近义去重要"抽掉脚手架、比内容核心"，那是另一层规则，单独放这儿才不会把 add 越写越肿。
##
## 判据（没有 embeddings / 分词器，只能用便宜启发式，够用、且阈值是常量可调）：
##   1. 把句子"抽成内容核心"：去标点 → 去日期（2026年9月27日 / 9月）→ 去停用词（主人/我/喜欢/很/相关…）
##   2. 两条的核心：相等 / 一条包含另一条 / 最长公共子串占较短核心 ≥ DEDUP_THRESHOLD → 算同一条
##
## 合并语义（**只并、不丢信息方向**）：复习次数累加、时间戳刷新、保留**更长**那句当代表。
##
## ⚠️ 这是启发式，不是语义等价：极端情况下两条"有点像"的会被并成一条（比如"加班到十点"和
## "下班到十点"）。代价是少一条细节，收益是"同一件事不再 4 连"。阈值调高 = 更保守。
##
## 接口面：
##   merge_into(mem, text, importance_boost, kind) -> "added" / "merged" / "skipped"
##   consolidate(mem) -> 合并掉的条数（**只改内存，不 save**，调用方自己落盘）
## 两个方法都**不主动 save**（和 pet_memory.add() 的约定一致：谁调谁存）

extends RefCounted

const OUT_ADDED := "added"
const OUT_MERGED := "merged"
const OUT_SKIPPED := "skipped"

## 近义判定阈值：共享内容占较短核心的比例 ≥ 这个数就算"同一件事"
const DEDUP_THRESHOLD := 0.5

## 停用词（句子的脚手架，去掉它们剩下的才是"内容核心"）。**顺序有讲究**：长的排前面
const STOPWORDS: Array[String] = [
	"主人", "我们", "咱们", "我", "她", "你", "他",
	"非常", "特别", "喜欢", "讨厌", "爱吃", "爱喝", "爱玩", "相关", "认真",
	"长时间", "已经", "因为", "所以", "结果", "居然", "然后", "当时", "现在",
	"之前", "以后", "最近", "今天", "昨天", "前天", "上周", "今年",
	"一个", "一次", "一直", "有点", "好像",
	"的", "了", "在", "是", "有", "很", "最", "挺", "太", "更", "都", "就",
	"和", "跟", "还", "又", "也", "而",
	"得", "着", "过", "被", "把", "给", "啊", "哦", "呀", "嘛", "呢", "吧", "啦",
	"这", "那", "个", "次", "件", "款", "场", "位", "只",
]
## 标点（和 pet_memory 的 PUNCT 同一张表，抽核心前先清掉）
const PUNCT := " ，。！？、,.!?;:：；\n\r\t　“”‘’()（）<>《》[]【】-—…~～·\"'|"

## 抽掉日期那几块（2026年9月27日 / 9月27日 / 9月 / 2026年）—— 日期是"哪天"，不是"什么事"
const DATE_PATS: Array[String] = [
	"\\d{4}年\\d{1,2}月\\d{1,2}日?", "\\d{1,2}月\\d{1,2}日?", "\\d{1,2}月", "\\d{4}年",
]


## 写入端入口：先查有没有近义旧条，有就"复习 + 合并"，没有才新增。
## 返回 OUT_ADDED / OUT_MERGED / OUT_SKIPPED（文本为空 = skipped）
static func merge_into(mem, text: String, importance_boost: float = 0.0,
		kind: String = "fact") -> String:
	var t := text.strip_edges()
	if t == "":
		return OUT_SKIPPED
	var core := content_core(t)
	if core.length() < 2:
		# 内容核心太短（几乎全是脚手架）—— 判不出近义，按老规矩直接 add
		mem.add(t, importance_boost, kind)
		return OUT_ADDED
	var best = null
	var best_score := 0.0
	for it in mem.items:
		if String(it.kind) != kind:
			continue
		if mem._squash(String(it.text)) == mem._squash(t):
			# 原文就一样：交给 add 去"复习"，也算并掉了，不算新增
			mem.add(t, importance_boost, kind)
			return OUT_MERGED
		if _date_conflict(t, String(it.text)):
			continue        # 都带日期且日期不同 = 不同事件，不并
		var s := similarity(core, content_core(String(it.text)))
		if s > best_score:
			best_score = s
			best = it
	if best != null and best_score >= DEDUP_THRESHOLD:
		# 近义 → 复习旧条（access_count 累加、时间戳刷新），不新增；
		# 文本保留更长那句（信息量更大的当代表）
		best.access_count = int(best.access_count) + 1
		best.last_access = Time.get_unix_time_from_system()
		best.consolidated = true
		if importance_boost > 0.0:
			best.importance = clampf(float(best.importance) + importance_boost, 0.0, 1.0)
			best.layer = mem.layer_of(float(best.importance), float(best.intensity))
		if t.length() > String(best.text).length():
			best.text = t
		return OUT_MERGED
	mem.add(t, importance_boost, kind)
	return OUT_ADDED


## 一次性整理：把**已有**的近义 fact 合并（只并 fact，self_line / mood 不动）。
## 返回合并掉的条数。**只改内存里的 items，不 save** —— 调用方先备份、再自己 save
static func consolidate(mem) -> int:
	var merged := 0
	var kept: Array = []
	for it in mem.items:
		if String(it.kind) != "fact":
			kept.append(it)
			continue
		var core := content_core(String(it.text))
		var target = null
		if core.length() >= 2:
			for k in kept:
				if String(k.kind) != "fact":
					continue
				if _date_conflict(String(it.text), String(k.text)):
					continue       # 不同日期 = 不同事件
				if similarity(core, content_core(String(k.text))) >= DEDUP_THRESHOLD:
					target = k
					break
		if target != null:
			# 并入 target：复习次数累加，保留更长那句当代表
			target.access_count = int(target.access_count) + int(it.access_count)
			if String(it.text).length() > String(target.text).length():
				target.text = String(it.text)
			merged += 1
		else:
			kept.append(it)
	mem.items = kept
	return merged


# ------------------------------------------------------------------ 纯函数（探针直接验）

## 抽"内容核心"：去标点 → 去日期 → 去停用词，剩下的就是"这件事本身"
static func content_core(text: String) -> String:
	var t := _clean(text)
	for pat in DATE_PATS:
		var re := RegEx.new()
		if re.compile(pat) == OK:
			t = re.sub(t, "", true)
	for w in STOPWORDS:
		t = t.replace(w, "")
	return t

## 两条内容核心的相似度（0~1）。
## 相等 / 互相包含 = 1；否则 = 最长公共子串长 ÷ 较短那串的长（子串 < 2 字记 0）
static func similarity(a: String, b: String) -> float:
	if a == "" or b == "":
		return 0.0
	if a == b or a.find(b) >= 0 or b.find(a) >= 0:
		return 1.0
	var lcs := _longest_common_substring(a, b)
	if lcs.length() < 2:
		return 0.0
	return float(lcs.length()) / float(mini(a.length(), b.length()))

## 抽句子里的日期串（"2026年9月27日"/"9月22日"/"9月"/"2026年"），没有返回 ""
static func _date_of(text: String) -> String:
	var re := RegEx.new()
	if re.compile("\\d{4}年\\d{1,2}月\\d{1,2}日?|\\d{1,2}月\\d{1,2}日?|\\d{1,2}月|\\d{4}年") == OK:
		var m := re.search(text)
		if m != null:
			return m.get_string()
	return ""

## 两条都带日期、且日期不同 → 是**不同的事件**（比如"9/22 加班" vs "9/27 加班"），不能并
static func _date_conflict(a: String, b: String) -> bool:
	var da := _date_of(a)
	var db := _date_of(b)
	return da != "" and db != "" and da != db

static func _clean(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if PUNCT.find(ch) >= 0:
			continue
		out += ch
	return out

static func _longest_common_substring(a: String, b: String) -> String:
	var best := ""
	for i in a.length():
		for j in b.length():
			var k := 0
			while i + k < a.length() and j + k < b.length() and a[i + k] == b[j + k]:
				k += 1
			if k > best.length():
				best = a.substr(i, k)
	return best
