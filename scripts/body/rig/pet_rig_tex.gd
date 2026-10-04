# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 <YOUR NAME OR GITHUB USERNAME>
#
## 贴图 / 材质修整：把像素画渲染出来的杂讯消干净（轮廓白边、棱边白锯齿、UV 越界渗色）。
##
## 从 pet_rig.gd 搬出来（作业单 B3.2 —— B3.1 之后复核，那边还剩两套只关贴图的机制）。
## 为什么值得单独一个文件：这些代码共同点是**每一条都由实测现象驱动**，
## 注释里写的是"量到了什么、所以这么改"，和"装配"（校包围盒 / 拼动画）完全是两回事。
##
## 两套机制：
##   1. **消白边** `harden_materials` + `dilate_image`：最近邻采样、关 alpha 抗锯齿、
##      改用 alpha scissor、图集边缘 RGB 外扩（alpha 不动）
##   2. **消棱边锯齿** `inset_uvs` + `inset_mesh` + `inset_tri` + `tex_size_of`：
##      面片 UV 朝自身包围盒中心内缩半 texel，越界采样拿不到邻岛的亮色
##
## 全是 **static**，宿主节点当参数传进来（`pet` = 桌宠根节点：借它的 `_model` 和几个
## 检查器参数）。pet_rig.gd 留同名壳转发，所以 desktop_pet 的调用点一行没改。
## `dilate_image` 更是纯函数（图进图出），能离线测。
##
## 接口面：**改宿主场景里的材质与网格**（挂 surface override 材质 / 把 mesh 换成重建过的）。
## 不碰文件、不碰网络、不发信号
extends RefCounted

## 把所有材质改成"像素画友好"的设定，消除轮廓白边：
##   - 最近邻采样：不再把相邻 texel（尤其是透明区里那些亮色 RGB）混进方块边缘
##   - 关掉 alpha 抗锯齿：alpha 本来是二值的，开抗锯齿只会造出半透明描边
## 这里逐个 MeshInstance3D 设置 surface override，不依赖 .import 是否被重新生成。
## 同一个源材质只复制一份、所有 surface 共用，避免 567 个材质各占一个着色器。
static func harden_materials(pet: Node3D) -> void:
	var touched := 0
	var cache: Dictionary = {}
	var dilated: Dictionary = {}
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not (n is MeshInstance3D):
			continue
		var mi: MeshInstance3D = n
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(si)
			if src == null:
				src = mi.mesh.surface_get_material(si)
			if not (src is StandardMaterial3D):
				continue
			var key := src.get_rid()
			if not cache.has(key):
				var sm: StandardMaterial3D = (src as StandardMaterial3D).duplicate()
				sm.texture_filter = pet.texture_filter_mode
				sm.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_OFF
				# 贴图 alpha 是二值的（实测半透明像素 0%），用 alpha scissor 裁切最干净：
				#   - alpha scissor 的边缘会被 MSAA / 超采样真正抗锯齿；alpha 混合的边缘不会
				#   - 不需要按深度排序，方块之间不会互相串色
				# 阈值取 0.5，避免把采样产生的零散半透明像素留成锯齿点。
				if sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA:
					sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				if sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
					sm.alpha_scissor_threshold = pet.alpha_scissor_threshold
				# 关掉镜面高光，消掉棱边上的白色小锯齿（原因见 disable_specular 的说明）
				if pet.disable_specular:
					sm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				# 图集边缘外扩：UV 岛之间的空白会渗进轮廓，扩一圈图案颜色把它顶开
				if pet.dilate_pixels > 0 and sm.albedo_texture != null:
					var tex_key := sm.albedo_texture.get_rid()
					if not dilated.has(tex_key):
						var src_img: Image = sm.albedo_texture.get_image()
						dilated[tex_key] = (ImageTexture.create_from_image(
								dilate_image(src_img, pet.dilate_pixels))
							if src_img != null else null)
					if dilated[tex_key] != null:
						sm.albedo_texture = dilated[tex_key]
				cache[key] = sm
			mi.set_surface_override_material(si, cache[key])
			touched += 1
	if OS.is_debug_build():
		print("[PetDeek] 材质加固：%d 个 surface 共用 %d 个材质，filter=%d scissor=%.2f dilate=%dpx" % [
			touched, cache.size(), pet.texture_filter_mode, pet.alpha_scissor_threshold, pet.dilate_pixels])

