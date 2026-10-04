# PetDeek 🐾

> 名字来自 **Pet**（她住在桌面上），`Deek` 只是念着顺口的后缀。中文里平时就叫她**桌宠** —— 那是类别词，
> 不是项目名。
>
> ⚠️ **别改 `project.godot` 里的 `config/name` 就完事**：那会让 `user://` 指向新的数据目录，
> 她的长期记忆 / 配置 / 密钥全部"失联"（`app_userdata` 下那些旧目录就是这么来的）。
> 项目用 `use_custom_user_dir` 把数据目录钉在原处，改名请连那两行一起看。

一个用 **Godot 4.7** 做的 3D 桌面宠物：无边框置顶小窗口里站着一位 Blockbench 蓝发女仆，
会在屏幕上自己散步、偶尔跑两步，可以拖着走、摸摸头。

> **要改代码先看这两样**：`CONVENTIONS.md`（**代码宪法** —— 文件上限 / 分区与索引 /
> 模块边界 / GDScript 写法 / 验证阶梯 / 密钥规矩）。
>
> 想一眼看清 20 个脚本各自管什么、哪个文件超了 500 行该拆：
> ```
> godot --headless --path . --script res://tools/probe_map.gd
> ```

窗口有两种形态，由 `opaque_background` 一个开关决定，三种跑法（编辑器 F5 / `启动桌宠.bat` / 导出的 exe）表现一致：

| 形态 | 桌面上的样子 | 什么时候是这种 | 抗锯齿 |
| --- | --- | --- | --- |
| **透明**（默认） | 只有人物，其余完全透明 | 编辑器 F5、`启动桌宠.bat`、导出的 exe 都一样 | MSAA 8x + 2x 超采样 |
| 不透明卡片 | 一块 330×470 的浅色卡片 | 手动把 `opaque_background` 打开 | 同上，另外可选 TAA |

以前导出版会单独发白，那是清屏色没清零造成的（已修，见下文
「导出版"发白发灰"的真相」），现在两种启动方式表现一致。


## 两个 .bat：跑起来看 / 一条命令做检查

都在项目根目录，双击即可：

| 文件 | 作用 |
| --- | --- |
| `启动桌宠.bat` | 直接跑起来看。等同于编辑器 F5，只是不用开编辑器 |
| `检查效果.bat` | 一条命令跑完静态检查：渲染固定取景 → 存到 `检查输出/`，并在控制台打印可对比的数字 |

`检查效果.bat` 调的是 `tools/check_effect.gd`。它把"当前配置"和"打开高光的参照"
放在**同一个引擎进程**里各渲染一遍 —— 每个变体都得重新实例化宠物（`uv_inset_texels`
之类是 `_ready` 里生效的），而拉起一次引擎要 5~10 秒，一个个单开进程一轮就得 40 秒起。

它同时会做一致性校验：两个变体的**实心像素数**应该几乎相同（差异 >5% 就报警），
因为"几何被改坏"正是最需要早点发现的事。

> **它能查什么、不能查什么**：模型有没有渲染出来、几何有没有被改坏、两次跑是否同一个姿势
> —— 这些它靠得住（姿势是显式钉死的，靠"等 N 帧"会被帧长抖动带偏，实测能差 22%）。
> 但**"白边"这类毛病它查不出来**：掠射角高光依赖视角，固定正脸姿势下连参照组都复现不出，
> 所以报告在参照组没有明显更脏时会直接说"别据此判断"，而不是给出假的通过结论。

模型和动画来自本项目原有的 `peekdeek.gltf`，已做了一轮优化（见下文）。

---


## 快速开始

用 Godot 4.7 打开这个文件夹，直接按 **F5**（主场景已设为 `scenes/pet.tscn`）。

命令行启动：

```powershell
& "<Godot 可执行文件>" --path "<项目目录>"
```


## 操作

