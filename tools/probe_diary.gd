extends SceneTree
## 验「她自己的日记」：数据与判定（pet_diary.gd）+ 提示词与洗回信（pet_diary_prompt.gd）。
##
## 全离线、不联网、不花额度。
##
## ⚠️ 它**会动你的真日记文件**（`user://pet_diary.json`）：因为要验存盘读回，
## 得往真路径上写。规矩按 CONVENTIONS.md 附录那条 —— **备份 → 改 → 验 → 还原挤在一起，
## 还原紧跟其后**，绝不放到"收尾"里（有一次探针中途死掉，用户的 AI 密钥就是这么丢的）。
## 所以这里：`_swap_in()` 存下原文件并清空，跑完 `_swap_out()` 立刻还原。
##
## 用法:
##   godot --headless --path . --script res://tools/probe_diary.gd
##
## 看门狗必须有（`--script` 模式下不调 quit 进程就一直挂着）

const Diary := preload("res://scripts/body/pet_diary.gd")
const DiaryPrompt := preload("res://scripts/body/pet_diary_prompt.gd")
const DiaryFlow := preload("res://scripts/body/pet_diary_flow.gd")

var _pass := 0
var _fail := 0
var _frames := 0
## 原文件的内容（null = 原来没有这个文件）
var _backup: Variant = null
var _had_file := false

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 2000:
		printerr("看门狗触发：探针超时")
		_swap_out()
		quit(2)
		return true
	return false

func _run() -> void:
	print("=== 日记自检 ===")
	_swap_in()
	_test_beats()
	_test_summarize()
	_test_clean_ai()
	_test_streak()
	_test_dates()
	_test_store_roundtrip()
	_test_material()
	_test_split_title()
	_test_relation()
	_swap_out()
	print("")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ------------------------------------------------------------------ 断言

func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ✓ %s" % what)
	else:
		_fail += 1
		printerr("  ✗ %s" % what)

func _eq(a: Variant, b: Variant, what: String) -> void:
	if a == b:
		_pass += 1
		print("  ✓ %s" % what)
	else:
		_fail += 1
		printerr("  ✗ %s —— 实际 %s，期望 %s" % [what, str(a), str(b)])

# ------------------------------------------------------------------ 真文件换进换出

## 备份真文件并清空（后面所有写入都落在临时状态上）
func _swap_in() -> void:
	_had_file = FileAccess.file_exists(Diary.SAVE_PATH)
	if _had_file:
		var f := FileAccess.open(Diary.SAVE_PATH, FileAccess.READ)
		if f != null:
			_backup = f.get_as_text()
			f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Diary.SAVE_PATH))

## **紧跟在测试之后**还原真文件
func _swap_out() -> void:
	if _had_file and _backup != null:
		var f := FileAccess.open(Diary.SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(String(_backup))
			f.close()
	elif not _had_file:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Diary.SAVE_PATH))

# ------------------------------------------------------------------ 拍子

func _test_beats() -> void:
	print("\n[1] 拍子：认得 / 不认得 / 一天的上限")
	var host := Node.new()
	var d := Diary.new()
	d.setup(host)
	_ok(d.note("pet"), "note(\"pet\") 记下了")
	_ok(not d.note("不存在的种类"), "未知种类被拒（白名单）")
	_ok(not d.note(""), "空种类被拒")
	# 同类一天最多 MAX_SAME_BEAT 条
	for i in 10:
		d.note("talk")
	var talks := 0
	for b in (d.days[0]["beats"] as Array):
		if String(b["kind"]) == "talk":
			talks += 1
	_eq(talks, Diary.MAX_SAME_BEAT, "同类拍子一天最多 %d 条" % Diary.MAX_SAME_BEAT)
	_eq(d.total_pets, 1, "累计被摸次数 +1")
	_ok(d.has_today(), "has_today() = true")
	_ok(d.first_day != "", "first_day 自动填上了")
	host.free()

# ------------------------------------------------------------------ 合成

