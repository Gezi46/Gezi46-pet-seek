# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends RefCounted
## 让桌宠把活交给本机的 **DeepSeek Harness（dsh）** 去干 —— 包括**给她自己升级**。
##
## dsh 是什么：`@deepseek-ai/dsh`，一个装在 npm 缓存里的 agent harness，
## 平时双击 `DeepSeekHarnessLauncher` 会用 `node bin.js web` 起个 Web UI（127.0.0.1:3080）。
## 但我们要用的不是那个界面，而是它的**一次性任务模式**：
##
##     dsh --profile headless "任务文本"
##
## 跑一个全新会话、把最终答案打到 **stdout**、退出。官方原话："不开端口、不留后台，
## 适合脚本、CI 与一次性任务"，退出码 0 = 完成、1 = 出错。实测一句话的小任务 4~6 秒。
##
## 为什么走命令行、而不是 HTTP 去调它那个 Web 服务：
##   1. 一次性模式本来就是给"脚本化"用的（stdout 即答案、退出码即成败），
##      比去猜它家前端的接口稳得多 —— 那套接口是给自家 UI 用的，没有对外契约；
##   2. 不管 3080 那个服务在不在跑都能用；
##   3. 不用管它 Web 那边的登录态、会话列表。
##
## 两件事只能在"设置层"改（headless 都没有对应命令行参数，官方 README 注明它们
## "刻意不是配置字段"，真源是 `$DSH_HOME/settings.yaml`）：
##
##   `agent-default-model.reasoningEffort`  推理档：off / low / high / max
##   `permission.defaultPreset`             文件权限：read-only / workspace-write / danger-full-access
##
## 所以每次跑之前会**临时改这两项、跑完原样写回** —— 那套（含备份/还原/只动一行）
## 在 scripts/pet_dsh_settings.gd 里，本文件只留下 `_swap_settings` / `_swap_back` 两个壳。
## 权限那一项是"给她自己升级"的关键：`workspace-write` 只允许改**工作目录里**的东西，
## 而工作目录由我们指定 = 她的项目目录 —— 也就是说她改不到别处去。
## （`danger-full-access` 故意不提供：那等于把整台机器交出去，自我升级用不着。）
##
## 两处"不得不绕"的地方，都记在这儿：
##
##   1) **多一个 node 转发器**（RUNNER_SOURCE，运行时写到 user://）。
##      直接用 OS.execute 收 dsh 的 stdout 会**中文乱码** —— 实测 "1 加 1 等于 2。"
##      回来是 "1 鍔?1 绛変簬 2銆?：Godot 在 Windows 上按系统 ANSI 代码页解码子进程
##      输出，而 dsh（node）写的是 UTF-8；错的不只是显示，有些字节直接变成 '?'，
##      也就是说**不可逆**、事后救不回来。
##      （顺带说明：任务文本传过去是好的 —— Godot 拼命令行走 CreateProcessW，
##        中文没问题，坏的只有"回收输出"这一段。）
##      所以让 node 帮忙转发：把 dsh 的 stdout/stderr 用**文件描述符**接走（原始字节，
##      一个字节都不动），我们再按 UTF-8 读文件。顺带还能拿到 stderr = 它的推理流。
##
##   2) **工作线程**。OS.execute 要等到子进程结束（一次五秒起，自我升级那种活几分钟也正常），
##      在主线程里调就等于把桌宠卡住。所以丢给一个工作线程，主脚本每帧 poll()。
##      线程里只写几个字段（bool / String / int），不碰场景树、不发信号，跑完 join。

## 用哪个 profile。headless = 一次性任务（见文件头）
const PROFILE := "headless"
## dsh 认的四档推理能力（顺序 = 从省到费）
const EFFORTS: Array[String] = ["off", "low", "high", "max"]
## 设置文件那套（读一个键 / 改一个键 / 备份还原）在 **pet_dsh_settings.gd** —— 作业单 B2.1。
## 它是全项目唯一动到项目**外面**文件的地方（$DSH_HOME/settings.yaml），所以单独一个文件
const DshSettings := preload("res://scripts/sys/pet_dsh_settings.gd")
## 段名 / 键名：**真源在 pet_dsh_settings.gd**，这里只是别名（探针仍旧写 PetHarness.XXX）
const SETTINGS_SECTION := DshSettings.SETTINGS_SECTION
const SETTINGS_KEY := DshSettings.SETTINGS_KEY
const PERMISSION_SECTION := DshSettings.PERMISSION_SECTION
const PRESET_KEY := DshSettings.PRESET_KEY
## "允许她改文件"时换成的权限档：只能动工作目录里的东西
const PRESET_WRITE := DshSettings.PRESET_WRITE

