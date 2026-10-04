# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
extends Node3D
## 3D 桌宠主控
##
## 行为：
##   - 透明无边框窗口里显示 3D 模型，角色脚下有软阴影
##   - 在屏幕上随机散步 / 偶尔奔跑，走到屏幕边上会折返
##   - 左键按住 = 拖动窗口；左键点击 = 摸头反应；双击 = 打开聊天输入框
##   - 右键 = 弹出菜单（摸头 / 喂食 / 睡觉 / 跳跃 / 缩放 / 置顶 / 聊天 / 退出）
##   - 鼠标贴着角色时窗口"接住"事件，移开则点击穿透到后面的窗口
##
## 聊天（scripts/pet_chat.gd）：OpenAI 兼容的 HTTP + SSE —— 接官方 API，或接本机
##   deepseek-web-api（两者差别见 README）。主动说话完全由本地计时决定，不依赖后端推送；
##   连不上就退回本地台词，关掉 chat_enabled 即回到纯本地桌宠
##
## 这个文件**只管总谱**：状态、设置、装配顺序、每帧推进顺序。具体行为在下面那些模块里 ——
## 先看"分区索引"和"加东西时放哪儿"，别整篇翻
##
## ── 体量豁免（它**永远不会 ≤500 行**，这一段就是记账）──────────────────────
## 按 CONVENTIONS.md 的规矩：超过 500 行的文件要么继续拆，要么把"为什么拆不动"写清楚。
## 这个文件属于后者 —— 留下的是三样**拆不动**的东西：
##
##   1. 可调参数（87 个 @export）：检查器只认挂在场景上的脚本，这是引擎事实不是习惯
##   2. 装配顺序（_enter_tree / _ready 里那串 setup）：**顺序就是契约**，改动要连冒烟一起跑
##   3. 每帧推进的唯一一处（_process / _tick_chat 的调用次序）
##
## 外加一批**接线壳**：模块的信号接回这里（`_on_touch_line` / `_on_chat_replied`…），
## 以及探针按老名字直接打的那些（`pet.call("_peek_screen")` 这种写法）。
## 壳挪走不会让文件更清楚，只会让"谁在调谁"更难查 —— 所以它们留。
##
## 行为块已经搬走了（作业单 B1–B6）：
##   被摸到的反应 → `pet_touch.gd`｜偷看屏幕 + 摄像头 → `pet_peek.gd`
##   聊天客户端全家 → `pet_conn` `pet_sse` `pet_once` `pet_retry` `pet_net` `pet_probe` `pet_usage`
##   系统集成 → `pet_shell_ps1` `pet_shell_watch` `pet_windows`｜装配动画 → `pet_rig_stats` `pet_rig_tex`
##   记忆 → `pet_memory_prompt` `pet_memory_forget`｜dsh 的改档 → `pet_dsh_settings`
##
## 两次"评估后决定不搬"（作业单 B6.2 / B6.3，理由记在这儿免得以后重问一遍）：
##   B6.2 —— 「长期记忆」那一段现在**全是聊天接线**（收流 / 回执 / 离线判定 / 状态同步），
##           没有"纯提示词 / 纯数据"可搬 —— 那些早就在 `pet_memory_flow.gd` 里了
##   B6.3 —— 「设置面板桥」**不搬**：它就是 `SETTING_VARS`（@export ↔ 面板键的映射表），
##           和上面第 1 条是同一件事，拆开等于两处要同步；况且它要读 shell / memory / _say 这些宿主状态，
##           本质是编排。硬搬进 pet_settings.gd 还会把那个文件顶到 650 行以上
##
## 动画分层：
##   $Character/Pivot/Model/AnimationPlayer   主体（待机 / 走 / 跑 / 睡 / 各种反应）
##   $Character/Pivot/Model/AnimationPlayer2  表情叠加层（眨眼）
## 眨眼只驱动眼睛、眉毛这些部件，单独放一个 player 就不会和身体动画抢轨道。
## 这个叠加层是运行时创建的，不写进 pet.tscn，避免 scene 文件里内联整个模型。
##
## ── 分区索引 ──────────────────────────────────────────────────────────────
## 按行号自上而下。改东西先看这张表，别整篇翻；
## 行号会随改动漂，重列一条：`Select-String -Path scripts\desktop_pet.gd -Pattern '^# -+ '`
##
##   #     分区                              相关的模块 / 看哪儿
##   ───────────────────────────────────────────────────────────────────
##   1     可调参数（87 个 @export）          检查器 + 设置面板 pet_settings.gd
##   2     台词 / 提示词                      人设见 pet_persona.gd
##   3     常量 + 静态工具                    probe_memory.gd 直接离线试它们
##   4     内部状态                           状态住这儿，行为在模块里
##   5     生命周期（装配顺序 / _process）    **顺序就是契约**，改动要连冒烟一起跑
##   6     窗口 / 缩放                        pet_window.gd
##   7     装配 / 动画                        pet_rig.gd
##   8     行为（散步 / 睡觉 / 喂食）         pet_walk.gd + pet_common_sense.gd
##   9     鼠标 / 互动                        pet_pointer.gd
##   10    菜单 / 气泡                        pet_menu.gd + pet_bubble.gd
##   11    菜单：交给 pet_menu.gd             条目 / 分组 / 勾选项都在那边
##   12    设置面板桥接（键→变量）            pet_settings.gd
##   13    调用本机 dsh                       pet_harness.gd
##   14    工作台（派活 / 自我升级）          pet_workbench.gd
##   15    开机与系统（自启动 / 托盘）        pet_shell.gd
##   16    主动说话的频率（四档）            隔多久自己开口
##   17    聊天（发一句 / 收流 / 对话记录）   pet_chat.gd
##   18    聊天：接线（信号 / 配置 / tick）   配置改动要考虑运行时重配
##   19    长期记忆（抽取 / 摘要 / 存档）     pet_memory.gd + pet_memory_flow.gd
##   20    聊天：AI 服务设置                  面板在 pet_menu.gd
##   21    UI 面板（谁开着 / 点外面收起）     pet_pointer.gd 的穿透区要用
##   22    聊天：主动说话（自己找话题）       提示词在 #3 那段常量里
##   23    生闷气 / 被摸到的反应（同一条情绪线）**状态与判定在 pet_mood.gd**；
##                                           本文件只负责开口（要截图 / 流式气泡）
##                                           分带判定在 pet_pointer.gd
##   24    聊天：对话记录 / 存档              user://pet_chat.cfg
##   另有  快速回答（气泡下那列按钮）整块在 **pet_quick.gd**
##
## 为什么只有序号没有行号：行号改一次上面就全漂，写死的行号比没有更糟。
## 想看带行号的（以及**别的 18 个文件**分别管什么），跑一遍代码地图 ——
## 它会按行数从大到小列出每个文件：一句话职责、函数/@export/分区数、各分区的行号区间：
##     godot --headless --path . --script res://tools/probe_map.gd
## （只要列主脚本的分区标记：`Select-String -Path scripts\desktop_pet.gd -Pattern '^# -+ '`）
##
## ── 加东西时放哪儿（按这几条来就不会越缠越乱）─────────────────────────────
##   1. **设置**（@export）留本文件：检查器只认挂在场景上的脚本，
##      设置面板也是 `SETTING_VARS` → `set(变量名)` 打在这儿
##   2. **行为**尽量搬模块：模块自持状态、自建 UI，宿主只递它要用的东西
##   3. **模块之间不互相 preload**，一律经宿主中转（防循环依赖 + preload 顺序坑）
##   4. 模块要用宿主的什么，就在模块头部写清那张"接口面"，只列真正用到的那几项
##   5. **每帧推进的顺序只在 _process / _tick_chat 一处**，模块只提供 tick()
##   6. 拆完要能**离线单测**（像 pet_quick.gd 里那两个 static）—— 做不到就别拆

# ------------------------------------------------------------------ 可调参数

@export_group("窗口")
## 角色在窗口里的相对高度（1.0 = 顶到边）
@export_range(0.4, 1.0, 0.01) var fit_ratio: float = 0.78
## 鼠标离角色轮廓多远之内还算"碰到角色"（像素）
@export var catch_padding: float = 8.0
## 窗口初始大小
@export var window_size: Vector2i = Vector2i(330, 470)
## "家"锚点，也是启动时的停靠位置：屏幕可用区域里的归一化坐标（0~1）。
## (1, 1) = 右下角（默认）、(0.5, 1) = 底部居中、(0, 0) = 左上角。
## 三种改法：
##   1. 直接改这个值；
##   2. 右键菜单「把当前位置设为家」——把她拖到想放的地方再用；
##   3. 直接拖拽（见 drag_sets_home）。
## 后两种会存进 user:// 配置，下次启动仍然停在那儿。
@export var home_anchor: Vector2 = Vector2(1.0, 1.0)

@export_group("行为")
@export var walk_speed: float = 46.0
@export var run_speed: float = 130.0
@export var turn_speed: float = 9.0
## 待机多久之后**才考虑**动一次（秒），还要乘 behavior_pace。
## 2026-10-01 从 (5,13) 收到 (2,6)：用户反馈"刚打开半天不动"——
## 启动 / 没走成的那些轮次等的就是它，太长就像卡住了
@export var idle_before_move: Vector2 = Vector2(2.0, 6.0)
## 待机时间到了之后，**真的起身走动**的概率。没中的话只是接着待机（再等一轮）——
## 这是把"一直在动"调成"偶尔动一下"的主开关，想让她活泼就往 1.0 调。
## 2026-10-01 默认从 0.35 调到 0.2（用户要求"走动概率再调低点"）；
## 右键菜单「移动频率」四档 / 设置面板都能改
@export_range(0.0, 1.0, 0.05) var move_chance: float = 0.2
## 「移动频率」菜单的四档值（对应 pet_menu 的 ID_MOVE_*）。
## 想让档位更细就改这张表 + pet_menu 里的标签
const MOVE_CHANCE_STEPS: Array[float] = [0.0, 0.1, 0.2, 0.5]
## 「只在小范围走动」：开着她只在**家**附近那一小块里转，不再满屏溜达。
## 家 = home_anchor / 你拖到的位置（见 drag_sets_home）。
## 边界怎么算、已经在圈外怎么处理，都在 pet_walk._step_move 里（和安静模式共用一套）
@export var stay_nearby: bool = false
## 上面那一小块有多大（像素，半径）。
## 2026-09-27 从 220 收到 **140**：用户反馈"限制他活动范围再小一点"——
## 220 的正方形边长 440px，在 330×470 的窗口里几乎还是满屏转；140 更贴身。
## 想再调：设置面板里能改（或检查器），这里只是出厂值
@export_range(40.0, 400.0, 10.0) var nearby_radius: float = 140.0
## 走路一次持续多久（秒）—— 和跑步分开计时
@export var walk_duration: Vector2 = Vector2(2.0, 6.0)
## 跑步一次持续多久（秒）。跑步更费劲，通常比走路短促
@export var run_duration: Vector2 = Vector2(1.0, 2.5)
@export var rest_min: float = 0.4
@export var rest_max: float = 2.2
@export var run_chance: float = 0.22
@export var emote_chance: float = 0.3
@export var blink_chance: float = 0.006
## 会不会往屏幕上下方向走（在 3D 里就是"背对镜头走远 / 正对镜头走近"）
@export var allow_vertical_move: bool = true
## 竖直方向相对左右的出现权重：1 = 同概率，0 = 从不
@export_range(0.0, 2.0, 0.05) var vertical_move_weight: float = 0.7
## 朝向跟随移动方向的程度：
##   1 = 完全朝移动方向（向右走就转向右、往上走就背对镜头）
##   0 = 永远正对屏幕
@export_range(0.0, 1.0, 0.05) var face_move_direction: float = 1.0
## 离"家"多远之内不施加回家的倾向（像素）
@export var home_deadzone: float = 150.0
## 回家倾向的强度：0 = 关闭（永远随机走），1 = 远离到屏幕半对角线时必然往回走
@export_range(0.0, 1.0, 0.05) var home_pull: float = 0.8
## 拖拽放下后，把落点当成新的"家"（同时更新启动时的停靠位置）。
## 关掉的话拖拽只是临时挪一下，家仍然是 home_anchor / 菜单设的那个。
@export var drag_sets_home: bool = true

@export_group("全屏时")
## 检测到有全屏窗口（看视频、玩游戏）时进入"安静模式"：只在家的附近一小块里挪动、
## 起身更少、不跑。关掉这个开关就**不会**再留那个后台检测进程（见 scripts/pet_shell.gd）
@export var quiet_when_fullscreen: bool = true
## 安静模式下允许离"家"多远（像素）。窗口左上角的活动半径 ——
## 220 的直径在 1080p 上就是屏幕的一小块
@export var quiet_radius: float = 110.0
## 安静模式下待机时间的倍率
@export_range(1.0, 6.0, 0.1) var quiet_idle_scale: float = 2.5
## 安静模式下单次移动时长的倍率（走两下就停，不在小范围里来回蹭）
@export_range(0.1, 1.0, 0.05) var quiet_move_scale: float = 0.5

@export_group("系统")
## 隐藏任务栏图标：不在任务栏和 Alt+Tab 里出现（桌面上照常显示）。
## 桌宠是常驻后台的，默认开着 —— 不然任务栏会一直挂着一条。
## 实现见 scripts/pet_shell.gd（Windows 上是 WS_EX_TOOLWINDOW）
@export var hide_taskbar_icon: bool = true
## 开机自启动（Windows 用户级注册表 Run 项）。
## 默认**关**：写注册表这种事得你主动点一下菜单里那个开关，不该替你做主
@export var autostart_enabled: bool = false
## 托盘图标：任务栏右下角"隐藏的图标"溢出区里放一个，右键能显示/隐藏她、或退出。
## Godot 没有托盘 API，这个图标由辅助进程托管（和全屏检测共用一个进程）
@export var tray_icon: bool = true

@export_group("互动")
@export var pet_cooldown: float = 0.45
@export var hop_height: float = 0.35
@export var double_click_ms: int = 320

@export_group("动画节奏")
## 所有动画的播放速度倍率（1.0 = 模型原始速度，越小动作越慢）
@export_range(0.2, 2.0, 0.05) var anim_speed: float = 0.7
## 眨眼间隔倍率（越大越少眨眼）
@export_range(0.5, 8.0, 0.1) var blink_slowdown: float = 2.5
## 行为节奏倍率（待机 / 散步时段整体拉长，越大越"懒"）
@export_range(0.5, 3.0, 0.05) var behavior_pace: float = 1.3