| 操作 | 效果 |
| --- | --- |
| 左键**点击**角色 | 摸头：随机做出害羞 / 挥手 / 表情动作，并说一句话 |
| 左键**双击** | 弹出聊天输入框，跟她说话（见下文「聊天」） |
| 左键**按住拖动** | 把桌宠拖到屏幕任意位置 |
| **右键**角色 | 弹出菜单：摸头 / 喂食 / 睡觉·起床 / 跳一下 / 放大缩小 / 窗口置顶 / 说点什么 / 把当前位置设为家 / 初始位置恢复右下角 / 退出 / 跟我说话 / 让她主动说一句 / 让她看看我在干嘛 / 看看我这边（摄像头） / 主动说话☑ / 偷看屏幕☑ / 摄像头☑ |
| 鼠标移到角色上 | 窗口"接住"鼠标，指针变成手型 |
| 鼠标移开角色 | 默认**不穿透**（窗口整块可点）。想恢复穿透就把 `mouse_passthrough_enabled` 打开，但会带一层提亮，见下文 |

桌宠闲置一会儿会自己在屏幕上散步，撞到屏幕边缘会折返。走动时只做 ±20° 的朝向偏转，
不整个转身——转身就只能看到后脑勺了。

---


## 目录

功能细节按**目录归属**拆到了各自的 README，这里是入口：

| 想看什么 | 去哪 |
| --- | --- |
| **聊天与 AI** —— 对话链路、流式、主动开口、快速回答、离线降级 | [`scripts/ai/README.md`](scripts/ai/README.md) |
| **人格与长期记忆** —— 她是谁、记得什么、怎么忘 | [`scripts/ai/memory/README.md`](scripts/ai/memory/README.md) |
| **界面** —— 右键菜单、设置面板、AI 服务设置、工作台 | [`scripts/ui/README.md`](scripts/ui/README.md) |
| **系统集成** —— 托盘图标、全屏安静、开机自启、窗口样式、dsh 干活 | [`scripts/sys/README.md`](scripts/sys/README.md) |
| **身体与动作** —— 朝向、走路节奏、待机与表情 | [`scripts/body/README.md`](scripts/body/README.md) |
| **场景与 3D 资产** —— 模型优化、贴图、动画、渲染与抗锯齿 | [`scenes/README.md`](scenes/README.md) |
| **踩过的坑** —— 改代码前值得看一眼 | [`docs/README.md`](docs/README.md) |
| **代码规范** —— 文件上限 / 分区 / 模块边界 / 验证阶梯 / 密钥规矩 | [`CONVENTIONS.md`](CONVENTIONS.md) |

| **自检探针** —— 改完代码怎么验 | [`tools/`](tools/)（`probe_*.gd`） |


## 文件说明

