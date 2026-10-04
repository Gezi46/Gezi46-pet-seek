# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## token 账：从服务商给的 usage 里取"命中多少 / 未命中多少"，并拼那一行日志。
##
## 从 pet_chat.gd 搬出来（作业单 B1.4）。全是 **static** —— 只认一个 Dictionary，
## 不碰连接也不碰状态，所以能离线测（tools/probe_memory.gd 里那组就是）。
##
## 各家的字段名不一样，这里统一：
##   DeepSeek 系：`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`
##   OpenAI 系：`prompt_tokens_details.cached_tokens`（未命中 = prompt_tokens − cached）
##
## 接口面：无（不访问宿主，也不访问 PetChat）
extends RefCounted

## 命中 token（拿不到返回 -1）
static func hit(usage: Dictionary) -> int:
	return field(usage, true)

## 未命中 token（拿不到返回 -1）
static func miss(usage: Dictionary) -> int:
	return field(usage, false)

static func field(usage: Dictionary, want_hit: bool) -> int:
	if usage.is_empty():
		return -1
	var k := "prompt_cache_hit_tokens" if want_hit else "prompt_cache_miss_tokens"
	if usage.has(k):
		return int(usage[k])
	var det: Variant = usage.get("prompt_tokens_details")
	if typeof(det) == TYPE_DICTIONARY:
		var cached := int((det as Dictionary).get("cached_tokens", -1))
		if cached >= 0:
			if want_hit:
				return cached
			return maxi(0, int(usage.get("prompt_tokens", 0)) - cached)
	return -1

## 拼那一行账（`命中缓存 640 / 未命中 245（提示共 885，命中率 72%）`）。
## 后端不报缓存账时返回**空串** —— 调用方据此决定"这行不打"，别打一行全是 -1 的
static func line(tag: String, usage: Dictionary) -> String:
	var h := hit(usage)
	if h < 0:
		return ""
	var m := miss(usage)
	var total := int(usage.get("prompt_tokens", 0))
	var rate := 0.0 if h + m <= 0 else 100.0 * float(h) / float(h + m)
	return "[桌宠] %s token 账：命中缓存 %d / 未命中 %d（提示共 %d，命中率 %.0f%%）" % [
		tag, h, m, total, rate]
