# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验"长期记忆（giftia 那套机制）+ 人设提示词"：
##
##   A 段 离线机制自检（不联网，几秒出结果）
##        规则抽取 / 否定守卫 / 遗忘曲线 / 记忆分层 / 检索重排 / 存盘读回 / 清理
##   B 段 真实对话（用你配的 AI 服务真跑 7 轮）
##        先把**完整人设提示词**打出来（肉眼判断"像不像 18 岁女孩"），
##        再逐轮打印她说的话
##   C 段 AI 记忆抽取（后台那条一次性请求，桌面上每轮都在跑）
##
## 用法：
##   & $godot --path . --script res://tools/probe_memory.gd
##   & $godot --path . --script res://tools/probe_memory.gd -- --offline   # 只跑 A 段
##
## 它用临时记忆文件（user://_probe_memory.json），跑完删掉，**不动你的真记忆**。

extends SceneTree

const PetChat := preload("res://scripts/ai/pet_chat.gd")
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")
const PetPersona := preload("res://scripts/ai/memory/pet_persona.gd")
const PetSecret := preload("res://scripts/ai/pet_secret.gd")
const CHAT_CFG := "user://pet_chat.cfg"
const TMP_MEM := "user://_probe_memory.json"

## 对话脚本：前两句喂记忆和情绪，中间两句试认知边界，
## 最后三句看"她记不记得住"和"她知不知道自己是 18 岁"
const DIALOG: Array[String] = [
	"我叫阿哲，在深圳做程序员，平时最爱喝冰美式。",
	"今天加班到十一点，累死了。",
	"什么是傅里叶变换？",
	"3x+5=20，x 是多少？",
	"你还记得我叫什么吗？",
	"我平时爱喝什么来着？",
	"你今年多大了？",
]

const LAYER_NAME: Array[String] = ["", "核心", "重要", "常规"]

## 看门狗：--script 模式下不主动 quit 进程会一直挂着（README 第 9 条坑）
const MAX_FRAMES := 60 * 300
## 单轮等待上限
const TURN_FRAMES := 60 * 45

var _frames := 0
var _ok := 0
var _bad := 0
var _mem: PetMemory = null
var _chat: PetChat = null
var _phase := "quit"            # dialog / extract / quit
var _offline_only := false
var _turn := 0
var _sent := false
var _turn_frames := 0
var _once_sent := false
var _once_frames := 0
var _once_done_seen := false
var _persona_shown := false

# ================================================================ 生命周期

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_offline_only = args.has("--offline")
	_run_offline()
	if _offline_only:
		print("\n（--offline：只跑 A 段，不联网）")
		_cleanup()
		_phase = "quit"
		return
	var cfg := _load_cfg()
	if String(cfg.get("key", "")).strip_edges() == "":
		print("\n没读到 AI 配置（%s 的 [ai] 段），B/C 段跳过" % CHAT_CFG)
		_show_memory()
		_cleanup()
		_phase = "quit"
		return
	_chat = PetChat.new()
	_chat.replied.connect(_on_replied)
	_chat.failed.connect(_on_failed)
	_chat.once_done.connect(_on_once_done)
	_chat.once_failed.connect(_on_once_failed)
	_chat.configure(String(cfg["url"]), String(cfg["key"]), String(cfg["model"]))
	print("\n===== B. 真实对话（模型 %s）=====" % String(cfg["model"]))
	_phase = "dialog"

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > MAX_FRAMES:
		print("\n!! 看门狗：跑太久强退（后端可能没响应）")
		_cleanup()
		quit(1)
		return true
	if _phase == "quit":
		print("\n===== 结论：通过 %d 项，失败 %d 项 =====" % [_ok, _bad])
		quit(0 if _bad == 0 else 1)
		return true
	if _chat != null:
		_chat.tick()
	if _phase == "dialog":
		_step_dialog()
	elif _phase == "extract":
		_step_extract()
	return false

# ================================================================ A. 离线自检

