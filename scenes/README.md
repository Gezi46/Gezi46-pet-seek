# 场景与 3D 资产

> 模型怎么从 Blockbench 出来变成能跑的 glTF / glb、贴图怎么调、动画怎么裁，
> 以及渲染和抗锯齿那几个把人坑过的坑。
>
> 返回 [项目主 README](../README.md)

## 模型与动画优化

原文件 `peekdeek.gltf` **10.8 MB**（722 节点、567 个方块网格、151 个动画），
优化后 `peekdeek_opt.glb` **1.30 MB**。原始文件原样保留，没有覆盖。

### 省下来的是什么

二进制数据里**六分之五是动画**，而且两个动画严重注水：`MainAnim` 实际只是 4 条轨道在
轻微呼吸摆动，导出时被拉成了 **72 分钟**；`hold_mainhand$minecraft:mace` 同理。
另外整个 buffer 是 base64 内嵌在 JSON 里的，光编码开销就占三分之一。

优化做了四件事：

1. **glTF → GLB** —— buffer 不再 base64
2. **砍掉用不到的动画**：151 → 33
3. **`MainAnim` 限时重采样**：4312 秒 → **24 秒 @ 8Hz**，呼吸摆动的手感保留
4. **删掉恒定不变的轨道**（550 条，不携带任何信息）

**没动的东西**：节点层级、节点名、网格、材质、UV、贴图。所以保留下来的动画依然驱动着
完全相同的节点。

### 保留下来的 33 个

- **基础**：`idle` `walk` `walkBack` `run` `jump` `sneak` `sit` `sleep` `climb` `swim` `fly` `death` `attacked`
- **互动**：`use_mainhand` `use_offhand` `swing_hand` `swing_offhand` `BlinkEye` `BlinkTwo`
- **表情动作**：`extra0` `extra2`~`extra7`
- **其他**：`MainAnim`（已重采样）、`ladder_up/down/stillness`

`idle` 和 `MainAnim` 在运行时合并成 `__pet_idle`（见 `desktop_pet.gd` 的
`_build_idle_anim()`）。眨眼动画进了**第二个 AnimationPlayer**，且只保留 `/Face/` 下的
轨道 —— 原因见下面「走着走着变成静止姿势」。

### 动画的两个坑

**1. 持续动作必须手动开循环。** 导出的 glb 里 `loop_mode` 默认是 `LOOP_NONE`，
播完停在最后一帧 —— "走到一半突然定住"就是这么来的。`_apply_loop_modes()` 启动时把
`LOOPING_ANIMS` 里的设成 `LOOP_LINEAR`。顺带修掉了 `sit` / `sleep`：它俩长度只有
0.001 秒，之前播完立刻触发 `animation_finished` 被弹回待机。

**2. 一次性动作的等待时间要按动画自身长度算，不能写死。** 写死 1.6 秒时，`extra7`
有 7.5 秒长，播到 1.6 秒就被切走。现在 `_play_action()` 的等待时间 =
`动画长度 / anim_speed + 缓冲`。

### 修掉的两处毛病

**1. 左腿骨骼下混着右腿的方块。** 左脚骨骼（`LeftFoot13`）下挂着一块 `local_x = +0.119`
的方块，而模型中线在 x=0、左腿在负侧 —— 它其实长在右腿那边，却跟着左腿摆动。
右脚骨骼下已有位置完全相同的方块，所以是个重复件。`_fix_crossed_leg_parts()` 在
`_ready()` 里按位置校正：另一侧已有同位置方块就移除，否则挪过去并保持世界变换。

> 排查时的坑：**Godot 导入 glb 会给重名节点加数字后缀**，骨骼实际叫 `LeftLeg9` /
> `LeftFoot13`，用精确名字找不到。只能前缀匹配 + "该节点直接挂着 MeshInstance3D"
> 来认出骨骼（方块节点也叫 `LeftFoot4` 这类名字，但它们是叶子）。