```
scenes/pet.tscn            场景：相机 / 灯光 / 环境 / 软阴影 / 气泡 / 右键菜单
scripts/desktop_pet.gd     桌宠主控：**只管总谱** —— 状态、设置、装配顺序、每帧推进顺序。
                           文件头有一张「分区索引」和「加东西时放哪儿」的规矩，先看那儿。
                           行为尽量在下面那些模块里（模块自持状态、宿主只递它要用的东西）
scripts/ai/pet_chat.gd        对话客户端：非阻塞 HTTPClient 状态机 + SSE 流式解析（不 await、不起线程）
                           协议是 OpenAI 兼容（deepseek-web-api），见上文「聊天与 AI」
scripts/ai/pet_quick.gd       快速回答（气泡下那列"主人可能接着说"的按钮）：本地候选 + 让模型现编 +
                           那列 UI + 它自己的一条连接
scripts/ai/pet_memory_flow.gd 记忆流程：什么时候记、记哪条、后台"抽事实 / 更新摘要"的节奏与认领
                           （**记忆本身**在 pet_memory.gd：档案卡 / 遗忘曲线 / 检索 / 存档）
scripts/body/pet_mood.gd        情绪：委屈度（生闷气）+ 被摸到的反应。**只放状态和判定，不开口说话** ——
                           她说什么 / 要不要截图偷看 / 动作怎么播由主控接信号去做
                           （2026-09 从主控里拆出来的三块之一；三块都留了离线可测的 static 函数）
scripts/ui/pet_menu.gd        右键菜单：分类子菜单 + 勾选项 + AI 服务设置面板（运行时搭，见上文）
scripts/ui/pet_settings.gd    设置面板：表驱动（SECTIONS 一张表决定有什么设置、范围多少、怎么存）
scripts/ui/pet_ui.gd          两个面板共用的 UI 零件（卡片 / 标签 / 输入框 / 勾选框 / 数字框 / 按钮）
scripts/sys/pet_harness.gd     让她把简单活交给本机 DeepSeek Harness（dsh）：估推理档 / 改档还原 /
                           node 转发器（绕开中文乱码）/ 工作线程（不卡主线程）
scripts/ui/pet_workbench.gd   工作台面板：派活 / 看原文 / 选工作目录与文件权限 / 一键重启她
                           （主要用途是让她给自己升级：dsh 在项目目录里改代码）
peekdeek_opt.glb           优化后的模型（1.30 MB）
tools/build_pet_scene.gd   重新生成 scenes/pet.tscn
tools/smoke_test.gd        无头冒烟测试：跑 420 帧 + 截图 + 打印包围盒
tools/shoot_pose.gd        指定动画 + 朝向截图，用来确认落地和正面朝向
tools/shot_plain.gd        按正常流程渲染一张（深色底板，方便看轮廓）
tools/shot_alpha.gd        渲染带 alpha 的透明图，可指定最近邻/线性过滤对比
tools/measure_alpha_edge.gd 统计渲染图轮廓上的半透明像素与亮度
tools/zoom_crop.gd         把窗口里任意区域按真实像素放大，并可切变体做 A/B（定位边缘毛病用）
tools/uv_probe.gd          打印各面的 UV 矩形，以及矩形内外各 2 个 texel 的颜色
tools/probe_material.gd    打印导入后材质的透明/采样/高光设置
tools/probe_ring.gd        量贴图"透明环"的 RGB —— 白边的根因就藏在这里
tools/check_effect.gd      一键检查：渲染固定取景 + 打印可对比数字（见根目录 检查效果.bat）
tools/probe_anim_stats.gd  打印每个动画的长度 vs 动作计时（查"计时够不够长"）
tools/probe_pose_curve.gd  量每个动画"动作真正做到哪一刻"（找静止尾巴，见上文）
tools/probe_action_play.gd 强制播一个动画，记录它的切换过程与 finished 信号
tools/probe_watch.gd       让宠物高频动作跑一段，统计"动画被中途切走"的次数
tools/probe_interrupt.gd   验证"动作被打断会不会补发 finished 信号"
tools/probe_blink_walk.gd  验证"走路中眨眼不再把身体钉成静止姿势"（对照完整版眨眼）
tools/probe_home_pull.gd   验"家/初始位置"：默认右下角、锚点存档往返、菜单项、回家方向偏置
                           （要带窗口跑：--path . --script res://tools/probe_home_pull.gd）
tools/probe_vision.gd      验"偷看屏幕"整条链路：读 user://pet_chat.cfg → 抓屏 → 视觉模型 →
                           打印她看到了什么（要带窗口跑，会把当前屏幕发给模型服务商）
tools/probe_camera.gd      看本机有没有摄像头；没摄像头时验桌宠会安静地返回空串而不是崩
tools/probe_shell.gd       验"隐藏任务栏图标 / 开机自启动"：问 Windows 要窗口 ex-style、
                           走一遍注册表写→读→删（要带窗口跑，不能用 --headless）
tools/make_icon.gd         把一张现成图片裁成方形图标（先量出角色实际范围，再居中补底色）
                           用法: -- <图> [head|pad] [边长] [输出]
tools/probe_memory.gd      验"人格 + 长期记忆"：A 段离线跑机制自检，B 段真跑 7 轮对话
                           并打出整份人设提示词，C 段验 AI 记忆抽取。
                           用法: -- --offline 只跑离线那段（不联网、几秒出结果）
tools/probe_quiet.gd       验"全屏检测 → 安静模式"和"移动概率"：真开一个全屏窗口看检测翻不翻、
						   硬冲小活动范围、统计起身概率、用 z 序验"被压住后能自己回最上层"
tools/probe_tray.gd        验托盘：辅助进程的参数、图标文件、命令通道（toggle 收起/叫回、quit 退出）
tools/probe_menu.gd        验"菜单打开期间是不是一直在宠物前面"（用系统 z 序编号连续采样）
tools/probe_offline.gd     验"离线假死"：把探活结果扳成离线，逐项断言该停的停了、
                           基础功能还在、恢复后又能走（要真窗口）
tools/probe_settings.gd    验"设置面板 + 菜单入口"：根菜单的信号接没接上（就是「退出」点不动
                           那个 bug）、表里每项都有控件、值灌进去读回来一致、存档往返 + 钳制。
                           用法: --path <项目> --script res://tools/probe_settings.gd（要真窗口）
tools/probe_harness.gd     验"让她调 dsh 干活"：A 段离线验估档 / 封顶 / 派活前缀 / 改设置文件的
                           三种情况，B 段真跑一个任务并确认设置文件被原样改回去。
                           用法: -- --offline 只跑 A 段（不花额度）；B 段要 dsh 装好、能上网
tools/probe_chat_stream.gd 验对话客户端（deepseek-web-api）：多字节切分 / 真一轮对话 /
                           探活（注意 /healthz 在根路径）/ 上游令牌失效识别 / 思考通道 /
                           服务不可达（要 deepseek-web-api 在跑，见文件头注释）
tools/probe_chat_ui.gd     验聊天 UI：菜单项、输入框焦点、流式冒字、截屏编码、带图那一轮、
                           摄像头那条、三个开关（勾选/翻转/存盘/老存档缺键落回检查器值）
                           （要带窗口跑：--path . --script res://tools/probe_chat_ui.gd；
                           G 段要 AIGirlfriend 在跑才拿得到真回复，否则等它超时兜底；
                           H 段会动 user://pet_chat.cfg，它自己先备份再还原）
tools/gltf_to_glb.mjs      模型优化脚本（Node.js）

peekdeek.gltf              原始模型（10.8 MB，未改动，作为备份保留）
peekdeek_0.png             原始贴图（未改动）
```