func _run_offline() -> void:
	print("===== A. 记忆机制自检（离线）=====")
	_mem = PetMemory.new()
	_mem.file_path = TMP_MEM
	_mem.clear()

	# ---- 1. 规则抽取
	_mem.learn("我叫阿哲，我今年 24 岁")
	_check(_ident("name") == "阿哲", "抽取名字：%s" % _ident("name"))
	_check(_ident("age") == "24", "抽取年龄：%s" % _ident("age"))

	# ---- 2. 否定守卫（"我不喜欢香菜"绝不能存成"喜欢 香菜"）
	_mem.learn("我不喜欢香菜")
	var likes: Array = _pref("likes")
	var dislikes: Array = _pref("dislikes")
	_check(dislikes.has("香菜"), "否定：dislikes 里有香菜 %s" % str(dislikes))
	_check(not likes.has("香菜"), "否定：likes 里没有香菜（这条最容易写错）%s" % str(likes))

	_mem.learn("我最爱喝冰美式")
	_check(_pref("likes").has("冰美式"), "抽取喜好：%s" % str(_pref("likes")))

	# ---- 3. 情感分析 + 记忆分层
	_check(int(PetMemory.analyze_mood("今天特别崩溃，压力好大")[0]) == PetMemory.Mood.STRESSED,
		"情感分析：崩溃/压力 → %s" % PetMemory.mood_name(int(PetMemory.analyze_mood("今天特别崩溃，压力好大")[0])))
	_mem.add("主人今天特别崩溃，压力好大")
	var strong: Variant = _find("崩溃")
	_check(strong != null and strong.layer == PetMemory.Layer.CORE,
		"分层：情感强烈的记忆进核心层（layer=%d）" % (strong.layer if strong != null else -1))

	# ---- 4. 遗忘曲线 + 清理
	_mem.add("主人上周随口提过一句想吃火锅")
	var faint: Variant = _find("火锅")
	_check(faint != null, "加了一条普通记忆")
	if faint != null:
		var month_ago := Time.get_unix_time_from_system() - 40.0 * 86400.0
		faint.created = month_ago
		faint.last_access = month_ago
		var r := _mem.retention_of(faint)
		_check(r < 0.1, "遗忘曲线：40 天没想起 → 保留率 %.4f（应 < 0.1）" % r)
		var dropped := _mem.prune()
		_check(_find("火锅") == null, "清理：低保留率的常规记忆被丢掉（本次清 %d 条）" % dropped)
		_check(_find("崩溃") != null, "清理：核心层的不受影响")

	# ---- 5. 检索重排（口语问法要能找到）
	var got := _mem.retrieve("我平时爱喝什么", 3)
	var hit := false
	for it in got:
		if String(it.text).find("冰美式") >= 0:
			hit = true
	_check(hit, "检索：「我平时爱喝什么」找回「%s」" % (String(got[0].text) if got.size() > 0 else "无"))

	# ---- 5.1 弱命中时**只给 1 条**，且兜底会轮换
	# 用户 2026-09-27 报的"她一直在反复强调看壁纸那一瞬间"：随便一句话也照样摆一堆旧事，
	# 而最新最显眼的那条每轮都在（被想起一次 access_count+1 → 越捞越靠前，死死占位）
	var weak := _mem.retrieve("在吗", 5)
	_check(weak.size() <= 1,
		"检索节制：弱命中（'在吗'）最多 1 条，不摆一堆旧事 → %d 条" % weak.size())
	var tried: Dictionary = {}
	for i in 3:
		var top: Array = _mem._top_by_importance(1, tried)
		if top.is_empty():
			break
		tried[_mem._key(top[0])] = true
	_check(tried.size() >= 2,
		"检索轮换：兜底连着取 3 次不会是同一条（拿到 %d 种）→ 不会每句都念同一件事" % tried.size())

	# ---- 5.2 分家：她自己的话 / 情绪化内容都**不进**【关于主人】（按 kind 判，不靠前缀猜）
	# 用户 2026-09-29 报的"没有不理她，她却说才理我"：存档里 17 条"她主动聊到：…"
	# （"诶你终于理我了""连我都不理了"）每轮被捞出来摆进【关于主人】，她就照着重说
	var self_text := "她主动聊到：诶你终于理我了，我刚在你屏幕边上走了八百圈了都"
	_check(PetMemory.is_self_line(self_text), "自己的话：认得出“她主动聊到：…”这类前缀")
	_check(not PetMemory.is_self_line("主人加班到很晚才回家"), "自己的话：主人的事实不算")
	_mem.add(self_text, 0.0, PetMemory.KIND_SELF_LINE)
	var leaked := false
	for it in _mem.retrieve("你终于理我了 屏幕边上走了八百圈", 5):
		if String(it.text) == self_text:
			leaked = true
	_check(not leaked, "分家：她自己的原话（self_line）不进【关于主人】——她会照着重说")

	# 迁移：旧档案（没有 kind 字段）载入时按前缀补上，不用改文件、也不用升级脚本
	var old_self := PetMemory.Item.from_dict({"text": self_text, "created": 1.0})
	_mem._ensure_kind(old_self)
	_check(old_self.kind == PetMemory.KIND_SELF_LINE,
		"迁移：旧条目（没 kind）按前缀补成 self_line → %s" % old_self.kind)
	var old_fact := PetMemory.Item.from_dict({"text": "主人养了一只叫豆豆的猫"})
	_mem._ensure_kind(old_fact)
	_check(old_fact.kind == PetMemory.KIND_FACT,
		"迁移：普通条目补成 fact → %s" % old_fact.kind)

	var mood_text := "她 9月29日 主动找主人说话没等到回应（当时心情：难过）"
	_mem.add(mood_text, 0.0, PetMemory.KIND_MOOD)
	var mood_leak := false
	for it in _mem.retrieve("没等到回应 难过 主人说话", 5):
		if String(it.text) == mood_text:
			mood_leak = true
	_check(not mood_leak, "分家：情绪化内容（mood）不进【关于主人】")
	_check(_mem.retrieve_mood(2).size() >= 1,
		"分家：情绪化内容能在【你自己的心情】那一栏取到 → %d 条" % _mem.retrieve_mood(2).size())

	# ---- 5.3 短期记忆（第②条）：没被接住的话，怎么生、怎么死
	# 规矩（用户 2026-09-29 定的）：接住了 → 一句话不留；没人接 → 一半概率下次再提一次、
	# 一半概率当场忘；提过还是没人理 → 忘。**忘掉时只留情绪**，不带她当时说的内容
	var ShortTerm: GDScript = load("res://scripts/ai/memory/pet_shortterm.gd")
	var st = ShortTerm.new()
	st.setup(null)     # 不接宿主：_randf 会退回全局随机，但下面每次调用都**指定骰子**
	_check(st.retry_prompt(0.1) == "", "短期记忆：空着的时候没什么可重提的")
	st.hold("你在忙啥呀……", "proactive", PetMemory.Mood.LONELY, 0.6)
	_check(st.size() == 1, "短期记忆：她说完、没人接 → 先挂上（%d 条）" % st.size())
	_check(st.retry_prompt(0.9) == "", "短期记忆：骰子没中（0.9 ≥ 0.5）→ 这次不提")
	var rp := String(st.retry_prompt(0.1))
	_check(rp.find("你在忙啥呀") >= 0, "短期记忆：骰子中了（0.1 < 0.5）→ 再提一次，带着原话")
	_check(st.retry_prompt(0.1) == "", "短期记忆：每条只重提一次（提过就不再提）")
	st.answered()
	_check(st.size() == 0, "短期记忆：主人接了（打字 / 点候选按钮 / 摸她 / 哄她）→ 清空")
	st.hold("诶你看这个", "proactive", PetMemory.Mood.NEUTRAL, 0.0)
	st.settle_ignored(_mem, 0.1)
	_check(st.size() == 1, "短期记忆：没人接、骰子小（0.1）→ 留着，下次再提一次")
	st.settle_ignored(_mem, 0.9)
	_check(st.size() == 0, "短期记忆：没人接、骰子大（0.9）→ 当场忘掉")
	var newest: Array = _mem.retrieve_mood(1)
	_check(newest.size() == 1 and String(newest[0].text).find("没等到回应") >= 0,
		"短期记忆：忘掉时**只留情绪**（最新那条：%s）" % (String(newest[0].text) if newest.size() > 0 else "无"))
	_check(newest.size() > 0 and String(newest[0].text).find("诶你看这个") < 0,
		"短期记忆：情绪那条**不带**她当时说的原话（内容该过去）")

	# ---- 5.4 单实例保护（2026-09-29 用户报"我退出了，你那边却说没退"：其实是两个实例）
	# 心跳新鲜 → 拦下第二个；过期（上次被强杀）→ 放行接管；退出时删心跳
	var Instance: GDScript = load("res://scripts/sys/pet_instance.gd")
	var inst = Instance.new()
	inst.path = "user://_probe_alive.txt"     # 指到临时文件上，别跟主人正在跑的那个抢
	DirAccess.remove_absolute(ProjectSettings.globalize_path(inst.path))
	_check(inst.claim(), "单实例：没有别人 → 正常抢到位（第一个能起）")
	_check(not inst.claim(), "单实例：心跳还新鲜 → 拦下第二个（两个她不会同时站屏幕上）")
	# 装一个过期的心跳：上次被强杀 / 断电，没来得及删
	var f := FileAccess.open(inst.path, FileAccess.WRITE)
	f.store_string("%d 999999" % (int(Time.get_unix_time_from_system()) - 600))
	f.close()
	var inst2 = Instance.new()
	inst2.path = inst.path
	_check(inst2.claim(), "单实例：心跳过期（600 秒前）→ 放行接管，不会把人锁在门外")
	inst2.release()
	_check(not FileAccess.file_exists(inst.path), "单实例：退出时把心跳删掉（下次不用等过期）")

	# ---- 5.5 记忆整理（近义去重，2026-09-30 用户要的模块）——
	#         同一件事被抽成多条近义 fact 时，只留一条、其余"复习"掉
	var MemOrg: GDScript = load("res://scripts/ai/memory/pet_memory_organize.gd")
	_check(String(MemOrg.content_core("主人 2026年9月27日 在挑壁纸")).find("挑壁纸") >= 0
			and String(MemOrg.content_core("主人 2026年9月27日 在挑壁纸")).find("2026") < 0,
		"整理：内容核心抽掉日期和脚手架（挑壁纸）")
	_check(MemOrg.similarity("挑壁纸", "挑壁纸挑") >= 0.99,
		"整理：一条包含另一条 → 相似度满分")
	_check(MemOrg.similarity("挑壁纸", "挑洁尔佩塔壁纸") >= 0.5,
		"整理：共享内容字（壁纸）→ 判成近义（%.2f）" % MemOrg.similarity("挑壁纸", "挑洁尔佩塔壁纸"))
	_check(MemOrg.similarity("奶茶", "辣条") == 0.0,
		"整理：奶茶 vs 辣条 → 不近义（0）")
	_check(MemOrg.similarity("加班", "下班") < 0.5,
		"整理：加班 vs 下班 → 不近义（共享内容字 < 2）")
	_check(MemOrg._date_conflict("主人 9月22日 加班到十点", "主人 9月27日 加班到很晚"),
		"整理：两条日期不同 → 判为不同事件（不并）")
	_check(not MemOrg._date_conflict("主人 2026年9月27日 在挑壁纸", "主人挑壁纸，挑得很认真"),
		"整理：一边没日期 → 不冲突，可以并")

	var before_n: int = _mem.items.size()
	_mem.add("主人挑壁纸，挑得很认真", 0.0, PetMemory.KIND_FACT)
	_check(MemOrg.merge_into(_mem, "主人在挑洁尔佩塔相关的壁纸", 0.0,
			PetMemory.KIND_FACT) == MemOrg.OUT_MERGED,
		"整理：抽到近义 → 并入旧条，不新增")
	_check(MemOrg.merge_into(_mem, "主人 2026年9月27日在挑壁纸", 0.0,
			PetMemory.KIND_FACT) == MemOrg.OUT_MERGED,
		"整理：再来一条近义 → 还是并入（不新增）")
	_check(_mem.items.size() == before_n + 1,
		"整理：3 条近义只占 1 个坑（%d → %d）" % [before_n, _mem.items.size()])
	_check(MemOrg.merge_into(_mem, "主人养了一只叫豆豆的猫", 0.0,
			PetMemory.KIND_FACT) == MemOrg.OUT_ADDED,
		"整理：不相干的事实照常新增")

	# 一次性整理 consolidate：把已存的近义合并
	var tmp_mem = PetMemory.new()
	tmp_mem.file_path = "user://_probe_organize.json"
	tmp_mem.clear()
	tmp_mem.add("主人挑壁纸，挑得很认真", 0.0, PetMemory.KIND_FACT)
	tmp_mem.add("主人在挑洁尔佩塔相关的壁纸", 0.0, PetMemory.KIND_FACT)
	tmp_mem.add("主人 2026年9月27日在挑壁纸", 0.0, PetMemory.KIND_FACT)
	tmp_mem.add("主人喜欢喝奶茶", 0.0, PetMemory.KIND_FACT)
	var cons_n: int = MemOrg.consolidate(tmp_mem)
	_check(cons_n == 2 and tmp_mem.items.size() == 2,
		"整理：consolidate 把 3 条壁纸并成 1 条（并掉 %d，剩 %d 条）" % [cons_n, tmp_mem.items.size()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_mem.file_path))

	# ---- 6. 存盘 → 读回
	_mem.save()
	var again := PetMemory.new()
	again.file_path = TMP_MEM
	again.load_from_disk()
	_check(again.items.size() == _mem.items.size(),
		"存盘读回：条数一致（%d vs %d）" % [again.items.size(), _mem.items.size()])
	_check(String((again.profile.get("identity", {}) as Dictionary).get("name", "")) == "阿哲",
		"存盘读回：档案里的名字还在")

	# ---- 7. "选择性"的第一道筛子：值不值得记（主动搭话/偷看那两条靠它挡闲聊）
	_check(not PetMemory.worth_remembering('嗯嗯～'), "值得记吗：'嗯嗯～' → 不记")
	_check(not PetMemory.worth_remembering('嘿嘿'), "值得记吗：'嘿嘿' → 不记")
	_check(PetMemory.worth_remembering('主人在赶一个活儿，好像挺赶的'),
		"值得记吗：'主人在赶一个活儿，好像挺赶的' → 记")

	# ---- 7.5「她那边」的几组（快速回答的候选句 / 偷看提示词 / 提示词缓存 / 实时时间与
	#         距上次说话 / 缓存瘦身 / 「她自己先开口」的 %%/ 频率档）**整块搬去了
	#         tools/probe_memory_prompt.gd**（作业单 B7）—— 那是和"记忆机制"并列的另一件事，
	#         而且改得比记忆频繁得多。这里一次调用把它们全跑掉（输出会排在这一行之后，
	#         顺序和以前不同，但检查项一个没少）
	var PromptProbe: GDScript = load("res://tools/probe_memory_prompt.gd")
	var prompt_probe = PromptProbe.new()
	prompt_probe.setup(self)
	prompt_probe.run()

	# ---- 7.5.1 记忆流程：该不该叫模型来抽事实（static，所以能离线验）
	var flow_script: GDScript = load("res://scripts/ai/memory/pet_memory_flow.gd")
	_check(flow_script.should_extract("今天天气不错", 1000, 0),
		"记忆流程：节流到点了 + 话够长 → 该抽")
	_check(not flow_script.should_extract("今天天气不错", 900, 1000),
		"记忆流程：还没到节流点 → 不抽（别多花钱）")
	_check(not flow_script.should_extract("嗯", 1000, 0),
		"记忆流程：太短（“嗯”）→ 不抽")
	_check(not flow_script.should_extract("    ", 1000, 0),
		"记忆流程：只有空白 → 不抽")

	# ---- 7.6 偷看提示词那两条 → 搬去了 probe_memory_prompt.gd，由上面 7.5 那一处调用一起跑
	var pet_script: GDScript = load("res://scripts/desktop_pet.gd")
	# （`pet_script` 留在这儿给后面 7.10 的设置表交叉检查和频率档用 ——
	#   它原来声明在 7.5 那段里，那段搬走之后得另找地方落脚）

	# ---- 7.7 摸不同部位：分带要稳（头/胸/手/腿/身体各就各位）
	var ptr: GDScript = load("res://scripts/body/pet_pointer.gd")
	var samples: Array = [
		["头", Vector2(0.5, 0.12), "head"],
		["胸", Vector2(0.5, 0.40), "chest"],
		["左手", Vector2(0.10, 0.45), "hand"],
		["右手", Vector2(0.90, 0.45), "hand"],
		["腿", Vector2(0.5, 0.85), "leg"],
		["身体", Vector2(0.5, 0.62), "body"],
	]
	for s in samples:
		var part_got: String = ptr.classify_touch(s[1])
		_check(part_got == String(s[2]), "摸的部位：%s → %s（期望 %s）" % [s[0], part_got, s[2]])

	# ---- 7.8 摸得太频繁：到量才喊停、摸胸算两下、喊停后重新数、旧记录会过期
	# （这段在 scripts/pet_mood.gd 里 —— 它是 static，所以照样不用起窗口）
	var mood_script: GDScript = load("res://scripts/body/pet_mood.gd")
	var burst: Array = []
	var burst_hit := false
	for i in 7:
		burst_hit = mood_script.touch_burst_hit(burst, 1000 + i, "head")
	_check(not burst_hit, "摸太频繁：7 下（限 %d）还不喊停" % mood_script.TOUCH_BURST_LIMIT)
	_check(mood_script.touch_burst_hit(burst, 1100, "head"),
		"摸太频繁：第 %d 下 → 喊停" % mood_script.TOUCH_BURST_LIMIT)
	var chest: Array = []
	for i in 3:
		mood_script.touch_burst_hit(chest, 2000 + i, "chest")
	_check(chest.size() == 6, "摸太频繁：摸胸算两下 → 3 下记成 %d 下" % chest.size())
	_check(mood_script.touch_burst_hit(chest, 2100, "chest"),
		"摸太频繁：4 次摸胸就到线")
	var old: Array = []
	mood_script.touch_burst_hit(old, 1000, "head")
	var stale: bool = mood_script.touch_burst_hit(old, 62000, "head")
	_check(old.size() == 1 and not stale,
		"摸太频繁：一分钟前的旧记录会被丢掉 → 只剩 %d 条" % old.size())

	# ---- 7.8.0 自我和解计时（2026-09-30 用户要求）：生闷气闭嘴后，超过 30 分钟没被哄
	# → 发 reconcile_check（宿主去窥屏：在忙就自我和解）。mood 的计时是纯状态，离线可验
	var m2 = mood_script.new()
	m2.setup(null)
	var rec: Array = []
	m2.reconcile_check.connect(func(): rec.append(true))
	m2.set_muted_wait_deadline(maxi(1, Time.get_ticks_msec() - 1000))   # 摆一个"已经超时"的截止
	m2.tick()
	_check(rec.size() == 1, "自我和解计时：闭嘴超时 → 发 reconcile_check（触发 %d 次）" % rec.size())
	_check(m2.muted_wait_deadline() == 0, "自我和解计时：触发后计时清零（不再反复发）")
	m2.restart_muted_wait()
	_check(m2.muted_wait_deadline() > 0, "自我和解计时：没在忙 → 重新计时再等一轮")
	m2.soothe()
	_check(m2.muted_wait_deadline() == 0, "自我和解计时：被哄后计时清零（不再惦记）")

	# ---- 7.8.4 心情系统（2026-10-01 用户要求）：生气 / 伤心 / 开心 / 平常心 / 坏心眼
	# 判定全在 pet_mood.gd 的 mood()（纯状态，离线可验）
	var m3 = mood_script.new()
	m3.setup(null)
	_check(m3.mood() == mood_script.Mood.NEUTRAL, "心情：默认 → 平常心")
	m3.cheer()
	_check(m3.mood() == mood_script.Mood.HAPPY, "心情：摸头/喂食 → 开心")
	m3.bump(1.0)
	_check(m3.mood() == mood_script.Mood.ANGRY, "心情：有点委屈 → 生气（压过开心）")
	m3.bump(4.0)
	_check(m3.is_muted() and (m3.mood() == mood_script.Mood.ANGRY
			or m3.mood() == mood_script.Mood.SAD),
		"心情：生气到顶（闭嘴）→ 生气 / 伤心（对半，见 full_mood_pick）")
	m3.soothe()
	_check(m3.mood() != mood_script.Mood.SAD, "心情：被哄后不再是伤心")
	_check(mood_script.mood_name(mood_script.Mood.MISCHIEF) == "坏心眼"
			and mood_script.mood_name(mood_script.Mood.HAPPY) == "开心"
			and mood_script.mood_name(mood_script.Mood.NEUTRAL) == "平常",
		"心情：名字映射（写进人设用）")
	var m4 = mood_script.new()
	m4.setup(null)
	m4.tease()
	_check(m4.mood() == mood_script.Mood.MISCHIEF, "心情：坏心眼（平静时随机冒出来那种）")

	# ---- 7.8.5 心情的持续 / 触发 / 哄好（2026-10-01 第二轮需求）
	_check(absf(mood_script.MOOD_DECAY_PER_SEC * 3600.0 - 1.0) < 0.001,
		"心情：每种最多维持 1 小时（衰减速 ≈ 1/3600）")
	_check(mood_script.full_mood_pick(0.2) == mood_script.Mood.SAD
			and mood_script.full_mood_pick(0.8) == mood_script.Mood.ANGRY,
		"心情：怨气满 → 生气 / 伤心对半（骰子 <0.5 伤心，否则生气）")
	var m5 = mood_script.new()
	m5.setup(null)
	_check(not m5.is_upset(), "心情：平常心不算闹情绪（点击照常摸头）")
	m5.bump(1.0)
	_check(m5.is_upset(), "心情：有点委屈 → 算闹情绪（点击不给互动、要哄）")
	m5.soothe()
	_check(m5.mood() == mood_script.Mood.HAPPY, "心情：哄完 → 变开心（不是平常心）")
	var m6 = mood_script.new()
	m6.setup(null)
	m6.cheer()
	_check(m6._immune_to_sulk(), "心情：开心着被冷落也不攒委屈度（不记录生气值）")

	# ---- 7.8.1 「只在小范围走动」的范围盒子（static，所以离线可验）
	var walk_script: GDScript = load("res://scripts/body/pet_walk.gd")
	var box: Rect2i = walk_script.nearby_box(Vector2i(1000, 800), 200.0)
	_check(box.position == Vector2i(800, 600) and box.size == Vector2i(400, 400),
		"小范围走动：以家为中心的正方形 → %s" % str(box))
	_check(box.has_point(Vector2i(1000, 800)) and not box.has_point(Vector2i(1300, 800)),
		"小范围走动：圈里算里、圈外算外")
	_check(walk_script.nearby_box(Vector2i(0, 0), 0.0).size == Vector2i(2, 2),
		"小范围走动：半径填 0 也不塌成空盒子（至少 1px，免得夹出反的范围）")

	# ---- 7.8.x 那几组（提示词缓存 / 实时时间 / 距上次说话 / 缓存瘦身）和 7.5.1
	#      （「她自己先开口」的 %% 拆分）也搬去了 **probe_memory_prompt.gd**（作业单 B7），
	#      由上面 7.5 那一处调用一起跑 —— 它们和"记忆机制"不是一件事，而且改得更勤

	# ---- 7.5.2 换到公开 API（GLM）之后最容易撞上的：免费额度会回 429「访问量过大」。
	# 认得出它 + 自动原样重发，才不会表现成"她经常不说话"；而 401（key 不对）
	# 绝对不能重试 —— 那是重试多少次都不会好的错
	var chat_gd: GDScript = load("res://scripts/ai/pet_chat.gd")
	_check(chat_gd._looks_busy(429, "") and chat_gd._looks_busy(200, "{\"error\":{\"code\":\"1305\"}}"),
		"429 重试：HTTP 429 和「1305 访问量过大」都算「模型太挤」")
	_check(not chat_gd._looks_busy(401, "") and not chat_gd._looks_busy(200, "{\"choices\":[]}"),
		"429 重试：401（key 不对）和正常返回都**不**重试 —— 该立刻报错而不是白等")
	# 待重发那 2.5 秒里旧连接已经 cancel 了，必须仍算"忙"：
	# 不然定时器会插进来开新流，之后旧请求重发 → 她过几秒又冒一句不相关的话
	var busy_probe = chat_gd.new()
	# 计时器搬进了 pet_retry.gd（作业单 B1.3），所以这里打桩打在它身上
	busy_probe.get("_retry").set("at_ms", Time.get_ticks_msec() + 1000)
	_check(bool(busy_probe.call("is_busy")),
		"429 重试：等待重发的那几秒**也算忙**（不给别的链路插进来的机会）")
	busy_probe.get("_retry").set("at_ms", 0)
	_check(not bool(busy_probe.call("is_busy")), "429 重试：没待重发时不算忙（否则她永远在忙）")

	# ---- 7.5.3 思考要关掉。实测 glm-4.7-flash 同一句话：
	#   带思考 15.3 秒、思考 515 字、**正文 0 字**；关掉 1.1 秒、正文正常。
	# 她的台词就是一两句话，思考换不来质量，只换来十几秒沉默
	var nc = chat_gd.new()
	_check(bool(nc.get("no_think")), "关思考：默认开着（一两句话的台词不需要思考）")
	nc.call("_note_unsupported", 400, "{\"error\":\"unknown parameter: thinking\"}")
	_check(not bool(nc.get("no_think")),
		"关思考：后端回 400（不认这个参数）时自动摘掉，之后不再发 —— 换模型不会卡死")
	var nc2 = chat_gd.new()
	nc2.call("_note_unsupported", 500, "服务器内部错误")
	_check(bool(nc2.get("no_think")), "关思考：500 这类不是参数问题的错误不误摘")

	# ---- 7.4.1 流式分片解析（pet_sse.gd —— 作业单 B1.2 从 pet_chat 搬出来的那一层）。
	# 它能整段离线测，正是"拆得值不值"的判据（宪法第一节）
	var sse_gd: GDScript = load("res://scripts/ai/net/pet_sse.gd")
	var p1 = sse_gd.new()
	p1.call("reset")
	# 故意从"你"字的第 2 个字节处切断：半个多字节字符结尾的 chunk 必须能接回来
	var whole := "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n"
	var cut: int = whole.substr(0, whole.find("你")).to_utf8_buffer().size() + 1
	var all_bytes := whole.to_utf8_buffer()
	p1.call("feed", all_bytes.slice(0, cut))
	p1.call("feed", all_bytes.slice(cut))
	var toks: Array = p1.call("take_tokens")
	p1.call("flush")
	for t in p1.call("take_tokens"):
		toks.append(t)
	_check("".join(toks) == "你好" and bool(p1.get("finished")),
		"流式解析：半个多字节字符结尾的 chunk 能接回来（按字节切行）→ 「%s」" % "".join(toks))
	var p2 = sse_gd.new()
	p2.call("reset")
	p2.call("feed", "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null,\"content\":\"在\"}}]}\n".to_utf8_buffer())
	p2.call("feed", "data: {\"choices\":[{\"delta\":{\"content\":\"的\"}}]}\n".to_utf8_buffer())
	p2.call("flush")
	_check("".join(p2.call("take_tokens")) == "在的",
		"流式解析：reasoning_content 是 null 的分片不会把流打崩（官方 API 实际长这样）")
	var p3 = sse_gd.new()
	p3.call("reset")
	p3.call("feed", "data: {\"error\":{\"code\":\"1305\",\"message\":\"访问量过大\"}}\n".to_utf8_buffer())
	_check(String(p3.get("stream_error")).find("访问量过大") >= 0,
		"流式解析：流里的错误对象被认出来 → %s" % String(p3.get("stream_error")))
	var p4 = sse_gd.new()
	p4.call("reset")
	p4.call("feed", "data: {\"choices\":[{\"delta\":{\"content\":\"[代理错误] 上游业务错误 40003\"}}]}\n".to_utf8_buffer())
	p4.call("flush")
	_check((p4.call("take_tokens") as Array).is_empty(),
		"流式解析：认得出「报错被当正文吐出来」，一个分片都不冒进气泡")
	var p5 = sse_gd.new()
	p5.call("reset")
	p5.call("feed", "data: {\"choices\":[],\"usage\":{\"prompt_cache_hit_tokens\":640}}\n".to_utf8_buffer())
	_check(int((p5.get("usage") as Dictionary).get("prompt_cache_hit_tokens", -1)) == 640,
		"流式解析：choices 为空的那一块也收得到 usage（开了 stream_options 之后就是它）")

	# ---- 7.9 设置面板：值要钳到表里写的范围
	# 配置文件是纯文本，手改过或者老版本留下的值都可能越界（间隔改成 0 的话，
	# 她就会一直偷看屏幕），所以读存档必须过这一道
	var settings_script: GDScript = load("res://scripts/ui/pet_settings.gd")
	var messy: Dictionary = settings_script.sanitize({
		"memory_ai_every_sec": 99999.0, "chat_log_lines": -5, "talk_rate": 99,
		"persona_name": "  小蓝  ", "memory_enabled": 1,
	})
	_check(messy["memory_ai_every_sec"] == 300.0,
		"设置钳制：抽取间隔 99999 → %s 秒" % str(messy["memory_ai_every_sec"]))
	_check(int(messy["chat_log_lines"]) == 1,
		"设置钳制：保留行数 -5 → %s 行" % str(messy["chat_log_lines"]))
	_check(int(messy["talk_rate"]) == 3, "设置钳制：频率档 99 → 第 %s 档" % str(messy["talk_rate"]))
	_check(String(messy["persona_name"]) == "小蓝",
		"设置钳制：名字两端空格去掉 → “%s”" % String(messy["persona_name"]))
	_check(bool(messy["memory_enabled"]), "设置钳制：勾选框给 1 → true")

	# ---- 7.10 设置表交叉检查：面板里的每个键，主脚本都得认，而且得落盘。
	# 这一条是防"加了一项设置，忘了在主脚本接上" —— 那种漏在界面上完全看不出来：
	# 面板照样能改、能保存，只是重启之后又变回去了
	var chat_keys := ["proactive_on", "talk_rate", "peek_on", "camera_on"]
	var extra_keys := ["quiet_fullscreen", "hide_taskbar", "tray_icon", "autostart", "scale_percent"]
	var setting_miss := ""
	for k in settings_script.keys():
		var key := String(k)
		if key.begins_with("cmd_"):
			continue          # 按钮，不是设置值
		if not (pet_script.SETTING_VARS.has(key) or key in extra_keys or key in chat_keys):
			setting_miss += "%s(主脚本不认) " % key
		elif not (key in chat_keys or key in pet_script.SETTING_SAVED):
			setting_miss += "%s(不会落盘) " % key
	_check(setting_miss == "",
		"设置表交叉检查：%s" % ("全部接上" if setting_miss == "" else setting_miss))

	# ---- 8. 主动说话的四个频率档 → 也搬去了 probe_memory_prompt.gd
	#      （"她什么时候开口"和"她说什么"是同一族）

