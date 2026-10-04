# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 记忆的**分层与遗忘**：一条记忆属于哪一层、忘得多快、什么时候清掉、什么时候巩固。
##
## 从 pet_memory.gd 搬出来（作业单 B4.2）。为什么值得独立：这是唯一一套"数学"——
## 分层阈值、遗忘强度、艾宾浩斯曲线、清理/巩固的判据都在这里；
## 而它**不碰存盘、不碰提示词**，只按字段算，所以能逐条离线验（tools/probe_memory.gd
## 里"分层 / 遗忘曲线 / 清理"那几组就是）。
##
## 全是 **static**：算单个记忆的那几支是纯函数；扫全部记忆的那几支（decay / prune /
## consolidate / stats）把记忆对象当参数传进来 —— 这样"忘"这件事不需要有实例就能验。
##
## 参数 `mem` **故意不标类型**：它属于 pet_memory.gd，标上就成循环 preload
## （规矩见 CONVENTIONS.md 的"禁止循环 preload"）。本模块只读/写它的 `items` 和 `profile`。
##
## 接口面：读 `mem.items` / `mem.profile`，写 `mem.items`（prune 会整组替换）。
## 不碰文件、不碰网络、不发信号
extends RefCounted

## 记忆分层（对应 giftia 的 memory_layer.py）。
## **这是层号的真源** —— pet_memory.gd 的 `PetMemory.Layer` 由这里派生（探针要那个写法）
enum Layer { CORE = 1, IMPORTANT = 2, REGULAR = 3 }

## 按重要性和情感强度自动分层。阈值照搬 giftia：情感强烈的更容易进核心层 ——
## "吵架/表白/崩溃"这种话只说过一次也值得记住
static func layer_of(importance: float, intensity: float) -> int:
	if importance >= 0.8 or intensity >= 0.8:
		return Layer.CORE
	if importance >= 0.6 or intensity >= 0.7:
		return Layer.IMPORTANT
	return Layer.REGULAR

## 遗忘强度系数：核心层忘了 10 倍慢
static func forgetting_strength(layer: int) -> float:
	match layer:
		Layer.CORE: return 10.0
		Layer.IMPORTANT: return 2.0
		_: return 1.0

## 检索时的权重：核心层的事优先被想起来
static func retrieval_weight(layer: int) -> float:
	match layer:
		Layer.CORE: return 1.0
		Layer.IMPORTANT: return 0.8
		_: return 0.5

## 「从某个时刻到现在过了多少小时」—— **全仓只此一处算这个**。
##
## 为什么值得单抽一支：同一个量有三个消费者，口径必须一致 ——
##   ① 遗忘曲线（下面的 retention）
##   ② 检索重排里的时间分（pet_memory.gd 的 time_score）
##   ③ 给模型看的"那大概是多久以前"（下面的 rough_age）
## 2026-09-27 的教训：显示那一侧自己写了一套日期逻辑，结果**同一天记的事**
## 被读成"他现在正在做"，而她照着说 —— 用户当场发现。
static func hours_since(ts: float) -> float:
	return (Time.get_unix_time_from_system() - ts) / 3600.0

## 当前保留率 0~1。t 取"上次被想起来到现在"的小时数 ——
## 所以每次检索命中都会刷新 last_access，等于复习一次，忘得更慢（间隔重复）
static func retention(created: float, last_access: float, importance: float,
		access_count: int) -> float:
	var elapsed_hours := hours_since(last_access if last_access > 0.0 else created)
	var strength := 0.3 + importance * 0.5 + minf(access_count * 0.15, 1.0)
	return clampf(exp(-elapsed_hours / (strength * 24.0 + 1.0)), 0.0, 1.0)