## 转发器脚本落在这儿（运行时写出来，内容没变就不重写）。
## 和 pet_shell.gd 那套一样：PowerShell / node 要的是**真实文件路径**，
## 而导出版里 res:// 下不是资源的东西压根不进包、进了包也拿不到路径
const RUNNER_FILE := "user://pet_harness_runner.js"
## 一次跑用的文件名前缀：转发器会把 dsh 的 stdout / stderr 写成 `<前缀>.out` 和 `<前缀>.err`。
## **传给它的是前缀，读回来的是带后缀的名字** —— 这两头写岔了会"退出码 0 但答案空"，
## 而且看起来像"dsh 没答"，实际是答案写在了别的文件名里（踩过一次）
const RUN_BASE := "user://pet_harness"
## dsh 的答案（UTF-8，原始字节）
const OUT_FILE := RUN_BASE + ".out"
## dsh 的 stderr（推理流 + 出错信息）
const ERR_FILE := RUN_BASE + ".err"

## 转发器源码。**这里不要出现中文**：PowerShell 5.1 那条坑在 node 上不存在
## （node 读 .js 一律按 UTF-8），但保持纯 ASCII 省得日后有人拿它去别的 shell 跑。
## 它的全部工作：把 dsh 的 stdout / stderr 按原始字节接到两个文件上，在指定的工作目录里
## 跑 dsh，然后把 dsh 的退出码原样传出去。
## （argv: 1=bin.js 2=任务文本 3=输出前缀 4=工作目录，空串 = 继承当前目录）
const RUNNER_SOURCE := """// dsh runner: hand dsh's stdout/stderr to files as raw bytes (no re-encoding).
// Why: Godot's OS.execute decodes child output with the system ANSI codepage on
// Windows, while node writes UTF-8 -> Chinese comes back as mojibake, and some
// bytes turn into '?' which is not reversible. Passing the task IN as an argv is
// fine (Godot builds the command line itself); only reading the output back is.
const fs = require("fs");
const { spawn } = require("child_process");
const bin = process.argv[2];
const task = process.argv[3];
const outBase = process.argv[4];
const cwd = process.argv[5];
const out = fs.openSync(outBase + ".out", "w");
const err = fs.openSync(outBase + ".err", "w");
const opts = { stdio: ["ignore", out, err] };
// The directory dsh runs in IS the workspace root it may touch - so this is
// what keeps a "workspace-write" run inside the project folder.
if (cwd) opts.cwd = cwd;
const p = spawn(process.execPath, [bin, "--profile", "headless", task], opts);
p.on("error", (e) => {
  try { fs.writeSync(err, "spawn failed: " + e.message); } catch (_) {}
  process.exit(1);
});
p.on("close", (code) => {
  try { fs.closeSync(out); fs.closeSync(err); } catch (_) {}
  process.exit(code === null ? 1 : code);
});
"""

## 重活关键词：出现一个 +1.2 分
const HEAVY_WORDS: Array[String] = [
	"分析", "为什么", "设计", "方案", "实现", "重构", "调试", "排查", "对比", "评估",
	"优化", "算法", "总结", "报告", "步骤", "计划", "证明", "推导", "代码", "测试",
]
## 轻活关键词：出现一个 -0.8 分（"查一下""一句话"这种不该让她开思考）
const LIGHT_WORDS: Array[String] = [
	"查一下", "一句话", "简单", "翻译", "告诉我", "是什么", "念一下", "复述", "直接说",
]
## 要拆成好几件事的说法：出现一个 +0.7 分
const MULTI_WORDS: Array[String] = ["\n", "；", ";", "然后", "另外", "并且", "接着", "同时"]

# ------------------------------------------------------------------ 状态

## 能不能用（node 和 dsh 入口都找到了）
var available := false
## 不能用时的原因，给菜单 / 设置面板显示
var last_error := ""
## 正忙（一次只跑一个任务）
var busy := false
## 这次跑用的工作目录 / 允许改文件（日志和界面显示用）
var last_workspace := ""
var last_allow_write := false
## 任务回来时发。answer 是 dsh 的最终答案（UTF-8 读回来的原文）
signal finished(task: String, answer: String, ok: bool, effort: String)
## 起不来 / 找不到 dsh
signal failed(msg: String)