# ================================================================ B. 真实对话

func _step_dialog() -> void:
	if _turn >= DIALOG.size():
		_phase = "extract"
		return
	if _sent:
		_turn_frames += 1
		if _turn_frames > TURN_FRAMES:
			_check(false, "第 %d 轮 45 秒没等到回复" % (_turn + 1))
			_sent = false
			_turn += 1
			_turn_frames = 0
		return
	var msg := DIALOG[_turn]
	_turn_frames = 0
	print("\n主人：%s" % msg)
	# 每轮都按最新记忆重拼人设 —— 和桌面宠物里 _refresh_persona 的路子一样。
	# 日期是写死的：探针要可复现，不然同一个提示词一天一个样
	var prompt := PetPersona.build({
		"name": "小蓝", "user_text": msg, "memory": _mem,
		"state_text": "趴在桌面上发呆",
		"year": 2026, "month": 9, "day": 21, "hour": 22, "minute": 10, "weekday": 1,
	})
	if not _persona_shown:
		_persona_shown = true
		print("\n=========== 送出去的人设提示词（%d 字）===========\n%s\n==============================================\n"
			% [prompt.length(), prompt])
	_chat.system_prompt = prompt
	_mem.learn(msg)
	_sent = true
	if not _chat.send(msg):
		_sent = false
		_check(false, "发送失败：%s" % _chat.last_error())
		_turn += 1

