# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## dsh 的设置文件：读一个键、改一个键、**原样**写回。
##
## 从 pet_harness.gd 搬出来（作业单 B2.1）。为什么值得单独一个文件 ——
## 这是整个项目里**唯一会动到项目外面**的地方（改的是 `$DSH_HOME/settings.yaml`，
## 用户的真配置），所以它的三条规矩要写得足够显眼、也要能被单独验：
##
##   1. **只动要改的那一行，其余一个字节都不碰**（不引 YAML 库、不重排、不删别人的键）
##      —— "顺手整理一下配置文件"正是这类代码最典型的翻车方式
##   2. 改之前把整份内容**备份在内存里**，跑完原样写回去（原样 = 整份，不做任何整理）
##   3. 权限那一项**只在要放宽时才动**：不主动写回 `read-only` ——
##      "这次不额外放宽"不等于"我要把它按回只读"（用户可能本来就配了别的档）
##
## 一多半是纯字符串操作（改文本那几支），另几支在用户配置目录里读写一个文件，
## 所以整块都能离线测：tools/probe_harness.gd 里有"改档"那一组。
##
## 接口面：**只碰 dsh 的设置文件**（那是它存在的理由：临时改档、跑完还原）。
## 不碰项目里的文件、不碰网络、不碰场景树
extends RefCounted

## 设置文件里的段名 / 键名
const SETTINGS_SECTION := "agent-default-model"
const SETTINGS_KEY := "reasoningEffort"
const PERMISSION_SECTION := "permission"
const PRESET_KEY := "defaultPreset"
## "允许她改文件"时换成的权限档：只能动工作目录里的东西
## （`danger-full-access` 故意不给：那等于把整台机器交出去，自我升级用不着）
const PRESET_WRITE := "workspace-write"

## 改之前的整份内容（"" = 这趟没动过文件）
var _backup := ""
## 有没有改过、还没写回
var _dirty := false

## dsh 的家目录。它支持 $DSH_HOME 覆盖，不给就用 ~/.dsh
static func home() -> String:
	var h := OS.get_environment("DSH_HOME")
	if h != "":
		return h
	return OS.get_environment("USERPROFILE").path_join(".dsh")

static func path() -> String:
	return home().path_join("settings.yaml")

## 读某个键的当前值（不管它在哪个段里 —— 这些键名都是 dsh 自己的，不会重名）
static func read_setting(text: String, key: String) -> String:
	for line in text.split("\n"):
		var t := String(line).strip_edges()
		if t.begins_with(key + ":"):
			return t.substr(key.length() + 1).strip_edges()
	return ""

static func read_effort(text: String) -> String:
	return read_setting(text, SETTINGS_KEY)

## 把 section 段里 key 的值换成 value，返回改好的整份内容。
##
## **纯字符串操作**（不引 YAML 库、也不重排任何一行）—— 这样好验证：探针拿几份样例
## 直接比输入输出。删掉/重排别人写的键正是这类"顺手改一下配置文件"最典型的翻车方式，
## 所以原则是"只动那一行，其余原样"。
##
## 三种情况：键在 → 换值（保留它自己的缩进）；键不在但段在 → 补在段里
## （缩进照抄同段第一条）；连段都没有 → 末尾整段补上。
static func with_setting(text: String, section: String, key: String, value: String) -> String:
	var lines := text.split("\n")
	var out: Array[String] = []
	var in_section := false
	var section_seen := false
	var done := false
	var indent := "  "
	for i in lines.size():
		var raw := String(lines[i])
		var t := raw.strip_edges()
		# 顶级键 = 顶格、非空、不是注释
		var top := raw.length() > 0 and not raw.begins_with(" ") and not raw.begins_with("\t") \
			and not t.begins_with("#")
		if top:
			if in_section and not done:
				out.append(indent + key + ": " + value)     # 段到头了还没那个键
				done = true
			in_section = false
			if t == section + ":":
				in_section = true
				section_seen = true
			out.append(raw)
			continue
		if in_section and t.begins_with(key + ":"):
			out.append(leading_ws(raw) + key + ": " + value)
			done = true
			continue
		# 段里第一行有内容的，把它的缩进当模板
		if in_section and indent == "  " and t != "":
			indent = leading_ws(raw)
		out.append(raw)
	if in_section and not done:
		out.append(indent + key + ": " + value)
		done = true
	if not done and not section_seen:
		if not out.is_empty() and String(out[out.size() - 1]).strip_edges() != "":
			out.append("")
		out.append(section + ":")
		out.append(indent + key + ": " + value)
	return "\n".join(out)

static func with_effort(text: String, value: String) -> String:
	return with_setting(text, SETTINGS_SECTION, SETTINGS_KEY, value)

static func leading_ws(s: String) -> String:
	var i := 0
	while i < s.length() and (s[i] == " " or s[i] == "\t"):
		i += 1
	return s.substr(0, i)

## 跑之前把两项设置改成这次要的样子：推理档、以及"允不允许改文件"。
##
## 返回**错误说明**（"" = 顺利），调用方负责把它挂到自己的 `last_error` 上 ——
## 本模块不该知道"桌宠怎么报错"。
##
## 关于权限那一项：**只在 allow_write 为 true 时才动它**（理由见文件头第 3 条）
func swap(effort: String, allow_write: bool) -> String:
	_dirty = false
	_backup = ""
	var p := path()
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return "读不到 dsh 的设置文件（%s），这一趟就用它原来的档" % p
	_backup = f.get_as_text()
	f.close()
	var text := _backup
	if read_setting(text, SETTINGS_KEY) != effort:
		text = with_setting(text, SETTINGS_SECTION, SETTINGS_KEY, effort)
	if allow_write and read_setting(text, PRESET_KEY) != PRESET_WRITE:
		text = with_setting(text, PERMISSION_SECTION, PRESET_KEY, PRESET_WRITE)
	if text == _backup:
		return ""                 # 本来就都对，不用动文件
	var err := _write(p, text)
	if err != "":
		return err
	_dirty = text != _backup
	return ""

## 把设置原样写回去。**原样** = 之前读到的整份内容，不做任何"顺手整理"。
## 返回错误说明（"" = 顺利）
func swap_back() -> String:
	if not _dirty:
		return ""
	_dirty = false
	return _write(path(), _backup)

func _write(p: String, text: String) -> String:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return "写不了 dsh 的设置文件（%s）" % p
	f.store_string(text)
	f.close()
	return ""