## 把每个三角形的 UV 朝它自己的 UV 包围盒中心收缩 `uv_inset_texels` 个 texel。
##
## 为什么需要（实测结论）：
##   1. 面片的 UV 正好压在 texel 边界上，而 **MSAA 的着色是按像素中心求值的** ——
##      边缘像素的像素中心可能落在三角形之外，插值出来的 UV 就越过了矩形边界；
##   2. 这张 256×256 的图集里不同部件是**紧挨着**排的。实测鞋面（深色 rgb≈0.11）
##      的 UV 矩形右边 1 个 texel 就是白袜子（rgb≈0.95,0.91,0.95），
##      上方 2 个 texel 是浅色条纹（rgb≈0.91,0.82,0.82）。
## 两条凑一起：越界采样拿到的就是亮色，渲染出来正是"方块棱边上的白色小锯齿"。
## 它是不透明像素，所以不随背景变色（深色底/白底合成图完全一样），
## 也就不可能靠 TAA / SMAA / FXAA / 超采样解决 —— 那些都作用在覆盖率和时间累积上。
##
## 内缩之后边缘像素的 UV 永远落在本面最外那一排 texel 之内，越界采样消失。
## 纹理内容几乎不变（只有最外一小条 texel 的映射被压掉），肉眼看不出来。
static func inset_uvs(pet: Node3D) -> void:
	if pet.uv_inset_texels <= 0.0:
		return
	var made: Dictionary = {}
	var rebuilt := 0
	var stack: Array[Node] = [pet._model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if not (n is MeshInstance3D):
			continue
		var mi: MeshInstance3D = n
		if mi.mesh == null:
			continue
		var key := mi.mesh.get_rid()
		if not made.has(key):
			made[key] = _inset_mesh(mi.mesh, mi, pet.uv_inset_texels)
			if made[key] != null:
				rebuilt += 1
		# surface override 材质挂在 MeshInstance3D 上，换 mesh 不会丢
		if made[key] != null:
			mi.mesh = made[key]
	if OS.is_debug_build():
		print("[PetDeek] UV 内缩 %.2f texel：重建 %d 个网格（%d 个实例共用）" % [
			pet.uv_inset_texels, rebuilt, made.size()])

static func _inset_mesh(src: Mesh, mi: MeshInstance3D, inset: float) -> ArrayMesh:
	var out := ArrayMesh.new()
	var touched := false
	for si in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(si)
		var has_uv: bool = arr.size() > Mesh.ARRAY_TEX_UV and arr[Mesh.ARRAY_TEX_UV] != null
		if has_uv and (arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() >= 3:
			var uvs: PackedVector2Array = (arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array).duplicate()
			var idx := PackedInt32Array()
			if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			var tex := _tex_size_of(mi, si)
			var tris: int = idx.size() / 3 if idx.size() > 0 else uvs.size() / 3
			for t in tris:
				var a := t * 3
				if idx.size() > 0:
					_inset_tri(uvs, idx[a], idx[a + 1], idx[a + 2], tex, inset)
				else:
					_inset_tri(uvs, a, a + 1, a + 2, tex, inset)
			arr[Mesh.ARRAY_TEX_UV] = uvs
			touched = true
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out if touched else null

## 一个方块面的两个三角形各自都含该矩形的 3 个角，所以两者的 UV 包围盒**完全相同**，
## 共享的那条对角边会被算出同样的结果 —— 不会在面中间撕出一条缝。
static func _inset_tri(uvs: PackedVector2Array, i0: int, i1: int, i2: int, tex: Vector2,
		inset: float) -> void:
	var lo: Vector2 = uvs[i0].min(uvs[i1]).min(uvs[i2])
	var hi: Vector2 = uvs[i0].max(uvs[i1]).max(uvs[i2])
	var span_px := (hi - lo) * tex          # 该面的 UV 跨度，单位 texel
	# 两边合计最多缩掉跨度的 1/4（即每边 1/8）：跨度 ≥4 texel 的面按 inset 走，
	# 再小的面会被这个上限压住 —— 否则 2 texel 的面会被压缩掉一半，贴图肉眼可见地偏移。
	var ix: float = minf(inset, span_px.x * 0.125)
	var iy: float = minf(inset, span_px.y * 0.125)
	if span_px.x <= 0.0 or span_px.y <= 0.0 or ix <= 0.0 or iy <= 0.0:
		return
	var center := (lo + hi) * 0.5
	var k := Vector2(
		(span_px.x - ix * 2.0) / span_px.x,
		(span_px.y - iy * 2.0) / span_px.y)
	for i in [i0, i1, i2]:
		uvs[i] = center + (uvs[i] - center) * k

## 取该表面的贴图尺寸，用来把 UV 跨度换算成 texel
static func _tex_size_of(mi: MeshInstance3D, si: int) -> Vector2:
	var m: Material = mi.get_surface_override_material(si)
	if m == null and mi.mesh != null:
		m = mi.mesh.surface_get_material(si)
	if m is StandardMaterial3D:
		var t: Texture2D = (m as StandardMaterial3D).albedo_texture
		if t != null:
			return t.get_size()
	return Vector2(256.0, 256.0)

## 贴图边缘外扩（dilate）：把不透明像素的 RGB 复制到紧邻的透明像素上，alpha 保持 0。
##
## 为什么需要：Blockbench 的皮肤图集是一堆 UV 岛拼在一张 256×256 的图上，岛与岛之间
## 是"完全透明"的空白（实测这些空白的 RGB 全是纯黑）。模型面的 UV 正好压在 texel
## 边界上，采样一旦因为浮点误差跨过边界，就会把这块空白混进来 —— 表现就是轮廓外面
## 多一圈偏暗的描边；一旦开了 mipmap 或者拉远距离，采样范围变大，会更明显。
##
## 外扩只改 RGB、不动 alpha，所以有两层好处：
##   - 边界再采样到岛外时，拿到的是相邻图案的颜色，那圈暗描边消失；
##   - alpha 仍然是 0，alpha scissor 的裁切位置和原来完全一致，图案不会"长胖"。
static func dilate_image(img: Image, passes: int) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var stride: int = w * 4
	var data: PackedByteArray = img.get_data()

	for _pass in passes:
		# 每轮都基于上一轮的结果再往外推一层，才能覆盖 2px、3px……
		var next: PackedByteArray = data.duplicate()
		for y in h:
			for x in w:
				var i: int = y * stride + x * 4
				if data[i + 3] != 0:
					continue                        # 本来就是不透明像素，不动
				var r := 0
				var g := 0
				var b := 0
				var n := 0
				if x > 0 and data[i - 1] != 0:
					r += data[i - 4]
					g += data[i - 3]
					b += data[i - 2]
					n += 1
				if x < w - 1 and data[i + 7] != 0:
					r += data[i + 4]
					g += data[i + 5]
					b += data[i + 6]
					n += 1
				if y > 0 and data[i - stride + 3] != 0:
					r += data[i - stride]
					g += data[i - stride + 1]
					b += data[i - stride + 2]
					n += 1
				if y < h - 1 and data[i + stride + 3] != 0:
					r += data[i + stride]
					g += data[i + stride + 1]
					b += data[i + stride + 2]
					n += 1
				if n > 0:
					next[i] = r / n
					next[i + 1] = g / n
					next[i + 2] = b / n
					# alpha 保持 0
		data = next

	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
	return img
