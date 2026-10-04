# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 验"让桌宠调用本机 dsh（DeepSeek Harness）干点活"这条链路。
##
## A 段（离线、秒级、不花钱）：按工作量估推理档的打分、改设置文件那两步（纯字符串）、
##   能不能找到 node 和 dsh。
## B 段（真跑一次，花一点点额度）：交一个一句话的任务给 dsh，看答案回不回得来，
##   **并确认设置文件被原样改回去了** —— 那一步是这套设计里唯一会动别人文件的地方，
##   最该盯的就是"改完有没有还原"。
##
## 用法:
##   & $godot --headless --path . --script res://tools/probe_harness.gd -- --offline   # 只跑 A 段
##   & $godot --headless --path . --script res://tools/probe_harness.gd                # 连 B 段一起
##
## 可以 headless（不像 probe_vision 要抓屏幕），但 B 段要能上网、且 dsh 已经装好。
extends SceneTree

const PetHarness := preload("res://scripts/sys/pet_harness.gd")

var _fail := 0
var _harness: PetHarness = null

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	print("")
	print("=== A1. 按工作量估推理档 ===")
	var cases: Array = [
		["现在几点", "off"],
		["跟我说一句话", "off"],
		["帮我查一下今天北京的天气", "off"],
		["把这段话翻译成英文：今天天气不错", "off"],
		["帮我分析一下这段代码为什么报错", "high"],
		["用一句话说明为什么天空是蓝色的", "low"],
		["设计一个登录模块的实现方案，然后写测试，另外评估一下性能", "max"],
	]
	for c in cases:
		var task := String(c[0])
		var want := String(c[1])
		var got := PetHarness.estimate_effort(task)
		_check(got == want, "「%s」→ %s（%.1f 分）" % [task, got, PetHarness.effort_score(task)])

	print("=== A1b. 设置里的「最高档」是天花板 ===")
	_check(PetHarness.clamp_effort("max", "low") == "low", "估到 max、天花板 low → low")
	_check(PetHarness.clamp_effort("low", "max") == "low", "估到 low、天花板 max → 还是 low（不越级）")
	_check(PetHarness.clamp_effort("off", "off") == "off", "天花板就是 off → off")
	_check(PetHarness.clamp_effort("high", "乱写") == "high", "天花板写歪了 → 不封顶，听估的")

	print("=== A1c. 聊天框里那句是不是在派活 ===")
	var pet_script: GDScript = load("res://scripts/desktop_pet.gd")
	_check(String(pet_script.harness_task_of("干活：看看这段代码为什么报错")) == "看看这段代码为什么报错",
		"「干活：…」摘出任务正文")
	_check(String(pet_script.harness_task_of("dsh: 算一下 25*4")) == "算一下 25*4", "「dsh: …」也认")
	_check(String(pet_script.harness_task_of("今天天气不错")) == "",
		"普通聊天不会被误判成派活")

	print("=== A2. 改设置文件：只动那一行，其余原样 ===")
	var sample := "ui-onboarding:\n  welcomeNoticeVersion: 2026-08-13.1\n" \
		+ "permission:\n  defaultPreset: read-only\n" \
		+ "agent-default-model:\n  provider: deepseek-official\n" \
		+ "  model: deepseek-flash\n  reasoningEffort: high\n"
	var swapped := PetHarness.with_effort(sample, "low")
	_check(PetHarness.read_effort(swapped) == "low", "有那个键 → 换成 low")
	_check(swapped.split("\n").size() == sample.split("\n").size(),
		"换值不增删行（%d 行 → %d 行）" % [sample.split("\n").size(), swapped.split("\n").size()])
	_check(swapped.find("ui-onboarding:") >= 0 and swapped.find("defaultPreset: read-only") >= 0
			and swapped.find("model: deepseek-flash") >= 0,
		"别的键一个字没动")
	_check(PetHarness.with_effort(swapped, "low") == swapped, "再改一次同一个值 → 结果不变（幂等）")

	# 键不在、但段在：要补在段里，不能掉到文件末尾（那样就成顶级键了）
	var no_key := "locale:\n  preference: zh\nagent-default-model:\n  provider: deepseek-official\n" \
		+ "  model: deepseek-flash\npermission:\n  defaultPreset: read-only\n"
	var added := PetHarness.with_effort(no_key, "max")
	var idx_sec := added.find("agent-default-model:")
	var idx_key := added.find("reasoningEffort: max")
	var idx_perm := added.find("permission:")
	_check(idx_key > idx_sec and idx_key < idx_perm,
		"键不在时补进了段里（段 %d < 键 %d < 下一段 %d）" % [idx_sec, idx_key, idx_perm])
	_check(added.find("  reasoningEffort: max") >= 0, "补进去的那行缩进照抄同段（两个空格）")

	# 连段都没有：整段补在末尾
	var no_sec := "locale:\n  preference: zh\n"
	var whole := PetHarness.with_effort(no_sec, "high")
	_check(PetHarness.read_effort(whole) == "high" and whole.find("locale:") >= 0,
		"段也不在时整段补上，原内容保留")

	print("=== A2b. 文件权限那一项也是同一个改写函数（只是换了段和键）===")
	var perm := PetHarness.with_setting(sample, PetHarness.PERMISSION_SECTION,
		PetHarness.PRESET_KEY, PetHarness.PRESET_WRITE)
	_check(PetHarness.read_setting(perm, PetHarness.PRESET_KEY) == PetHarness.PRESET_WRITE,
		"permission.defaultPreset → %s" % PetHarness.PRESET_WRITE)
	_check(PetHarness.read_effort(perm) == "high", "改权限**没有**顺手把推理档也改了")
	_check(perm.split("\n").size() == sample.split("\n").size(), "同样不增删行")
	var perm_new := PetHarness.with_setting("locale:\n  preference: zh\n", "permission",
		PetHarness.PRESET_KEY, PetHarness.PRESET_WRITE)
	_check(PetHarness.read_setting(perm_new, PetHarness.PRESET_KEY) == PetHarness.PRESET_WRITE,
		"段不在时也能整段补上（新装 dsh 的 settings.yaml 里没有 permission 段）")

	print("=== A3. 能不能找到 dsh ===")
	var node := PetHarness.find_node()
	var bin := PetHarness.find_bin_js()
	print("  node = %s" % node)
	print("  bin.js = %s" % ("（没找到）" if bin == "" else bin))
	if bin != "":
		print("  版本目录 = %s" % bin.get_base_dir())
	_check(bin != "", "找到了 dsh 的入口 bin.js（没写死 npx 哈希目录，是扫出来的）")

	print("=== A4. 当前设置里的档位 ===")
	_harness = PetHarness.new()
	_harness.setup()
	print("  可用=%s  当前档位=%s" % [_harness.available, _harness.current_effort()])
	_check(_harness.available, "harness 自检：%s" % ("" if _harness.available else _harness.last_error))

	if OS.get_cmdline_user_args().has("--offline"):
		_summary()
		return

	print("=== B. 真跑一个任务（会花一点点额度）===")
	var path := PetHarness.settings_path()
	var before := _read_file(path)
	var task := "用一句话回答：1 加 1 等于几"
	print("  任务：%s" % task)
	var t0 := Time.get_ticks_msec()
	if not _harness.run(task):
		_check(false, "任务没跑起来：%s" % _harness.last_error)
		_summary()
		return
	print("  估出来的档位 = %s（原档位 %s）" % [_harness.current_effort(), PetHarness.read_effort(before)])
	var until := t0 + 300000
	while _harness.busy and Time.get_ticks_msec() < until:
		_harness.poll()
		await process_frame
	_harness.poll()
	var waited := (Time.get_ticks_msec() - t0) / 1000.0
	print("  用时 %.1f 秒" % waited)
	print("  答案：%s" % _harness.last_answer)
	print("  退出码 = %d（0 = 完成）" % _harness.last_code)
	if _harness.last_stderr != "":
		print("  stderr：%s" % _harness.last_stderr.substr(0, 300))
	_check(_harness.last_answer != "", "dsh 给了答案")
	# 中文不乱码是这套"转发器 + 按 UTF-8 读文件"要解决的核心问题，所以专门盯一下：
	# 乱码时里面会出现 鍔 / 绛 / 銆 这类 GBK 解 UTF-8 的典型字
	var bad := _harness.last_answer.find("鍔") >= 0 or _harness.last_answer.find("绛") >= 0 \
		or _harness.last_answer.find("銆") >= 0 or _harness.last_answer.find("?") >= 0
	_check(not bad, "答案里的中文没乱码（原文：%s）" % _harness.last_answer)
	_check(_harness.last_code == 0, "退出码是 0")
	# 最该盯的一条：那一步会动别人文件，改完必须原样还回去
	var after := _read_file(path)
	_check(after == before, "设置文件被原样改回去了（%d 字节 → %d 字节）" % [before.length(), after.length()])

	print("=== B2. 卡死的活会被放弃（busy 解锁，聊天不再被挡）===")
	# 真跑一个任务，但把 timeout 拧到几乎为 0：下一次 poll 就该放弃等待。
	# 这是在模拟"headless 下 dsh 卡死" —— 没有这层的话 busy 会永远 true，
	# 聊天从此只剩"我还在弄那件活呢"
	var before2 := _read_file(path)
	if not _harness.run("用一句话回答：1 加 1 等于几", "max", "", false):
		_check(false, "B2 起不来：%s" % _harness.last_error)
		_summary()
		return
	_harness.timeout_sec = 0.001      # 拧到最小
	await create_timer(0.2).timeout   # 得真等一下：刚 run 完 elapsed 还是 0，不算超时
	_harness.poll()
	_harness.poll()
	_check(not _harness.busy, "超时后 busy 解锁")
	_check(_harness.last_error.find("放弃等待") >= 0, "失败原因说清楚 → %s" % _harness.last_error)
	var after2 := _read_file(path)
	_check(after2 == before2, "放弃等待时设置文件也原样还原了")
	_summary()

func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

func _summary() -> void:
	print("")
	if _fail == 0:
		print("===== 结论：全部通过 =====")
	else:
		print("===== 结论：%d 项没过 =====" % _fail)
	quit(1 if _fail > 0 else 0)

func _check(ok: bool, what: String) -> void:
	if ok:
		print("  [OK]   %s" % what)
	else:
		_fail += 1
		print("  [FAIL] %s" % what)
