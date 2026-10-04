# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends SceneTree
## 验"偷看屏幕"整条链路：从 user://pet_chat.cfg 读设置 → 抓屏 → 视觉模型 → 打印回复。
##
##   用法: & $godot --path . --script res://tools/probe_vision.gd
##   （**不能 headless**：要抓真实屏幕）
##
## 覆盖：
##   A. user://pet_chat.cfg 能读出来（设置面板存的就是它，格式不对这里会暴露）
##   B. 抓屏 → JPEG → data URL 的体积合理（太大说明缩放没生效）
##   C. 视觉模型真的能看图说话（这才是"偷看屏幕"成不成）
const PetChat = preload("res://scripts/ai/pet_chat.gd")
const CFG := "user://pet_chat.cfg"
var _frames := 0

func _initialize() -> void:
	_run.call_deferred()

func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 30000:
		printerr("看门狗超时")
		quit(2)
		return true
	return false

func _run() -> void:
	var cfg := ConfigFile.new()
	var loaded := cfg.load(CFG)
	print("A 读 %s：%s" % [
		ProjectSettings.globalize_path(CFG), "成功" if loaded == OK else "文件不存在（err=%d）" % loaded])
	var url := String(cfg.get_value("ai", "vision_url", ""))
	var model := String(cfg.get_value("ai", "vision_model", ""))
	var key := String(cfg.get_value("ai", "key", ""))
	print("A 视觉服务=%s  模型=%s  key=%s" % [
		url, model, ("有（%d 字符）" % key.length()) if key != "" else "空"])
	if url == "" or model == "" or key == "":
		ok_fail("配置不全：先在桌宠菜单「AI 服务设置…」里填好，或直接写进 %s" % CFG)

	var c = PetChat.new()
	c.configure(url, key, model)
	c.system_prompt = "你是主人电脑桌面上的小女仆，看图说话，简短口语化，一两句话。"
	var got := {"tokens": 0, "reply": "", "fail": ""}
	c.token.connect(func(_t: String) -> void: got["tokens"] = int(got["tokens"]) + 1)
	c.replied.connect(func(t: String) -> void: got["reply"] = t)
	c.failed.connect(func(m: String) -> void: got["fail"] = m)

	var shot := _shot()
	if shot == "":
		ok_fail("截图失败（远程桌面 / 无显示器时抓不到）")
	print("B 截图 data URL 长度 = %d 字节（约 %d KB 图片）" % [shot.length(), int(shot.length() * 0.75 / 1024.0)])

	var t0 := Time.get_ticks_msec()
	c.send("（这是我屏幕现在的样子，你看看我在忙什么，跟我说一句话）", shot)
	var until := t0 + 180000
	while Time.get_ticks_msec() < until:
		c.tick()
		await process_frame
		if String(got["reply"]) != "" or String(got["fail"]) != "":
			break
	print("C 用时 %.1fs  token 片段=%d" % [
		(Time.get_ticks_msec() - t0) / 1000.0, int(got["tokens"])])
	print("C 回复：%s" % (String(got["reply"]) if String(got["reply"]) != "" else "（无）"))
	print("C 失败：%s" % (String(got["fail"]) if String(got["fail"]) != "" else "（无）"))
	var ok: bool = String(got["reply"]) != ""
	print("PROBE_VISION %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)

func ok_fail(msg: String) -> void:
	printerr("PROBE_VISION FAILED: " + msg)
	quit(1)

## 抓当前屏幕 → JPEG → data URL。和桌宠里 _peek_screen() 的做法保持一致
func _shot() -> String:
	var img := DisplayServer.screen_get_image(DisplayServer.window_get_current_screen())
	if img == null or img.is_empty():
		return ""
	if img.get_width() > 1280:
		var r: float = 1280.0 / float(img.get_width())
		img.resize(int(img.get_width() * r), int(img.get_height() * r), Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(0.75)
	if jpg.is_empty():
		return ""
	return "data:image/jpeg;base64," + Marshalls.raw_to_base64(jpg)
