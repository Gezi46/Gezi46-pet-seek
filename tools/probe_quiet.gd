# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 验证「全屏检测 → 安静模式」和「减小移动概率」。
##
## 分四段，每段都对着**客观事实**断言，不看"我觉得":
##   A 检测链路真的在跑（后台进程活着、状态文件在更新）
##   B 开一个**真·全屏窗口**，检测要从 0 翻成 1，关掉再翻回 0
##   C 安静模式下她只能在进入那一刻的位置附近一小块里动，而且**不能瞬移**
##   D 移动概率统计（调用 400 次"该起身了"，数多少次真的走）
##
## 用法: --path <项目> --script res://tools/probe_quiet.gd
## 注意：**不要用 --headless**（要真窗口；B 段还会短暂全屏占屏几秒）
extends SceneTree

const STATE_FILE := "user://pet_shell_state.txt"
const FULLSCREEN_SECS := "7"

var _pet: Node = null
var _shell: RefCounted = null

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var packed: PackedScene = load("res://scenes/pet.tscn")
	_pet = packed.instantiate()
	get_root().add_child(_pet)
	for i in 6:
		await process_frame
	_shell = _pet.get("shell")
	if _shell == null:
		print("! pet.shell 没建起来")
		quit(1)
		return
	print("")
	print("环境：%s   move_chance=%.2f  quiet_radius=%.0f  quiet_idle_scale=%.1f" % [
		OS.get_name(), _pet.move_chance, _pet.quiet_radius, _pet.quiet_idle_scale])

	await _part_a()
	await _part_b()
	await _part_c()
	await _part_d()
	await _part_e()

	# 收尾：把伪造的状态清掉、检测进程放回去，别让宠物留在安静模式里
	_write_state("0")
	await _wait(1.0)
	_shell.start_watcher()
	print("")
	print("收尾：状态文件=%s  quiet=%s  检测进程 pid=%s" % [
		_read_state(), _pet._quiet(), _shell.get("_watcher_pid")])
	quit(0)

# ---------------------------------------------------------------- A. 检测链路

func _part_a() -> void:
	print("")
	print("=== A. 检测链路 ===")
	await _wait(1.5)          # 给后台进程一点时间写第一次
	var pid: int = _shell.get("_watcher_pid")
	print("  后台检测进程 pid=%s 活着=%s" % [pid, OS.is_process_running(pid) if pid > 0 else false])
	print("  状态文件内容=「%s」  shell.fullscreen=%s  安静模式=%s" % [
		_read_state(), _shell.fullscreen, _pet._quiet()])
	print("  （现在没开全屏，期望：1/0 里是 0、fullscreen=false）")

# ---------------------------------------------------------------- B. 真全屏窗口

func _part_b() -> void:
	print("")
	print("=== B. 开一个真·全屏窗口（会短暂占屏 %s 秒）===" % FULLSCREEN_SECS)
	var helper: String = _shell.ps1_path()
	OS.create_process(_shell.powershell(), PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", helper, "fakefullscreen", FULLSCREEN_SECS,
	]), false)

	var turned_on: bool = await _wait_until(func() -> bool: return _shell.fullscreen, 6.0)
	print("  %s 检测到全屏：fullscreen=%s 安静模式=%s" % [
		"✅" if turned_on else "❌", _shell.fullscreen, _pet._quiet()])

	# 等那个窗口自己关掉
	var turned_off: bool = await _wait_until(func() -> bool: return not _shell.fullscreen, 14.0)
	print("  %s 它关掉之后：fullscreen=%s 安静模式=%s" % [
		"✅" if turned_off else "❌", _shell.fullscreen, _pet._quiet()])

# ---------------------------------------------------------------- C. 小范围约束

func _part_c() -> void:
	print("")
	print("=== C. 安静模式下的小范围约束 ===")
	# 把检测进程停掉：不然它 800ms 一轮，会把我们伪造的"全屏中"覆盖回去
	_shell.stop_watcher()
	_write_state("1")
	# 读取那一步挂在"辅助进程活着"这个前提上（进程没了就没人维护状态），
	# 所以停掉进程之后得手动催一次读取 —— 直接把文件放那儿是读不到的
	_shell.call("_poll_state")
	await _wait(1.2)
	if not _pet._quiet():
		print("  ❌ 伪造的全屏状态没生效，后面测不了")
		return
	var center: Vector2i = _pet._quiet_center
	var start: Vector2i = DisplayServer.window_get_position()
	print("  进入安静模式：活动中心=%s 当前位置=%s 差=%s（期望几乎为 0 —— 不能瞬移）" % [
		center, start, (start - center).abs()])

	# 让她以远超正常速度往右冲，看能不能冲出这个小框
	_pet._state = _pet.State.WALK
	_pet._move_dir = Vector2.RIGHT
	_pet._speed = 900.0
	_pet._timer = 3.0
	_pet._move_accum = Vector2.ZERO

	var bounds: Rect2i = _pet._quiet_bounds()
	# 先把她放到小框的左上角，再往右下硬冲 —— 否则她可能本来就贴着屏幕边，
	# 一动就被屏幕边界挡住，看着像"没跑起来"，其实是有地方不够
	DisplayServer.window_set_position(bounds.position)
	await process_frame
	start = DisplayServer.window_get_position()
	var minx := start.x
	var maxx := start.x
	var miny := start.y
	var maxy := start.y
	var first_step := 0
	var first_done := false
	var max_step := 0
	var last := start
	var until := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < until:
		# 每帧都压一遍：她自己的状态机（_ensure_walk_anim / _begin_move）会重设速度，
		# 只设一次的话实际还是按正常步速走 —— 那"硬冲"就没测到，属于自欺欺人。
		# 所以这里每帧重设，并且把实测的**单帧最大位移**也打出来，好知道到底有没有冲起来。
		_pet._state = _pet.State.WALK
		_pet._speed = 900.0
		_pet._move_dir = Vector2.RIGHT
		_pet._timer = 9.0
		await process_frame
		var p: Vector2i = DisplayServer.window_get_position()
		var step: int = maxi(absi(p.x - last.x), absi(p.y - last.y))
		max_step = maxi(max_step, step)
		if not first_done and p != start:
			first_step = step
			first_done = true
		last = p
		minx = mini(minx, p.x)
		maxx = maxi(maxx, p.x)
		miny = mini(miny, p.y)
		maxy = maxi(maxy, p.y)

	print("  允许范围（窗口左上角）=%s .. %s" % [bounds.position, bounds.end])
	print("  实测活动范围        = (%d,%d) .. (%d,%d)  全程走了 %dpx" % [
		minx, miny, maxx, maxy, maxi(maxx - minx, maxy - miny)])
	var inside: bool = minx >= bounds.position.x and maxx <= bounds.end.x \
			and miny >= bounds.position.y and maxy <= bounds.end.y
	print("  %s 全程都在框内（她按 900px/s 往右下冲，撞边就折返）" % ("✅" if inside else "❌"))
	print("  %s 没有瞬移：第一次移动只走了 %dpx；实测单帧最大位移 %dpx" % [
		"✅" if first_step < 120 else "❌", first_step, max_step])

