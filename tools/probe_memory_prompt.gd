# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 自检里"**她那边**"的那几组：人设 / 提示词 / 她该说什么（快速回答的候选句）。
##
## 从 probe_memory.gd 搬出来（作业单 B7）。为什么值得独立：那边 621 行里混着两件事 ——
## 「记忆机制」（抽取 / 分层 / 遗忘 / 检索 / 存档 / 设置）和「她怎么说、说什么」。
## 后者改起来的频率高得多（提示词、候选句、时间口径），该有自己的地方。
##
## 与主探针的分工：主探针负责跑流程与计数，本模块只提供一批检查。
## `_check()` 在这儿是个**转发**（转到主探针上，那里才管 [OK]/[FAIL] 和计数）——
## 好处是搬过来的检查**逐字不用改**，以后加检查也只管照着老样子写。
##
## 参数 `h` 故意不标类型（它是 SceneTree 脚本里那个探针对象，见 CONVENTIONS.md）。
##
## 用法（主探针里）：`var p := PromptProbe.new(); p.setup(self); p.run()`
extends RefCounted

var _h = null

func setup(h) -> void:
	_h = h

## 检查结果与计数都交给主探针
func _check(cond: bool, text: String) -> void:
	_h._check(cond, text)

func run() -> void:
	# 本模块要用到的几个脚本（原来散在主探针里，各自就近 load —— 声明式，不藏状态）
	var pet_script: GDScript = load("res://scripts/desktop_pet.gd")
	var quick_script: GDScript = load("res://scripts/ai/pet_quick.gd")
	var persona_script: GDScript = load("res://scripts/ai/memory/pet_persona.gd")
	var chat_script: GDScript = load("res://scripts/ai/pet_chat.gd")

	# ---- 7.5 快速回答：本地按口气挑，问句/撒娇/生闷气各一组，且不该重样
	# （这两块现在都在 scripts/pet_quick.gd 里：候选和"把模型返回洗干净"是同一件事的两半。
	#  两个函数都写成 static，所以不用实例化整个场景就能试）
	var q_ask: Array = quick_script.quick_options_for("proactive", "你在忙什么呀？")
	var q_talk: Array = quick_script.quick_options_for("proactive", "我刚在屏幕边上溜达了一圈。")
	var q_sulk: Array = quick_script.quick_options_for("sulk", "哼。")
	var q_peek: Array = quick_script.quick_options_for("peek", "你在赶活儿啊。")
	_check(q_ask.size() == 3 and String(q_ask[0]).find("在呢") >= 0,
		"快速回答：问句给答话 %s" % str(q_ask))
	_check(q_talk.size() == 3 and String(q_talk[0]) != String(q_ask[0]),
		"快速回答：陈述句给另一组 %s" % str(q_talk))
	# 真聊天里的问句：本地那组**不可能知道答案**（她可能问"吃饭了没"，也可能问别的），
	# 所以只给"打太极"的三句。**绝不能**再给"在呢，你说"那种答非所问的 ——
	# 2026-09 用户报的"选项不对"就是这个：她问吃饭了没，按钮给"刚在忙，怎么啦？"
	var q_chat_ask: Array = quick_script.quick_options_for("chat", "吃饭了没呀？")
	_check(q_chat_ask.size() == 3
			and String(q_chat_ask[0]).find("在呢") < 0
			and String(q_chat_ask[0]).find("然后呢") < 0,
		"快速回答：聊天里的问句不给“答非所问”那组 %s" % str(q_chat_ask))
	_check(q_sulk.size() == 3 and String(q_sulk[0]).find("别生气") >= 0,
		"快速回答：生闷气给哄她的 %s" % str(q_sulk))
	_check(q_peek.size() == 3 and String(q_peek[0]).find("发现") >= 0,
		"快速回答：偷看屏幕给“被抓到”那组 %s" % str(q_peek))
	# 被摸烦了不能给"摸摸头，等会儿陪你" —— 那就是又摸她一下
	var q_touch: Array = quick_script.quick_options_for("touch", "喂！别摸了！")
	_check(q_touch.size() == 3 and String(q_touch[0]).find("不摸") >= 0,
		"快速回答：被摸烦了给“手放好了”那组 %s" % str(q_touch))
	# 模型现编的那组要洗得干净：markdown 围栏 / 编号 / 书名号 / 太长 / 空的都得处理掉。
	# 洗不出来就返回空数组 —— 调用方会继续用本地那组，**按钮不会因为模型乱答而消失**
	var ai_raw := """```json
["1. 在呢在呢", "「刚在忙」", "这三句有点太长了，长到按钮一行根本放不下就该被丢掉", "", "哈哈哈", "第四句"]
```"""
	var ai_opts: Array = quick_script.parse_quick_options(ai_raw)
	_check(ai_opts.size() == 3, "快速回答：只要三句（模型给多了也砍掉）→ %s" % str(ai_opts))
	if ai_opts.size() == 3:
		_check(String(ai_opts[0]) == "在呢在呢", "快速回答：编号被削掉 → %s" % String(ai_opts[0]))
		_check(String(ai_opts[1]) == "刚在忙", "快速回答：书名号被削掉 → %s" % String(ai_opts[1]))
		_check(String(ai_opts[2]) == "哈哈哈",
			"快速回答：空的和太长的都跳过 → %s" % String(ai_opts[2]))
	_check((quick_script.parse_quick_options("模型今天不想给 JSON") as Array).is_empty(),
		"快速回答：模型不吐 JSON 时返回空（继续用本地那组）")

	# ---- 7.6 被冷落时"偷看一眼屏幕"：判断交给她自己，我们不再解析任何标记
	# 为什么值得验：摘标记的代码已经删了，提示词里要是还留着 [忙]/[闲]，
	# 她会把标记**原样念到气泡里**（以前有摘除逻辑挡着，现在没有那层了）
	var peek_prompt := String(load("res://scripts/body/pet_mood_ui.gd").PROMPT_SULK_PEEK)
	_check(peek_prompt.find("[") < 0,
		"偷看提示词里没有标记语法（看到什么、怎么想都由她说）→ %s" % peek_prompt)
	_check(peek_prompt.find("你自己") >= 0 and peek_prompt.find("你自己的想法") >= 0,
		"偷看提示词把判断交给她自己 → %s" % peek_prompt)

	# ---- 7.6.1 记忆污染防线（2026-10-03 用户报的 bug）：她"看屏幕"看到的是**画面**，
	# 不一定是主人在做的事（可能是视频/直播/游戏）。OBSERVE_PROMPT 必须挡住这类内容，
	# 否则会被抽成"主人 9 月 X 日在玩植物大战僵尸"存进【关于主人】，下次当现实提起 ✗
	var observe_prompt := String(load("res://scripts/ai/memory/pet_memory.gd").OBSERVE_PROMPT)
	_check(observe_prompt.find("只能靠") >= 0,
		"观察提示词：挡住『只能靠看屏幕得知』的内容（截图内容不许当事实）")
	_check(observe_prompt.find("他最近在玩什么") < 0,
		"观察提示词：不再教模型记『他最近在玩什么』（那正是屏幕污染的老来源）")

	# ---- 7.8.2 提示词缓存：把"能命中的前缀"钉成不变量。
	# 服务商的前缀缓存按"逐字相同的最长前缀"算钱，所以规矩是：
	#   人设（系统提示词）逐字不变 + 每轮的上下文单独一条、附在历史之后
	# compose_messages 写成 static 就是为了能在这儿离线量
	var stable := String(persona_script.build({"name": "小蓝", "extra": "说话再短一点"}))
	var ctx1 := String(persona_script.build_context({"user_text": "今天加班到十点",
		"state_text": "趴在桌面上发呆"}))
	var hist := [{"role": "user", "content": "今天加班到十点"},
		{"role": "assistant", "content": "欸，又到十点啊……"}]
	var ctx2 := String(persona_script.build_context({"user_text": "嗯，你困不困？",
		"state_text": "在屏幕边上溜达"}))
	var m1: Array = chat_script.compose_messages(stable, [], ctx1, "今天加班到十点", "")
	var m2: Array = chat_script.compose_messages(stable, hist, ctx2, "嗯，你困不困？", "")
	_check(m1.size() == 3 and m2.size() == 5,
		"缓存前缀：一轮 3 条（人设 / 上下文 / 这一句），下一轮 5 条（多了上一轮）→ %d / %d" % [m1.size(), m2.size()])
	_check(String(m1[0]["content"]) == String(m2[0]["content"]) and stable.length() >= 900,
		"缓存前缀：两轮的系统提示词**逐字相同**（%d 字）" % stable.length())
	_check(String(m1[1]["role"]) == "system" and String(m2[3]["role"]) == "system",
		"缓存前缀：每轮的上下文是单独一条、位置在历史之后")
	_check(stable.find("【现在】") < 0 and stable.find("关于主人") < 0,
		"缓存前缀：时间 / 记忆**不在**系统提示词里（它们每轮都变，放进去缓存就断）")
	_check(ctx1.find("【现在】") >= 0 and ctx1 != ctx2,
		"缓存前缀：时间和记忆都在每轮的上下文里，且两轮确实不同")
	print("  [数] 稳定部分 %d 字；每轮上下文 %d 字；末尾这条上下文是唯一不命中的一段" % [
		stable.length(), ctx1.length()])

	# ---- 7.8.1 实时时间：她自己是不知道今天几号的（模型只有训练时的印象，会说错年份），
	# 这一行是它唯一的来源 —— 所以必须真的读系统时钟、且精确到分钟
	var dt := Time.get_datetime_dict_from_system()
	var live := String(persona_script.now_line())
	_check(live.find("%d年%d月%d日" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]) >= 0,
		"实时时间：now_line() 读到系统当前日期 → %s" % live.substr(0, 24))
	_check(live.find("%02d:%02d" % [int(dt["hour"]), int(dt["minute"])]) >= 0,
		"实时时间：精确到分钟（她会说「现在 20:47」，不是只会说「晚上」）")
	var late := String(persona_script.now_line({
		"year": 2026, "month": 9, "day": 22, "hour": 3, "minute": 5, "weekday": 2}))
	_check(late.find("深夜") >= 0 and late.find("这么晚") >= 0,
		"实时时间：凌晨会带一句关心，但只写情境、不写成台词 → %s" % late)
	_check(String(persona_script.now_line({"hour": 20})).find("晚上") >= 0,
		"实时时间：时段用口语说法（20 点 → 晚上）")

	# ---- 7.8.2 距上次说话：让"她在过日子"这件事有依据
	# **门槛 30 分钟**（2026-09-29 从 2 分钟提上来的）：太近就报时，模型会接一句
	# "诶你终于理我了" —— 那正是用户报的 bug。所以"刚聊完"必须**一个字都不提**
	var near := String(persona_script.build_context({"user_text": "在吗", "gap_min": 45}))
	var far := String(persona_script.build_context({"user_text": "在吗", "gap_min": 300}))
	_check(near.find("距上次说话 45 分钟") >= 0 and far.find("距上次说话 5 小时") >= 0,
		"距上次说话：分钟 / 小时各一档 → %s｜%s" % [near.substr(0, 40), far.substr(0, 40)])
	_check(String(persona_script.build_context({"user_text": "在吗", "gap_min": 3})).find("距上次说话") < 0,
		"距上次说话：刚聊完（3 分钟）不提 —— 不然她会冒一句“你终于理我了”")
	_check(String(persona_script.build_context({"user_text": "在吗"})).find("距上次说话") < 0,
		"距上次说话：没给这个数就不提（免得她编「我们好久没聊了」）")

	# ---- 7.8.2b 启动 / 关闭的概念（2026-09-30 用户要求）：她知道自己是个桌宠，
	#              且对"什么时候被打开 / 被关掉"有概念
	var stable_id: String = String(persona_script.build({}))
	_check(stable_id.find("桌宠") >= 0 and stable_id.find("被打开") >= 0
			and stable_id.find("被退出") >= 0,
		"自我认知：人设写明她是桌宠，且知道启动（被打开）/ 关闭（被退出）")
	var with_start := String(persona_script.build_context({"user_text": "在吗", "started_at": "19:14"}))
	_check(with_start.find("你是 19:14 启动的") >= 0,
		"启动概念：上下文带上「几点启动」→ %s" % with_start.substr(0, 44))
	_check(String(persona_script.build_context({"user_text": "在吗"})).find("启动") < 0,
		"启动概念：没给这个数就不硬塞")

	# ---- 7.8.3 瘦身：每轮都变的那一段是**按原价**付钱的（吃不前缀缓存），能省就省
	var one_now := String(persona_script._now_block({"hour": 20, "minute": 30}, "趴在桌面上发呆"))
	_check(one_now.split("\n").size() == 1 and one_now.begins_with("【现在】"),
		"缓存瘦身：「现在」压成一行 → 「%s」" % one_now)
	_check(String(persona_script._sense_block(["测试一条"])).length() < 40,
		"缓存瘦身：常识标题压短 → %s" % String(persona_script._sense_block(["测试一条"])))
	var capped := String(persona_script._cap_lines("aaa\nbbb\nccc\nddd", 7))
	_check(capped == "aaa\nbbb", "缓存瘦身：记忆超预算就整行丢（从末尾）→ 「%s」" % capped.replace("\n", "\\n"))
	var capped2 := String(persona_script._cap_lines("档案\n【记得】\n- 一条\n- 两条", 12))
	_check(not capped2.ends_with("："), "缓存瘦身：别留一个后面空掉的标题 → 「%s」" % capped2.replace("\n", "\\n"))

	# ---- 7.5.1 「她自己先开口」那条：模型把「她的话 + %% [候选…]」写在**同一次回答**里
	# 用分隔符而不用 JSON，是因为她的话里一出现引号（中文引号、书名号、问号都算）
	# 就会把 JSON 弄坏 —— 而"她的话"是最不该被格式绑住的东西
	var pet_gd: GDScript = load("res://scripts/desktop_pet.gd")
	var sp: Dictionary = pet_gd.split_options(
		"欸，十点才回来啊……饭吃了没？\n%% [\"刚吃过\", \"还没呢\", \"你也早点睡\"]")
	_check(String(sp["say"]) == "欸，十点才回来啊……饭吃了没？",
		"主动开口带候选：分隔符之前那句原样留下 → 「%s」" % String(sp["say"]))
	_check((sp["options"] as Array).size() == 3,
		"主动开口带候选：%% 后面洗出 3 句 → %s" % str(sp["options"]))
	var sp2: Dictionary = pet_gd.split_options("我有点困了")
	_check(String(sp2["say"]) == "我有点困了" and (sp2["options"] as Array).is_empty(),
		"主动开口带候选：模型没写 %% 时整段当她说的话、候选为空（会退回原来的做法，按钮不会消失）")
	var sp3: Dictionary = pet_gd.split_options(
		"啊这……「你说什么？」我没听清\n%% [\"没事\", \"我说你早点睡\"]")
	_check((sp3["options"] as Array).size() == 2 and String(sp3["say"]).find("「") >= 0,
		"主动开口带候选：她的话里有书名号/问号也不影响拆分（这就是不用 JSON 的原因）")

	# ---- 7.5.2 闹情绪时点击她（生气 / 伤心）：不给正常互动、要哄
	# （**开心 / 平常心时照常摸头**，见 pet_mood.is_upset）。逻辑在 pet_mood_ui.gd（2026-10-01 拆）
	var mood_ui_gd: GDScript = load("res://scripts/body/pet_mood_ui.gd")
	_check(String(mood_ui_gd.sulk_click_reaction(false, 0.0)) == "pet",
		"点击：没闹情绪（开心 / 平常）时照常摸头反应（pet）")
	_check(String(mood_ui_gd.sulk_click_reaction(true, 0.1)) == "comfort",
		"点击：闹情绪、骰子小（0.1 < 0.7）→ 弹「哄她」选择框")
	_check(String(mood_ui_gd.sulk_click_reaction(true, 0.9)) == "cold",
		"点击：闹情绪、骰子大（0.9 ≥ 0.7）→ 冷冷一句、还是不给互动")
	_check(String(mood_ui_gd.sulk_click_reaction(true, -1.0)) == "comfort",
		"点击：闹情绪、不掷骰子（dice<0）→ 直接弹选择框")

	# ---- 8. 主动说话的四个频率档：从"很少"到"很频繁"必须单调变短，
	#         而且要能在合理范围里（不然菜单点了像没反应）
	var prev_lo := INF
	for i in 4:
		var span: Vector2 = pet_script.talk_span_for(i, Vector2(300.0, 900.0))
		var lo := minf(span.x, span.y)
		var hi := maxf(span.x, span.y)
		print("  频率档 %d（%s）：%.0f ~ %.0f 秒 = %.1f ~ %.1f 分钟" % [
			i, pet_script.TALK_RATE_NAMES[i], lo, hi, lo / 60.0, hi / 60.0])
		if i > 0:
			_check(lo < prev_lo, "频率档 %d 比上一档更短（%.0f < %.0f 秒）" % [i, lo, prev_lo])
		_check(lo >= 20.0 and hi <= 3600.0, "频率档 %d 的区间在合理范围（20 秒~1 小时）" % i)
		prev_lo = lo

	# ---- 8.1 「主动说话」整块搬进 pet_proactive.gd 了（2026-09-29 第③条）：
	#         宿主留的壳必须**转到模块**，别哪天又长回第二份实现（两份必然对不上）
	var Proactive: GDScript = load("res://scripts/ai/pet_proactive.gd")
	_check(Proactive.span_for(1, Vector2(300.0, 900.0))
			== pet_script.talk_span_for(1, Vector2(300.0, 900.0)),
		"主动说话模块：宿主 talk_span_for 只是壳，时长算法在 pet_proactive.span_for（同源）")
	_check(String(Proactive.PROMPT_PROACTIVE).find("别回答我这句话") >= 0,
		"主动说话模块：提示词（别回答我这句话…）跟着搬过去了")
	_check(Proactive.new().rate == 1 and Proactive.new().timer == 0.0,
		"主动说话模块：新实例的出厂档位是 1（普通）、倒计时由 setup 里数")