**2. 鼠标碰到角色时窗口闪一下。** `window_set_mouse_passthrough()` 每次调用都会让
Windows 重建窗口区域，闪的就是这个。现在可点区域**固定成角色所在的矩形**（外扩
`catch_padding`），只在包围盒真的变化（>1.5px）时才更新。

---

## 渲染 / 抗锯齿

### 白边的根因：贴图导入参数

贴图是 256×256 的硬边像素画（alpha 只有 0 和 1），但**那圈"完全透明、紧贴图案"的
texel 里存着接近白色的 RGB**。原来的导入设置：

```
compress/mode=2                  # VRAM 压缩
mipmaps/generate=true            # 生成 mipmap
process/fix_alpha_border=true    # 把边缘颜色扩散进透明区
```

`fix_alpha_border` 把图案边缘的颜色扩散进透明区，配上 VRAM 压缩和 mipmap 的多次降采样，
那圈透明 texel 就被填成了亮色。方块模型是**线性过滤**，每个方块的边缘都会采到这一圈
—— 整圈轮廓被掺进白色，看起来就是"抗锯齿白边"。

**改成**：

| 参数 | 改成 | 原因 |
| --- | --- | --- |
| `compress/mode` | **0（无损）** | 贴图才 30 KB，压缩省不了空间，反而在色块边界产生伪影 |
| `mipmaps/generate` | **false** | 像素画用不上，降采样只会把透明区颜色混进边缘 |
| `process/fix_alpha_border` | **false** | 就是它把亮色填进透明环的 |

**采样**：材质设 `TEXTURE_FILTER_NEAREST`（在 `_harden_materials()` 里统一设置）。
方块面都是轴对齐矩形，UV 正好落在 texel 边界上，最近邻最准 —— 这也是 Minecraft 类画风
的通行做法。

> **Godot 4 的 PNG 导入面板里没有"采样过滤"这一项。** 导入面板能控的只有 mipmap、
> 压缩方式、fix alpha border；采样过滤只存在于**材质**的 `texture_filter`。
> 所以"把 Filter 改成 Nearest"在这个项目里是代码里做的。

### 抗锯齿：两个来源分开治

| 锯齿来源 | 用什么 | 说明 |
| --- | --- | --- |
| 几何边缘（方块轮廓） | MSAA | 只跟三角形边界有关，贴图设置帮不上忙 |
| 贴图镂空边缘 | alpha scissor | alpha **混合**的边缘 MSAA 无效，改成 scissor 才吃抗锯齿 |

- `msaa_3d = 3`（8x）
- `screen_space_aa = 0`（关闭 —— 原因见下）
- `scaling_3d/scale = 2.0`（2 倍超采样，压方块之间的亚像素缝隙）
- 材质 `TRANSPARENCY_ALPHA` → **`TRANSPARENCY_ALPHA_SCISSOR`**（阈值 0.5）。
  贴图 alpha 是二值的，裁切结果和混合一样，但边缘能被 MSAA 抗锯齿，还不用深度排序

超采样的代价是轮廓外多出一层很淡的过渡带 —— 比白线好得多，所以留着。不想要就把
`scaling_3d/scale` 改回 `1.0`。

### 透明背景下别用 SMAA / FXAA

它会**帮倒忙**：屏幕空间抗锯齿只做边缘检测后混合 RGB、**不碰 alpha**，而轮廓的锯齿
恰恰长在 alpha 上（该磨的地方一点没磨到）；同时它把轮廓外透明区的**纯黑**混进边缘，
合成到桌面上就是一圈**深色描边** —— 正好是白边的镜像毛病。

透明窗口里真正管用的只有 **MSAA + 超采样**：它们在**采样阶段**生效，会真的磨到 alpha。

### 方块棱边上的"白色小锯齿"：两个叠加的原因

#### 一、UV 越界采样（主因，也是上面那圈白边的真凶之一）