## 「那大概是多久以前的事」—— 给模型看的**粗粒度**说法。用户 2026-09-27 要求：
## "加入大概时间，并且融合原装的记忆打分系统"。
##
## 两条口径上的讲究：
##   1. 算的是**事情发生**到现在（`created`），不是"上次被想起来"到现在（那是 retention 的 t）——
##      两件事别混：一件旧事今天刚被想起，它仍然是一件旧事；
##   2. 用的时钟和打分那边**是同一个**（都走 hours_since），只是分档更粗 ——
##      这样"她读到的年龄"和"打分认为的新鲜度"不会互相矛盾。
##
## 近两天刻意**不写日期**：今天是 27 号时，"9月27日主人在挑壁纸"读起来就是"他今天正在挑壁纸" ✗。
## 更久才给具体月日（旧事写日期是上一轮用户明确要过的：换个说法也认得出）。
static func rough_age(created: float) -> String:
	if created <= 0.0:
		return ""
	var h := hours_since(created)
	if h < 1.0:
		return "刚刚"                    # 一小时内的事不用标（她本来就知道是刚说的）
	var d := _day_gap(created)
	match d:
		0: return "今天早些时候"
		1: return "昨天"
		2: return "前天"
	if d <= 6:
		return "前几天"
	if d <= 13:
		return "上周"
	if d <= 29:
		return "前阵子"
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var dt := Time.get_datetime_dict_from_unix_time(int(created) + bias)
	return "%d月%d日" % [int(dt["month"]), int(dt["day"])]

## 「多久没说话」的数字说法（"3 分钟" / "5 小时" / "2 天"）。
##
## 为什么放在这儿、而不是各写各的：**它以前被写了两套** ✗ ——
## 记忆那边有 `since_text()`（"上次和主人说话是 %d 小时前"），人设那边有 `_gap_text()`
## （"距上次说话 %d 小时"），而且两个数的**来源还不一样**（`memory.last_chat` 持久 ✓
## vs 宿主的 `_last_talk_ms` 只在本次运行里数 ✗）⇒ 同一段提示词里能同时出现
## "上次和主人说话是 2 小时前" 和 "距上次说话 5 小时"（2026-09-27 审出来的）。
## 现在：数字在**这里**统一（和 hours_since 同一个时钟），句子框架各自保留（本来就不同）。
static func gap_phrase(hours: float) -> String:
	if hours < 0.0:
		return ""
	if hours < 1.0:
		return "%d 分钟" % maxi(1, int(round(hours * 60.0)))
	if hours < 24.0:
		return "%d 小时" % int(round(hours))
	return "%d 天" % int(round(hours / 24.0))

## 差了几个**当地日历天**（按 UTC+时区 的日序号相减，省掉夏令时那些麻烦）
static func _day_gap(created: float) -> int:
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var now := int(Time.get_unix_time_from_system())
	return (now + bias) / 86400 - (int(created) + bias) / 86400

## 单条记忆的保留率。
## 内部类（`Item`）看不到外层作用域，算不了这个 —— 所以必须由外层拿字段代算，
## 这条注释以前挂在 Item 上，现在挂在这儿（谁用谁看）
static func retention_of(mem, it) -> float:
	return retention(it.created, it.last_access, it.importance, it.access_count)

## 所有记忆衰减一次。核心层靠 layer_of 保住，常规层会掉下去等着被清
static func decay(mem) -> void:
	for it in mem.items:
		var r := retention_of(mem, it)
		it.importance = clampf(it.importance * r * 0.8 + 0.1, 0.0, 1.0)
		it.layer = layer_of(it.importance, it.intensity)

## 清理：保留率低 + 层级低 + 没被想起来过的记忆，丢掉。
## 核心层和近期的常规记忆一律不动
static func prune(mem) -> int:
	var kept: Array = []
	var dropped := 0
	for it in mem.items:
		var can_drop: bool = it.layer == Layer.REGULAR and it.access_count <= 1 and not it.consolidated
		if can_drop and retention_of(mem, it) < 0.1:
			dropped += 1
			continue
		kept.append(it)
	if dropped > 0:
		mem.items = kept
	return dropped

## 巩固：保留率掉到 0.3 以下但 importance 还高的，标记成"已巩固"（不再参与清理）
static func consolidate(mem) -> int:
	var n := 0
	for it in mem.items:
		if it.consolidated:
			continue
		if retention_of(mem, it) < 0.3 and it.importance >= 0.6:
			it.consolidated = true
			n += 1
	return n

static func stats(mem) -> Dictionary:
	var by_layer := {Layer.CORE: 0, Layer.IMPORTANT: 0, Layer.REGULAR: 0}
	for it in mem.items:
		by_layer[it.layer] = int(by_layer.get(it.layer, 0)) + 1
	return {"total": mem.items.size(), "core": by_layer[Layer.CORE],
		"important": by_layer[Layer.IMPORTANT], "regular": by_layer[Layer.REGULAR],
		"profile": mem.profile.size()}
