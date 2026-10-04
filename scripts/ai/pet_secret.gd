# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 密钥**不写明文**：存到一个用引擎官方接口加密的文件里。
##
## 为什么不是"往 pet_chat.cfg 里写一段密文"：那样得自己挑算法、自己管 IV 和分组填充 ——
## 手搓加密正是最不该干的事。引擎自带 `FileAccess.open_encrypted_with_pass()`（AES-256 +
## SHA-256 派生口令），是标准库实现，直接用它。所以密钥**单独住一个文件**：
##
##     user://pet_secret.dat      ← 加密文件，里面是第一行 key、第二行 vision key
##     user://pet_chat.cfg        ← 配置文件，`[ai] key` 从此**永远是空**（不留明文）
##
## 口令从"这台机器 + 这个用户"推出来（`OS.get_unique_id()` / USERNAME / COMPUTERNAME + 固定盐，
## 过 SHA-256 取十六进制）。**换机器 / 换用户名 = 解不开** → `load_key()` 返回空串，
## 调用方按"没配 key"处理（比"静默用错 key 一直 401"好查）。
##
## ⚠️ **它挡的是"随手看到"，不是"拿到你电脑的人"**：能读这份代码的人就能推出那个口令。
## 目标只有一个 —— 配置、日志、截图、误提交里**不再出现明文 `sk-…`**。
## 真要抗住拿到机器的人，得走系统级密钥库（Windows DPAPI / 凭据管理器），那是另一个量级的事。
##
## 迁移：老配置里可能躺着明文 key（2026-09-23 之前的形态）—— 调用方读到之后调 `store()` 存进
## 这儿、并把配置里那一项清掉即可，不需要专门的迁移步骤（`_load_chat_config` 就是这么做的）
##
## 接口面：**只在 user:// 下读写 `pet_secret.dat` 这一个文件**，不碰配置、不认识桌宠
extends RefCounted

const FILE := "user://pet_secret.dat"
## 派生口令时拌进去的固定盐（不是秘密，只是别让别的项目算出同一个口令）
const SALT := "desktop-pet/secrets/v1"

## 存两个 key（chat / vision）。空串表示"没有"，写进去就是空行
static func store(chat_key: String, vision_key: String) -> bool:
	if chat_key.strip_edges() == "" and vision_key.strip_edges() == "":
		# 两个都空 = 没什么可存 → 把文件删掉，别留一个空壳在那儿
		if FileAccess.file_exists(FILE):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))
		return true
	var f := FileAccess.open_encrypted_with_pass(FILE, FileAccess.WRITE, _pass())
	if f == null:
		return false
	f.store_line(chat_key.strip_edges())
	f.store_line(vision_key.strip_edges())
	f.close()
	return true

## 读回来。文件不在 / 解不开（换了机器）都返回 ["", ""]
static func load_keys() -> Array:
	if not FileAccess.file_exists(FILE):
		return ["", ""]
	var f := FileAccess.open_encrypted_with_pass(FILE, FileAccess.READ, _pass())
	if f == null:
		return ["", ""]
	var chat := f.get_line().strip_edges()
	var vision := f.get_line().strip_edges()
	f.close()
	return [chat, vision]

## 有没有存过（界面用它决定"要不要提示去填"）
static func has_any() -> bool:
	var k: Array = load_keys()
	return String(k[0]) != "" or String(k[1]) != ""

## 口令 = SHA-256(机器标识 | 用户名 | 机器名 | 盐) 的十六进制。
## `OS.get_unique_id()` 在部分平台上会是空串，所以三项都拌进去；
## 三项全拿不到时退化成"这台机器上任何用户都能开" —— 那也比明文强（而且基本只出现在奇怪的构建里）
static func _pass() -> String:
	var material := "%s|%s|%s|%s" % [
		OS.get_unique_id(),
		OS.get_environment("USERNAME"),
		OS.get_environment("COMPUTERNAME"),
		SALT,
	]
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(material.to_utf8_buffer())
	return h.finish().hex_encode()
