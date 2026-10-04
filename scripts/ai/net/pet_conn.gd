# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 一条连接的生命周期：连 → 发 → 收（HTTPClient 状态机）。
##
## 原先它是 pet_chat.gd 里的**内部类**，2026-09-23 按作业单 B1.1 搬出来单独一个文件
## （pet_chat 当时 850 行，超过宪法里的 500 行软上限）。选它当第一条是因为**接缝最干净**：
## 它不认识宿主、也不认识 PetChat，只认 HTTPClient —— 纯叶子，零行为变化。
##
## 用法：`start()` 发一次 → 每帧 `poll()` → 看 `phase` 判断进度 → `take()` 取走字节。
## 阶段值是我们自己需要的进度，和 HTTPClient 的 status 不是一回事。
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

const IDLE := 0        # 没在用
const CONNECTING := 1  # 握手/解析中
const SENDING := 2     # 已连接，还没发请求
const READING := 3     # 正在收 body
const DONE := 4        # 连接断开，body 收完了
const FAILED := 5      # 出错

var c := HTTPClient.new()
var phase: int = IDLE
var code: int = 0                # 响应状态码
var error: String = ""
var pending := PackedByteArray() # 已收到但还没被上层取走的字节
var method: int = HTTPClient.METHOD_GET

var _tls := false
var _host := ""
var _port := 80
var _path := ""
var _headers := PackedStringArray()
var _body := PackedByteArray()
var _start_ms := 0
var _last_rx_ms := 0

## 发起一次请求。会先关掉上一次连接，所以同一个 Conn 可以反复用。
func start(host: String, port: int, path: String, headers: PackedStringArray,
		body: PackedByteArray, use_tls: bool) -> void:
	c.close()
	_host = host
	_port = port
	_path = path
	_headers = headers
	_body = body
	_tls = use_tls
	method = HTTPClient.METHOD_GET if body.is_empty() else HTTPClient.METHOD_POST
	pending = PackedByteArray()
	code = 0
	error = ""
	_start_ms = Time.get_ticks_msec()
	_last_rx_ms = _start_ms
	if c.connect_to_host(_host, _port, TLSOptions.client() if _tls else null) != OK:
		phase = FAILED
		error = "连接发起失败"
		return
	phase = CONNECTING

func cancel() -> void:
	c.close()
	phase = IDLE
	pending = PackedByteArray()

func busy() -> bool:
	return phase == CONNECTING or phase == SENDING or phase == READING

func take() -> PackedByteArray:
	var out := pending
	pending = PackedByteArray()
	return out

func since_rx_ms() -> int:
	return Time.get_ticks_msec() - _last_rx_ms

func since_start_ms() -> int:
	return Time.get_ticks_msec() - _start_ms

## 每帧推一次。阶段不变时不做事，收到数据就追加到 pending。
func poll() -> void:
	if phase == IDLE or phase == DONE or phase == FAILED:
		return
	c.poll()
	match c.get_status():
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			pass
		HTTPClient.STATUS_CONNECTED:
			if phase == CONNECTING:
				# 必须等到连上再发，连接过程中直接请求没保证
				phase = SENDING
				if c.request_raw(method, _path, _headers, _body) != OK:
					phase = FAILED
					error = "请求发送失败"
			elif code != 0:
				# keep-alive 连接在 body 读完之后会把 status 从 BODY 退回 CONNECTED。
				# 这就是"这一轮响应收完了"。不认它的话，会把它当成刚连上而
				# **反复重发同一个请求**，而且每轮都在同一帧里二次读 body
				# （实测刷满 `Condition "status != STATUS_BODY"`）
				phase = DONE
		HTTPClient.STATUS_BODY:
			if not c.has_response():
				return
			if code == 0:
				code = c.get_response_code()
			phase = READING
			# 每帧最多读 8 块，别让一帧被一次长流拖住
			var n := 0
			while n < 8:
				# read_response_body_chunk() 读完整个 body 就会改掉 status，
				# 下一轮再读必报错，所以每轮都得重新看一次
				if c.get_status() != HTTPClient.STATUS_BODY:
					break
				var chunk: PackedByteArray = c.read_response_body_chunk()
				# 空 chunk = 这一帧暂时没数据，**不是**流结束
				if chunk.is_empty():
					break
				pending.append_array(chunk)
				_last_rx_ms = Time.get_ticks_msec()
				n += 1
		HTTPClient.STATUS_DISCONNECTED:
			phase = DONE
		_:
			phase = FAILED
			error = "连接失败（status=%d）" % c.get_status()
