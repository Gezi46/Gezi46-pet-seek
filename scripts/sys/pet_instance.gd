# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 单实例保护 + "我还在"心跳（2026-09-29 用户报"我退出了，你那边却说没退"）。
##
## 两个毛病一起治：
##   1. **没有单实例保护** —— `pet_start.log` 里 21:37:38 起了 dist\pet.exe、
##      21:37:45 又起了 dist\pet_new.exe：两个她一起站在屏幕上。
##      你退掉其中一个，另一个还在 —— 看起来就是"明明退了，怎么还在跑"。
##      另外两个实例还会各自写同一份记忆文件（后写的把前写的覆盖掉）。
##   2. **启动日志只有"启动"没有"退出"** —— 于是"到底退没退"永远说不清，
##      只能拿"文件被占用"去猜；而那个锁更常是 Windows Defender 在扫 exe
##      （2026-09-29 我就这么猜错过一次）。退出那一行由宿主补，见 desktop_pet.gd 的 _log_exit
##
## 做法（纯 GDScript，不碰系统 API）：一个心跳文件，活着的那位每几秒盖一次时间戳。
## 新实例启动时先看一眼：**时间戳还新鲜 → 已经有人在跑 → 自己退出**；
## 过期了（上次被强杀 / 断电，没来得及删）→ 接管。
##
## ⚠️ 探针不受影响：tools 里那些跑法都带 `--script`，不加载主场景，根本走不到这儿。
## 反过来，宿主里那次判断也**特意跳过带 `--script` 的启动**，免得探针被拦下来

extends RefCounted

## 心跳文件。是变量不是常量：探针要指到临时文件上跑，别跟真实例抢
var path: String = "user://pet_alive.txt"
## 多久没盖戳就算"人没了"。约等于盖戳间隔的 3 倍：
## 太短会在对方两次盖戳之间误判（以为没人，于是两个一起跑），
## 太长则"上次被强杀"之后要干等很久才起得来
const FRESH_SEC := 9.0
## 盖戳间隔
const BEAT_SEC := 3.0

var _since_beat := 0.0
## 这次是不是我们抢到了（只有抢到的人才有资格删心跳文件 ——
## 否则"第二个实例"退出时会把正在跑的那个的心跳删掉）
var _claimed := false

## 抢位置。返回 false = 已经有一个她在跑，调用方应当**立刻退出**，别起第二个
func claim() -> bool:
	if _has_live_other():
		return false
	_claimed = true
	beat()
	return true

## 每帧调（内部按 BEAT_SEC 节流）：告诉别人"我还在"
func tick(delta: float) -> void:
	if not _claimed:
		return
	_since_beat += delta
	if _since_beat < BEAT_SEC:
		return
	_since_beat = 0.0
	beat()

func beat() -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("%d %d" % [int(Time.get_unix_time_from_system()), OS.get_process_id()])
	f.close()

## 退出时收摊：能删就把心跳删掉，下一个实例不必等它过期
func release() -> void:
	if not _claimed:
		return
	_claimed = false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## 心跳文件里的 [时间戳, pid]，读不出来就是 [0, 0]
func read_stamp() -> Array:
	if not FileAccess.file_exists(path):
		return [0, 0]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [0, 0]
	var parts := f.get_as_text().strip_edges().split(" ", false)
	f.close()
	if parts.is_empty():
		return [0, 0]
	var pid := 0
	if parts.size() > 1:
		pid = int(parts[1])
	return [int(parts[0]), pid]

## 除了我，还有活的吗（心跳新鲜 **且那个 pid 真的还在**）
##
## ⚠️ 2026-10-04 补的 pid 检查：原来只看时间戳，于是"被强杀 / 被任务管理器结束"
## 留下的心跳会在 FRESH_SEC（9 秒）里说得像还有人在跑 —— 表现就是用户报的
## "**怎么老出现开着的情况，我已经关闭了**"：他明明关了，新实例却起不来。
## 那份文件里一直存着 pid，只是没人用它。现在两样都对上才算"有人"。
func _has_live_other() -> bool:
	var st := read_stamp()
	var stamp := int(st[0])
	if stamp <= 0:
		return false
	var age := float(int(Time.get_unix_time_from_system()) - stamp)
	# 负数是时钟被往回调过，当成"不新鲜"处理：宁可放行，也别把主人锁在门外
	if age < 0.0 or age >= FRESH_SEC:
		return false
	return _pid_alive(int(st[1]))

## 那个 pid 还活着吗。
##   · pid <= 0（老格式的心跳文件，或读坏了）→ 只能按时间戳判，放行
##   · 平台不支持查（OS.is_process_running 返回 false 有些平台一律如此）—— 这里
##     **不能**因此就把人锁在门外，所以查不到时按"活着"处理，退回时间戳判断
func _pid_alive(pid: int) -> bool:
	if pid <= 0:
		return true
	return OS.is_process_running(pid)

## 给探针/日志看：正在跑的那个是谁（pid，0 = 没有）
func alive_pid() -> int:
	return int(read_stamp()[1]) if _has_live_other() else 0
