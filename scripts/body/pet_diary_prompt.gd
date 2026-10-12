extends RefCounted
## 日记的**提示词进出口**：把"这天发生了什么"拼成让模型写一段日记的请求，以及把回信洗干净。
##
## 为什么单独一个文件（而不是塞进 pet_diary.gd）：
##   `pet_diary.gd` 是**数据与判定**（拍子 / 合成本地正文 / 连续天数），能离线单测；
##   这里是**和模型打交道的那一面**（提示词长什么样、回信怎么洗）。
##   两边改动的原因完全不同 —— 调口气不该动存档格式，改存档不该动提示词。
##   （和 `pet_memory.gd` / `pet_memory_prompt.gd` 是同一个分法）
##
## ── 两条硬约束（写这段提示词前先看）─────────────────────────────────────
## 1. **只能写素材里真有的事**。模型很容易"为了写得好看"编一件事出来
##    （"今天他带我去看了海"），而这篇是**给你看的**、你还记得那天干了什么 ——
##    编出来的东西一眼就穿帮，比写得平淡糟得多。所以提示词末尾那条约束是死命令。
## 2. **别报数字**。素材里有"被摸过 137 次"这种累计数，模型会忍不住写进日记里
##    （"今天被摸了第 137 次"），那就不像人话了。
##
## 它自己**不建客户端、不发请求** —— 发请求那一步在 `pet_diary_flow.gd`（要 tick、
## 要认领迟到的回复），这里只出提示词和洗回信，所以能离线验。

## 让模型写日记时的系统提示词。
## **短**：日记的口气主要由正文的素材和约束定，系统提示词写长了反而会把它拉成"作文腔"
const SYS := "你在写自己的日记。用第一人称、口语、短句，像随手记下来的一句话两句话。"

## 正文提示词。%s = 那天的素材（时间 + 做过的事 + 当时的情绪）。
## %s 用两次 —— format 前先数清楚占位符个数，别加一个忘一个
const PROMPT := """下面是我今天真实发生的事（只有这些，没有别的）：

%s

请你**以我的口吻**写今天的日记。按这个格式，两行：

标题：<不超过 8 个字>
<一到三句话的正文>

对**正文**的要求：
1. 口语，短句。别用书面语、别堆成语、别写"今天真是充实的一天"这种总结句。
2. **只写上面列出来的事，一个字都不许编**。没提到的人、地方、活动都不许出现。
3. 别报数字（不要写"被摸了几次""聊了几轮"），也别写"素材""记录"这种词。
4. 别写"作为一个人工智能"之类的话，你就是我。
5. 不要引号、不要任何解释。

对**标题**的要求：像日记本上随手写的日期标签（"被摸头的一天"/"他没理我"），
不要写成新闻标题，也别带标点。"""

## 拼出正文提示词。material = 素材文本（由 `material_of` 生成或宿主自己拼）
static func build(material: String) -> String:
	var m := material.strip_edges()
	if m == "":
		m = "（今天没发生什么特别的事）"
	return PROMPT % m

## 把模型回信拆成 {title, body}。
##
## 格式是"标题：xxx"换行"正文"，但**模型不一定照做**，所以：
##   - 第一行以「标题：」/「标题:」开头 → 取出来当标题，剩下的当正文
##   - 否则 title 为空、整段当正文（**绝不因此丢掉正文** —— 那才是主体）
## 抽成 static 是为了能离线验（探针里试各种畸形回信）
static func split_title(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	var title := ""
	var body := text
	# 只认**第一行**：正文里出现"标题："字样不该被当成标题
	var nl := text.find("\n")
	var first := text if nl < 0 else text.substr(0, nl)
	var rest := "" if nl < 0 else text.substr(nl + 1)
	for tag in ["标题：", "标题:", "**标题**：", "**标题**："]:
		if first.begins_with(tag):
			title = first.substr(tag.length()).strip_edges()
			body = rest.strip_edges()
			break
	# 标题自身也洗一下（模型爱加引号 / 书名号 / 句号）
	title = _tidy_title(title)
	# 标题空 / 太长 → 当没有（太长说明它把正文写进标题了）
	if title.length() > 16:
		title = ""
	if body == "":
		body = text          # 只有标题没有正文 → 宁可把整段当正文，也别丢内容
	return {"title": title, "body": body}

## 洗标题：去引号、去首尾标点、压成一行
static func _tidy_title(t: String) -> String:
	var s := t.strip_edges().replace("\n", " ")
	while s.length() >= 2:
		var a := s.substr(0, 1)
		var b := s.substr(s.length() - 1, 1)
		if (a == "\"" and b == "\"") or (a == "「" and b == "」") or (a == "“" and b == "”"):
			s = s.substr(1, s.length() - 2).strip_edges()
		else:
			break
	# 末尾的句号 / 逗号 / 冒号都去掉（标题不该带）
	while s.length() > 0:
		var last := s.substr(s.length() - 1, 1)
		if last in ["。", "，", "、", "：", ":", ".", ",", "！", "!"]:
			s = s.substr(0, s.length() - 1).strip_edges()
		else:
			break
	return s

## 把"那天的拍子 + 情绪"拼成素材。
## kinds = 拍子种类列表；mood_text = 当时的情绪（空串 = 平常）；
## counts = 可选的累计数（**只用来给提示词当背景，并要求模型别写出来**）。
##
## 素材写成**人话清单**而不是 JSON：模型对 JSON 素材容易"照着字段翻译"，
## 出来的是报告体；写成一句一句的短句，它才会顺着说下去。
static func material_of(kinds: Array, mood_text: String = "", counts: Dictionary = {}) -> String:
	var api := preload("res://scripts/body/pet_diary.gd")
	var lines: Array[String] = []
	# 同类合并计数（"被摸了摸头"出现 3 次 → "被摸了摸头（好几次）"）
	var tally: Dictionary = {}
	var order: Array[String] = []
	for k in kinds:
		var key := String(k)
		if not tally.has(key):
			order.append(key)
			tally[key] = 0
		tally[key] = int(tally[key]) + 1
	for key in order:
		var n := int(tally[key])
		var text := String(api.BEAT_TEXT.get(key, ""))
		if text == "":
			continue
		if n >= 3:
			lines.append("- " + text + "（这天有好几次）")
		elif n == 2:
			lines.append("- " + text + "（两次）")
		else:
			lines.append("- " + text)
	if lines.is_empty():
		return ""
	if mood_text.strip_edges() != "":
		lines.append("- 她当时的心情：%s" % mood_text.strip_edges())
	# 累计数单独一段，并明确要求别写出去
	var pets := int(counts.get("total_pets", 0))
	var talks := int(counts.get("total_talks", 0))
	if pets > 0 or talks > 0:
		lines.append("")
		lines.append("（背景：认识以来累计被摸 %d 次、聊天 %d 轮。**这些数字只是给你知道个大概，" \
			% [pets, talks] + "绝对不要写进日记里**）")
	return "\n".join(lines)