这张图集里**不同部件是紧挨着排的**：鞋面（深色）的 UV 矩形右边 1 个 texel 就是白袜子。
而面片的 UV 正好压在 texel 边界上，**MSAA 的着色按像素中心求值** —— 边缘像素的中心可能
落在三角形之外，插值出来的 UV 就越过矩形边界，采到隔壁的亮 texel。

这也解释了为什么它对 TAA / SMAA / FXAA / MSAA / 超采样**全都无感**：那些都作用在
覆盖率或时间累积上，而问题出在 **UV 采样位置**上。

**修法**：`_inset_uvs()` 把每个面的 UV 朝自己的包围盒中心收缩半个 texel
（`uv_inset_texels`，默认 0.5）。

> 一个方块面拆成的两个三角形各自都含该矩形的 3 个角，UV 包围盒完全相同，
> 共享的对角边会算出同样的结果 —— 不会在面中间撕出缝。

#### 二、镜面高光

导入后的材质是 `specular_mode = Schlick-GGX` + `metallic_specular = 0.5`，Fresnel 在
**掠射角**趋近 1，而方块模型的每条棱边恰好都是掠射角 —— 整圈棱边被环境光加亮。
**修法**：`SPECULAR_DISABLED`（`disable_specular` 开关，默认开）。像素画本来就该是
平面着色。

> `disable_specular` 立即生效；`uv_inset_texels` 是启动时生效的，改了要重启。

### "extra 做一半就回到静止动画"：动画自带静止尾巴

不是状态机的问题（切换记录干净）。真正原因在动画数据：这些 extra **做完手势就回到站立
姿势空转**，后面那段其实没在动。而计时按全长算，宠物就在那儿杵着等。

`_measure_action_ends()` 启动时逐个量出动作结束时刻，一次性动作用它而不是全长
（`action_tail_trim`，默认开）。判据是单步位移要同时超过**绝对下限**和**本动作峰值的
15%** —— 只用一个都不行：只用下限会把静止尾巴上的回正残留当成"还在动"，只用比例会把
本来就很轻的动作整段判成没动。

### "行走时不播走路/跑步动画"：一个状态卡死 bug

移动路径本身没问题，真凶在**点击路径**：走路中点一下角色，`_begin_drag()` 把 `_state`
设成 `DRAG` 并播 `jump`；松开时如果正好落在**摸头冷却**里，旧代码直接 `return`，
**没人把状态拉回来**。后果是连锁的：`_begin_move()` 只在 `IDLE` 触发 → 从此不再走路；
`_on_main_finished()` 又被 `DRAG` 挡住 → 宠物僵在 `jump` 末帧。

**修法**：冷却分支里把状态拉回 `IDLE`。

**走跑分离**：原来走路和跑步共用一个 `move_duration`，现在拆成 `walk_duration` 和
`run_duration`（跑步默认更短促）。

### "走着走着变成静止姿势在滑行"：眨眼动画覆盖全身

症状是"窗口在平移、动画却是静止的"。加了两层自愈（`_ensure_walk_anim()` 每帧纠正 +
`_on_main_finished()` 补回循环），但**根因在第二个 AnimationPlayer 上**：
`BlinkEye` / `BlinkTwo` 各有 **39 条轨道，和 `walk` 的轨道集合一模一样**（Root、四肢、
裙子全有），只是身体部分的键值恰好是站立姿势。眨眼在任何状态下随机触发，叠加层在场景
树里排在主 player 后面、同节点冲突它赢 —— 走路途中一眨眼，全身被钉成站立姿势。

**修法**：`_strip_to_face()` 只保留 `/Face/` 下的轨道。必须 `duplicate()` 再裁，
否则会把主库里共享的同一份动画资源也裁掉。

> 自愈要放在 `_step_move()` **之前**：它结尾可能调 `_start_idle()` 改状态，自愈若在后面，
> 会拿着过期的 WALK 假设把动画又改回去，两者打架。

### 鼠标穿透会让窗口整体"提亮"

