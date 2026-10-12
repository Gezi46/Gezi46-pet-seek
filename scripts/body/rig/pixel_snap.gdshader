shader_type spatial;
// 屏幕像素网格对齐（3D 像素画的标准做法 ✓）
//
// 治的是：她"微微晃动"时，方块之间的**缝隙边缘出现移动锯齿** ✗。
// 待机动画只把她晃了 0.1~0.15°（实测 ✓），换算到画面是**亚像素位移** ✗ ——
// 顶点在像素格之间来回蹭，最近邻采样的纹素格 + alpha scissor 的覆盖跟着翻 ✗，
// 表现就是"边缘一格一格地抖、带锯齿" ✓。
//
// 做法：把顶点在**裁剪空间**里吸附到渲染目标像素的格点上 ✓ ——
// 于是顶点要么不动、要么整格跳 1 像素 ✓，抖动变成像素级的稳定台阶 ✓
//（复古 3D 里常说的 pixel-perfect / vertex snapping ✓）。
//
// 其余外观**照抄** StandardMaterial3D 那套（= pet_rig_tex.harden_materials 的设定）：
//   最近邻采样 ✓ ｜ alpha scissor 0.5 ✓ ｜ 关镜面高光 ✓ ｜ 粗糙度拉满 ✓
// 注意：只改了"画到哪个像素" ✓，UV / 贴图内容一个字节没动 ✓（所以不会再把方块拉长 ✗）
//
// ⚠️ 本文件由 harden_materials 在 `pet.pixel_snap == true` 时挂上（替换那份共用材质 ✓）；
//    宿主上把它改回 false 就完全回到原来的 StandardMaterial3D ✓（随时 A/B ✓）。
render_mode cull_back, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_nearest, repeat_disable;
uniform float scissor_threshold : hint_range(0.0, 1.0) = 0.5;
// 吸附的粗细：渲染目标相对屏幕的倍率（超采样时 > 1，值取自工程 rendering/scaling_3d/scale ✓）。
// 手机是 1.0 ✓，PC 是 2.0 ✓ —— 不除它的话，PC 会吸附到"半个屏幕像素"，抖动还会剩一点 ✗
uniform float snap_divisor : hint_range(1.0, 4.0) = 1.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (POSITION.w > 0.0001) {
		vec2 grid = max(VIEWPORT_SIZE / snap_divisor, vec2(1.0));
		vec2 pix = (POSITION.xy / POSITION.w) * 0.5 + 0.5;
		pix = floor(pix * grid + 0.5) / grid;
		POSITION.xy = (pix * 2.0 - 1.0) * POSITION.w;
	}
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = scissor_threshold;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