@export_group("聊天")
## 总开关。关掉 = 完全不联网，回到纯本地桌宠
@export var chat_enabled: bool = true
## 联系不上 AI 服务时她进**假死**：只剩基础功能（走动 / 眨眼 / 摸头 / 喂食 / 睡觉 /
## 拖拽 / 菜单 / 本地台词），一切要联网的都不做 —— 主动说话、生闷气、偷看、看摄像头、
## 记忆抽取、派活，连自己乱走都停（待在原地，被摸了还是会反应）。
## 恢复之后自动回来。关掉这个 = 断网时她照旧装作没事
@export var hibernate_when_offline: bool = true
## AI 服务地址。两种都能用，菜单「AI 服务设置…」里一键切：
##   官方 API（付费 key）      https://api.deepseek.com
##   本地网页版（不用付钱）    http://127.0.0.1:8520/v1   ← deepseek-web-api
## 默认先走官方 API：网页端 userToken 会过期，付费 key 更稳
@export var chat_url: String = "https://api.deepseek.com"
## 官方 API 的付费 key（sk- 开头）。留空也行 —— 在菜单「AI 服务设置…」里填，
## 会存进 user://pet_chat.cfg（在用户目录里，不进项目目录、不会被误提交）
@export var chat_access_key: String = ""
## 文本模型。官方 API 实测可用：deepseek-flash / deepseek-v4-pro
@export var chat_model: String = "deepseek-flash"
## 视觉那条链路的服务地址与模型 —— **偷看屏幕 / 看摄像头都走它**。
## 网页版只把对话拼成文本，图片等于没发；官方 API 有带视觉的别名
@export var vision_url: String = "https://api.deepseek.com"
@export var vision_model: String = "deepseek-v4-flash-vision-exp"
## 视觉那条的 key。留空 = 复用 chat_access_key（官方 API 同一个 key 能调视觉）
@export var vision_access_key: String = ""
## 人设提示词。deepseek-web-api 会把 messages 拼成一段 prompt，
## 所以这就是"她是谁"的唯一来源
@export var chat_system_prompt: String = ""
## 她的名字（写进人设提示词）。想换名字改这里，不用动 scripts/pet_persona.gd
@export var chat_persona_name: String = "小蓝"
## 长期记忆总开关（scripts/pet_memory.gd）。关掉 = 她每次都像第一次见你
@export var memory_enabled: bool = true
## 让她用模型抽记忆。会多一次非流式请求（很便宜但确实在花钱）；
## 关掉只影响"自动抽取"，本地规则抓到的记忆照常记
@export var memory_ai_extract: bool = true
## 两次 AI 抽取之间至少隔多久（防止连发几句就连着调模型）
@export_range(5.0, 300.0, 5.0) var memory_ai_every_sec: float = 30.0
## 每聊几轮更新一次"工作记忆"（整体了解 + 还没聊完的话题 + 最近心情）
@export_range(1, 50, 1) var memory_summary_every: int = 6
## 把她"主动搭话 / 偷看屏幕"说的内容也选择性记进长期记忆（关掉只记打字聊的那些）
@export var memory_observe: bool = true
## 让她把"简单工作"交给本机的 DeepSeek Harness（dsh）去做，见 scripts/pet_harness.gd。
## 默认**关**：它会在你机器上真跑一个 agent 进程、花你的额度，这种事得你主动开
@export var harness_enabled: bool = false
## dsh 推理档的天花板（off / low / high / max）。任务大小会自动估一档，但不会超过它 ——
## 想让额度有个上限就把这个压低
@export var harness_max_effort: String = "max"
## 一趟 dsh 的活最多等多久（秒）。超过就放弃等待、解锁聊天（dsh 进程杀不掉，随它去）。
## **没有这层的话，一次卡死的活会把聊天永远钉在"我还在弄那件活呢"上**
@export_range(60.0, 3600.0, 30.0) var harness_timeout_sec: float = 600.0
## 聊天框里保留几行对话
@export_range(1, 8, 1) var chat_log_lines: int = 3
## "快速回答"按钮：她说完话后，气泡下面给几个"主人可能接着说"的按钮。
## 出现在两个时机：她主动开口之后、以及**聊天之后概率出现**
@export var quick_enabled: bool = true
## 让模型现编那几句候选。关掉 = 只用本地那几组写死的（秒出，但翻来覆去就那几句）
@export var quick_ai: bool = true
## 快速回答那条**单独用哪个模型**。留空 = 跟聊天同一个。
## 留这个口子是因为：这条只要"快"（编三句候选而已），而聊天那条可能想让它"想得深" ——
## 嫌它慢就填个不思考的模型（本机 web-api 那边常用 deepseek-chat）
@export var quick_model: String = ""
## 她**主动开口**时，弹出快速回答的概率。不给 1.0 是刻意的：
## 每次都有就变成"必看的表"，有时有、有时没有才像随手递过来的话
@export_range(0.0, 1.0, 0.05) var quick_chance: float = 0.7
## 聊天时也**概率**弹一次。比主动开口低 —— 聊天时你多半正打着字，按钮反而碍事
@export_range(0.0, 1.0, 0.05) var quick_chance_chat: float = 0.20
## 「回复按钮出现频率」菜单的四档值（对应 pet_menu 的 ID_QUICK_*）。
## 只给四档而不是细滑条：右键菜单里选档比翻设置面板快，想要更细去设置面板拖 quick_chance
const QUICK_CHANCE_STEPS: Array[float] = [0.0, 0.25, 0.5, 0.75]
## 主动说话总开关。注意 deepseek-web-api **没有推送通道**，
## 所以"主动开口"完全由本地计时决定（见 self_talk_after）
@export var proactive_enabled: bool = true
## 偷看屏幕后评论（截图 → 视觉模型）。**截图会发给模型服务商**，默认关
@export var peek_enabled: bool = false
## 多久偷看一次（分钟）
@export_range(1.0, 60.0, 0.5) var peek_every_min: float = 5.0
## **主动说话时先瞥一眼屏幕**再找话题（默认开，2026-09-27 用户要求）。
## 为什么要它：不然她只能凭**记忆**起话头，而记忆是过去的事 —— 用户报的
## "他主动说话与我正在干的事不一样"就是这么来的。开了之后她拿着画面（以及
## "前台开着什么窗口"）说话，画面抓不到时也至少有窗口标题可以纠偏（见 pet_peek）。
@export var proactive_peek_enabled: bool = true
## 上面那个"瞥一眼"的概率。**不是每次都看**：每次开口都抓屏 + 多一次视觉请求太贵，
## 而且老盯着主人看很黏人。0.35 ≈ 三次里看一次
@export_range(0.0, 1.0, 0.05) var proactive_peek_chance: float = 0.35
## 桌宠自己闲得慌时主动说一句（本地行为触发，不依赖后端）
@export var self_talk_enabled: bool = true
## 多久没人理她才自己开口（秒，在这个区间里随机）
@export var self_talk_after: Vector2 = Vector2(300.0, 900.0)
## 高峰时段的定义**不在检查器里**：照 DeepSeek 官方峰谷定价写死在 pet_proactive.peak_active
## （工作日 9:00–12:00、14:00–18:00，北京时间；周末全天低谷）。这里只留开关本身
## 定时用**本机摄像头**看看我在干嘛（走 Godot 自带的 CameraServer，不依赖外部程序）
@export var camera_look_enabled: bool = false
## 多久看一次摄像头（分钟）
@export_range(1.0, 60.0, 0.5) var camera_every_min: float = 10.0
## 多摄像头时挑哪一个
@export_range(0, 4, 1) var camera_index: int = 0

# ------------------------------------------------------------------ 台词

## 本地台词：AI 服务没起来（或没配）时她说的那些话。
## 口吻必须和 scripts/pet_persona.gd 的人设一致 —— 这里写成"女仆腔"的话，
## 一断网她就换了个人，特别出戏
const LINES_IDLE: Array[String] = [
	"诶，你在忙什么呀？", "有点无聊…陪我会儿嘛。", "我刚刚是不是又发呆了。",
	"要不要歇一下？", "你一直没理我诶。",
]
## 摸头 / 摸各部位的台词、被冷落的台词，都搬去 scripts/pet_mood.gd 了 ——
## 它们是"情绪"那块自己的内容，和判定规则放在一起才不会改漏一边
const LINES_FEED: Array[String] = ["好吃！", "谢谢…我正好饿了。", "还有吗？就一口。"]
const LINES_SLEEP: Array[String] = ["那我先眯一会儿…", "困死了，晚安。", "呼…呼呼…"]
const LINES_WAKE: Array[String] = ["唔…我睡多久了？", "早…现在几点了诶。", "啊，我睡着了？"]

# ------------------------------------------------------------------ 常量

enum State { IDLE, WALK, DRAG, SLEEP }

const EMOTE_NAMES: Array[String] = [
	"extra0", "extra2", "extra3", "extra4", "extra5", "extra6", "extra7",
]

## 聊天客户端（非阻塞 HTTPClient + SSE 流式解析），见 scripts/pet_chat.gd
const PetChat := preload("res://scripts/ai/pet_chat.gd")
const PetBubble := preload("res://scripts/ui/pet_bubble.gd")
## 窗口 / 缩放 / 家（背景、机位、归一化锚点存档），见 scripts/pet_window.gd
const PetWindow := preload("res://scripts/sys/pet_window.gd")
## 装配 / 动画（包围盒、材质、UV、眨眼叠加层、动作计时），见 scripts/pet_rig.gd
const PetRig := preload("res://scripts/body/rig/pet_rig.gd")
## 行为（待机 / 散步 / 回家引力 / 朝向），见 scripts/pet_walk.gd
const PetWalk := preload("res://scripts/body/pet_walk.gd")
## 鼠标 / 互动（悬停 / 穿透 / 拖拽 / 摸头喂食睡觉跳跃），见 scripts/pet_pointer.gd
const PetPointer := preload("res://scripts/body/pet_pointer.gd")
## 系统集成（开机自启动 / 隐藏任务栏图标），见 scripts/pet_shell.gd
const PetShell := preload("res://scripts/sys/shell/pet_shell.gd")
## 长期记忆（遗忘曲线 + 分层 + 检索 + 工作记忆），见 scripts/pet_memory.gd
const PetMemory := preload("res://scripts/ai/memory/pet_memory.gd")
## 人设提示词拼装（scripts/ai/pet_persona.gd）现在只被 pet_memory_host.gd 用，
## 宿主这边不再直接引它了 —— 原来那两处调用（_refresh_persona / _context_for）已搬走
## 聊天设置：后端地址 / 用户 id / 主动说话开关。
## 和"家"一样存 user:// —— 改完就记住，不动场景文件
const CHAT_CONFIG := "user://pet_chat.cfg"
## 主动搭话的提示词跟着那条路搬去了 **pet_proactive.gd**（2026-09-29 第③条）——
## 它只被那一支用；留在宿主这边只会变成"改了没反应"的副本
## 偷看屏幕 / 摄像头那两条的提示词跟着那条链搬去了 **pet_peek.gd**（作业单 B6.1b）——
## 它们只被那几支用；留在这儿只会变成"改了没反应"的副本
## 生闷气 / 偷看式生闷气那两条提示词搬去了 **pet_mood_ui.gd**（2026-10-01 拆分）
## 摸得太频繁时用的提示词：她**主动开口**让主人停手。
## 口气是"不耐烦但没真生气"—— 写狠了就变成另一种人物了
const PROMPT_TOUCH := "（主人一直在摸你、戳你，没完没了。用你自己的口气跟他说一句，让他停手，" \
	+ "一两句就好。可以有点不耐烦、可以撒着娇地凶他，但别真的长篇大论）"
## dsh 干完活之后给她的提示词：让她**用自己的口气讲结论**。
##
## 为什么不让它照念原文：dsh 的答案经常是带小标题的一大段（它是个 agent，不是翻译机），
## 原样念进气泡既不像她、也塞不下。原文另有一份在聊天记录里（_push_chat_line("dsh", …)），
## 要细节回头看就行。**特意交代别提 "dsh / harness"** —— 她一嘴工具名，人设就破了
const PROMPT_HARNESS_RESULT := "（主人让你做一件事，你已经用本机的 DeepSeek Harness 做完了。\n" \
	+ "主人要你做的：%s\n它的结果：%s\n" \
	+ "现在用你自己的口气把**结论**讲给主人听，一两句话，别把上面那段照念，" \
	+ "也别提 dsh、harness、模型这些词）"
## 聊天框里怎么给她派活：说一句以这些开头的（"干活：帮我看看这段代码为什么报错"）
const HARNESS_PREFIXES: Array[String] = ["干活：", "干活:", "dsh：", "dsh:", "/dsh ", "让dsh "]
## dsh 的答案塞进"让她转述"那条提示词里时最多留多少字（太长的原文她也没法一两句讲完）
const HARNESS_FEED_LIMIT := 1500
## 快速回答（气泡下那列"主人可能接着说什么"的按钮）整块在 scripts/pet_quick.gd：
## 常量 / 本地候选 / 那列 UI / 它自己的那条连接都跟着走了
##
## 情绪那块的常量（等多久算被冷落、摸几下算太频繁、各部位的台词）在 scripts/pet_mood.gd

## 进假死状态时（联系不上外面）她说的那一句 —— 只说一次，别每轮探活失败都念叨
const LINES_OFFLINE: Array[String] = [
	"诶…我好像联系不上外面了。先这样陪你吧。",
	"网是不是断了？那我先不吵你，就待在这儿。",
]

## 本地候选（quick_options_for）和"把模型吐的 JSON 洗干净"（parse_quick_options）
## 也搬去 scripts/pet_quick.gd 了 —— 它们是同一件事的两半，放一起才好改

## 菜单：条目/分组/勾选项/AI 设置面板都在 scripts/pet_menu.gd 里，
## id 用它的 PetMenu.ID_* —— 场景里只留一个空的 PopupMenu 节点
const PetMenu := preload("res://scripts/ui/pet_menu.gd")
## 设置面板（人设 / 记忆 / 说话 / 窗口 / 系统），见 scripts/pet_settings.gd
const PetSettings := preload("res://scripts/ui/pet_settings.gd")
## 调用本机 DeepSeek Harness（dsh）干简单活，见 scripts/pet_harness.gd
const PetHarness := preload("res://scripts/sys/pet_harness.gd")
## 工作台面板（派活 / 看原文 / 重启她），见 scripts/pet_workbench.gd
const PetWorkbench := preload("res://scripts/ui/pet_workbench.gd")

## 设置面板里那批键 → 检查器里的变量名。
## **面板只认键、主脚本只认变量**，两边靠这张表对上 —— 所以"加一项设置"要动的地方
## 只有三处：pet_settings.gd 的 SECTIONS（长什么样）、这张表（存到哪个变量）、
## _apply_settings()（要不要额外做点什么）。
##
## 不在这张表里的键各有各的出处，单独处理，见 _apply_settings：
##   proactive_on / talk_rate / peek_on / camera_on —— 运行时开关（不是检查器变量）
##   quiet_fullscreen / hide_taskbar / tray_icon / autostart —— 真正动手的是 shell
##   scale_percent —— 真正动手的是 window
##
## 顺序上：这两张 const 必须排在**用它们的变量声明之前** —— GDScript 解析
## `var x: PetSettings` 这类类型标注时不看后面，放后面会报 "Could not find type"
const SETTING_VARS: Dictionary = {
	"persona_name": "chat_persona_name",
	"persona_extra": "chat_system_prompt",
	"memory_enabled": "memory_enabled",
	"memory_ai_extract": "memory_ai_extract",
	"memory_ai_every_sec": "memory_ai_every_sec",
	"memory_summary_every": "memory_summary_every",
	"memory_observe": "memory_observe",
	"chat_log_lines": "chat_log_lines",
	"self_talk_enabled": "self_talk_enabled",
	"peek_every_min": "peek_every_min",
	"camera_every_min": "camera_every_min",
	"catch_padding": "catch_padding",
	"double_click_ms": "double_click_ms",
	"pet_cooldown": "pet_cooldown",
	"drag_sets_home": "drag_sets_home",
	"move_chance": "move_chance",
	"stay_nearby": "stay_nearby",
	"nearby_radius": "nearby_radius",
	"chat_enabled": "chat_enabled",
	"quick_enabled": "quick_enabled",
	"quick_ai": "quick_ai",
	"quick_model": "quick_model",
	"quick_chance": "quick_chance",
	"quick_chance_chat": "quick_chance_chat",
	"quiet_fullscreen": "quiet_when_fullscreen",
	"gpu_threshold": "gpu_threshold",
	"harness_enabled": "harness_enabled",
	"harness_max_effort": "harness_max_effort",
	"harness_timeout_sec": "harness_timeout_sec",
}

## 设置面板里**需要落盘**的键。
## 上面那张表**减掉**已经在 "chat" 段存过的四个（主动说话 / 频率 / 偷看 / 摄像头，
## 见 _save_chat_config）—— 同一件事存两处，早晚会不一致
const SETTING_SAVED: Array[String] = [
	"persona_name", "persona_extra",
	"memory_enabled", "memory_ai_extract", "memory_ai_every_sec",
	"memory_summary_every", "memory_observe",
	"chat_log_lines", "self_talk_enabled", "peek_every_min", "camera_every_min",
	"catch_padding", "double_click_ms", "pet_cooldown", "drag_sets_home",
	"move_chance", "stay_nearby", "nearby_radius",
	"chat_enabled", "quiet_fullscreen", "gpu_threshold", "hide_taskbar", "tray_icon", "autostart",
	"scale_percent", "harness_enabled", "harness_max_effort", "harness_timeout_sec",
	"quick_enabled", "quick_ai", "quick_model", "quick_chance", "quick_chance_chat",
]

## （`PEEK_RETRY_SEC` 跟着偷看 / 摄像头那条链搬去了 pet_peek.gd —— 只有那两支用它）

# ------------------------------------------------------------------ 内部状态

var _state: int = State.IDLE
var _timer: float = 3.0
## 当前移动方向（屏幕空间单位向量：+x 向右、+y 向下；零向量 = 没在动）
var _move_dir: Vector2 = Vector2.ZERO
## 窗口位置只能取整像素，用它把每帧不足 1px 的位移累积起来 —— 否则 60fps 下
## 46px/s 会被 int() 截断成 0，走不走得动全看帧率
var _move_accum: Vector2 = Vector2.ZERO
var _speed: float = 0.0
var _run: bool = false
var _sleeping: bool = false

# 角色包围盒的节流缓存
var _aabb_cache: AABB = AABB()
var _aabb_frame: int = -1

# 拖动
var _dragging: bool = false
var _drag_origin_mouse: Vector2 = Vector2.ZERO
var _drag_origin_win: Vector2i = Vector2i.ZERO
var _moved: float = 0.0

# 鼠标
var _last_click_ms: int = 0
var _last_pet: float = 0.0
var _hover: bool = false
var _catching: bool = false
var _passthrough_bound: Rect2 = Rect2()    # 当前"可点区域"的包围盒，只用于死区比较
var _passthrough_set: bool = false
## 透明模式（点不到我）：整窗不再接鼠标 —— 点她 = 点到她后面的窗口，
## 看不见的边界也随之消失（2026-09-30 用户要求）。开关在菜单和托盘图标里；
## 这是运行时状态、不落盘，重启回到可点
var _ghost_on: bool = false
## GPU 占用率超过这个值（%）她自动"透视"自己：整窗穿透（不挡后面的游戏、不被误触）
## + 不递候选按钮。0 = 关掉自动透视。阈值在设置面板里拖（2026-10-03 用户要求）
@export_range(0.0, 100.0, 1.0) var gpu_threshold: float = 40.0
## 现在是否处于"自动透视"状态（GPU 高）。穿透和候选抑制都看它
var _gpu_passthrough: bool = false

