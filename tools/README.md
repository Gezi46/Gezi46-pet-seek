# tools/ —— 自检探针与一次性工具

这个目录是**改代码之后用来验证**的。`probe_*.gd` 都是独立的脚本，不参与游戏运行，
用命令行跑一次就知道有没有改坏东西。

> 返回 [项目主 README](../README.md)

## 怎么跑

```powershell
# 离线探针（不联网、几秒出结果）
godot --headless --path . --script res://tools/probe_memory.gd -- --offline

# 需要真窗口的探针（要看到窗口在动 / 要问系统要窗口状态）
godot --path . --script res://tools/probe_settings.gd
```

带 `-- --offline` 的那种只验机制，不花 AI 额度；不带的话可能会真的发请求。

## 一键检查

**`check_effect.bat`**（项目根目录）跑的是 `check_effect.gd`：渲染几张固定取景、存进
`检查输出/`，并在控制台打印**可对比的数字**（实心像素数 / 亮像素数），这样"改了之后到底
变好没有"不用靠盯着看。

它把"当前配置"和"打开高光的参照"放在**同一个引擎进程**里各渲一遍 —— 因为每个变体都得
重新实例化宠物（`uv_inset_texels` 之类是 `_ready` 里生效的），而拉起一次引擎要 5~10 秒，
一个个单开进程一轮就得 40 秒起。

> **它能查什么、不能查什么**：模型有没有渲染出来、几何有没有被改坏、两次跑是否同一个姿势
> —— 这些靠得住（姿势是显式钉死的；靠"等 N 帧"会被帧长抖动带偏，实测能差 22%）。
> 但**"白边"这类毛病它查不出来**：掠射角高光依赖视角，固定正脸姿势下连参照组都复现不出，
> 所以报告在参照组没有明显更脏时会直接说"别据此判断"，而不是给个假的通过结论。

## 不用命令行也能用的

| 脚本 | 干什么 |
| --- | --- |
| `build_pet_scene.gd` | 重新生成 `scenes/pet.tscn` |
| `smoke_test.gd` | 无头冒烟：跑 420 帧 + 截图 + 打印包围盒 |
| `gltf_to_glb.mjs` | 模型优化（Node.js，见下） |
| `make_icon.gd` | 把一张图片裁成方形图标（量出角色范围再居中补底色）<br>用法：`-- <图> [head\|pad] [边长] [输出]` |

### 重新生成模型和场景

改了模型之后：

```powershell
# 1. 重新优化模型（需要 Node.js）
node tools/gltf_to_glb.mjs peekdeek.gltf peekdeek_opt.glb

# 2. 让 Godot 重新导入 + 重建场景
godot --headless --path . --import
godot --headless --path . --script res://tools/build_pet_scene.gd
```

## 探针清单

用 `--offline` 标了的那种不会联网。

| 脚本 | 验什么 |
| --- | --- |
| `probe_memory.gd` | 人格 + 长期记忆：A 段离线跑机制自检，B 段真跑 7 轮对话并打出整份人设提示词，C 段验记忆抽取。`--offline` 只跑 A 段 |
| `probe_memory_prompt.gd` | 人设提示词的拼装（含"截图内容不许当事实"那条防线） |
| `probe_settings.gd` | 设置面板 + 菜单入口：根菜单信号接没接上、表里每项都有控件、值灌进去读回来一致、存档往返 + 钳制（**要真窗口**） |
| `probe_menu.gd` | 菜单开着时是不是一直在宠物前面（用系统 z 序连续采样） |
| `probe_harness.gd` | 让她调 dsh 干活：估档 / 封顶 / 派活前缀 / 设置文件的三种情况。`--offline` 只跑不花额度的部分 |
| `probe_chat_stream.gd` | 对话客户端：多字节切分 / 真一轮对话 / 探活 / 上游令牌失效识别 / 思考通道 / 服务不可达（要后端在跑） |
| `probe_chat_ui.gd` | 聊天 UI：菜单项、输入框焦点、流式冒字、截屏编码、带图那一轮、摄像头那条、三个开关（**要真窗口**；H 段会动配置，它自己先备份再还原） |
| `probe_vision.gd` | 「偷看屏幕」整条链路：读配置 → 抓屏 → 视觉模型 → 打印她看到了什么（**要真窗口**，会把当前屏幕发给服务商） |
| `probe_camera.gd` | 本机有没有摄像头；没有时会不会安静返回空串而不是崩 |
| `probe_shell.gd` | 隐藏任务栏图标 / 开机自启动：问 Windows 要窗口 ex-style、走一遍注册表写→读→删（**要真窗口**） |
| `probe_tray.gd` | 托盘：辅助进程的参数、图标文件、命令通道（收起 / 叫回 / 退出） |
| `probe_quiet.gd` | 全屏检测 → 安静模式，以及移动概率（真开一个全屏窗口看检测翻不翻） |
| `probe_offline.gd` | 「离线假死」：把探活扳成离线，逐项断言该停的停了、基础功能还在、恢复后又能走（**要真窗口**） |
| `probe_home_pull.gd` | 「家 / 初始位置」：默认右下角、锚点存档往返、菜单项、回家方向偏置（**要真窗口**） |
| `probe_map.gd` | **全仓地图**：每个脚本多少行、一句话职责、函数与 `@export` 数、分区行号区间。想快速摸清结构就跑它 |
| `probe_cache.gd` | 导入缓存相关的排查 |
| `probe_material.gd` | 导入后材质的透明 / 采样 / 高光设置 |
| `probe_ring.gd` | 贴图"透明环"的 RGB —— **白边的根因藏在这里** |
| `probe_anim_stats.gd` | 每个动画的长度 vs 动作计时（查"计时够不够长"） |
| `probe_pose_curve.gd` | 每个动画"动作真正做到哪一刻"（**找静止尾巴**） |
| `probe_action_play.gd` | 强制播一个动画，记录切换过程与 `finished` 信号 |
| `probe_watch.gd` | 让宠物高频动作跑一段，统计"动画被中途切走"的次数 |
| `probe_interrupt.gd` | 动作被打断会不会补发 `finished` 信号 |
| `probe_blink_walk.gd` | 走路中眨眼不再把身体钉成静止姿势（对照完整版眨眼） |
| `probe_live.gd` | 真连一次 AI 服务看能不能聊 |
| `uv_probe.gd` | 各面的 UV 矩形，以及矩形内外各 2 个 texel 的颜色 |
| `measure_alpha_edge.gd` | 统计渲染图轮廓上的半透明像素与亮度 |
| `zoom_crop.gd` | 把窗口里任意区域按真实像素放大，并可切变体做 A/B（定位边缘毛病用） |
| `apply_autostart.gd` | 直接改注册表的自启动项（正常情况下走菜单就行） |
| `shoot_pose.gd` / `shot_plain.gd` / `shot_alpha.gd` | 截图工具：指定动画 / 正常流程 / 带 alpha 并对比过滤方式 |
| `composite_edge.gd` | 边缘合成相关的实验脚本 |

## 改探针时注意

- **探针走 `--script` 启动，不加载主场景**，所以它们**不受单实例保护影响** ——
  桌宠正开着也能跑。要验主场景的（比如 `probe_settings`）得自己 `--path` 跑。
- **日志前缀是 `[PetDeek]`**，grep 的时候按这个找。
- 临时探针用完就删，别留在 `tools/` 里（历史上有过 `_tmp_*.gd` 忘了删）。