func _test_summarize() -> void:
	print("\n[2] 本地合成：口径对不对")
	# 闹别扭 + 和好 → 必须提"和好了"
	var s1: String = Diary.summarize(["ignored", "soothe", "pet"])
	_ok(s1.contains("和好"), "被冷落+被哄 → 提到和好")
	# 只有开心的事
	var s2: String = Diary.summarize(["pet", "feed"])
	_ok(s2.length() > 0, "有拍子就有正文")
	_ok(not s2.contains("难过"), "没难过就不提难过")
	# 空拍子 → 空串（不是"今天也挺平常的"）
	_eq(Diary.summarize([]), "", "没有拍子 → 空串")
	# 只有生气、没被哄 → 收尾那句
	var s3: String = Diary.summarize(["angry"])
	_ok(s3.contains("哼") or s3.contains("闷"), "生气没被哄 → 有情绪收尾")
	# 素材里必须**不出现数字**（本地那版是给人看的，不是报表）
	var s4: String = Diary.summarize(["pet", "talk", "feed", "sleep", "happy"])
	_ok(not s4.contains("次"), "本地正文里不报数字")
	_ok(s4.length() < 120, "本地正文不冗长（<120 字）")

# ------------------------------------------------------------------ 洗回信

func _test_clean_ai() -> void:
	print("\n[3] 洗模型回信")
	_eq(Diary.clean_ai_text("日记：今天被摸了摸头。"), "今天被摸了摸头。", "去掉「日记：」前缀")
	_eq(Diary.clean_ai_text("\"今天挺好的。\""), "今天挺好的。", "去掉包裹的英文引号")
	_eq(Diary.clean_ai_text("「今天挺好的。」"), "今天挺好的。", "去掉包裹的中文引号")
	_eq(Diary.clean_ai_text("（这段是说明）\n今天被摸了头。"), "今天被摸了头。", "丢掉整行的括号说明")
	_eq(Diary.clean_ai_text("   \n  "), "", "全空白 → 空串")
	_eq(Diary.clean_ai_text("今天很好。\n\n他给我喂了东西。"), "今天很好。\n他给我喂了东西。",
		"多行保留、空行丢掉")

# ------------------------------------------------------------------ 连续天数

func _test_streak() -> void:
	print("\n[4] 连续天数")
	var days := [
		{"date": "2026-10-09", "beats": [], "text": "a"},
		{"date": "2026-10-08", "beats": [], "text": "b"},
		{"date": "2026-10-07", "beats": [], "text": "c"},
		{"date": "2026-10-05", "beats": [], "text": "d"},   # 中间缺 10-06
	]
	_eq(Diary.streak_of(days, "2026-10-09"), 3, "连着三天 → 3")
	_eq(Diary.streak_of(days, "2026-10-10"), 3, "今天没记录 → 从昨天起算，仍是 3")
	# 注意这条的语义：查的这天没记录时，会**往前看一天**（"今天还没写不等于断了"）。
	# 10-06 缺、但 10-05 有 → 1；这不是 bug，是刻意的
	_eq(Diary.streak_of(days, "2026-10-06"), 1, "这天缺、但前一天有 → 1（今天还没记不算断）")
	# 前后两天都没有 → 真的断了
	_eq(Diary.streak_of(days, "2026-10-04"), 0, "这天和前一天都没有 → 0")
	_eq(Diary.streak_of([], "2026-10-09"), 0, "空列表 → 0")
	# 跨月
	var across := [{"date": "2026-11-01", "beats": [], "text": "a"},
		{"date": "2026-10-31", "beats": [], "text": "b"}]
	_eq(Diary.streak_of(across, "2026-11-01"), 2, "跨月连续 → 2")

# ------------------------------------------------------------------ 日期

func _test_dates() -> void:
	print("\n[5] 日期换算")
	_eq(Diary._shift_day("2026-10-09", -1), "2026-10-08", "往前一天")
	_eq(Diary._shift_day("2026-10-01", -1), "2026-09-30", "跨月往前")
	_eq(Diary._shift_day("2026-01-01", -1), "2025-12-31", "跨年往前")
	_eq(Diary._shift_day("2026-03-01", -1), "2026-02-28", "跨月（平年 2 月）")
	_eq(Diary._shift_day("乱七八糟", -1), "乱七八糟", "非法日期原样返回（不崩）")
	_eq(DiaryFlow.is_new_day("", "2026-10-09"), true, "从没记过 → 算新的一天")
	_eq(DiaryFlow.is_new_day("2026-10-09", "2026-10-09"), false, "同一天 → 不是新的一天")
	_eq(DiaryFlow.is_new_day("2026-10-08", "2026-10-09"), true, "换了天 → 是新的一天")
	# 「该不该写」的判据
	_eq(DiaryFlow.want_write(3, 3, false), true, "攒够 3 条、还没写 → 该写")
	_eq(DiaryFlow.want_write(2, 3, false), false, "只有 2 条 → 还不够")
	_eq(DiaryFlow.want_write(5, 3, true), false, "已经写过 → 不再写")