var _rng := RandomNumberGenerator.new()
var _screen: Rect2i = Rect2i()

@onready var _character: Node3D = $Character
@onready var _pivot: Node3D = $Character/Pivot
@onready var _model: Node3D = $Character/Pivot/Model
@onready var _anim: AnimationPlayer = $Character/Pivot/Model/AnimationPlayer
@onready var _camera: Camera3D = $Camera3D
@onready var _bubble: Label = $UI/Anchor/Bubble
@onready var _menu: PopupMenu = $UI/Menu

var _anim_face: AnimationPlayer = null     # 运行时创建的表情叠加层
var _has: Dictionary = {}                  # 已探测到的动画名 -> true
var _action_end: Dictionary = {}           # 一次性动作名 -> "动作真正结束的时刻"（动画时间轴秒）
var _idle_anim: String = "idle"
var _hop_tween: Tween = null
var _calibrated: bool = false
var _calib_aabb: AABB = AABB()
var _ground_offset: float = 0.0

# 聊天
var _chat: PetChat = null                  # 客户端实例（RefCounted，不用手动释放）
var _menu_mod: PetMenu = null              # 菜单模块（分类菜单 + AI 设置面板）
var _settings_mod: PetSettings = null      # 设置面板（scripts/pet_settings.gd）
## 检查器里的出厂值（设置面板的「恢复默认」要用）。
## **必须在读存档之前抓下来** —— 读存档会把值写回那些变量，之后就再也分不清
## "你改过的"和"检查器里的默认值"了
var _factory: Dictionary = {}
## 当前大小档（1.0 = 100%）。窗口那边只认百分比，这里记一份是为了设置面板能显示
var _scale_pct: float = 1.0
var _chat_open: bool = false               # 输入框是否开着
var _chat_streaming: bool = false          # 正在收流（气泡里逐字冒字）
var _chat_panel: Control = null            # 运行时搭的输入面板
var _chat_log_label: Label = null          # 面板上方的历史行
## 聊天记录的滚动容器（上下拖动/滚轮往前翻）。面板高度固定，记录本身可以有很多行
var _chat_scroll: ScrollContainer = null
var _chat_input: LineEdit = null
var _chat_log: Array[String] = []          # 最近几行对话，只用来显示
var _proactive_on: bool = true             # 主动说话总开关（运行时，可被菜单切）
## 高峰时段少说话（运行时开关，菜单里切）。开着时，在 DeepSeek 官方高峰时段
## （工作日 9~12、14~18）主动开口间隔 ×5（口径见 pet_proactive.peak_active）
var _peak_reduce_on: bool = false
var _peek_on: bool = false                 # 偷看屏幕开关（运行时，可被菜单切）
var _camera_on: bool = false               # 摄像头开关（运行时，可被菜单切）
## 主动说话时先瞥一眼屏幕（运行时；出厂默认开，见 proactive_peek_enabled）
var _proactive_peek_on: bool = true
var _peek_timer: float = 0.0               # 距离下次偷看屏幕还有多久
## 「她自己开口」的倒计时和频率档**不在这儿**了：2026-09-29 第③条整块搬进了
## scripts/ai/pet_proactive.gd —— 用时取 `_proactive.timer` / `_proactive.rate`
## 这一轮回复是谁引出来的：chat（打字）/ proactive（她自己找话）/ peek（偷看屏幕）/ camera。
## 记忆那边要按它决定记不记、怎么记 —— 主动搭话和偷看每天好几条，不能像打字那样整轮存
var _last_origin: String = ""
## 进假死状态的那句"联系不上了"说过了没（只说一次，恢复时再说一句"好了"）
var _offline_said := false

## 情绪（委屈度 / 生闷气 / 被摸到的反应）整块在 scripts/pet_mood.gd：
## **状态和判定归它，开口说话留在本文件**（要窗口 / 截图 / 流式气泡，模块不该碰）。
## 委屈度会写进人设【现在】，所以她的口气会自然带出来 —— 取用见 _mood.level()
const PetMood := preload("res://scripts/body/pet_mood.gd")
var _mood: PetMood = null
## 情绪 / 触摸的「开口 + 哄她选择框」层（判定在 pet_mood.gd）。2026-10-01 从本文件拆出
const PetMoodUi := preload("res://scripts/body/pet_mood_ui.gd")
var _mood_ui := PetMoodUi.new()
## 快速回答（气泡下那列按钮）整块在 scripts/pet_quick.gd：
## 它自持状态、自建 UI、自有一条连接，宿主这边只剩这一个引用
const PetQuick := preload("res://scripts/ai/pet_quick.gd")
var _quick: PetQuick = null
var _cjk_font: SystemFont = null           # 中文字体，切换输入框焦点时也要用
var bubble: PetBubble = null               # 气泡模块（scripts/pet_bubble.gd）：显示 / 撑高 / 淡出 / 流式按住
var window: PetWindow = null               # 窗口模块（scripts/pet_window.gd）：背景 / 机位 / 家锚点存取
var rig: PetRig = null                     # 装配模块（scripts/pet_rig.gd）：包围盒 / 材质 / 动画工具
var walk: PetWalk = null                   # 行为模块（scripts/pet_walk.gd）：待机 / 散步 / 回家引力 / 朝向
var pointer: PetPointer = null             # 互动模块（scripts/pet_pointer.gd）：悬停 / 穿透 / 拖拽 / 反应
var shell: PetShell = null                 # 系统集成（scripts/pet_shell.gd）：开机自启动 / 任务栏图标
## 单实例保护 + 心跳（scripts/sys/pet_instance.gd）：已经有一个她在跑就别起第二个 ——
## 2026-09-29 用户报"我退出了，你那边却说没退"，根子就是两个实例同时在跑
const PetInstance := preload("res://scripts/sys/pet_instance.gd")
var instance := PetInstance.new()
var memory: PetMemory = null               # 长期记忆（scripts/pet_memory.gd）
var harness: PetHarness = null             # 本机 dsh 的调用口（scripts/pet_harness.gd）
var _workbench: PetWorkbench = null        # 工作台面板（scripts/pet_workbench.gd）
## 这一轮派给 dsh 的活（回来时要拿它拼"让她转述"的提示词）
var _harness_task: String = ""
## 这一轮的活是从工作台派的（那就不让她转述，原文直接摆在工作台里）
var _harness_from_workbench: bool = false
## 记忆流程（收尾 / 筛选 / 后台请求的节奏）整块在 scripts/pet_memory_flow.gd ——
## 它自己记"上一句说了什么""第几轮""后台那条在干什么"，宿主只剩这一个引用
const PetMemoryFlow := preload("res://scripts/ai/memory/pet_memory_flow.gd")
var _memory_flow: PetMemoryFlow = null
## 记忆 / 人设 / 上下文的**宿主侧**整块在 scripts/ai/pet_memory_host.gd ——
## 建记忆、拼人设、每轮上下文、"这句话该不该记"的总谱都归它。
## 宿主只留一批**同名薄壳**：pet_touch / pet_peek / pet_mood_ui 这些模块是按
## `_refresh_persona` / `_ai_busy` 这类老名字调进来的，壳挪走只会让调用链更难追
const PetMemoryHost := preload("res://scripts/ai/memory/pet_memory_host.gd")
var _memory_host := PetMemoryHost.new()
## 聊天那条链的接线与流式整块在 scripts/ai/pet_chat_flow.gd
const PetChatFlow := preload("res://scripts/ai/pet_chat_flow.gd")
var _chat_flow := PetChatFlow.new()
## 聊天输入面板的样子与开关在 scripts/ui/pet_chat_panel.gd ——
## 搭 UI / 开收 / 报送出一句话 / 记录与滚动都归它。
## 宿主留同名薄壳：_open_chat 被 pet_pointer（双击）和菜单调、_push_chat_line 被别的模块调
const PetChatPanel := preload("res://scripts/ui/pet_chat_panel.gd")
var _chat_panel_mod := PetChatPanel.new()
## 短期记忆：「她主动说的话、主人还没接」的那些（2026-09-29 第②条）。
## 长期记忆只管"关于主人的事实"；**她自己说过什么**归这条管 ——
## 两边分家的起因见 scripts/ai/pet_shortterm.gd 的头部说明
const PetShortTerm := preload("res://scripts/ai/memory/pet_shortterm.gd")
var _shortterm := PetShortTerm.new()
var _vision: PetChat = null                # 视觉那条链路（偷看屏幕 / 看摄像头）。
										   # 独立一个客户端 = 独立一条连接：和文本流互不排队，
										   # 她正在说话时也照样能截屏去问
var _camera_busy: bool = false             # 摄像头那张照片还没回来
## 上一次采集摄像头失败的原因。用来把"没设备"和"设备在但出不了图"分开报 ——
## 这两种情况的排查方向完全不同（前者看权限/驱动/引擎枚举，后者看是否被占用、硬开关）
var _camera_last_error: String = ""
var _camera_timer: float = 0.0             # 距离下次"看一眼摄像头"还有多久
										   # 必须和 _chat_streaming 分开：两条链路各自有各自的
										   # 生命周期，共用的话摄像头结束会把正在收的流标记清掉

# ------------------------------------------------------------------ 生命周期

## 采样方式：方块模型的贴图是 256x256 的硬边像素画，alpha 只有全透明/全不透明两种。
## 用线性过滤的话，每个方块的边缘都会把相邻像素（包括透明区里那些偏亮的 RGB）
## 混进来，在轮廓上形成一圈白边。改成最近邻采样就完全没有这个问题。
@export var texture_filter_mode: int = BaseMaterial3D.TEXTURE_FILTER_NEAREST
## alpha 裁切阈值：alpha 大于它才算实体。贴图是二值 alpha，0.5 正好取在中间
@export_range(0.01, 0.99, 0.01) var alpha_scissor_threshold: float = 0.5
## 贴图边缘外扩（dilate）的像素数，0 = 关闭。
## Blockbench 图集的 UV 岛之间是空白像素，采样在 UV 边界会把空白混进轮廓；
## 把图案颜色往外扩几圈之后，边界采样拿到的就是相邻图案的颜色。见 _dilate_image()。
@export_range(0, 6, 1) var dilate_pixels: int = 2
## 是否启用 TAA（时间抗锯齿）。TAA 靠跨帧抖动 + 累积，能填掉方块之间那些
## MSAA 盖不住的亚像素缝隙（轮廓上的白线）。
## 注意：**TAA 和透明背景互斥** —— 实测打开 TAA 后 viewport 的透明像素会变成 0，
## 只能配不透明背景用，而且需要 Forward+ 渲染器。
## 当前选了透明背景，所以这里关掉 —— 透明窗口里真正管用的只有 MSAA + 超采样
## （原因见下面 screen_space_aa_mode 的说明）。
@export var use_taa: bool = false
## 是否用不透明背景。false = 只显示人物，其余部分完全透明。
## 注意：**导出后的 exe 拿不到窗口透明**（详见 README「导出成 exe」），
## 所以这个模式要用项目目录方式启动（`启动桌宠.bat`），不要导出。
@export var opaque_background: bool = false
## 不透明背景的颜色（只在 opaque_background 打开时生效）
@export var background_color: Color = Color(0.97, 0.97, 0.98)
## 每个面的 UV 向内收缩多少个 texel（0 = 关闭），启动时生效，改了要重启。
## 这是"方块棱边白色小锯齿"的根治手段，原理见 _inset_uvs()。
@export_range(0.0, 1.0, 0.05) var uv_inset_texels: float = 0.5
## 是否关掉镜面高光。
## 材质默认是 `specular_mode = Schlick-GGX = 0` + `metallic_specular = 0.5`（实测），
## 而 Fresnel 在**掠射角**会趋于 1 —— 方块模型的每条棱边恰好都是掠射角，
## 于是环境光被整片反射回来，在每条边烧出一串**白色小锯齿**
## （实测该区域亮像素 20 个里有 16 个是它造成的，颜色 rgb≈(0.85,0.85,0.94)
## 正好等于环境光色 (0.86,0.9,1)）。
## 像素画本来就是无高光的平面着色，关掉既符合原画风也更干净。
@export var disable_specular: bool = true
## 是否把"一次性动作的计时"裁到动作真正结束的那一刻。
## 起因：glb 里的 extra 动画做完手势后并不会立刻结束，而是**回到站立姿势再空转一段**
## （实测 extra0 只有前 51% 在动、extra5 只有前 39%，而 extra6/extra7 是 99%）。
## 按全长计时的话，表现就是"动作做一半就杵在那里不动，像回到了静止动画"。
## 打开后动作演完就接下一个，不再空等那段静止尾巴。
@export var action_tail_trim: bool = true
## 是否启用鼠标穿透（角色轮廓之外点击落到后面的窗口上）。
## 穿透是靠 Windows 的 SetWindowRgn 裁剪窗口区域实现的，实测它会让窗口可见区域
## 整体多出一层很淡的提亮（桌面图标看着发白、且边界正好在轮廓处），所以默认关掉；
## 需要穿透再打开，但要接受那层提亮。
@export var mouse_passthrough_enabled: bool = false
## 屏幕空间抗锯齿：关闭 / FXAA / SMAA。
## 它是**单帧的图像后处理**（边缘检测后沿着边缘混合），所以不要求不透明背景，
## 原理上能和透明窗口共存 —— 但实测它在透明背景下是**帮倒忙**（逐通道 diff 验证）：
##   - alpha 通道改动 **0** 个像素：它只磨 RGB、不磨 alpha，而轮廓锯齿长在 alpha 上，
##     所以该磨的地方一点没磨到；
##   - 被磨的只有 RGB，轮廓外侧透明区的 RGB 又是纯黑（实测），
##     于是边缘像素被**掺黑**（轮廓像素平均亮度 0.609 → 0.454，单点最大差 0.58），
##     合成到桌面上就是一圈**深色描边**，正好是"白色轮廓"的镜像毛病。
## 所以默认关闭。轮廓锯齿交给 MSAA 8x + 超采样 —— 它们在**采样阶段**生效，会真正磨到 alpha。
@export_enum("关闭", "FXAA", "SMAA") var screen_space_aa_mode: int = 0

## 把上面的下拉选项映射成 Viewport 的枚举值。
func _screen_space_aa_value() -> int:
	match screen_space_aa_mode:
		1:
			return Viewport.SCREEN_SPACE_AA_FXAA
		2:
			return Viewport.SCREEN_SPACE_AA_SMAA
		_:
			return Viewport.SCREEN_SPACE_AA_DISABLED

## 当前是否走不透明卡片形态，只看 `opaque_background` 这一个开关。
##
## 这里曾经额外加过"导出版强制切卡片"（`OS.has_feature("template")`），
## 因为当时以为"导出的 exe 拿不到窗口透明"。**那个结论是错的** ——
## 真实原因是清屏色没清零：清屏色默认 (0.3,0.3,0.3)，在透明 viewport 里它的 **RGB 会被保留而
## alpha 被置 0**，于是窗口的预乘 alpha 数据变成"alpha=0 但 RGB=0.3"，
## DWM 就把这 0.3 **加**在桌面上 —— 表现是整块均匀发灰/发白（实测 +153/255，不随底色变化，
## 典型的加法混合）。把 `environment/defaults/default_clear_color` 设成 (0,0,0,0) 就干净了，
## 导出版一样能真透明。所以强制卡片那段已经删掉。
func _use_opaque() -> bool:
	return opaque_background

## 透明 flag 越早设越可靠：窗口刚创建时设置才真正作用于 Windows 的窗口样式，
## 放到 _ready() 里可能已经晚了一步（导出版实测就是这种情况）。
func _enter_tree() -> void:
	DisplayServer.window_set_flag(
		DisplayServer.WINDOW_FLAG_TRANSPARENT, not _use_opaque())
	# 系统集成也在这里建：任务栏图标同样属于"窗口样式"，越早设越可靠。
	# 注意这时候 @onready 还没赋值，所以 shell.apply_early() 只碰配置和 DisplayServer。
	shell = PetShell.new()
	shell.setup(self)
	shell.apply_early()
	# 藏任务栏图标这一步也尽量早：窗口一被创建就已经有任务栏按钮了，
	# 而 _ready 里要跑几秒的校准（量包围盒、量化动作结束时刻），
	# 放到那儿再设等于让它在任务栏上多挂好几秒。辅助脚本那边会重试等窗口出现。
	shell.apply_native()

## 退出时把那个后台检测进程收掉（它自己也会在发现我们没了之后退出，双保险）
func _exit_tree() -> void:
	_log_exit()          # 留一行"退出"——不然日志里只有启动，答不了"到底退没退"
	instance.release()   # 心跳收掉：下一个实例不用等它过期
	if shell != null:
		shell.stop()
	# dsh 那边：跑着的任务**不掐**（让它自己跑完，它是一次性进程），
	# 但设置文件必须还原 —— 那个不能留到"下次启动再说"
	if harness != null:
		harness.shutdown()