var node_exe := ""
var bin_js := ""
## 上次跑的 stderr（出错时给主人看，或者看它到底想了些什么）
var last_stderr := ""
## 上次的答案（探针 / 日志用）
var last_answer := ""
## 上次的退出码
var last_code := -1

var _task := ""
var _effort := ""
var _ok := false
## 改设置前的整份设置文件（跑完原样写回去）
## 改 dsh 设置那个对象（备份 / 还原都在它肚子里，见 pet_dsh_settings.gd）
var _dsh := DshSettings.new()
var _started_ms := 0
## 超过这个时间还没回来就提示一次（只提示，不强杀）
const SLOW_SEC := 180.0
## 一趟活最多等多久（秒）。超过就放弃等待：聊天解锁、设置文件还原，
## dsh 那个进程随它去 —— **杀不掉**（OS.execute 拿不到 pid），只能不等它。
## 真卡住通常是它在等一个没人能回答的确认（headless 没有界面可以点头）
var timeout_sec: float = 600.0
var _slow_warned := false
## 放弃等待的线程攥在这儿不释放：Thread 活着就被释放 Godot 会报警，
## join 又会把退出卡住 —— 让它自己跑完（dsh 是一次性进程），结果不再看
var _abandoned: Array = []

var _thread: Thread = null
var _runner_path := ""


func setup() -> void:
	node_exe = find_node()
	bin_js = find_bin_js()
	available = node_exe != "" and bin_js != ""
	if not available:
		last_error = "找不到 DeepSeek Harness（%s）。双击一下 DeepSeekHarnessLauncher 让它自己装一次" % (
			"没找到 node" if node_exe == "" else "没找到 @deepseek-ai/dsh 的 bin.js")

# ------------------------------------------------------------------ 找 dsh

## node 的可执行文件。
## 先看标准安装位置，找不到就返回 "node" —— OS.execute 走 CreateProcess，
## 它自己会按 PATH 搜，所以名字能直接用
static func find_node() -> String:
	var pf := OS.get_environment("ProgramFiles")
	if pf != "":
		var p := pf.path_join("nodejs/node.exe")
		if FileAccess.file_exists(p):
			return p
	return "node"

## dsh 的入口 bin.js。
## **不能写死 npx 缓存里那个哈希目录名**（官方启动器写死了，那是它脆弱的地方）——
## 换个版本、重装一次，哈希就变了。这里扫 _npx 下所有目录，取**修改时间最新**的那份，
## 再退回 npm 全局安装（顺序和官方启动器一致：npx 缓存 → 全局）
static func find_bin_js() -> String:
	var local := OS.get_environment("LOCALAPPDATA")
	if local != "":
		var npx := local.path_join("npm-cache").path_join("_npx")
		var best := ""
		var best_t := 0
		var d := DirAccess.open(npx)
		if d != null:
			d.list_dir_begin()
			var name := d.get_next()
			while name != "":
				if d.current_is_dir():
					var cand := npx.path_join(name).path_join(
						"node_modules/@deepseek-ai/dsh/lib/bin.js")
					if FileAccess.file_exists(cand):
						var t := int(FileAccess.get_modified_time(cand))
						if t > best_t:
							best_t = t
							best = cand
				name = d.get_next()
			d.list_dir_end()
		if best != "":
			return best
	var appdata := OS.get_environment("APPDATA")
	if appdata != "":
		var g := appdata.path_join("npm/node_modules/@deepseek-ai/dsh/lib/bin.js")
		if FileAccess.file_exists(g):
			return g
	return ""

# ------------------------------------------------------------------ 按工作量配推理

static func estimate_effort(task: String) -> String:
	var s := effort_score(task)
	if s < 1.0:
		return "off"
	if s < 2.5:
		return "low"
	if s < 5.0:
		return "high"
	return "max"

## 给任务打个"多累"的分。写得**故意粗**：判错一档代价很小（多花几分钱，或者想浅一点），
## 而几个维度各加多少分是可以照着自己调的。想换算法就改这一个函数。
static func effort_score(task: String) -> float:
	var t := task.strip_edges()
	if t == "":
		return 0.0
	var s := 0.0
	# 1) 长度：40 字算 1 分，最多记 2.5（再长也不代表更难）
	s += minf(float(t.length()) / 40.0, 2.5)
	# 2) 要拆成好几件事（换行 / 分号 / "然后""另外"）
	s += minf(float(count_any(t, MULTI_WORDS)), 3.0) * 0.7
	# 3) 重活关键词
	s += minf(float(count_any(t, HEAVY_WORDS)), 4.0) * 1.2
	# 4) 轻活关键词（减分）
	s -= minf(float(count_any(t, LIGHT_WORDS)), 3.0) * 0.8
	# 5) 兜底：带了重活关键词的至少给 low。
	#    不然"用一句话说明为什么天空是蓝色的"会被"一句话"扣成 off ——
	#    可它问的是"为什么"，这种题不想一下就答，答出来也是背课文
	if count_any(t, HEAVY_WORDS) > 0:
		s = maxf(s, 1.0)
	return maxf(0.0, s)

