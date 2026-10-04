# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
extends RefCounted
## 窗口 / 缩放 / 家：背景切换、机位与落地、归一化"家"锚点的存取
## （由 desktop_pet.gd preload 为 PetWindow）。

## "家"的出厂值：右下角。菜单里的「初始位置恢复右下角」就是回到它
const HOME_DEFAULT := Vector2(1.0, 1.0)
## 记住"家"的位置的文件。用 user:// 而不是写回 .tscn ——
## 拖一下就把场景文件改掉，既意外也不好回滚
const HOME_CONFIG := "user://pet_home.cfg"

## 宿主（桌宠根节点）：读它的检查器参数 / 缓存的包围盒 / 屏幕可用区域
var pet: Node3D = null


func setup(pet_node: Node3D) -> void:
	pet = pet_node


## 按 pet._use_opaque() 铺背景：
##   透明模式 → viewport.transparent_bg = true，桌面上只看到人物；
##   卡片模式 → 关掉透明，用 Environment 的背景色铺一层浅色。
## 注意 TAA 也要求不透明背景（实测打开 TAA 后透明像素会变成 0）。
func apply_background() -> void:
	var opaque: bool = pet._use_opaque()
	# 关键：只靠项目设置 `window/size/transparent` 在**导出版**里不够 ——
	# 实测导出的 exe 会退回成不透明窗口，把背景清成默认的 0.3 灰（整个窗口一块灰白，
	# 逐点比对是均匀 +77/255）。窗口 flag 必须在运行时明确设一次。
	DisplayServer.window_set_flag(
		DisplayServer.WINDOW_FLAG_TRANSPARENT, not opaque)
	pet.get_viewport().transparent_bg = not opaque
	if OS.is_debug_build():
		print("[桌宠] 卡片模式=%s（窗口flag=%s / 平台可用=%s / 导出版=%s）" % [
			opaque,
			DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT),
			DisplayServer.is_window_transparency_available(),
			OS.has_feature("template")])
	var env: Environment = _effective_environment()
	if env == null:
		return
	if opaque:
		env.background_mode = Environment.BG_COLOR
		env.background_color = pet.background_color
	else:
		# 透明模式：背景色也一并清成全透明。
		# 只要它还留着 RGB，某些渲染路径就会写出"alpha=0 但 RGB 非 0"的帧缓冲，
		# 而 DWM 按预乘 alpha 合成就等于把那点 RGB **加**在桌面上
		# —— 实测整窗均匀 +153/255，就是"半透明白色背景"的真身。
		env.background_mode = Environment.BG_CANVAS
		env.background_color = Color(0, 0, 0, 0)


## 取当前**真正生效**的 Environment。
## Godot 4 里 Camera3D 自己挂了 `environment` 时它会**覆盖** WorldEnvironment，
## 所以只改 $WorldEnvironment 是不生效的（给相机加环境之后就会踩到）。
## 注意用的是 pet._camera（场景里那台）而不是当前激活相机，避免相机还没激活时取不到。
func _effective_environment() -> Environment:
	if pet._camera != null and pet._camera.environment != null:
		return pet._camera.environment
	var we: WorldEnvironment = pet.get_node("WorldEnvironment")
	return we.environment if we != null else null


func apply_window_size() -> void:
	var box: AABB = pet._calib_aabb
	var h: float = maxf(box.size.y, 0.001)

	# 让角色站到地面上：整只抬升，使待机时的最低点落在 y=0
	pet._ground_offset = -box.position.y
	pet._pivot.position.y = pet._ground_offset
	box.position.y = 0.0

	# 取景范围再除以「大小」档：pct 越小 → 取景越大 → 她在窗口里越小（见 set_scale_percent）。
	# 注意这**不再**改窗口大小了 —— 窗口只在 pct>1 时跟着变大，所以 UI 永远是 100%
	pet._camera.size = h / clampf(pet.fit_ratio, 0.2, 1.0) / clampf(pet._scale_pct, 0.1, 5.0)
	pet._camera.keep_aspect = Camera3D.KEEP_HEIGHT

	var center: Vector3 = box.position + box.size * 0.5
	# 略微俯视，让脚下的阴影可见
	var tilt := deg_to_rad(18.0)
	var dist: float = maxf(h * 3.0, 5.0)
	var dir := Vector3(0.0, sin(tilt), cos(tilt))
	pet._camera.look_at_from_position(center + dir * dist, center, Vector3.UP)
	pet._camera.near = 0.05
	pet._camera.far = maxf(dist + h * 4.0, 40.0)

	# 脚下阴影贴在角色正下方
	pet.get_node("Shadow").position = Vector3(center.x, 0.01, center.z)
	dock_to_home()

	# 机位和窗口尺寸都变了，可点区域必须重算一次
	pet._passthrough_set = false
	pet._update_passthrough_region()