### 重新生成

改了模型之后想重新优化 / 重新生成场景：

```powershell
# 1. 重新优化模型（需要 Node.js）
node tools/gltf_to_glb.mjs peekdeek.gltf peekdeek_opt.glb

# 2. 让 Godot 重新导入 + 重建场景
$g = "<Godot 可执行文件>"
& $g --headless --path . --import
& $g --headless --path . --script res://tools/build_pet_scene.gd
```

---


## 已知限制

- 走动是**移动窗口**实现的，不是窗口内平移，所以桌宠不会被其他窗口遮挡
  （配合"置顶"体验比较自然）
- 没有做屏幕边缘的"爬墙 / 掉落"物理，撞到边缘就折返
- 模型没有骨骼（skin），是 722 个节点的刚体层级，所以 567 个 draw call
  ——13.6k 顶点、6.8k 三角面，对桌宠来说完全够用
- 聊天走 OpenAI 兼容接口（`user://pet_chat.cfg` 的 `[ai]` 段，默认 DeepSeek 官方 API）；
  没配 key 或服务不可达时她只说本地台词
- 长期记忆**没有语义向量**（DeepSeek 没有 embeddings 接口），检索靠字面匹配 + `TOPIC_HINTS`
  话题扩展表，换个完全不同的说法可能就找不着 —— 稳定的事实走档案卡，那一部分不受影响
- 记忆抽取（规则 + 模型）**都可能抽错**。错条目会留在 `user://pet_memory.json` 里持续影响对话，
  怀疑她记岔了就直接删那个文件（或者只删文件里那一项）
- 「偷看屏幕」要求后端模型是多模态的（`CHAT_MODEL` 名字里带 `vision`），所以默认关着
- 「看看我这边（摄像头）」要 `AIGirlfriend.exe --serve` 在跑、摄像头可用，
  而且菜单里「摄像头」默认是 **关** 的；没开的时候点菜单她只会说
  "我这边还没接摄像头呢～"
- 三条链路（聊天 / 偷看 / 摄像头）**共用一个气泡**，同一时刻只允许一条在跑，
  同时点另一条她只会说"等我先把这句说完～"
- 摄像头那张照片在飞的时候，菜单里再点「看看我这边」是**静默忽略**的
  （气泡还停在"让我看看…"），不会叠一句新的提示