# ------------------------------------------------------------------ 存盘读回

func _test_store_roundtrip() -> void:
	print("\n[6] 存盘 / 读回")
	var host := Node.new()
	var a := Diary.new()
	a.setup(host)
	a.note("pet")
	a.note("feed")
	var t: String = a.write_today()
	_ok(t != "", "write_today() 写出了正文")
	_ok(not a.needs_write(), "写完就不需要再写了")
	a.set_today_ai("今天被摸了摸头，还吃了点东西。")
	_eq(a.today_text(), "今天被摸了摸头，还吃了点东西。", "模型那版覆盖了本地版")
	a.save()

	# 换一个实例读回来
	var b := Diary.new()
	b.setup(host)
	b.load()
	_eq(b.today_text(), "今天被摸了摸头，还吃了点东西。", "读回：正文一致")
	_eq(b.total_pets, 1, "读回：累计被摸次数一致")
	_eq(b.first_day, a.first_day, "读回：first_day 一致")
	var items: Array = b.entries()
	_eq(items.size(), 1, "entries() 只给有正文的那天")
	_eq(int(items[0]["beats"]), 2, "entries() 带上拍子数")
	_ok(bool(items[0]["ai"]), "entries() 标了「她写的」")

	# 空串不该覆盖
	_ok(not b.set_today_ai("   "), "空回信被拒（不会把日记洗成空的）")

	# 脏文件不该让界面崩
	var f := FileAccess.open(Diary.SAVE_PATH, FileAccess.WRITE)
	f.store_string("{\"days\": \"这不是数组\", \"total_pets\": \"这不是数字\"}")
	f.close()
	var c := Diary.new()
	c.setup(host)
	c.load()          # 不抛异常就算过
	_ok(true, "文件被改坏时 load() 不崩")
	a.clear_all()
	_eq(a.days.size(), 0, "clear_all() 清空")
	host.free()

# ------------------------------------------------------------------ 素材

func _test_material() -> void:
	print("\n[7] 给模型的素材")
	var m: String = DiaryPrompt.material_of(["pet", "pet", "pet", "feed"], "开心 60% / 生气 40%",
		{"total_pets": 12, "total_talks": 30})
	_ok(m.contains("被摸了摸头"), "素材里有那句拍子文案")
	_ok(m.contains("好几次"), "同一拍子出现 3 次 → 标了「好几次」")
	_ok(m.contains("开心 60%"), "素材带上当时的心情")
	_ok(m.contains("不要写进日记"), "累计数明确要求模型别写出来")
	# 空拍子 → 空串
	_eq(DiaryPrompt.material_of([]), "", "没有拍子 → 空素材")
	# 拼出来的提示词必须包含那条死命令（不许编）
	var p: String = DiaryPrompt.build(m)
	_ok(p.contains("一个字都不许编"), "提示词带「不许编」这条硬约束")
	_ok(p.contains("别报数字"), "提示词带「别报数字」")
	# 素材为空时也要给一句兜底，不能留空 %s
	var p2: String = DiaryPrompt.build("")
	_ok(p2.contains("没发生什么特别的事"), "空素材有兜底文案")
	# 占位符只能有一个 %s（多一个就会在 build 时抛）
	_ok(p2.count("<不超过 8 个字>") == 1, "提示词里标题格式只出现一次")

# ------------------------------------------------------------------ 标题（T5）