func _ready() -> void:
	# 单实例保护（摆在第一条，越早越好）：已经有一个她在跑就别起第二个 ——
	# 两个她会在屏幕上同时站着，你退掉其中一个、另一个还在（用户 2026-09-29 报的
	# "我这里已经退出，为什么你那里显示没退出"）；而且两个实例会互写同一份记忆文件。
	# 依据是心跳文件，见 scripts/sys/pet_instance.gd
	if _should_check_single_instance() and not instance.claim():
		var who := instance.alive_pid()
		print("[PetDeek] 已经有一个我在跑了（pid %d），这次不起第二个" % who)
		_log_line("没启动：已经有一个我在跑（pid %d）—— 两个实例会同时站在屏幕上" % who)
		get_tree().quit()
		return
	_rng.randomize()
	# 记录她这次是几点被"打开启动"的（写进上下文，让她对启动/关闭有概念）
	var _st := Time.get_datetime_dict_from_system()
	_started_at = "%02d:%02d" % [int(_st["hour"]), int(_st["minute"])]
	# 主动说话那条**必须在这里就接线**：下面的 _apply_settings() 会叫它重数倒计时
	# （_setup_chat 在它之后才跑 —— 接晚了那边一算 span() 就是 host=null，见 pet_proactive）
	_proactive.setup(self)
	# 出厂值先抓下来，后面 _load_* 会把变量改成存档里的值
	_factory = _factory_snapshot()
	bubble = PetBubble.new()
	bubble.setup(self, _bubble)
	window = PetWindow.new()
	window.setup(self)
	rig = PetRig.new()
	rig.setup(self)
	walk = PetWalk.new()
	walk.setup(self)
	pointer = PetPointer.new()
	pointer.setup(self)
	# 时间抗锯齿：跨帧累积，把方块边缘的阶梯磨平（需要不透明背景）
	get_viewport().use_taa = use_taa
	get_viewport().screen_space_aa = _screen_space_aa_value()
	_apply_background()
	if DisplayServer.window_get_size() != window_size:
		DisplayServer.window_set_size(window_size)
	_screen = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	_load_home()            # 上次记住的"家"（没有就用右下角），_apply_window_size 会停过去

	# 无边框 + no_focus 也要能收到鼠标移动事件
	if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS):
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)

	rig._fix_crossed_leg_parts()  # 模型里有几块右腿的方块挂在了左腿骨骼下，先纠正回来
	rig._scan_animations()      # 里面会创建表情叠加层并连好信号
	rig._apply_anim_speed()     # 所有动作整体放慢
	rig._harden_materials()     # 像素画采样 + 关掉 alpha 抗锯齿，消除轮廓白边
	rig._inset_uvs()            # 面片 UV 内缩半 texel，消除方块棱边的白色小锯齿
	rig._build_idle_anim()
	rig._apply_loop_modes()     # 走路/跑步这些持续动作要循环，否则会停在最后一帧
	rig._calibrate()            # 量出角色实际占用的空间，机位和落地都靠它
	rig._measure_action_ends()  # 量出每个一次性动作"真正做到哪一刻"，别空等静止的尾巴
	_apply_window_size()
	shell.apply_native()        # 窗口这时候才真的建出来，藏任务栏图标要等到这儿
	shell.fullscreen_aware = quiet_when_fullscreen
	shell.tray_icon = tray_icon
	shell.start_watcher()       # 全屏检测 + 托盘图标（两个都关掉才不起这个后台进程）

	_anim.animation_finished.connect(_on_main_finished)

	# 模块**先 setup 再干活**：_build_chat_ui 里就要用 _chat_panel_mod，
	# 放到后面（原来在 _apply_settings 之前那一串里）会拿到一个 _host 还是 null 的模块，
	# 表现是"面板建不出来 + 一堆 Nil 报错"（2026-10-04 拆完当天踩到的）
	_memory_flow = PetMemoryFlow.new()
	_memory_flow.setup(self)
	_memory_host.setup(self)
	_chat_flow.setup(self)
	_chat_panel_mod.setup(self)
	_build_chat_ui()        # 输入面板（先建好，收键盘时才来得及切焦点）
	_setup_quick()          # 快速回答那一列（跟在 _build_chat_ui 后面：要它建的中文字体）
	_setup_mood()           # 情绪（状态与判定归模块；它只发信号，开口的事留在本文件）
	_build_menu()           # 分类菜单 + AI 设置面板（runtime 搭，见 scripts/pet_menu.gd）
	_build_settings()       # 设置面板（scripts/pet_settings.gd）
	_build_workbench()      # 工作台面板（scripts/pet_workbench.gd）
	_load_chat_config()     # 上次改过的开关 / AI 后端设置
	# 设置面板里那些（人设 / 记忆 / 节奏 / 系统）也要在读记忆之前读回来：
	# memory_enabled 决定 _setup_memory 建不建，peek/camera 的间隔决定 _setup_chat
	# 里那几个倒计时的初值
	# 第二个参数 false = 别动系统层面的东西（注册表）。
	# 这里只是"把上次的选择读回来"，不是"用户刚改完"
	# 模块的 setup 挪到上面 _build_chat_ui 之前了（面板要用模块）。
	# 这里只留"为什么必须先建好再读设置"的原因：_apply_settings 里可能顺手调
	# _setup_chat()，而那儿要把 _chat 的信号接到 _memory_flow 上 —— 顺序错了接的就是 null
	# （也**不能**把创建放进 _setup_memory 里：memory_enabled 关掉时它第一行就返回）
	_apply_settings(_load_app_settings(), false)
	_setup_memory()         # 长期记忆要在 _setup_chat 之前建好：拼人设时就要用它
	_setup_chat()           # 连客户端信号 + 开局探一次 AI 服务
	_setup_harness()        # dsh 那条：只建对象（找 node/bin.js），真跑要等主人派活
	_sync_ai_status()       # 菜单里那行"AI 服务：…"（开局探活回来后会自己刷新）
	_sync_system_menu()     # 自启动的真实状态取自注册表，不看我们自己的开关
	_log_startup()          # "我是怎么被启动的" —— 自启动排查全靠这行日志

	walk._start_idle(walk._idle_time())

	if OS.is_debug_build():
		print("[PetDeek] 动画=%d 待机=%s 落地抬升=%.4f 相机size=%.3f" % [
			_has.size(), _idle_anim, _ground_offset, _camera.size])

func _process(delta: float) -> void:
	# _ready 还没跑完、或者中途出错停住时，这些模块还是 null —— 跳过这一帧就是。
	# ⚠️ 这道守卫**必须留**：窗口一显示就可能收到鼠标事件，_input 里 pointer 为 null
	# 会抛错并**打断 _ready**，于是那些模块再也没机会建起来，然后每帧接着抛
	# —— 表现是"启动即崩 + 满屏 Nil 报错"（2026-10-04 实测踩到）
	if pointer == null or rig == null or walk == null or instance == null:
		return
	instance.tick(delta)      # 心跳：告诉下一个想启动的实例"我还活着"（见 pet_instance.gd）
	pointer._update_hover()
	rig._update_idle_face()
	_tick_chat(delta)
	# 生闷气时弹的「哄她」选择框：8 秒没点就自己收掉（状态在 pet_mood_ui.gd）
	_mood_ui.tick()
	# GPU 占用率高（打游戏）→ 自动透视：整窗穿透 + 不递候选（阈值在设置面板）
	_tick_gpu()
	# 全屏检测 + 定期重申置顶（内部自己限流，不是每帧都干活）
	if shell != null:
		# 菜单开着时不能重申置顶：宠物是置顶窗口，重申会把它抬到置顶组最前面，
		# 正好盖住菜单（菜单也是置顶的独立窗口，谁在置顶组里更靠前就谁在上）
		shell.popup_open = _menu.visible
		shell.tick()
	_update_quiet()

	match _state:
		State.IDLE:
			_timer -= delta
			if _timer <= 0.0:
				walk._begin_move()
		State.WALK:
			# 自愈必须放在 _step_move 之前：它可能在结尾调 _start_idle 把状态改成
			# IDLE、动画改成 __pet_idle，自愈若放在后面就会拿着过期的 WALK 假设
			# 把动画又改回 walk（实测会打架：待机只活 0.04 秒就被改回去）
			rig._ensure_walk_anim()
			walk._step_move(delta)
		State.DRAG:
			pointer._process_drag()
		State.SLEEP:
			pass

	_update_facing(delta)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()

# ------------------------------------------------------------------ 窗口 / 缩放
# 实现全在 PetWindow（scripts/pet_window.gd）。这里留同名门面：探针和菜单
# 调的是这层稳定接口，模块内部怎么改都不影响它们。

func _apply_background() -> void:
	window.apply_background()

func _apply_window_size() -> void:
	window.apply_window_size()

func _dock_to_home() -> void:
	window.dock_to_home()

func _home_pos() -> Vector2i:
	return window.home_pos()

func set_home_here() -> void:
	window.set_home_here()

func set_home(anchor: Vector2) -> void:
	window.set_home(anchor)

func _load_home() -> void:
	window.load_home()

func set_scale_percent(pct: float) -> void:
	_scale_pct = pct
	window.set_scale_percent(pct)
	# UI 只受"窗口变大"影响（见 pet_window.set_scale_percent）：
	#   pct ≤ 1 → 窗口没变 → 画布 1:1 → UI 保持 100%，什么都不用做
	#   pct > 1 → 窗口放大了，画布跟着放大 → 把 UI 层反向缩回 100%
	# （UI 那层是 CanvasLayer，缩放的锚点就是窗口左上角，所以不用动 offset）
	var ui := get_node_or_null("UI") as CanvasLayer
	if ui != null:
		var k: float = 1.0 / maxf(1.0, pct)
		ui.scale = Vector2(k, k)

## 退出。
## **必须真的退干净**，这条路上踩过的坑：
##   1. 面板还开着（输入框抢着键盘焦点）时看着就像"点了没反应" —— 先收面板；
##   2. 托盘图标是那个辅助进程画的，不等它自己发现我们没了 —— 主动收掉，
##      点完退出图标立刻消失（_exit_tree 里还会再收一次，双保险）；
##   3. 顺手存一次设置：这次点退出多半刚改过设置，别指望"下次启动会存"。
## 真正结束进程交给引擎（get_tree().quit() 在当帧末尾生效）
func _quit() -> void:
	if OS.is_debug_build():
		print("[PetDeek] 退出")
	_close_panels()
	_save_app_settings()
	if shell != null:
		shell.stop()
	get_tree().quit()

# ------------------------------------------------------------------ 装配 / 动画
# 实现全在 PetRig（scripts/pet_rig.gd）。这里只留探针和其余区块要用的同名门面。

## 角色包围盒的节流缓存入口（说明见 PetRig._raw_model_aabb）
func _raw_model_aabb() -> AABB:
	return rig._raw_model_aabb()

func _beat(t: float) -> float:
	return rig._beat(t)

func _play_action(name: String, blend: float = 0.15, extra: float = 0.35) -> void:
	rig._play_action(name, blend, extra)

func _action_time(name: String, extra: float = 0.35) -> float:
	return rig._action_time(name, extra)

func _pick(names: Array, fallback: String) -> String:
	return rig._pick(names, fallback)

func _play(name: String, blend: float = 0.15) -> void:
	rig._play(name, blend)

func _blink() -> void:
	rig._blink()

func _on_main_finished(name: String) -> void:
	rig._on_main_finished(name)

# ------------------------------------------------------------------ 行为
# 实现全在 PetWalk（scripts/pet_walk.gd）。这里只留探针要用的两个门面；
# _ready / _process 和其它区块的内部调用直接打 walk._xxx。

func _pick_move_dir() -> Vector2:
	return walk._pick_move_dir()

func _update_facing(delta: float) -> void:
	walk._update_facing(delta)

## 当前是不是"安静模式"：检测到全屏 + 这个功能开着
func _quiet() -> bool:
	return quiet_when_fullscreen and shell != null and shell.fullscreen

## 安静模式的活动中心 = **进入安静模式那一刻她所在的位置**。
## 不用"家"：以家为中心的话，你一开全屏她就会被瞬间夹到家的位置，看着像瞬移。
var _quiet_center: Vector2i = Vector2i.ZERO
var _was_quiet: bool = false

## 每帧检查是不是刚进/刚出安静模式（进入时把当前位置记成活动中心）
func _update_quiet() -> void:
	var q := _quiet()
	if q and not _was_quiet:
		_quiet_center = DisplayServer.window_get_position()
		if OS.is_debug_build():
			print("[PetDeek] 进入安静模式：活动中心=%s 半径=%.0fpx" % [_quiet_center, quiet_radius])
	elif _was_quiet and not q and OS.is_debug_build():
		print("[PetDeek] 退出安静模式")
	_was_quiet = q

## 安静模式下窗口左上角的允许范围（和屏幕可用区域的求交在 pet_walk._step_move 里做）
func _quiet_bounds() -> Rect2i:
	var r := int(quiet_radius)
	return Rect2i(_quiet_center - Vector2i(r, r), Vector2i(r * 2, r * 2))

## 「只在小范围走动」的活动范围：以**家**为中心的一小块。
## 和安静模式的区别：那个的中心是"进入全屏那一刻她在哪儿"（自动触发的，不能瞬移），
## 这个的中心就是家（你主动开的开关，本来就希望她待在窝附近）。
## 已经在圈外的处理在 pet_walk._step_move 里 —— 等她溜达回来再管，不瞬移
func _nearby_bounds() -> Rect2i:
	return PetWalk.nearby_box(_home_pos(), nearby_radius)

# ------------------------------------------------------------------ 鼠标 / 互动
# 实现全在 PetPointer（scripts/pet_pointer.gd）。这里只留稳定门面：
#   - _input 是 Godot 虚函数，引擎只调主脚本，逐字转发给 pointer；
#   - _update_passthrough_region 被 PetWindow.apply_window_size 回调；
#   - _begin_drag / _end_drag 是探针（probe_drag_state）打的接口。

func _input(event: InputEvent) -> void:
	# _ready 完成之前窗口就可能收到鼠标事件（窗口一显示就算），那会儿 pointer 还是 null。
	# ⚠️ 漏了这道守卫：这里抛错会**打断 _ready**，模块再也建不起来，然后每帧跟着抛
	# —— "启动即崩 + 满屏 Nil 报错"（2026-10-04 实测）
	if pointer == null:
		return
	# GPU 自动透视中：鼠标事件一律不给 pointer（穿透其实已经让窗口收不到了，
	# 这是双保险 —— 万一 flag 被别的模式顶掉，也不能让她被误触）
	if _gpu_passthrough:
		return
	pointer._input(event)

func _update_passthrough_region() -> void:
	if pointer == null:
		return      # _ready 未完成（见 _process / _input 那两道守卫）
	pointer._update_passthrough_region()

func _begin_drag() -> void:
	pointer._begin_drag()

func _end_drag() -> void:
	pointer._end_drag()

## 透明模式（点不到我）：整窗对鼠标"透明"，点她不会选中她、也不会挡到后面的窗口。
## 用 WINDOW_FLAG_MOUSE_PASSTHROUGH（Godot 自带，整窗穿透）—— 比抠"只留轮廓可点"
## （mouse_passthrough_enabled 那套）干净得多，没有那层桌面提亮
func _apply_ghost() -> void:
	_apply_mouse_passthrough()

## 菜单 / 托盘都能切。开着时菜单里点不到了，所以托盘图标里也放了一份开关
func _toggle_ghost() -> void:
	_ghost_on = not _ghost_on
	_apply_ghost()
	_sync_menu_toggles()
	_say("点不到我啦～（用托盘图标能切回来）" if _ghost_on else "好啦，又能点我啦")

# -------------------------------------------------- 自动透视（GPU 高，2026-10-03）

## 整窗穿透的最终开关：透明模式（手动）或 GPU 自动透视，任一开着就穿透。
## 两者共用一个 WINDOW_FLAG_MOUSE_PASSTHROUGH，所以必须在这一处合并 ——
## 否则后写的一方会把另一方顶掉
func _apply_mouse_passthrough() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH,
		_ghost_on or _gpu_passthrough)

## 每帧调（只在状态翻面时才动 flag）：GPU 占用率超过阈值 → 自动透视；
## 降回来 → 恢复。数值来自 shell.gpu_usage（辅助进程每 0.5s 刷一次）
func _tick_gpu() -> void:
	var want := gpu_threshold > 0.0 and shell != null \
		and float(shell.gpu_usage) > gpu_threshold
	if want == _gpu_passthrough:
		return
	_gpu_passthrough = want
	_apply_mouse_passthrough()
	if want and _quick != null:
		_quick.hide()      # 透视时顺手把还挂着的候选收掉

# ------------------------------------------------------------------ 菜单 / 气泡