# ---------------------------------------------------------------- D. 移动概率

func _part_d() -> void:
	print("")
	print("=== D. 移动概率 ===")
	_write_state("0")
	await _wait(1.2)
	_pet._state = _pet.State.IDLE
	var n := 400
	var walked := 0
	for i in n:
		_pet._state = _pet.State.IDLE
		_pet._timer = 0.0
		_pet.walk._begin_move()
		if _pet._state == _pet.State.WALK:
			walked += 1
		# 每次测完复位，别让上一轮的移动影响下一轮
		_pet._state = _pet.State.IDLE
		_pet._timer = 0.0
	var rate := float(walked) / float(n)
	var expect: float = _pet.move_chance * (1.0 - _pet.emote_chance)
	print("  400 次「待机时间到」里真的起身 = %d 次（%.1f%%）" % [walked, rate * 100.0])
	print("  理论上限 move_chance=%.0f%%，扣掉先去做表情的 %.0f%% 之后约 %.1f%%" % [
		_pet.move_chance * 100.0, _pet.emote_chance * 100.0, expect * 100.0])
	print("  %s 实测和理论对得上（误差 <8 个百分点）" % [
		"✅" if absf(rate - expect) < 0.08 else "❌"])
	print("  对照：改之前是「时间一到必定起身」= 100%%")

# ---------------------------------------------------------------- E. 回到最上层

func _part_e() -> void:
	print("")
	print("=== E. 被别的置顶窗口压住之后，能不能自己回到最上层 ===")
	print("  （z 序编号：0 = 最上层，数字越小越靠上）")
	# C 段为了让伪造的全屏状态不被覆盖，把辅助进程停掉了 —— 那之后"维持置顶"就没人管了，
	# 所以这一段之前必须把它放回去，否则怎么等都不会有人把她抬起来
	_shell.start_watcher()
	await _wait(2.5)
	var my_pid := OS.get_process_id()
	print("  开始时：她=%d 焦点在她身上=%s" % [
		_zorder(my_pid, my_pid)[0], DisplayServer.window_is_focused()])

	# 开一个置顶小窗，它会插到她上面
	var top_pid: int = OS.create_process(_shell.powershell(), PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass", "-File", _shell.ps1_path(), "topwin", "16",
	]), false)
	await _wait(2.0)
	var z := _zorder(my_pid, top_pid)
	print("  置顶小窗出现后：她=%d 对方=%d  %s" % [
		z[0], z[1], "✅ 她确实被压到下面了（这样才测得出东西）" if z[0] > z[1] else "⚠️ 没压住，这段说明不了什么"])

	# 等"重申置顶"（2 秒一轮）把她抬回去
	var back: bool = await _wait_until(_is_above.bind(my_pid, top_pid), 14.0)
	z = _zorder(my_pid, top_pid)
	print("  %s 过几秒再看：她=%d 对方=%d" % [
		"✅ 自己回到最上层了" if back else "❌ 还在下面", z[0], z[1]])
	print("  过程中她的焦点状态：%s（她是 no_focus 的，不该去抢你的键盘焦点）" % [
		DisplayServer.window_is_focused()])

func _is_above(a: int, b: int) -> bool:
	var z := _zorder(a, b)
	return z[0] < z[1]

## 两个进程窗口的 z 序编号 [a, b]
func _zorder(pid_a: int, pid_b: int) -> Array:
	var out: Array = []
	OS.execute(_shell.powershell(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _shell.ps1_path(), "zorder", "%d %d" % [pid_a, pid_b]], out, true)
	var text := ""
	for l in out:
		text += String(l)
	var parts: PackedStringArray = text.strip_edges().split(" ")
	if parts.size() >= 2:
		return [int(parts[0]), int(parts[1])]
	return [-1, -1]

# ---------------------------------------------------------------- 小工具

func _wait(sec: float) -> void:
	await create_timer(sec).timeout

func _wait_until(pred: Callable, timeout: float) -> bool:
	var until := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < until:
		if pred.call():
			return true
		await process_frame
	return pred.call()

func _write_state(s: String) -> void:
	var f := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(s)
		f.close()

func _read_state() -> String:
	var f := FileAccess.open(STATE_FILE, FileAccess.READ)
	if f == null:
		return "<没有>"
	var t := f.get_as_text()
	f.close()
	return t.strip_edges()
