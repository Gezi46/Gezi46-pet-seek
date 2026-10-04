# PetDeek 🐾

一个住在你桌面上的蓝发女仆。

无边框小窗口，她会自己散步、跑两步，能被拖着走、摸头会害羞，会跟你聊天、记住你说过的话，
偶尔还会偷看一眼你的屏幕。

用 **Godot 4.7** 做的，模型是 Blockbench 的。

---

## 跑起来

**装好 Godot 4.7**，然后二选一：

- 用 Godot 打开这个文件夹，按 **F5**
- 或者直接双击 **`启动桌宠.bat`**（它会自己找 Godot）

命令行的话：

```powershell
godot --path .
```

> **第一次打开会先导入资源**，10~30 秒 —— 那个 3D 模型要转一遍。导入完成前启动会报一堆
> `referenced non-existent resource`，**那不是代码问题**。`.godot/` 是导入缓存，不进版本库。
> 双击 bat 的话它已经自动处理了这一步。

### 想让她能聊天

不配也能用，只是她只会说本地台词。要真聊天，**右键她 → 「AI 服务设置」**，填一个后端地址和 key。

支持任何 OpenAI 兼容接口：

| 后端 | 地址 | 说明 |
| --- | --- | --- |
| DeepSeek 官方 API | `https://api.deepseek.com` | 要付费 key |
| 本地网页版代理 | `http://127.0.0.1:8520/v1` | 自建，不需要官方 key |

> 密钥存进 `%APPDATA%\...\桌宠\pet_secret.dat`（AES-256 加密），配置文件里**永远是空的**，
> 面板里默认也**遮着显示** —— 截图不怕漏。

---

## 怎么玩

| 操作 | 效果 |
| --- | --- |
| 左键**点击** | 摸头：随机害羞 / 挥手 / 做表情，并说一句 |
| 左键**双击** | 弹出聊天框 |
| 左键**拖动** | 拖到屏幕任意位置 |
| **右键** | 菜单：喂食 / 睡觉 / 跳一下 / 放大缩小 / 位置 / 聊天 / 偷看屏幕 / 摄像头 / 设置 … |
| 鼠标移到她身上 | 指针变手型 |

闲置一会儿她会自己在屏幕上散步，撞到边就折返。

---

## 更多

细节都拆到了各自的 README：

| 想了解 | 去哪 |
| --- | --- |
| 聊天、AI、主动开口、离线降级 | [`scripts/ai/README.md`](scripts/ai/README.md) |
| 她的人格与长期记忆 | [`scripts/ai/memory/README.md`](scripts/ai/memory/README.md) |
| 菜单、设置面板、工作台 | [`scripts/ui/README.md`](scripts/ui/README.md) |
| 托盘、自启动、全屏安静、窗口 | [`scripts/sys/README.md`](scripts/sys/README.md) |
| 走路、朝向、动作节奏 | [`scripts/body/README.md`](scripts/body/README.md) |
| 模型、贴图、动画、渲染 | [`scenes/README.md`](scenes/README.md) |
| **改代码前先看这个** —— 踩过的坑 | [`docs/README.md`](docs/README.md) |
| 自检探针怎么用 | [`tools/README.md`](tools/README.md) |
| 代码规范（文件上限 / 模块边界 / 验证阶梯） | [`CONVENTIONS.md`](CONVENTIONS.md) |

---

## 已知限制

- 走动是**移动整个窗口**实现的，所以不会被别的窗口遮住
- 没有爬墙 / 掉落物理，撞到屏幕边就折返
- 模型没有骨骼，是 722 个节点的刚体层级（对桌宠够用）
- **长期记忆没有语义向量**（DeepSeek 没 embeddings），检索靠字面匹配 ——
  换个完全不同的说法可能就找不着
- **记忆可能记岔**：错的条目会一直影响对话。怀疑她记错了就删 `%APPDATA%\...\桌宠\pet_memory.json`
- 「偷看屏幕」要后端模型支持视觉（名字里带 `vision`），所以**默认关着**
- 聊天 / 偷看 / 摄像头**共用一个气泡**，同一时刻只跑一条

---

## 名字

`Pet`（她住在桌面上）+ `Deek`（念着顺口）。中文里平时就叫她**桌宠** —— 那是类别词，不是项目名。

> ⚠️ 想改 `project.godot` 里 `config/name` 的话**先看那两行注释**：改错会让 `user://`
> 指向新目录，她的记忆 / 配置 / 密钥全部"失联"（项目用 `use_custom_user_dir` 钉住了）。

## 协议
**GPL-3.0**（见 [`LICENSE`](LICENSE)）—— 可以自由使用、修改、再分发，仅仅包含善意使用。
但**衍生作品也必须以 GPL 开源**。

项目名与美术资产（图标、角色模型）**不随代码授权**，见 [`TRADEMARK.md`](TRADEMARK.md)，3d模型是bilibili蒙德砍王的模型，不是我自己的。
最后的最后这些readme是ai生成的，我自己懒得写那么多有什么需求不会的以视频为主。