## 右键菜单。注意 PopupMenu 是个**独立窗口**（项目里 embed_subwindows=false），
## 它的坐标是**屏幕坐标**；而 _input 给过来的是窗口内坐标 —— 直接拿窗口内坐标
## 当位置用，菜单就会跑到屏幕左上角附近去。这里把窗口自身的位置补上。
func _open_menu(pos: Vector2) -> void:
	var screen_pos: Vector2i = DisplayServer.window_get_position() + Vector2i(int(pos.x), int(pos.y))
	_menu.popup(Rect2i(screen_pos, Vector2i.ZERO))

func _on_menu_id(id: int) -> void:
	match id:
		PetMenu.ID_PET:
			_last_pet = 0.0
			pointer._react_click()
		PetMenu.ID_FEED: pointer._feed()
		PetMenu.ID_SLEEP:
			if _state == State.SLEEP:
				pointer._wake_up()
			else:
				pointer._go_sleep()
		PetMenu.ID_JUMP: pointer._do_jump()
		PetMenu.ID_SCALE_75: set_scale_percent(0.75)
		PetMenu.ID_SCALE_100: set_scale_percent(1.0)
		PetMenu.ID_SCALE_135: set_scale_percent(1.35)
		PetMenu.ID_TOGGLE_TOP:
			# 走 shell 的意愿接口，而不是直接改标志 ——
			# 菜单开着时我们会故意把置顶摘掉，直接看标志会读错她的意愿
			if shell != null:
				shell.set_top_wish(not shell.top_wish)
		PetMenu.ID_TALK_LOCAL: _say(LINES_IDLE[_rng.randi_range(0, LINES_IDLE.size() - 1)])
		PetMenu.ID_SOOTHE: _soothe_her()
		PetMenu.ID_HOME_HERE:
			set_home_here()
			_say("记住这里啦～")
		PetMenu.ID_STAY_NEARBY: _toggle_stay_nearby()
		PetMenu.ID_GHOST: _toggle_ghost()
		PetMenu.ID_HOME_DEFAULT:
			set_home(PetWindow.HOME_DEFAULT)
			_dock_to_home()
			_say("回到右下角啦～")
		PetMenu.ID_QUIT: _quit()
		PetMenu.ID_RENAME: _open_rename()
		PetMenu.ID_SETTINGS: _open_settings()
		PetMenu.ID_WORKBENCH: _open_workbench()
		PetMenu.ID_CHAT: _open_chat()
		PetMenu.ID_ASK: _ask_proactive()
		PetMenu.ID_PEEK_NOW: _peek_and_comment()
		PetMenu.ID_CAMERA_NOW: _camera_look()
		PetMenu.ID_PROACTIVE: _toggle_proactive()
		PetMenu.ID_PEAK_REDUCE: _toggle_peak_reduce()
		PetMenu.ID_PEEK: _toggle_peek()
		PetMenu.ID_PROACTIVE_PEEK: _toggle_proactive_peek()
		PetMenu.ID_CAMERA: _toggle_camera()
		PetMenu.ID_AI_SETTINGS: _open_ai_settings()
		PetMenu.ID_AI_RECONNECT: _reconnect_ai()
		PetMenu.ID_HARNESS: _toggle_harness()
		PetMenu.ID_HARNESS_TASK: _open_harness_task()
		PetMenu.ID_AUTOSTART: _toggle_autostart()
		PetMenu.ID_HIDE_TASKBAR: _toggle_hide_taskbar()
		PetMenu.ID_QUIET_FULLSCREEN: _toggle_quiet()
		PetMenu.ID_TRAY: _toggle_tray()
		PetMenu.ID_TALK_SELDOM: _set_talk_rate(0)
		PetMenu.ID_TALK_NORMAL: _set_talk_rate(1)
		PetMenu.ID_TALK_OFTEN: _set_talk_rate(2)
		PetMenu.ID_TALK_VERY_OFTEN: _set_talk_rate(3)
		PetMenu.ID_QUICK_NEVER: _set_quick_chance(0)
		PetMenu.ID_QUICK_RARE: _set_quick_chance(1)
		PetMenu.ID_QUICK_HALF: _set_quick_chance(2)
		PetMenu.ID_QUICK_OFTEN: _set_quick_chance(3)
		PetMenu.ID_MOVE_NEVER: _set_move_chance(0)
		PetMenu.ID_MOVE_RARE: _set_move_chance(1)
		PetMenu.ID_MOVE_SOME: _set_move_chance(2)
		PetMenu.ID_MOVE_OFTEN: _set_move_chance(3)
		_: pass

# -------------------------------------------------- 菜单：交给 pet_menu.gd

## 菜单条目/分组/勾选项/AI 设置面板全部由 scripts/pet_menu.gd 搭建，
## 这里只负责把它接起来，以及"点了之后干什么"（_on_menu_id）。
func _build_menu() -> void:
	_menu_mod = PetMenu.new()
	_menu_mod.setup(get_node_or_null("UI") as CanvasLayer, _menu, _cjk_font)
	_menu_mod.action.connect(_on_menu_id)
	_menu_mod.ai_saved.connect(_on_ai_settings_saved)
	_menu_mod.name_saved.connect(_on_name_saved)
	_menu_mod.ai_panel_closed.connect(_on_ai_panel_closed)
	_menu_mod.set_ai_settings({
		"url": chat_url, "key": chat_access_key, "model": chat_model,
		"vision_url": vision_url, "vision_model": vision_model,
	})
	_sync_menu_toggles()

func _sync_menu_toggles() -> void:
	if _menu_mod != null:
		_menu_mod.sync_toggles(_proactive_on, _peek_on, _camera_on, _proactive_peek_on)
		_menu_mod.sync_peak_reduce(_peak_reduce_on)
		_menu_mod.sync_talk_rate(_proactive.rate)
		_menu_mod.sync_quick_chance(_quick_chance_index())
		_menu_mod.sync_move_chance(_move_chance_index())
		_menu_mod.sync_ghost(_ghost_on)
		_menu_mod.sync_harness(harness_enabled)
		_menu_mod.sync_stay_nearby(stay_nearby)

# -------------------------------------------------- 设置面板（scripts/pet_settings.gd）
#
# 值存在两处，各有各的道理：
#   检查器变量（@export）—— 出厂值，也是运行时的唯一出处；
#   user://pet_chat.cfg   —— 你在面板里改过的那些（"chat" 段是老的四个开关，
#                            "app" 段是设置面板新加的）。
# 所以"读"是：检查器值 → 存档覆盖；"写"是：面板值 → 变量 → 存档。

func _build_settings() -> void:
	_settings_mod = PetSettings.new()
	_settings_mod.build(get_node_or_null("UI") as CanvasLayer, _cjk_font)
	_settings_mod.saved.connect(_on_settings_saved)
	_settings_mod.closed.connect(_on_settings_closed)
	_settings_mod.command.connect(_on_settings_command)

## 菜单 →「给她起个名字…」。就一格输入，改完立刻生效。
##
## 名字的**真源**是 chat_persona_name（检查器变量）—— 设置面板里那一项改的也是它。
## 两条路都汇到 _apply_settings，所以这儿不另开一套存储，免得两处打架。
func _open_rename() -> void:
	if _menu_mod == null:
		return
	_close_panels()          # 面板共用一块地方，先收掉另外几个
	_menu_mod.open_name_panel(chat_persona_name)
	# 面板里要敲字，得先把 NO_FOCUS 摘掉（和设置面板 / 聊天框一个道理）
	_set_chat_focus(true)

## 改名面板点了「就叫这个」（或回车）。空串 = 回到默认名（pet_persona 会兜底）
func _on_name_saved(new_name: String) -> void:
	_set_chat_focus(false)
	# 复用设置那条路：落变量 + 运行时 → 落盘 → 她说一句。
	# 人设提示词是每句现拼的，所以下一句话她就是新名字了，不用额外通知谁
	_on_settings_saved({"persona_name": new_name})

## 菜单 →「设置…」。面板的值由主脚本给：它才是"当前值"的出处
func _open_settings() -> void:
	if _settings_mod == null:
		return
	_close_panels()      # 面板共用一块地方，先收掉另外两个
	_settings_mod.open(_settings_snapshot(), _factory, _memory_status())
	# 面板里要敲字（名字 / 额外要求），得先把 NO_FOCUS 摘掉（和聊天框一个道理）
	_set_chat_focus(true)

func _on_settings_closed() -> void:
	_set_chat_focus(false)

## 面板里那些按钮（清空记忆 / 打开记忆文件夹 / 打开 AI 设置）
func _on_settings_command(name: String) -> void:
	match name:
		"cmd_clear_memory":
			if memory != null:
				memory.clear()
			_settings_mod.set_status(_memory_status())
			_say("好，都忘了。那…你是谁呀？")
		"cmd_memory_folder":
			if memory != null:
				var path := ProjectSettings.globalize_path(memory.file_path)
				OS.shell_open(path.get_base_dir())
		"cmd_open_ai":
			# 设置面板先收掉：AI 面板是另一个面板，两个同时开着既挤又容易点错
			if _settings_mod != null:
				_settings_mod.close()
			_open_ai_settings()
		_:
			pass

func _on_settings_saved(d: Dictionary) -> void:
	_apply_settings(d)      # 先落到变量和运行时
	_save_app_settings()    # 再把刚生效的那份落盘
	_say("设置好了～")

## 面板要的"当前值"。凡是能反映真实状态的，一律读**运行时的出处**，不读存档：
## 自启动的真实状态在注册表里（可能在别处被关掉），隐藏任务栏在 shell 里。
func _settings_snapshot() -> Dictionary:
	var d: Dictionary = {}
	for k in SETTING_VARS.keys():
		d[k] = get(String(SETTING_VARS[k]))
	# 上面那张表之外的几项
	d["proactive_on"] = _proactive_on
	d["talk_rate"] = _proactive.rate
	d["peek_on"] = _peek_on
	d["camera_on"] = _camera_on
	d["hide_taskbar"] = shell.hide_taskbar if shell != null else hide_taskbar_icon
	d["tray_icon"] = shell.tray_icon if shell != null else tray_icon
	d["autostart"] = shell.autostart_on if shell != null else autostart_enabled
	d["scale_percent"] = _scale_pct
	return d

## 出厂值。和 _settings_snapshot 只差一点：这里**一律读检查器变量**，
## 不读 shell 的运行时状态 —— 「恢复默认」要恢复的是出厂状态，不是"上次的样子"
func _factory_snapshot() -> Dictionary:
	var d := _settings_snapshot()
	d["hide_taskbar"] = hide_taskbar_icon
	d["tray_icon"] = tray_icon
	d["autostart"] = autostart_enabled
	d["scale_percent"] = 1.0
	return d

## 把设置落到运行时。d 里**有什么键就动什么**，没有的一律不碰。
##
## push_system：要不要动**系统层面**的东西（注册表 / 窗口样式）。
##   启动时传 false：那时 d 只是"上次存下来的偏好"，而自启动的真实状态在注册表里，
##   可能在别处被改过（任务管理器里关掉启动项、或者手动删了那条），
##   每次启动都按我们记的值写一遍注册表，等于把别处的改动覆盖掉。
##   **这个坑真踩了**：autostart_enabled 这个导出变量默认是 false，而存档里记着 true，
##   于是流程变成"启动 → 比对发现不一致 → set_autostart(false)" ——
##   一开机就把用户开着的自启动给关了，而且完全看不出来是谁关的。
##   只有用户在设置面板里点了保存（push_system = true）才该去写注册表。
func _apply_settings(d: Dictionary, push_system: bool = true) -> void:
	# 1) 键 → 检查器变量
	for k in SETTING_VARS.keys():
		if d.has(k):
			set(String(SETTING_VARS[k]), d[k])
	# harness 的超时是模块里的变量（不在检查器上），变量一变就同步过去
	if harness != null:
		harness.timeout_sec = harness_timeout_sec
	# 2) 主动说话那几个是运行时开关，不是检查器变量
	if d.has("proactive_on"):
		_proactive_on = bool(d["proactive_on"])
	if d.has("talk_rate"):
		_proactive.set_rate(clampi(int(d["talk_rate"]), 0, TALK_RATE_NAMES.size() - 1))
	if d.has("peek_on"):
		_peek_on = bool(d["peek_on"])
	if d.has("camera_on"):
		_camera_on = bool(d["camera_on"])
	if d.has("scale_percent"):
		set_scale_percent(float(d["scale_percent"]))
	# 3) 系统那几个：先把值收进变量（它们是"上次的选择"），再由 shell 动手
	if d.has("hide_taskbar"):
		hide_taskbar_icon = bool(d["hide_taskbar"])
	if d.has("tray_icon"):
		tray_icon = bool(d["tray_icon"])
	if d.has("autostart"):
		autostart_enabled = bool(d["autostart"])
	if shell != null:
		# 这两个只是让辅助进程按新意愿干活（那个进程自己有个意愿文件），不碰注册表，
		# 什么时候设都安全
		if d.has("quiet_fullscreen"):
			shell.set_fullscreen_aware(quiet_when_fullscreen)
		if d.has("tray_icon"):
			shell.set_tray_icon(tray_icon)
		# 下面两个会真改系统状态（注册表 / 窗口样式），只在"用户刚点过保存"时才动
		if push_system and d.has("hide_taskbar") and hide_taskbar_icon != shell.hide_taskbar:
			shell.set_hide_taskbar(hide_taskbar_icon)
		if push_system and d.has("autostart") and autostart_enabled != shell.autostart_on:
			if not shell.set_autostart(autostart_enabled):
				_say("没能设置开机自启动：%s" % shell.last_error)
	# 4) 倒计时按新时长重数。不重数的话，改完还要先等完旧值攒下的时间才生效，
	#    看起来像"改了没用"（菜单里那几处开关也是这么做的）
	_proactive.reschedule()
	_peek_timer = maxf(1.0, peek_every_min) * 60.0
	_camera_timer = maxf(1.0, camera_every_min) * 60.0
	while _chat_log.size() > CHAT_LOG_KEEP:
		_chat_log.pop_front()
	# 5) 聊天总开关：关掉只是不再用它（客户端留着不重建，免得来回开关一直重连）
	if chat_enabled and _chat == null:
		_setup_chat()
	# 6) 人设要重拼：名字 / 额外要求 / 记忆开关都可能变了
	_refresh_persona()
	_refresh_chat_log()
	_sync_menu_toggles()
	_sync_system_menu()

## 把设置面板里那些落盘。存的是 _settings_snapshot()（运行时真实值），
## 不是"面板刚提交的那份" —— 两者本该一样，但以真实值为准就不会有偏差
func _save_app_settings() -> void:
	var snap := _settings_snapshot()
	var cfg := ConfigFile.new()
	cfg.load(CHAT_CONFIG)     # 先读回来，别把 chat / ai 两段冲掉
	for k in SETTING_SAVED:
		cfg.set_value("app", k, snap.get(k, null))
	cfg.save(CHAT_CONFIG)
	# 主动说话 / 频率 / 偷看 / 摄像头 在 "chat" 段（老键，菜单也一直在用），一起存
	_save_chat_config()

## 读回设置面板里那些。**返回文件里真有的键**（过一遍范围钳制）——
## 不在文件里的键一律不碰，这样检查器里改过的默认值不会被一个空存档覆盖成 0。
## 配置文件是纯文本，手改过、或者老版本留下的值都可能越界（比如把间隔改成 0，
## 那她就会一直偷看屏幕），所以这里必须过一遍 PetSettings.sanitize()
func _load_app_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(CHAT_CONFIG) != OK:
		return {}
	var out: Dictionary = {}
	for k in SETTING_SAVED:
		if cfg.has_section_key("app", k):
			out[k] = cfg.get_value("app", k)
	return PetSettings.sanitize(out)

## 记忆的现状，显示在设置面板底下（也是"清空记忆"之后刷新的那行）。
## 薄壳：真正的数在 pet_memory_flow.gd 里数
func _memory_status() -> String:
	return _memory_flow.status() if _memory_flow != null else ""

# -------------------------------------------------- 调用本机 dsh（scripts/pet_harness.gd）
#
# 主人说"干活：…" → 她去调本机的 DeepSeek Harness 把活做了 → 回来用自己的口气讲结论。
# 推理档按任务大小自动估（见 pet_harness.gd），设置里那个"最高档"是天花板。

## 建调用口。**这里不跑任何东西** —— 只是找一次 node / dsh 在哪，
## 真跑要等主人派活（先在启动时找，是为了让设置面板和菜单能显示"我没找到 dsh"）
func _setup_harness() -> void:
	harness = PetHarness.new()
	harness.setup()
	harness.finished.connect(_on_harness_done)
	harness.failed.connect(_on_harness_failed)
	if OS.is_debug_build():
		print("[PetDeek] dsh：%s｜当前推理档=%s" % [
			harness.bin_js if harness.available else harness.last_error,
			harness.current_effort()])

## 聊天框里那句是不是在派活。是就返回任务正文，不是返回空串。
## 写成 static 是为了能脱离场景验证（tools/probe_harness.gd 会检查它）
static func harness_task_of(msg: String) -> String:
	var t := msg.strip_edges()
	for p in HARNESS_PREFIXES:
		if t.begins_with(p):
			return t.substr(p.length()).strip_edges()
	return ""