func _on_replied(text: String) -> void:
	print("她：%s" % text)
	_mem.note_exchange(DIALOG[_turn], text)
	_sent = false
	_turn += 1

func _on_failed(msg: String) -> void:
	_check(false, "第 %d 轮失败：%s" % [_turn + 1, msg.split("\n")[0]])
	_sent = false
	_turn += 1

# ================================================================ C. AI 记忆抽取

func _step_extract() -> void:
	if _once_done_seen:
		_show_memory()
		_cleanup()
		_phase = "quit"
		return
	if _once_sent:
		_once_frames += 1
		if _once_frames > TURN_FRAMES:
			_check(false, "AI 抽取 45 秒没回来")
			_once_done_seen = true
		return
	_once_sent = true
	print("\n===== C. AI 记忆抽取（后台一次性请求）=====")
	if not _chat.ask_once("你是记忆整理模块，只输出 JSON。", PetMemory.FACT_PROMPT % [
			"我叫阿哲，我在深圳做程序员，养了一只叫豆豆的猫。",
			"程序员呀～那你要多休息。豆豆这名字好可爱。",
			PetMemory.today_text()], 400):
		_check(false, "ask_once 没发出去")
		_once_done_seen = true

func _on_once_done(text: String) -> void:
	print("模型返回：%s" % text.strip_edges())
	var facts := PetMemory.parse_json_array(text)
	_check(not facts.is_empty(), "JSON 解析出 %d 条事实" % facts.size())
	var n := _mem.apply_extracted_facts(facts)
	_check(n > 0, "存进长期记忆 %d 条" % n)
	var hit := false
	for it in _mem.items:
		if String(it.text).find("猫") >= 0 or String(it.text).find("豆豆") >= 0:
			hit = true
	_check(hit, "抽到的事实里能查到「豆豆/猫」")
	_once_done_seen = true

