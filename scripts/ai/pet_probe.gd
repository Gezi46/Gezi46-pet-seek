# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 探活：定期打一下 `{base}/models`，判断"后端到底通不通"。
##
## 从 pet_chat.gd 搬出来（作业单 B1.4）。它**自带一条连接** —— 和聊天、后台任务那两条
## 互不排队（探活卡住不该拖住说话）。
##
## 为什么这条值得单独一个文件：它以前**漏了超时**（半开连接 / DNS 卡住会让它永远停在
## CONNECTING，`busy()` 一直 true → 此后再也不探活，可达值卡在最后一次上，
## "她是不是离线"的判断跟着失真）。**超时和"可达值"必须住在一起**，才不会各漏一条。
##
## 用法：`tick(目标…)` 每帧推一次（推连接 + 到点自己发一发）；`probe_now(目标…)` 立刻探一次。
## 目标（host/port/base_path/headers/tls）由宿主每次传进来 —— 本模块不存配置。
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 可达值变了（只在**真的变了**的时候发一次，别每次都惊动宿主的托盘 / 状态显示）
signal reachable_changed(ok: bool)

const Conn := preload("res://scripts/ai/net/pet_conn.gd")

## 多久探一次（毫秒）
const INTERVAL_MS := 15000
## 探活这条的超时。跟后台那条分开配：探活该短，卡住要立刻判离线
const TIMEOUT_CONNECT_MS := 10000
const TIMEOUT_IDLE_MS := 90000

## 后端通不通。**开局是 false**，等第一次探活回来才是真的（见 pet_chat 里那句
## "还没回来就别当离线"的注释）
var reachable := false

var _c := Conn.new()
## 有没有拿到过第一个确定的答案（据此决定要不要发信号）
var _known := false
var _next_ms := 0

func busy() -> bool:
	return _c.busy()

## 立刻探一次（右键菜单 / 开局用，不等定时器）
func probe_now(host: String, port: int, base_path: String,
		headers: PackedStringArray, tls: bool) -> void:
	_next_ms = Time.get_ticks_msec() + INTERVAL_MS
	if not _c.busy():
		_fire(host, port, base_path, headers, tls)

## 每帧推一次：推连接状态机；闲下来了、到点了就自己发一发
func tick(host: String, port: int, base_path: String,
		headers: PackedStringArray, tls: bool) -> void:
	if _c.phase == _c.IDLE:
		if Time.get_ticks_msec() >= _next_ms:
			_fire(host, port, base_path, headers, tls)
		return
	_c.poll()
	if _c.phase == _c.CONNECTING and _c.since_start_ms() > TIMEOUT_CONNECT_MS:
		_c.cancel()
		set_reachable(false)
		return
	if _c.phase == _c.READING and _c.since_rx_ms() > TIMEOUT_IDLE_MS:
		_c.cancel()
		set_reachable(false)
		return
	match _c.phase:
		_c.READING:
			pass
		_c.DONE:
			# **200 才算可达**。探活路径是 {base}/models（两个后端都有它，顺手证明 key 是对的）；
			# 原来打 /healthz 是 deepseek-web-api 专有的，换官方 API 之后那边是 404，
			# 会被判成"服务不可用"，然后她永远退回本地台词（实测踩过这个坑）
			var code := _c.code
			_c.cancel()
			set_reachable(code == 200)
		_c.FAILED:
			if _c.code == 0:
				set_reachable(false)
			_c.cancel()

## 宿主反过来告诉它"后端其实是通的"（成功收完一轮就是最好的证据）。
## 这条比探活本身更可靠：探活可能被限流挡掉，而"刚聊成功"不会说谎
func set_reachable(ok: bool) -> void:
	reachable = ok
	if not _known or _known != ok:
		_known = ok
		reachable_changed.emit(ok)

## 别叫 `_get` —— 那是 Object 的内置虚函数（属性访问用），签名一撞就直接解析失败（踩过）
func _fire(host: String, port: int, base_path: String,
		headers: PackedStringArray, tls: bool) -> void:
	_next_ms = Time.get_ticks_msec() + INTERVAL_MS
	_c.start(host, port, base_path + "/models", headers, PackedByteArray(), tls)