## 按"最高档"封顶：设置里那个档是天花板，估出来的档不许越过去。
## 为什么要有这一层：估分是粗的，而 max 一档花得明显多 —— 想让钱包有上限的人
## 只要把天花板压到 low，之后不管任务多大都不会超过 low
static func clamp_effort(effort: String, ceiling: String) -> String:
	var i := EFFORTS.find(effort)
	var c := EFFORTS.find(ceiling)
	if i < 0:
		return ceiling if c >= 0 else "high"     # 估出来的东西不认识就听天花板的
	if c < 0:
		return effort                            # 天花板不认识就不封顶
	return effort if i <= c else ceiling

## t 里出现了 words 中几个（一个词只算一次，避免"分析分析分析"刷分）
static func count_any(t: String, words: Array[String]) -> int:
	var n := 0
	for w in words:
		if t.find(w) >= 0:
			n += 1
	return n

# ------------------------------------------------------------------ 设置文件（改档用）

## 这一层（找 dsh 家目录 / 读一个键 / 改一个键 / 缩进处理）全在 **pet_dsh_settings.gd**
## —— 作业单 B2.1 搬的（理由见那边文件头：那是唯一动项目外文件的地方）。
## 下面留这些壳，是因为探针一直写 `PetHarness.XXX`（tools/probe_harness.gd），
## 而且 desktop_pet / 设置面板也都在用
static func dsh_home() -> String:
	return DshSettings.home()

static func settings_path() -> String:
	return DshSettings.path()

static func read_setting(text: String, key: String) -> String:
	return DshSettings.read_setting(text, key)

static func read_effort(text: String) -> String:
	return DshSettings.read_effort(text)

static func with_setting(text: String, section: String, key: String, value: String) -> String:
	return DshSettings.with_setting(text, section, key, value)

static func with_effort(text: String, value: String) -> String:
	return DshSettings.with_effort(text, value)

static func leading_ws(s: String) -> String:
	return DshSettings.leading_ws(s)

# ------------------------------------------------------------------ 干活

## 把任务交给 dsh。返回 false = 没跑起来（原因在 last_error / failed 信号里）。
##
## ceiling      设置里那个"最高推理档"，空串 = 不封顶
## workspace    在哪个目录里干（= dsh 的 workspace 根目录）。空串 = 继承当前目录
## allow_write  允许它改文件（只限 workspace 里），见文件头
func run(task: String, ceiling: String = "", workspace: String = "",
		allow_write: bool = false) -> bool:
	if busy:
		return false
	if not available:
		setup()
	if not available:
		failed.emit(last_error)
		return false
	_task = task.strip_edges()
	if _task == "":
		last_error = "任务是空的"
		failed.emit(last_error)
		return false
	var runner := _ensure_runner()
	if runner == "":
		failed.emit(last_error)
		return false
	_effort = clamp_effort(estimate_effort(_task), ceiling)
	last_workspace = workspace
	last_allow_write = allow_write
	last_answer = ""
	last_stderr = ""
	last_code = -1
	_ok = false
	_slow_warned = false
	_clear_outputs()
	_swap_settings(_effort, allow_write)
	busy = true
	_started_ms = Time.get_ticks_msec()
	# 传前缀（不带后缀）：转发器自己拼 .out / .err，和我们读的那两个名字对上
	var base := ProjectSettings.globalize_path(RUN_BASE)
	_thread = Thread.new()
	_thread.start(_worker.bind(node_exe, PackedStringArray([
		runner, bin_js, _task, base, workspace])))
	return true

## 线程体。**只能写字段，不能碰场景树、不发信号**（不在主线程上）
func _worker(exe: String, args: PackedStringArray) -> void:
	var out: Array = []
	# 转发器不往自己的 stdout 写东西（都进了文件），所以这里收不收都无所谓 ——
	# read_stderr = false 免得把它的杂音当答案
	last_code = OS.execute(exe, args, out, false)