## 菜单 / 设置面板 →「让她用 dsh 干活」的总开关
func _toggle_harness() -> void:
	harness_enabled = not harness_enabled
	_save_app_settings()
	_sync_menu_toggles()
	if not harness_enabled:
		_say("那就不折腾那些了～")
		return
	if harness == null or not harness.available:
		_say("开关开了，但我没找到 dsh…%s" % (harness.last_error if harness != null else ""))
		return
	_say("要我做点啥？在聊天框里说「干活：…」就行")

## 菜单 →「给她派个活…」：打开聊天框，把前缀先填好，主人接着写要干的事。
## 不另做一个输入框：聊天框本来就能打字，多一个面板只是多一处要维护的 UI
func _open_harness_task() -> void:
	_open_chat()
	if _chat_input != null:
		_chat_input.text = HARNESS_PREFIXES[0]
		_chat_input.caret_column = _chat_input.text.length()

## 把活交给 dsh。她先按住气泡说一句，跑完再由她用自己的口气讲给主人听
func _begin_harness(task: String) -> void:
	if not harness_enabled:
		_say("我还没被允许干那些活呢（右键 →「聊天与 AI」里有开关）")
		return
	# 假死：聊天这条路不通时不接活。**工作台那条不受这个限制** —— 那是你明确的指令，
	# 而且 dsh 有自己的账号和服务，让它自己报成败（见 _on_workbench_run）
	if _offline():
		_say("我现在联系不上外面，这活接不了…等连上了再说？")
		return
	if harness == null:
		return
	if not harness.available:
		harness.setup()
	if not harness.available:
		_say(harness.last_error)
		return
	_harness_task = task
	_push_chat_line("我", HARNESS_PREFIXES[0] + task)
	_soothe()        # 有活干了，之前那点别扭先放下
	_quick.hide()
	bubble.hold_with("让我看看…可能要一会儿")
	if OS.is_debug_build():
		print("[PetDeek] 派活给 dsh：%s（最高档 %s）" % [task, harness_max_effort])
	if not harness.run(task, harness_max_effort):
		_say("没跑起来：%s" % harness.last_error)

## dsh 干完了。两条路分开走：
##   聊天那条（"干活：…"）→ 原文进聊天记录，再由她**用自己的口气转述结论**
##   工作台那条 → 原文直接摆在面板里（那儿就是"看结果"的地方），她只报一句
func _on_harness_done(task: String, answer: String, ok: bool, effort: String) -> void:
	if OS.is_debug_build():
		print("[PetDeek] dsh 回来：档位=%s 用时=%.1fs 成功=%s 答案 %d 字" % [
			effort, harness.elapsed_sec(), ok, answer.length()])
	if _harness_from_workbench:
		_harness_from_workbench = false
		_finish_workbench_task(task, answer, ok)
		return
	if not ok:
		_say("dsh 那边没跑完…%s" % harness.last_error)
		return
	_push_chat_line("dsh", answer)
	# AI 不通（或它正忙）时她转述不了 —— 那就把结论直接摆出来，活是干完了的
	if _chat == null or _ai_busy() or not _chat.backend_reachable():
		_say(answer.substr(0, 80))
		return
	_begin_stream_bubble()
	_last_origin = "harness"
	var prompt := PROMPT_HARNESS_RESULT % [task, _clip(answer, HARNESS_FEED_LIMIT)]
	_refresh_persona(prompt)
	if not _chat.send(prompt):
		_chat_streaming = false
		_say(answer.substr(0, 80))

## 起不来的情况（找不到 node / bin.js、任务为空）。这种要说明白，不能只是没反应
func _on_harness_failed(msg: String) -> void:
	# 这个信号是 run() **同步**发出来的，所以工作台那边也会走到这儿 ——
	# 让它把面板的状态收干净，别留一个"正在跑…"挂在那儿
	if _harness_from_workbench:
		_harness_from_workbench = false
		if _workbench != null:
			_workbench.set_running(false)
			_workbench.set_result(false, "", msg, 0.0)
	_say("我这边调不动 dsh：%s" % msg)

# -------------------------------------------------- 工作台（scripts/pet_workbench.gd）
#
# 派活 / 看原文 / 重启她 —— 主要用来**让她给自己升级**：
# 工作目录指到项目目录、允许改文件，dsh 就会真去改源码；改完点「重启她」加载新代码。
# 和聊天那条"干活：…"的分工：那条是顺手的小活（她立刻用一句话讲给你听），
# 这条是正儿八经的活（原文留在界面上、能选目录和权限、干完能重启）。

func _build_workbench() -> void:
	_workbench = PetWorkbench.new()
	_workbench.build(get_node_or_null("UI") as CanvasLayer, _cjk_font)
	_workbench.run_requested.connect(_on_workbench_run)
	_workbench.closed.connect(_on_workbench_closed)
	_workbench.restart_requested.connect(_restart_self)
	_workbench.open_dir_requested.connect(_on_open_dir)

## 菜单 →「工作台…」
func _open_workbench() -> void:
	if _workbench == null:
		return
	_close_panels()           # 三个面板共用一块地方
	_workbench.open(_workbench_status())
	_set_chat_focus(true)     # 面板里要打字，得先把 NO_FOCUS 摘掉

func _on_workbench_closed() -> void:
	_set_chat_focus(false)

## 工作台顶栏那行小字：她这一趟会用哪个推理档、能不能改文件
func _workbench_status() -> String:
	if harness == null:
		return ""
	if not harness.available:
		return "找不到 dsh"
	return "档位 %s｜权限 %s" % [harness.current_effort(), harness.current_preset()]

## 工作台点「派活」
func _on_workbench_run(task: String, opts: Dictionary) -> void:
	if harness == null or _workbench == null:
		return
	if not harness_enabled:
		_workbench.set_result(false, "", "设置里那个「让她用 dsh 干活」还关着" \
			+ "（右键 →「聊天与 AI」→「让她用 dsh 干活」）", 0.0)
		return
	if harness.busy:
		_workbench.set_result(false, "", "上一件活还在跑，等它回来", 0.0)
		return
	var workdir := String(opts.get("workdir", ""))
	if workdir != "" and not DirAccess.dir_exists_absolute(workdir):
		_workbench.set_result(false, "", "工作目录不存在：%s" % workdir, 0.0)
		return
	var allow_write := bool(opts.get("allow_write", false))
	_harness_task = task
	# 先立旗再 run：run() 起不来时是**同步**发 failed 的，那条路要靠这个旗子认领
	_harness_from_workbench = true
	# 显示的是**封顶之后**的档：不然状态行写"max"、实际按设置里的天花板跑 low，
	# 看起来像"设置没生效"
	_workbench.set_running(true,
		PetHarness.clamp_effort(PetHarness.estimate_effort(task), harness_max_effort), workdir)
	if OS.is_debug_build():
		print("[PetDeek] 工作台派活：%s（目录=%s 允许改文件=%s）" % [
			task.substr(0, 60), workdir, str(allow_write)])
	if not harness.run(task, harness_max_effort, workdir, allow_write):
		_harness_from_workbench = false
		_workbench.set_running(false)

## 工作台那条活干完了：原文摆在面板里，她只报一句（"改好了，重启我一下"）
func _finish_workbench_task(task: String, answer: String, ok: bool) -> void:
	if _workbench != null:
		_workbench.set_running(false)
		_workbench.set_result(ok, answer, harness.last_stderr, harness.elapsed_sec())
	# "她改过自己"这件事值得记着 —— 以后聊起来她能提一句。
	# 注意 add() 只管进内存，落盘得自己叫 —— 这个 API 的约定是"调用方负责存"
	# （learn() / note_exchange() 都是它们自己存的），漏了这句就等于没记
	if ok and memory_enabled and memory != null:
		memory.add("主人让我改过自己的代码：%s" % task.substr(0, 50))
		memory.save()
	if ok:
		_say("弄好啦～重启我一下就能看到")
	else:
		_say("这次没跑成，工作台里写着为什么")

## 工作台里的「打开工作目录」
func _on_open_dir(path: String) -> void:
	if path != "":
		OS.shell_open(path)

## 重启自己：GDScript 是启动时加载的，改完代码得重新起一次才生效。
##
## 顺序是**先拉起新的、再退自己** —— 反过来的话有一小段"旧的没了、新的还没起来"。
## 怎么拉起自己沿用开机自启动那套规则（导出版 = exe 自己；编辑器里 = Godot + --path 跑这个项目），
## 所以不管她是从 exe 跑的还是从编辑器跑的，重启后都还是原来那个形态
func _restart_self() -> void:
	var exe := OS.get_executable_path()
	var args := PackedStringArray()
	if not OS.has_feature("template"):
		args.append_array(PackedStringArray([
			"--path", ProjectSettings.globalize_path("res://")]))
	if OS.create_process(exe, args) <= 0:
		_say("没能拉起新的进程…（%s）" % exe)
		return
	_say("那我重启一下，马上回来～")
	_quit()


# -------------------------------------------------- 开机与系统（scripts/pet_shell.gd）

## 把"开机与系统"那两个勾 + 状态行刷新到和真实情况一致。
## 注意自启动的状态是**去注册表读**的（shell.refresh()），不是读我们自己的开关 ——
## 用户可能在别处（或某个"启动项管理"工具里）关掉它，那菜单就不该还打着勾。
## 记一行"我是怎么被启动的"。排查自启动失败时，这就是唯一的证据：
##   文件里**没有**这一次 = 进程根本没被拉起来（问题在系统那边，不在桌宠里）；
##   有、且时间对得上 = 她起来了，那问题在"起来之后"（窗口没显示等）。
##
## 为什么要自己写文件、而不是 print 一份就完事：
## **导出版里 print() 不会进引擎日志** —— 实测导出的 pet.exe 跑完，
## `logs\godot.log` 里只有一行引擎横幅，print 的内容一个字都没有。
## 而自启动跑的正是导出版，所以这行证据必须自己落盘（user:// 两边都可靠）。
func _log_startup() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true)
	var line := "[%s] 启动：可执行=%s｜参数=%s｜自启动=%s｜登记=%s" % [
		stamp, OS.get_executable_path(), " ".join(OS.get_cmdline_args()),
		shell.autostart_status() if shell != null else "（shell 没建起来）",
		shell.autostart_cmd if shell != null else ""]
	print("[PetDeek] " + line)      # 编辑器里跑时顺便进引擎日志，开发时方便看
	_log_line(line)

## 退出也留一行（2026-09-29 用户报"我这里已经退出，为什么你那里显示没退出"）——
## 只有"启动"没有"退出"的日志答不了这个问题，只能拿"文件被占用"去猜；
## 而那个锁更常是 Windows Defender 在扫 exe，我那次就是这么猜错的
func _log_exit() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true)
	_log_line("[%s] 退出：pid=%d" % [stamp, OS.get_process_id()])

## 要不要做单实例检查。**带 `--script` 的启动一律跳过**：
## 那是 tools 里的探针（probe_live / probe_chat_ui 这些会真的加载主场景），
## 它们和主人正在跑的那个不是一回事，拦下来只会让探针哑掉。
## 正常启动（双击 exe / 启动桌宠.bat）不带这个参数，照样受保护
func _should_check_single_instance() -> bool:
	for a in OS.get_cmdline_args():
		if a == "--script" or a.begins_with("--script="):
			return false
	return true

## 往 pet_start.log 追一行（启动 / 退出 / 没启动都在这一处落盘）。
## 只留最近的内容：超过 64 KB 就重开文件，别让它无限长
func _log_line(line: String) -> void:
	var path := "user://pet_start.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f != null and f.get_length() > 65536:
		f.close()
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
	f.close()

func _sync_system_menu() -> void:
	if shell == null:
		return
	shell.refresh()
	if _menu_mod != null:
		_menu_mod.sync_system(shell.autostart_on, shell.hide_taskbar,
			quiet_when_fullscreen, tray_icon)
		_menu_mod.set_autostart_status(shell.autostart_status())

func _toggle_quiet() -> void:
	quiet_when_fullscreen = not quiet_when_fullscreen
	shell.set_fullscreen_aware(quiet_when_fullscreen)
	_sync_system_menu()
	_say("看视频时我会安静待着～" if quiet_when_fullscreen else "全屏时我也照常活动啦～")

func _toggle_tray() -> void:
	tray_icon = not tray_icon
	shell.set_tray_icon(tray_icon)
	_sync_system_menu()
	_say("托盘里有我啦，在右下角那个「隐藏的图标」里～" if tray_icon else "托盘图标收起来啦～")

func _toggle_autostart() -> void:
	if shell == null:
		return
	var want: bool = not shell.autostart_on
	if shell.set_autostart(want):
		_say("以后开机我自己就出来啦～" if want else "那开机就不打扰你啦～")
	else:
		# 失败（非 Windows / 注册表被锁）要说清楚原因，不能只是勾没变
		_say("没能设置开机自启动：%s" % shell.last_error)
	_sync_system_menu()

func _toggle_hide_taskbar() -> void:
	if shell == null:
		return
	shell.set_hide_taskbar(not shell.hide_taskbar)
	_sync_system_menu()

## 「只在小范围走动」：开着她只在家附近那一小块里转（范围大小在设置面板里调）。
## **已经在圈外不会瞬移** —— 等她溜达回来才夹住（见 pet_walk._step_move）
func _toggle_stay_nearby() -> void:
	stay_nearby = not stay_nearby
	_save_app_settings()
	_sync_menu_toggles()
	_say("好，我就在这附近待着～" if stay_nearby else "又能到处溜达啦～")

func _toggle_proactive() -> void:
	# 主动说话现在完全由本地计时决定（deepseek-web-api 没有推送通道），
	# 客户端那边不需要任何开关 —— 真正的门在 _check_self_talk 里
	_proactive_on = not _proactive_on
	# 重新开始数"她闲得慌"的倒计时：否则关着的时候攒下的时间会在打开瞬间就触发
	_proactive.reschedule()
	_save_chat_config()
	_sync_menu_toggles()
	_say("主动说话：%s" % ("开" if _proactive_on else "关"))

## 「高峰时段少说话」：DeepSeek 官方高峰（工作日 9~12、14~18，北京时间）把主动
## 开口间隔拉长 5 倍，少去撞限流 / 少等慢响应（2026-09-29 用户要求）。即时生效
func _toggle_peak_reduce() -> void:
	_peak_reduce_on = not _peak_reduce_on
	_proactive.reschedule()
	_save_chat_config()
	_sync_menu_toggles()
	_say("高峰时段少说话：%s" % ("开" if _peak_reduce_on else "关"))

# -------------------------------------------------- 主动说话（整块在 pet_proactive.gd）
#
# 计时 / 四档频率 / 门禁（总闸、生气闭嘴、离线、正忙、面板开着）/ 真正开口 ——
# 2026-09-29 第③条整块搬去了 **scripts/ai/pet_proactive.gd**，
# 短期记忆的"再提一次"也在那儿消费（见 pet_shortterm）。
# 下面这几个壳留着：菜单、设置面板、探针都按老名字调它们，改名就得连它们一起改
const PetProactive := preload("res://scripts/ai/pet_proactive.gd")
var _proactive := PetProactive.new()

## 频率档的名字（展示用）。**时长算法在模块里**（pet_proactive.span_for）——
## 这里只留文案：菜单的单选、设置面板那几档描述都在用它
const TALK_RATE_NAMES: Array[String] = ["很少", "普通", "频繁", "很频繁"]

## 档位 → 间隔区间（秒）。留成 static 壳：tools/probe_memory_prompt.gd 直接拿它
## 检查四档是不是单调变短（不用实例化整个桌宠）
static func talk_span_for(rate: int, base: Vector2) -> Vector2:
	return PetProactive.span_for(rate, base)

## 当前档的间隔区间（换档时要说给主人听）
func talk_span() -> Vector2:
	return _proactive.span()

## 菜单「主动说话的频率」：换档，并**立刻**按新档重数倒计时。
## 不重数的话，切到"很频繁"还得先等完上一档攒下的十几分钟，看起来像没生效
func _set_talk_rate(idx: int) -> void:
	_proactive.set_rate(clampi(idx, 0, TALK_RATE_NAMES.size() - 1))
	_proactive.reschedule()
	_save_chat_config()
	_sync_menu_toggles()
	var span := _proactive.span()
	_say("那我大概 %d~%d 分钟找你聊一次～" % [
		maxi(1, int(round(span.x / 60.0))), maxi(1, int(round(span.y / 60.0)))])

## 菜单「回复按钮出现频率」：把 quick_chance 设成四档里的某一档
func _set_quick_chance(idx: int) -> void:
	idx = clampi(idx, 0, QUICK_CHANCE_STEPS.size() - 1)
	quick_chance = QUICK_CHANCE_STEPS[idx]
	_save_app_settings()
	_sync_menu_toggles()
	_say(["好，那我以后不递候选了。", "行，偶尔给你递一句～",
		"嗯，一半一半吧～", "好，我多递几句～"][idx])