func _test_split_title() -> void:
	print("\n[8] 日记标题：拆模型回信")
	var a: Dictionary = DiaryPrompt.split_title("标题：被摸头的一天\n今天被摸了摸头，很舒服。")
	_eq(String(a["title"]), "被摸头的一天", "拆出「标题：」那行")
	_eq(String(a["body"]), "今天被摸了摸头，很舒服。", "正文是第二行")
	# 模型没照格式写 → 整段当正文，**不能丢**
	var b: Dictionary = DiaryPrompt.split_title("今天被摸了摸头。")
	_eq(String(b["title"]), "", "没有标题行 → 标题为空")
	_eq(String(b["body"]), "今天被摸了摸头。", "没有标题行 → 整段都当正文")
	# 标题带引号 / 末尾标点 → 洗掉
	var c: Dictionary = DiaryPrompt.split_title("标题：「被摸头的一天。」\n正文在这。")
	_eq(String(c["title"]), "被摸头的一天", "标题去引号去尾巴标点")
	# 标题太长（说明它把正文写进标题了）→ 丢掉标题，正文照收
	var d: Dictionary = DiaryPrompt.split_title("标题：今天被主人摸了摸头然后还吃了东西感觉挺开心的\n正文。")
	_eq(String(d["title"]), "", "标题过长 → 当没有")
	_eq(String(d["body"]), "正文。", "标题过长时正文仍然保留")
	# 正文里出现"标题："不该被当标题（只认第一行）
	var e: Dictionary = DiaryPrompt.split_title("今天还行。\n标题：这句是正文里的")
	_eq(String(e["title"]), "", "只认第一行的标题标记")
	_ok(String(e["body"]).contains("标题："), "正文里的「标题：」原样留在正文里")

	# 本地兜底标题：和 summarize 的开场同一优先级
	_eq(Diary.title_of(["ignored", "soothe"]), "闹别扭又和好了", "本地标题：别扭+和好")
	_eq(Diary.title_of(["pet"]), "被摸了摸头", "本地标题：被摸")
	_eq(Diary.title_of([]), "平常的一天", "本地标题：空拍子有兜底")

	# set_today_ai 收标题；不传标题时用本地兜底
	var host := Node.new()
	var g := Diary.new()
	g.setup(host)
	g.note("pet")
	g.write_today()
	_ok(g.today_title() != "", "本地那版也有标题")
	g.set_today_ai("今天很安静。", "安静的一天")
	_eq(g.today_title(), "安静的一天", "模型给的标题覆盖本地兜底")
	host.free()

# ------------------------------------------------------------------ 关系感知（T1）

func _test_relation() -> void:
	print("\n[9] 关系感知：给提示词的那段话")
	var host := Node.new()
	var d := Diary.new()
	d.setup(host)
	# 头一天、第一次打开、还没聊 → 什么都不说（别让她对着空白编）
	_eq(d.relation_text({}, 3), "", "第一次、没聊过 → 空串（不拼进提示词）")
	# 摆出"认识 5 天、连着 3 天"
	var t := Diary.day_stamp()
	d.first_day = Diary._shift_day(t, -4)      # 5 天前
	d.days = [
		{"date": t, "beats": [], "title": "", "text": "x", "ai": false, "n": {}},
		{"date": Diary._shift_day(t, -1), "beats": [], "title": "", "text": "x", "ai": false, "n": {}},
		{"date": Diary._shift_day(t, -2), "beats": [], "title": "", "text": "x", "ai": false, "n": {}},
	]
	var r1: String = d.relation_text({}, 3)
	_ok(r1.contains("认识主人 5 天"), "拼出「认识 N 天」")
	_ok(r1.contains("连着 3 天"), "拼出「连着 N 天」")
	_ok(r1.contains("工作日"), "周四（wk=4）→ 工作日")
	_ok(r1.contains("别报数字"), "带「别报数字」的约束（关键，防她念数字）")
	# 周末
	var r2: String = d.relation_text({}, 0)
	_ok(r2.contains("周末"), "周日（wk=0）→ 周末")
	# 见面次数 / 今天聊了几轮
	var r3: String = d.relation_text({"sessions_total": 30, "sessions_today": 3, "chats_today": 5}, 3)
	_ok(r3.contains("今天是他第 3 次打开你"), "今天第几次打开（今天 ≥2 用今天的数）")
	_ok(r3.contains("今天你们已经聊了 5 轮"), "今天聊了几轮")
	var r4: String = d.relation_text({"sessions_total": 30, "sessions_today": 1, "chats_today": 0}, 3)
	_ok(r4.contains("这是他第 30 次打开你"), "今天只开了一次 → 用累计数")
	_ok(not r4.contains("已经聊了"), "没聊够 3 轮就不提聊了几轮")
	host.free()