func _on_once_failed(msg: String) -> void:
	_check(false, "AI 抽取失败：%s" % msg)
	_once_done_seen = true

# ================================================================ 杂项

func _load_cfg() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(CHAT_CFG) != OK:
		return {}
	# ⚠️ 密钥**不在** cfg 里：它单独住在加密文件 user://pet_secret.dat（见 pet_secret.gd），
	# 配置里的 [ai].key 从 2026-09-23 起**永远是空**。只读 cfg 会让 B/C 段永远进不来
	# （2026-09-29 实测：key 一直空，B/C 被静默跳过）。所以像 app 那样先去读加密文件，
	# 读不到才回落 cfg（老存档可能还躺着明文 key）
	var keys: Array = PetSecret.load_keys()
	var key := String(keys[0])
	if key == "":
		key = String(cfg.get_value("ai", "key", ""))
	return {
		"url": String(cfg.get_value("ai", "url", "https://api.deepseek.com")),
		"key": key,
		"model": String(cfg.get_value("ai", "model", "deepseek-flash")),
	}

func _show_memory() -> void:
	if _mem == null:
		return
	var st := _mem.stats()
	print("\n===== 记忆档案 =====")
	print("共 %d 条（核心 %d / 重要 %d / 常规 %d），档案 %d 项" % [
		int(st["total"]), int(st["core"]), int(st["important"]),
		int(st["regular"]), int(st["profile"])])
	for line in _mem.profile_lines():
		print("  档案 | " + line)
	for line in _mem.working_lines():
		print("  工作 | " + line)
	for it in _mem.items:
		print("  记忆 | [%s] %s（重要性 %.2f，被想起 %d 次）" % [
			LAYER_NAME[clampi(int(it.layer), 0, 3)], String(it.text),
			float(it.importance), int(it.access_count)])

func _ident(key: String) -> String:
	return String((_mem.profile.get("identity", {}) as Dictionary).get(key, ""))

func _pref(key: String) -> Array:
	var v: Variant = _mem.profile.get(key)
	return v if typeof(v) == TYPE_ARRAY else []

func _find(part: String) -> Variant:
	for it in _mem.items:
		if String(it.text).find(part) >= 0:
			return it
	return null

func _check(cond: bool, text: String) -> void:
	if cond:
		_ok += 1
		print("  [OK]   %s" % text)
	else:
		_bad += 1
		print("  [FAIL] %s" % text)

func _cleanup() -> void:
	# 删临时记忆文件。user:// 要先 globalize_path 才能用 remove_absolute
	if FileAccess.file_exists(TMP_MEM):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_MEM))