## 每帧调。任务回来就收尾（读答案、把设置改回去、发信号）
func poll() -> void:
	if not busy:
		return
	if _thread != null and _thread.is_started():
		if _thread.is_alive():
			# 超过 SLOW_SEC 只提示一次：dsh 可能在等一个很慢的工具调用，
			# 也可能真卡住了。不强杀 —— 杀子进程得先有 pid，而 OS.execute 不给
			if not _slow_warned and elapsed_sec() > SLOW_SEC:
				_slow_warned = true
			# 超过 timeout_sec 就放弃等待 —— **没有这步的话，一次卡死的活会把
			# busy 永远钉在 true 上，聊天从此只剩"我还在弄那件活呢"**
			if elapsed_sec() > timeout_sec:
				_abandon()
			return
		_thread.wait_to_finish()
		_thread = null
	busy = false
	_swap_back()
	last_answer = read_text_file(ProjectSettings.globalize_path(OUT_FILE)).strip_edges()
	last_stderr = read_text_file(ProjectSettings.globalize_path(ERR_FILE)).strip_edges()
	_ok = last_code == 0 and last_answer != ""
	if not _ok and last_error == "":
		last_error = "dsh 回来了但没给答案（退出码 %d）%s" % [
			last_code, "" if last_stderr == "" else "：" + last_stderr.substr(0, 300)]
	finished.emit(_task, last_answer, _ok, _effort)

func elapsed_sec() -> float:
	return (Time.get_ticks_msec() - _started_ms) / 1000.0

## 放弃等待一个卡死的任务：busy 解锁、设置文件还原、发 failed。
## 结果**不看了** —— 放弃的那一刻它就已经迟到了，真跑完了也是过期答案
func _abandon() -> void:
	if _thread != null:
		_abandoned.clear()
		_abandoned.append(_thread)   # 只留最近一个，别让它被释放
	_thread = null
	busy = false
	_swap_back()
	last_code = -1
	last_answer = ""
	last_error = "等了 %d 秒还没回来，放弃等待（dsh 进程随它去，跑完自己退）" % int(elapsed_sec())
	_slow_warned = false
	failed.emit(last_error)

func is_slow() -> bool:
	return busy and _slow_warned

## 退出的收尾。**故意不 join**：正跑着的任务顶多再花几秒（自我升级那种可能几分钟，
## 但它是一次性进程，跑完自己退，不会留后台）；强行 join 会把退出卡住。
## 但设置文件必须还原 —— 那个不能留给"下次启动再说"
## （"没动过文件就别写"这件事由 _dsh 自己判断，见 pet_dsh_settings.gd 的 swap_back）
func shutdown() -> void:
	_swap_back()

## 把转发器写出来（内容没变就不重写），返回它的真实路径
func _ensure_runner() -> String:
	if _runner_path != "" and FileAccess.file_exists(_runner_path):
		return _runner_path
	var path := ProjectSettings.globalize_path(RUNNER_FILE)
	if not FileAccess.file_exists(path) or FileAccess.get_file_as_string(path) != RUNNER_SOURCE:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			last_error = "写不出转发器脚本：%s" % path
			return ""
		f.store_string(RUNNER_SOURCE)
		f.close()
	_runner_path = path
	return path

## 跑之前把上一轮的输出清掉：**必须先删**，否则跑失败时我们会把上一次的答案
## 当成这一次的（"她答非所问"里最难查的一种）
func _clear_outputs() -> void:
	for p in [OUT_FILE, ERR_FILE]:
		var real := ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(real):
			DirAccess.remove_absolute(real)

static func read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()      # get_as_text 按 UTF-8 解 —— 正好是转发器写下的原始字节
	f.close()
	return t

# ------------------------------------------------------------------ 改设置 / 还原

## 改档 / 还原那套都在 **pet_dsh_settings.gd** 的 `swap()` / `swap_back()` 里（作业单 B2.1）。
## 这两个壳只做一件事：把"读不到 / 写不了"的说明挂到本对象的 last_error 上 ——
## 那边不该知道"桌宠怎么报错"，但界面得看得到原因
func _swap_settings(effort: String, allow_write: bool) -> void:
	var err := _dsh.swap(effort, allow_write)
	if err != "":
		last_error = err

## 把设置原样写回去（原样 = 整份，不做任何"顺手整理"）
func _swap_back() -> void:
	var err := _dsh.swap_back()
	if err != "":
		last_error = err

## 当前设置里的推理档（日志和探针用；读不到返回空串）
func current_effort() -> String:
	return read_effort(read_text_file(settings_path()))

## 当前设置里的文件权限档（同上）
func current_preset() -> String:
	return read_setting(read_text_file(settings_path()), PRESET_KEY)