## 把 quick_chance（0~1）归到四档里的最近一档，给菜单勾选用
func _quick_chance_index() -> int:
	var best := 0
	var best_d := 1e9
	for i in QUICK_CHANCE_STEPS.size():
		var d := absf(quick_chance - QUICK_CHANCE_STEPS[i])
		if d < best_d:
			best_d = d
			best = i
	return best

## 菜单「移动频率」：把 move_chance 设成四档里的某一档。
## **立刻重数一次待机倒计时** —— 否则切到"经常"还得先等完上一档攒下的十几秒，像没生效
func _set_move_chance(idx: int) -> void:
	idx = clampi(idx, 0, MOVE_CHANCE_STEPS.size() - 1)
	move_chance = MOVE_CHANCE_STEPS[idx]
	walk._start_idle(walk._idle_time())
	_save_app_settings()
	_sync_menu_toggles()
	_say(["好，那我就一直待着啦～", "嗯，我少走动一点。",
		"行，偶尔溜达一下～", "好，我多走走～"][idx])

## 把 move_chance 归到四档里的最近一档，给菜单勾选用
func _move_chance_index() -> int:
	var best := 0
	var best_d := 1e9
	for i in MOVE_CHANCE_STEPS.size():
		var d := absf(move_chance - MOVE_CHANCE_STEPS[i])
		if d < best_d:
			best_d = d
			best = i
	return best

## 她想说一句（菜单「让她主动说一句」）。逻辑在模块里
func _ask_proactive() -> void:
	_proactive.ask()

## 每帧：到点就让她开口（三道挡板都在模块里，见 pet_proactive.tick）
func _check_self_talk(delta: float) -> void:
	_proactive.tick(delta)

## 立刻让倒计时到点。探针用（probe_chat_ui 要"马上让她想开口"）——
## 留这个方法名比让探针去抠模块内部稳
func _proactive_due_now() -> void:
	_proactive.timer = 0.0

func _toggle_peek() -> void:
	_peek_on = not _peek_on
	# 从关到开时别拿停用期间攒下的旧倒计时去催她，重新数
	_peek_timer = maxf(1.0, peek_every_min) * 60.0
	_save_chat_config()
	_sync_menu_toggles()
	_say("偷看屏幕：%s" % ("开" if _peek_on else "关"))

func _toggle_camera() -> void:
	_camera_on = not _camera_on
	# 从关到开时重新数，别拿停用期间攒下的旧倒计时去催她
	_camera_timer = maxf(1.0, camera_every_min) * 60.0
	_save_chat_config()
	_sync_menu_toggles()
	_say("摄像头：%s" % ("开" if _camera_on else "关"))

## 主动说话时先瞥一眼屏幕（默认开）。关掉她就只凭记忆起话头 ——
## 记忆是过去的事，主动开口就容易"和你正在干的不一样"（2026-09-27）
func _toggle_proactive_peek() -> void:
	_proactive_peek_on = not _proactive_peek_on
	_save_chat_config()
	_sync_menu_toggles()
	_say("主动说话时先看一眼屏幕：%s" % ("开" if _proactive_peek_on else "关"))

func _say(text: String) -> void:
	bubble.say(text)

# ------------------------------------------------------------------ 聊天

## 搭输入面板（实现在 scripts/ui/pet_chat_panel.gd）。
## 面板是运行时建的，不写进 pet.tscn —— 场景文件里塞这些只会让 .tscn 越来越难读
func _build_chat_ui() -> void:
	_chat_panel_mod.build()

## 快速回答那一列：UI 由 scripts/pet_quick.gd 自己建、自己摆、自己收（原来这一摊就在本文件里，
## 散在 6 个不相邻的区间，改一处要来回跳）。宿主只把**它要用的东西**递过去：
## 挂载点、气泡 Label、气泡模块、中文字体。点按钮走的是它发出来的信号，不直接调本文件的发送逻辑
func _setup_quick() -> void:
	_quick = PetQuick.new()
	_quick.setup(self, get_node_or_null("UI/Anchor") as Control, _bubble, bubble, _cjk_font)
	# 点了某句候选 = 主人说了这句话，走正常发送链路（所以它也会进记忆）
	_quick.picked.connect(_submit_chat)

## 快速回答按钮的屏幕矩形（没显示时是空的）。穿透区要把它算进去，见 pet_pointer.gd。
## 留这层薄壳是**有意的**：pointer 模块不必认识"快速回答"这块 —— 接口面越窄越不容易缠住
func quick_clickable_rect() -> Rect2:
	return _quick.clickable_rect() if _quick != null else Rect2()

## 给她"编候选"那条喂的上下文：最近几轮对话。
## **把她刚说的那句去掉** —— 提示词里已经单独给了她那句话，重复一次只会让模型更糊。
## 没有上下文时，模型编出来的话经常接不上她刚说的那句（"选项不对"就是这么来的）
func _quick_context(reply: String) -> String:
	var tail: Array = []
	var skip := "她：" + reply.strip_edges()
	var n := _chat_log.size()
	for i in range(maxi(0, n - 6), n):
		var s := String(_chat_log[i])
		if i == n - 1 and s == skip:
			continue
		tail.append(s)
	return "\n".join(tail)

## 有东西出现/消失，下一帧得重算"可点区域"（快速回答那列按钮、气泡都走这里）。
## 抽成一个方法是为了不让模块直接去摸 _passthrough_set 这个内部标记
func _invalidate_passthrough() -> void:
	_passthrough_set = false

func _open_chat() -> void:
	_chat_panel_mod.open()

func _close_chat() -> void:
	_chat_panel_mod.close()

## 临时摘掉 no_focus 好收键盘（实现在 pet_chat_panel.gd）
func _set_chat_focus(on: bool) -> void:
	_chat_panel_mod.set_focus(on)

func _on_chat_submitted(text: String) -> void:
	_submit_chat(text)

## 送出一句话（实现在 pet_chat_panel.gd）
func _submit_chat(text: String) -> void:
	_chat_panel_mod.submit(text)

## 流式冒字的起手式：清空气泡、掐掉旧的淡出 tween。
## 注意流中途**不能**调 _say() —— 那会带一个 1.8 秒的淡出，把气泡藏掉。
func _begin_stream_bubble() -> void:
	_chat_streaming = true
	bubble.begin_stream()

## 把气泡"按住"：掐掉旧的淡出 tween、清空、显出来。
## 刻意不碰任何"忙"标记 —— 收流（_chat_streaming）和摄像头（_camera_busy）
## 是两条独立的链路，只是共用这一个气泡，状态得各管各的
func _hold_bubble() -> void:
	bubble.hold()

## 气泡在场景里是固定 50px 高，两行以上会被裁掉。
## 按实际排版高度把底边撑开（autowrap 开着，得用字体量）
func _fit_bubble(text: String) -> void:
	bubble.fit(text)

# ------------------------------------------------------------------ 聊天：接线

func _setup_chat() -> void:
	if not chat_enabled:
		return
	if _chat == null:
		_chat = PetChat.new()
		_chat.token.connect(_on_chat_token)
		_chat.replied.connect(_on_chat_replied)
		_chat.failed.connect(_on_chat_failed)
		_chat.stream_ended.connect(_on_chat_stream_ended)
		_chat.reachable.connect(_on_chat_reachable)
		# 记忆的后台任务（抽事实 / 摘要）：只挂在文本那条上，
		# 视觉那条不做记忆（它的"用户消息"是提示词，不是主人说的话）。
		# 接线在这儿，干活的是 pet_memory_flow.gd（它自己认"回来的是哪件事"）
		_chat.once_done.connect(_memory_flow.task_done)
		_chat.once_failed.connect(_memory_flow.task_failed)
	# 快速回答那条小连接不在这儿建：它归 scripts/pet_quick.gd 自己管（见它的 setup()）
	# 视觉那条单独一个客户端：它俩是**两个独立连接**，
	# 这样"她正在说话"时照样能截屏去问，两张图也不会互相排队
	if _vision == null:
		_vision = PetChat.new()
		_vision.token.connect(_on_chat_token)
		_vision.replied.connect(_on_chat_replied)
		_vision.failed.connect(_on_chat_failed)
		_vision.stream_ended.connect(_on_vision_stream_ended)
		# 看图那条也一样要带上下文：她偷看屏幕时也得记得主人是谁
		# ⚠️ **两个客户端都要接**。文本那条（_chat）原来漏了这一行 —— 后果很难看：
	# 时间（【现在】）/ 关于主人的记忆 / 常识**全都没发过去**，她只能凭模型的印象猜时间，
	# 于是"现在几点"永远停在某个点（用户 2026-09-27 报的"时间停留在 10 点"就是它）。
	# 这两条接的是同一个 `_context_for`：每轮现算（时间真读系统时钟）——
	# 它**不**参与人设，所以前缀缓存照样命中（见 _refresh_persona 的说明）
	_chat.context_provider = _context_for
	_vision.context_provider = _context_for
	_apply_chat_config()
	_peek_timer = maxf(1.0, peek_every_min) * 60.0
	_camera_timer = maxf(1.0, camera_every_min) * 60.0
	_proactive.reschedule()    # 主动说话那条：按刚读到的设置重数倒计时（接线在 _ready 开头）

## 视觉那条收尾：除了清掉通用标记，还要解开"等摄像头"那把锁
func _on_vision_stream_ended() -> void:
	_camera_busy = false
	_on_chat_stream_ended()

## 把当前的后端设置灌给两个客户端并立刻探一次活。
## 菜单里改完 AI 设置也走这里 —— 不重建客户端，历史上下文还能留着。
func _apply_chat_config() -> void:
	if _chat != null:
		_chat.configure(chat_url, chat_access_key, chat_model)
		_chat.probe_now()   # 主动说话要先知道服务在不在，不等定时器
	if _vision != null:
		_vision.configure(vision_url, vision_key(), vision_model)
		_vision.probe_now()
	# 快速回答那条用**文本模型**（它编的是纯文字，和看图无关）。
	# 单独配了 quick_model 就用它 —— 这条最怕慢（会思考的模型二十几秒才回来）
	_quick.configure(chat_url, chat_access_key,
		quick_model if quick_model.strip_edges() != "" else chat_model)
	_refresh_persona()

# ------------------------------------------------------------ 长期记忆（pet_memory.gd + pet_memory_flow.gd）
#
# 分工（别混）：
#   pet_memory.gd       **记忆本身**：档案卡 / 遗忘曲线 / 分层 / 检索 / 存档 / 提示词模板
#   pet_memory_flow.gd  **什么时候记、记哪条**：一轮聊完的收尾、她主动说话时的筛选、
#                       后台那条"抽事实 / 更新摘要"的节奏与认领（2026-09 从本文件搬出去）
# `memory` 这个对象仍由本文件持有 —— 拼人设、状态显示都要用它

## 建记忆并在开局把它读回来。**必须在 _setup_chat 之前调** ——
## 拼人设时要拿它往里塞记忆（实现在 scripts/ai/pet_memory_host.gd）
func _setup_memory() -> void:
	_memory_host.setup_memory()

## 重新拼她的人设（系统提示词）。**只拼"她是谁"这一半** ——
## 记忆 / 现在 / 常识归下面的 `_context_for()`，附在历史后面。
##
## 为什么不在这儿一次拼完：那几样每轮都变，混进来这个系统提示词就每轮都变，
## 而**服务商的前缀缓存是按"逐字相同的最长前缀"算的** —— 它一变，后面的历史全部按原价。
## 所以这里必须逐字稳定：同样的人设参数拼出来的字节永远一样。
## （`_user_text` 参数留着兼容调用点，已经不再参与拼装 —— 检索挪到每轮的上下文里了）
func _refresh_persona(_user_text: String = "") -> void:
	_memory_host.refresh_persona(_user_text)

## 这一轮的上下文（关于主人 + 现在 + 常识）—— 由 PetChat 的 context_provider 回调进来。
## 它被附在**历史之后、这一句之前**，所以前面那一大段（人设 + 历史）的缓存不会被动到。
## 两个客户端都用它：文本那条和看图那条（她偷看屏幕时也得记得主人是谁）
## 上一次开口的时刻（毫秒，0 = 还没开口过）。上下文里靠它写"距上次说话多久" ——
## 她记得"刚刚才聊过"还是"隔了大半天"，才像真的在过日子，而不是每次都当第一次见面
var _last_talk_ms: int = 0
## 这次是几点被"打开启动"的（HH:MM）。写进上下文，让她对"什么时候被打开"有概念
## （2026-09-30 用户要求：让她知道自己是个桌宠、且对启动/关闭有概念）
var _started_at: String = ""

func _context_for(query: String) -> String:
	return _memory_host.context_for(query)

## 她"刚在做什么"（实现在 pet_memory_host.gd）。`_last_talk_ms` / `_started_at`
## 这两个会话状态**留在宿主**：模块要读写它俩，而且重启归零的语义属于宿主
func _pet_state_text() -> String:
	return _memory_host.pet_state_text()

## 一轮回复收尾：按"这轮是谁引出来的"决定记忆怎么记。
## **这段是总谱，留在宿主** —— 它同时要处置快速回答和"她在等你回话"的计时，
## 不只记忆一件事（收尾 / 筛选规则在 pet_memory_flow.gd）
##   打字聊天 → 整轮记下来
##   主动搭话 / 偷看屏幕 / 看摄像头 → **选择性**地记
## 为什么必须分开：后三条每天会产生好几条，而且大多没信息量（"嗯嗯～""嘿嘿"），
## 整轮存进去会把档案冲成流水账，反而把真正重要的事挤掉
func _note_reply(reply: String, given: Array = []) -> void:
	_memory_host.note_reply(reply, given)

## "她自己说的"怎么筛选着记（四道筛子）、以及"抽事实 / 更新摘要"那条后台请求的
## 节奏与认领，都搬去 scripts/pet_memory_flow.gd 了 ——
## 那边头部写清了它和 pet_memory.gd 的分工，以及它对宿主的接口面

## "让模型编候选"那条（发请求 / 洗候选 / 认领迟到的那组 / 空返回重试）也搬去
## scripts/pet_quick.gd 了 —— 它自带一条独立连接，理由见那个文件的头部注释

## 提示词里塞原话就行，但别把一整篇长文丢进去。
## **留在宿主**：pet_memory_flow / pet_harness 也按 `_host._clip()` 调它
func _clip(s: String, n: int) -> String:
	var t := s.strip_edges()
	return t.substr(0, n) if t.length() > n else t

## 看图那条现在能不能用（实现在 pet_memory_host.gd）
func _vision_ready() -> bool:
	return _memory_host.vision_ready()

## 视觉那条的 key：没单独配就复用文本那条的（实现在 pet_memory_host.gd）
func vision_key() -> String:
	return _memory_host.vision_key()

## 文本 / 视觉 / dsh 任一条在忙（实现在 pet_memory_host.gd）
func _ai_busy() -> bool:
	return _memory_host.ai_busy()

## 每帧推进：先喂客户端（网络状态机），再看要不要主动开口（实现在 pet_chat_flow.gd）
func _tick_chat(delta: float) -> void:
	_chat_flow.tick(delta)

func _on_chat_token(t: String) -> void:
	_chat_flow.on_token(t)

## 把「她的话 + %% [候选]」拆开（实现在 pet_chat_flow.gd）。
## **壳保持 1 参数**：tools/probe_memory_prompt.gd / probe_live.gd 是按
## `pet_gd.split_options(raw)` 直接试的（写成 static 就是为了能离线验）
static func split_options(raw: String) -> Dictionary:
	return PetChatFlow.split_options(raw, OPTIONS_MARK)

func _on_chat_replied(text: String) -> void:
	_chat_flow.on_replied(text)

func _on_chat_failed(msg: String) -> void:
	_chat_flow.on_failed(msg)

func _on_chat_stream_ended() -> void:
	_chat_flow.on_stream_ended()

## 她是不是"联系不上外面"（实现在 pet_chat_flow.gd）。**假死状态就认这一个判据**
func _offline() -> bool:
	return _chat_flow.offline()

## 探活结果变了（实现在 pet_chat_flow.gd）
func _on_chat_reachable(ok: bool) -> void:
	_chat_flow.on_reachable(ok)

## 刷新菜单里那行"AI 服务：…"（实现在 pet_chat_flow.gd）
func _sync_ai_status() -> void:
	_chat_flow.sync_ai_status()

# ------------------------------------------------------------------ 聊天：AI 服务设置

## 菜单 →「AI 服务设置…」：打开面板，并把当前状态（没连上 / 令牌过期）写在里面
func _open_ai_settings() -> void:
	if _menu_mod == null:
		return
	_close_chat()
	_menu_mod.set_ai_settings({
		"url": chat_url, "key": chat_access_key, "model": chat_model,
		"vision_url": vision_url, "vision_model": vision_model,
	})
	var status := ""
	if _chat != null and not _chat.backend_reachable():
		status = "连不上 %s —— 官方 API 要能上网；本地网页版要先双击它的 start.cmd" % chat_url
	elif chat_access_key.strip_edges() == "":
		status = "还没填访问密钥：官方 API 填 sk- 开头的付费 key，本地网页版填管理页第 ② 栏那串"
	_menu_mod.open_ai_panel(status)
	# 面板里要打字，得先把 NO_FOCUS 摘掉（和聊天框一个道理）
	_set_chat_focus(true)

