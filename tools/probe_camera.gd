# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 看这台机器上 Godot 能不能直接拿到摄像头（决定"看摄像头"是走本机采集还是外部服务）。
## 用法: & $godot --path . --headless --script res://tools/probe_camera.gd
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 3000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	# 必须先开监控：不开的话 get_feed_count() 直接返回 0 并报
	# "CameraServer is not actively monitoring feeds"
	CameraServer.set_monitoring_feeds(true)
	# **别只看一眼**：开监控之后驱动是异步去枚举设备的，立刻读会读到 0 ——
	# 这台机器上就是这么误报过一次（枚举要等一会儿才变成 1）。
	# 所以这里每帧轮询，最多等 8 秒，并把"等了多久才看到"打出来
	var n: int = CameraServer.get_feed_count()
	var waited := 0
	while n <= 0 and waited < 480:      # 60fps × 480 ≈ 8 秒
		await process_frame
		waited += 1
		n = CameraServer.get_feed_count()
	print("CameraServer 摄像头数量 = %d（开监控后等了约 %.1f 秒）" % [n, float(waited) / 60.0])
	for i in n:
		var f: CameraFeed = CameraServer.get_feed(i)
		if f == null:
			continue
		print("  feed %d: 名字=%s id=%s 在用=%s" % [i, f.get_name(), f.get_id(), f.is_active()])
	print("显示器数量 = %d（主屏 %s）" % [
		DisplayServer.get_screen_count(),
		DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())])

	# 顺带验一下桌宠那条采集逻辑本身：没摄像头时它必须**安静地返回空串**，
	# 不能抛异常、也不能卡住 —— 这条才是"看摄像头"在无摄像头机器上的行为
	var pet: Node = load("res://scenes/pet.tscn").instantiate()
	get_root().add_child(pet)
	await process_frame
	await process_frame
	var shot: Variant = await pet.call("_camera_shot")
	print("桌宠 _camera_shot() 返回：%s" % (
		"空串（没摄像头，符合预期，会提示一句人话）" if String(shot) == ""
		else "data URL，%d 字节" % String(shot).length()))
	pet.free()
	# 能不能采到一帧：feed 的纹理 + get_image()
	if n > 0:
		var feed: CameraFeed = CameraServer.get_feed(0)
		var tex: Texture2D = feed.get_texture(CameraServer.FEED_RGBA_IMAGE)
		print("  feed0 纹理 = %s" % ("有" if tex != null else "无"))
		for i in 30:
			await process_frame
		if tex != null:
			var img: Image = tex.get_image()
			print("  tex.get_image() = %s" % (
				"空（这条路拿不到像素）" if img == null else "%dx%d" % [img.get_width(), img.get_height()]))
	quit(0)