`window_set_mouse_passthrough()` 在 Windows 上是靠 **`SetWindowRgn` 裁剪窗口区域**实现
的，副作用是**被裁出的可见区域整体多一层很淡的提亮**，边界正好落在角色轮廓上（很容易
被误判成光照问题）。

所以 `mouse_passthrough_enabled` 默认 **false**："背景绝对干净"和"空白处能点到后面的
窗口"只能二选一。

### 导出版"发白发灰"的真相

原因是**背景色的 RGB 没被清零**。透明 viewport 里，清屏色的 **alpha 会被置 0、RGB 原样
保留**，而 DWM 按**预乘 alpha** 合成 —— 等价于把那点 RGB **加到**桌面上，表现就是整块
均匀发白。

**修法**：`project.godot` 加一行

```ini
environment/defaults/default_clear_color=Color(0, 0, 0, 0)
```

> **根因**：Vulkan 后端（Forward+ / Mobile）在透明窗口下写出的帧缓冲没有做预乘 alpha。
> **换成 Compatibility（OpenGL）渲染器后彻底消失**（像素差从 `+36,36,36` 变成 `0,0,0`）。
> 这也是项目默认用 `gl_compatibility` 的原因之一。
>
> 顺带删掉了之前那段"导出版强制切不透明卡片"的逻辑 —— 它是基于错误结论加的。

> **Camera3D 自己挂了 `environment` 时会覆盖 WorldEnvironment。**
> `_apply_background()` 改的是真正生效的那个（`_effective_environment()`）。

### 导出成 exe

`项目 → 导出 → Windows Desktop`，预设和模板都已就绪，**不用改任何开关**。

两个坑：

1. **当前预设是 `binary_format/embed_pck=false`** —— 产物是 **exe + pck 两个文件**，
   分发时必须一起拷贝。想只发一个文件就在导出面板勾 **Embed PCK**。
2. **测导出版之前先关掉编辑器的嵌入窗口模式**（`编辑器设置 → Run → Window Placement`
   → Embed Game Window），否则看到的还是编辑器里的画面。

### 图集边缘外扩（dilate）

Blockbench 的图集是一堆 UV 岛拼在一张 256×256 上，岛与岛之间是**纯黑**的空白（不是
白色）。所以 UV 越界采样混进来的是黑 —— 表现为**偏暗的描边**。

`_harden_materials()` 里加了运行时外扩：`_dilate_image()` 把不透明像素的 RGB 往相邻
透明像素复制，**alpha 保持 0** —— 越界采到的是相邻图案的颜色，而 alpha scissor 的裁切
位置完全不变（图案不会"长胖"）。参数 `dilate_pixels`，默认 2。

**1px 就已经饱和**（最近邻 + UV 压在边界上，真正会越界的边界像素本来就不多），默认给
2px 是为了将来万一改成线性采样或开 mipmap 时 padding 够用。

> **为什么在运行时做，而不是直接改那张 PNG**：glb 的贴图是**内嵌**的，Godot 导入时
> 提取成 `peekdeek_opt_0.png` —— 直接改这个文件会在重新导入时被覆盖。真要落到资产上，
> 得改 `gltf_to_glb.mjs`（Node 侧做 PNG 解码 / 外扩 / 重编码）。

### 如果你还看到白边

1. **确认你看的是运行中的游戏窗口**，不是 Godot 编辑器的 3D 视口 —— 编辑器视口有独立的
   一套背景/抗锯齿设置，和最终效果不是一回事
2. **确认重启了应用** —— 贴图导入参数是导入期生效的。必要时删掉
   `.godot/imported/peekdeek_opt_0*` 再让 Godot 重新导入
3. 检查是不是**显示器/显卡驱动的锐化**（NVIDIA 图像锐化、AMD RIS）在深色桌面上放大了
   边缘对比
4. `desktop_pet.gd` 的 `texture_filter_mode` 默认最近邻，想换线性可以直接改
5. 如果看到的是**深色**描边 —— 看 `screen_space_aa_mode` 是不是被打开了，调回「关闭」