## 启动 / 改窗口大小时，把窗口停到"家"的位置
func dock_to_home() -> void:
	DisplayServer.window_set_position(home_pos())


## "家"对应的窗口位置。锚点是归一化坐标，乘的是"窗口能落到的范围"
## （可用区域减去窗口自身），所以 (1,1) 正好是右下角贴边、(0.5,1) 是底部居中 ——
## 不管窗口多大、任务栏多高，停下去都不会露出一截在屏幕外。
func home_pos() -> Vector2i:
	var span: Vector2 = Vector2(pet._screen.size - DisplayServer.window_get_size())
	var a: Vector2 = pet.home_anchor.clamp(Vector2.ZERO, Vector2.ONE)
	return pet._screen.position + Vector2i((span * a).round())


## 把窗口当前所在的位置记为新的"家"
func set_home_here() -> void:
	var span: Vector2 = Vector2(pet._screen.size - DisplayServer.window_get_size())
	if span.x <= 1.0 or span.y <= 1.0:
		return
	var rel: Vector2 = (Vector2(DisplayServer.window_get_position()) - Vector2(pet._screen.position)) / span
	set_home(rel)


## 设一个归一化的"家"：立刻存档，下次启动也停在这儿
func set_home(anchor: Vector2) -> void:
	pet.home_anchor = anchor.clamp(Vector2.ZERO, Vector2.ONE)
	_save_home()
	if OS.is_debug_build():
		print("[桌宠] 新家：%s（窗口位置 %s）" % [pet.home_anchor, home_pos()])


func _save_home() -> void:
	var cfg := ConfigFile.new()
	cfg.load(HOME_CONFIG)          # 文件不存在时返回错误，忽略即可
	cfg.set_value("home", "anchor", pet.home_anchor)
	cfg.save(HOME_CONFIG)


## 读回上次记住的"家"。文件不存在或读坏了都退回 HOME_DEFAULT（右下角）
func load_home() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(HOME_CONFIG) != OK:
		return
	pet.home_anchor = Vector2(cfg.get_value("home", "anchor", HOME_DEFAULT)) \
		.clamp(Vector2.ZERO, Vector2.ONE)


## 「大小」档。**2026-09-27 改了机制**：以前是"把窗口连同画布一起缩"，
## 结果 UI 跟着一起变小（`stretch/mode=canvas_items`：画布坐标恒为 330×470，
## 窗口一小，UI 的物理尺寸就按比例缩）——用户报的"UI 不要随桌宠变小而变小"就是它。
##
## 现在：
##   pct ≤ 1  → **窗口不动**（固定 330×470），只把相机取景范围放大 → 桌宠变小、UI 不变
##   pct > 1  → 窗口才跟着变大（不然她会顶到窗外），UI 由宿主反向缩放回 100%
## 真正的"变大变小"落在相机上（见 apply_window_size 里的 `pet._scale_pct`），
## 所以可点区域（pointer 那边是 unproject 出来的）会自动跟着对，不用手改
func set_scale_percent(pct: float) -> void:
	var base := Vector2i(330, 470)
	var grow: float = maxf(1.0, pct)
	DisplayServer.window_set_size(Vector2i(int(base.x * grow), int(base.y * grow)))
	apply_window_size()