func _on_ai_panel_closed() -> void:
	_set_chat_focus(false)

func _on_ai_settings_saved(d: Dictionary) -> void:
	chat_url = String(d.get("url", chat_url))
	chat_access_key = String(d.get("key", chat_access_key))
	chat_model = String(d.get("model", chat_model))
	vision_url = String(d.get("vision_url", vision_url))
	vision_model = String(d.get("vision_model", vision_model))
	_save_chat_config()
	if _chat == null:
		_setup_chat()      # 之前没开聊天的话，现在开起来
	else:
		_apply_chat_config()
	_say("AI：%s" % chat_model)

## 菜单 →「重新连接 AI 服务」：不重建客户端，按当前设置重连并探活
func _reconnect_ai() -> void:
	if not chat_enabled:
		_say("聊天总开关是关着的哦")
		return
	if _chat == null:
		_setup_chat()
	else:
		_apply_chat_config()
	_say("重新连接中…")

# ------------------------------------------------------------------ UI 面板

## 有"吃键盘 / 吃点击"的面板开着吗（聊天框 / AI 设置面板 / 设置面板 / 工作台）
func _ui_panel_open() -> bool:
	return _chat_open \
		or (_menu_mod != null and _menu_mod.ai_panel_visible()) \
		or (_menu_mod != null and _menu_mod.name_panel_visible()) \
		or (_settings_mod != null and _settings_mod.is_open()) \
		or (_workbench != null and _workbench.is_open())

## 面板之外点一下 = 收起来。三个一起管，免得关了一个另一个还挂着
func _close_panels() -> void:
	_close_chat()
	if _menu_mod != null:
		_menu_mod.close_ai_panel()
		_menu_mod.close_name_panel()
	if _settings_mod != null:
		_settings_mod.close()
	if _workbench != null:
		_workbench.close()

## 点在面板里面吗？三个都要算上，否则点设置面板会被当成"点在空白处"而被收掉
func _point_in_any_panel(pos: Vector2) -> bool:
	if _chat_panel != null and _chat_panel.visible \
			and _chat_panel.get_global_rect().has_point(pos):
		return true
	if _menu_mod != null and _menu_mod.point_in_ai_panel(pos):
		return true
	if _menu_mod != null and _menu_mod.point_in_name_panel(pos):
		return true
	if _settings_mod != null and _settings_mod.point_inside(pos):
		return true
	return false

# ------------------------------------------------------------------ 聊天：主动说话

## 她自己先开口时，让模型**同一次回答里把候选也写出来** —— 附在各条提示词末尾。
##
## 为什么不用 JSON：她的话里随时可能出现引号（中文引号、书名号、"啊"里面的引号），
## 一出现就把 JSON 弄坏，而"她的话"是最不该被格式绑住的东西。
## 分隔符方案还多一个好处：%% **之前**那半句可以照旧边生成边冒字（见 _on_chat_token）
## 「她的话 + %% [候选…]」的分隔符：**真源在 pet_chat.gd**（回复格式归客户端管），
## 这里只是别名 —— 历史上它就是硬编码在两处的，2026-09-27 修"聊天框卡丢"时收拢
const OPTIONS_MARK := PetChat.OPTIONS_MARK
const PROMPT_OPTIONS_TAIL := "\n\n（说完之后另起一行，行首写两个百分号 %% ，接着写" \
	+ "主人最可能接着说的 3 句话：JSON 数组形式，每条不超过 14 个字，口气随意、像随手打字，" \
	+ "彼此别雷同，也别都写成提问。严格照这个格式，别写别的：\n%% [\"句一\",\"句二\",\"句三\"]）"

## 这一轮是"她自己先开口 + 让模型把候选一并给出"吗（见 _send_first）
var _reply_opts_mode: bool = false
## 只覆盖"按钮挑哪一组"（记忆仍按 `_last_origin` 记）——主动开口时顺带瞥了一眼屏幕那轮用，
## 理由见 _note_reply 里边那段说明
var _opts_kind_override: String = ""
## 这一轮已经收到的原文（含 %% 之后那段候选，用来切分隔符）
var _reply_raw: String = ""
## 已经冒进气泡的那部分（切到分隔符之前的可见文本）
var _stream_shown: String = ""

## 她自己先开口的那几条（找话题 / 偷看 / 摄像头 / 生闷气 / 被摸烦）都从这里发：
## 请求里**顺带**让她把"主人可能接着说什么"也写出来。
## 原来是她说完之后再单独问一次模型 —— 多一次请求，按钮还要晚好几秒才出现。
## shot 给图就走视觉那条（偷看 / 摄像头），否则走文本那条
func _send_first(prompt: String, shot: String = "") -> bool:
	_reply_opts_mode = true
	_reply_raw = ""
	_stream_shown = ""
	var ok := false
	if shot != "" and _vision != null:
		ok = _vision.send(prompt + PROMPT_OPTIONS_TAIL, shot)
	elif _chat != null:
		ok = _chat.send(prompt + PROMPT_OPTIONS_TAIL)
	if not ok:
		_reply_opts_mode = false     # 没发出去就别留着这个标记，否则下一次回复会被误拆
	return ok

# -------------------------------------------------- 生闷气 / 被摸（判定在 pet_mood.gd）

## 建情绪模块并接线。**它只发信号，不许自己去说话** —— 三个信号的接收方都在下面，
## 因为它们要窗口 / 截图 / 流式气泡，那些是宿主的活
func _setup_mood() -> void:
	_mood = PetMood.new()
	_mood.setup(self)
	# 情绪模块的信号接回 _mood_ui（它只发信号，开口/选择框那摊在 pet_mood_ui.gd）
	_mood_ui.setup(self)
	# 心情变了 → 播一个"能体现这个情绪的动作"（2026-10-01）
	_mood.mood_changed.connect(_on_mood_changed)
	# 被摸到的反应：两样"跨不过来"的东西（脚本常量）在这儿交给它 —— 见 pet_touch.gd
	_touch.setup(self, PROMPT_TOUCH, EMOTE_NAMES)
	# 偷看屏幕 / 看摄像头那条感知链：宿主那几个字段它都要读写 —— 见 pet_peek.gd
	_peek.setup(self)
	# 短期记忆（她说完、没人接的那些）。接线点在 _note_reply / _soothe / _on_sulk_timeup
	_shortterm.setup(self)

## 连着被冷落到顶（pet_mood.SULK_MAX 次）：她**不主动开口了**。
## 这里只说最后一句 —— 之后的闭嘴由 pet_proactive.tick 问 _mood.is_muted() 来管。
## 要哄才回来：聊天 / 摸头 / 喂食 / 菜单「哄哄她」都会 soothe（用户 2026-09-27 要求）。
## 开口那句、自我和解、哄她选择框都搬去了 **pet_mood_ui.gd** —— 本区块只剩几个壳

## 菜单「哄哄她」：走和"被理了"同一条路 + 一句软话（实现在 pet_mood_ui.gd）
func _soothe_her() -> void:
	_mood_ui.soothe_her()

## 被理了就消气。聊天、摸头、喂食都算 —— 别让她记仇记到没人愿意搭理她。
## 薄壳：状态在 pet_mood.gd（这个函数好几处都在调，留着它比让各处去摸 _mood 干净）
func _soothe() -> void:
	_mood_ui.soothe()

## 从一串台词里随手挑一句。模块里的台词组也走它，省得每处都写一遍下标
## （pet_touch 也通过 _host._pick_line 走到这里，所以留壳）
func _pick_line(lines: Array) -> String:
	return _mood_ui.pick_line(lines)

# -------------------------------------------------- 被摸到的反应（判定在 pet_mood.gd）

## 这一整条链搬去了 **pet_touch.gd**（作业单 B6.1），开口 + 选择框搬到 pet_mood_ui.gd。
## 菜单的「摸摸头」和 pet_pointer 调 `_touch_react`，留壳最省事
const PetTouch := preload("res://scripts/body/pet_touch.gd")
var _touch := PetTouch.new()

## 被摸到了（部位判定见 pet_pointer 的 classify_touch / 分寸见 pet_mood.gd）
## 壳：生闷气时点击弹选择框那套在 pet_mood_ui.gd
func _touch_react(part: String) -> void:
	_mood_ui.touch_react(part)

# -------------------------------------------------- 心情 → 动作（2026-10-01）

## 心情变了 → 播一个"能体现这个情绪"的动作（心情表与实现都在 pet_mood_ui.gd）
func _on_mood_changed(m: int) -> void:
	_mood_ui.on_mood_changed(m)

## 播一个"持续姿势"：静态姿势动画**循环播** = 一直保持那个姿势（伤心蜷缩）。
## 和 _play_action 的区别：那个是"播一下就回待机"，这个是"保持到下一次动画"。
## 循环是关键 —— 0.001 秒的姿势动画不循环就会瞬间 finished，被 `_on_main_finished` 拉回待机
func _play_pose_loop(name: String) -> void:
	if name == "" or not _has.has(name):
		return
	var a := _anim.get_animation(name)
	if a != null and a.loop_mode != Animation.LOOP_LINEAR:
		a.loop_mode = Animation.LOOP_LINEAR
	_anim.play(name, 0.25)
	_state = State.IDLE
	_timer = 9999.0    # 郁闷着就蹲着：不摇也不乱走
	# 眨眼叠加层（_anim_face）照常跑 → 就是"蜷着 + 眨眼"的并行

## 回到待机状态。**必须留在宿主**：`State` 是本脚本的枚举，模块在弱类型引用下取不到
## （见 CONVENTIONS.md）—— 所以给它一个落状态的口子
func go_idle() -> void:
	_state = State.IDLE

## 「偷看屏幕 + 看摄像头」那一条感知链搬去了 **pet_peek.gd**（作业单 B6.1b）。这些壳留着：
## 菜单的「偷看一眼」「看一眼摄像头」和 _process 里那两条定时器按老名字调它们；
## 更要紧的是 **tools/probe_chat_ui.gd / probe_camera.gd 用 `pet.call("_peek_screen")`
## 这类写法直接打它们** —— 名字一改，探针就哑了
const PetPeek := preload("res://scripts/body/pet_peek.gd")
var _peek := PetPeek.new()

## 定时偷看（三道挡板 + 到点抓图，全在 pet_peek.gd）
func _check_peek(delta: float) -> void:
	_peek.check_peek(delta)

## 定时看摄像头（camera_look 是协程，这里故意不 await —— 理由见 pet_peek.gd）
func _check_camera(delta: float) -> void:
	_peek.check_camera(delta)

## 现在就看一眼屏幕（菜单「偷看一眼」）
func _peek_and_comment() -> void:
	_peek.peek_and_comment()

## 抓当前屏幕 → JPEG data URL（做法与理由见 pet_peek.gd）
func _peek_screen() -> String:
	return _peek.peek_screen()

## 看一眼摄像头（协程；菜单「看一眼摄像头」也调它）。
## 实现在 pet_peek.gd —— 两个实测坑（必须先开监控 / 纹理晚几帧）都写在那边
func _camera_look() -> void:
	await _peek.camera_look()

## 从本机摄像头抓一帧 → JPEG data URL（实现在 pet_peek.gd；探针也打这个名字）
func _camera_shot() -> String:
	return await _peek.camera_shot()

func _say_local() -> void:
	_say(LINES_IDLE[_rng.randi_range(0, LINES_IDLE.size() - 1)])

# ------------------------------------------------------------------ 聊天：对话记录 / 存档

## 聊天记录**留在内存里**多少行。面板靠滚动看历史，所以可以比"显示几行"（chat_log_lines）
## 大得多 —— 60 行够你翻回去看刚才聊了什么（2026-09-27 用户报"聊天不显示在聊天记录"：
## 原来这里跟显示行数共用同一个数，3 行以外的对话直接被丢掉）。
## **留在宿主**：_apply_settings 里改"显示几行"时也要按它裁一遍（见上面那段）
const CHAT_LOG_KEEP := 60

## 往聊天记录里补一行（实现在 pet_chat_panel.gd）
func _push_chat_line(who: String, text: String) -> void:
	_chat_panel_mod.push_line(who, text)

func _refresh_chat_log() -> void:
	_chat_panel_mod.refresh_log()

## 把聊天记录滚到最底下（最新那行）—— 实现在 pet_chat_panel.gd
func _scroll_chat_to_bottom() -> void:
	_chat_panel_mod.scroll_to_bottom()

## 只记住几个开关：地址 / 用户 id 这些只在检查器里改，
## 存进配置文件反而会盖掉检查器的新值（改了参数却不生效，很难查）。
## 缺键时必须落回**检查器里的值**（get_value 的第 3 个参数），
## 不然新加的开关在老存档上会变成 false，看起来像"改了检查器不生效"。
## 密钥的加解密（配置文件里不再出现明文 `sk-…`）—— 理由与边界见 pet_secret.gd
const PetSecret := preload("res://scripts/ai/pet_secret.gd")

func _load_chat_config() -> void:
	_proactive_on = proactive_enabled
	_peek_on = peek_enabled
	_camera_on = camera_look_enabled
	var cfg := ConfigFile.new()
	if cfg.load(CHAT_CONFIG) != OK:
		return
	_proactive_on = bool(cfg.get_value("chat", "proactive", proactive_enabled))
	_proactive.set_rate(clampi(int(cfg.get_value("chat", "talk_rate", _proactive.rate)), 0, 3))
	_peek_on = bool(cfg.get_value("chat", "peek", peek_enabled))
	_camera_on = bool(cfg.get_value("chat", "camera", camera_look_enabled))
	_proactive_peek_on = bool(cfg.get_value("chat", "proactive_peek", proactive_peek_enabled))
	proactive_peek_chance = float(cfg.get_value("chat", "proactive_peek_chance",
		proactive_peek_chance))
	_peak_reduce_on = bool(cfg.get_value("chat", "peak_reduce", _peak_reduce_on))
	# AI 后端设置现在可以在菜单里改，所以这些也存。
	# **两个 key 不在配置文件里** —— 它们单独住在加密文件 `user://pet_secret.dat`
	# （见 pet_secret.gd）。这里处理的是**一次性迁移**：老配置里还躺着明文 key 的那种。
	# 迁完立刻把配置里那两项清空并落盘（所以这个方法**只有第一次**会写盘，之后是纯读）
	chat_url = String(cfg.get_value("ai", "url", chat_url))
	var legacy_key := String(cfg.get_value("ai", "key", ""))
	var legacy_vkey := String(cfg.get_value("ai", "vision_key", ""))
	if legacy_key != "" or legacy_vkey != "":
		if legacy_key != "":
			chat_access_key = legacy_key
		if legacy_vkey != "":
			vision_access_key = legacy_vkey
		PetSecret.store(chat_access_key, vision_access_key)
		cfg.set_value("ai", "key", "")
		cfg.set_value("ai", "vision_key", "")
		cfg.save(CHAT_CONFIG)
		if OS.is_debug_build():
			print("[PetDeek] AI 密钥已从配置文件迁进加密文件（配置里从此不留明文）")
	else:
		var keys: Array = PetSecret.load_keys()
		if String(keys[0]) != "":
			chat_access_key = String(keys[0])
		if String(keys[1]) != "":
			vision_access_key = String(keys[1])
	chat_model = String(cfg.get_value("ai", "model", chat_model))
	vision_url = String(cfg.get_value("ai", "vision_url", vision_url))
	vision_model = String(cfg.get_value("ai", "vision_model", vision_model))

func _save_chat_config() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CHAT_CONFIG)   # 先读回来，别把文件里其它键冲掉
	cfg.set_value("chat", "proactive", _proactive_on)
	cfg.set_value("chat", "talk_rate", _proactive.rate)
	cfg.set_value("chat", "peek", _peek_on)
	cfg.set_value("chat", "camera", _camera_on)
	cfg.set_value("chat", "proactive_peek", _proactive_peek_on)
	cfg.set_value("chat", "proactive_peek_chance", proactive_peek_chance)
	cfg.set_value("chat", "peak_reduce", _peak_reduce_on)
	cfg.set_value("ai", "url", chat_url)
	# **配置里永远不写密钥**（连密文都不写）：两项恒为空串，密钥单独住在加密文件里。
	# 这样"配置文件整体可以被安全地分享/截图/误提交"这个性质才成立
	cfg.set_value("ai", "key", "")
	cfg.set_value("ai", "model", chat_model)
	cfg.set_value("ai", "vision_url", vision_url)
	cfg.set_value("ai", "vision_model", vision_model)
	cfg.set_value("ai", "vision_key", "")
	cfg.save(CHAT_CONFIG)
	PetSecret.store(chat_access_key, vision_access_key)
