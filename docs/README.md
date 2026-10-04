# 踩过的坑

> 改代码前值得看一眼。每一条都是真踩过的 —— 不是理论上的可能性。
>
> 返回 [项目主 README](../README.md)
## 几个踩过的坑（改代码前值得看一眼）

1. **`AnimationPlayer.seek()` 不会立刻刷新 3D 变换**
   想采样"角色在动画里到底占多大"时，用 `seek()` 量出来的永远是静止姿势。
   必须让动画真正跑起来、跨帧采样（`_calibrate()` 就是这么做的）。

2. **量包围盒必须用 `global_transform`**
   这个模型的动画驱动的是网格的**祖先**节点（`Root/MAllBody` 等），
   网格自身的 `transform` 一直是静止值。用 `mi.transform` 会永远量到静止姿势。

3. **`owner` 不能乱设**
   给 GLB 实例内部的节点设 `owner`，`PackedScene.pack()` 会把整棵树
   （567 个 MeshInstance3D）**内联展开**写进 `pet.tscn`，而不是留一个
   `instance=ExtResource` 引用——场景文件会从 4 KB 膨胀到 1,900 行。

4. **Godot 4.7 的 `window_set_mouse_passthrough()` 收的是多边形数组**，不是 bool。
   传 `PackedVector2Array()` 表示整窗可点，传一整块矩形表示整窗穿透。

5. **模型的正面朝向 −Z**
   相机在 +Z 看向原点，所以基准旋转是 `PI` 才面向镜头。
   别按数据直觉猜，用 `tools/shoot_pose.gd` 渲一张就知道。

6. **不要用 PowerShell 的 `Set-Content` 改这个 .gd 文件**
   它会把中文写成非 UTF-8，Godot 直接报 `Unicode parsing error`。
   用编辑器或者 UTF-8 安全的方式改。

7. **轮廓白边不在 alpha 上，在贴图的透明区 RGB 上**
   这个模型的 alpha 一直是干净的（半透明像素为 0），
   白边来自"透明 texel 里存着亮色 RGB"被线性过滤掺进边缘。
   所以别去调 MSAA / alpha 抗锯齿，先去量 `tools/probe_ring.gd`。

8. **贴图导入参数是导入期生效的**
   改完 `.import` 要重新导入；只重启游戏窗口是不会生效的。

9. **`tools/*.gd` 这种 `extends SceneTree` 脚本必须有看门狗**
   `--script` 模式下 Godot 不会自己退出：脚本跑完不调 `quit()`，进程就一直挂着。
   更坑的是中途抛错（比如访问了当前版本里不存在的属性），写在函数末尾的 `quit(0)`
   根本执行不到，命令行就会一直等 —— 表现出来就是"跑引擎卡死了"。
   所以每个工具脚本都要在 `_process()` 里数帧数、超时强退
   （`probe_material.gd` 之前漏了，现已补上；它当初就是踩了 `alpha_hash_enabled`
   这个 Godot 4.7 已移除的属性）。

10. **PopupMenu 是独立窗口，坐标是屏幕坐标**
    项目里 `embed_subwindows=false`，所以 PopupMenu 会开成一个真正的系统窗口。
    它的 `position` / `popup(rect)` 用的是**屏幕坐标**，而 `_input` 里拿到的
    `mb.position` 是**窗口内坐标** —— 直接混用，菜单就会跑到屏幕左上角附近去。
    正确写法是补上窗口自身的位置：
    `DisplayServer.window_get_position() + Vector2i(pos)`。

11. **在 PowerShell 里跑 `godot.exe` 不会等它、也收不到它的输出**
    这个 steam 版的 exe 是 **GUI 子系统**构建（目录里没有 `.console.exe`），
    所以用 `& $godot ...` 调用会**立刻返回**，`$LASTEXITCODE` 是空的、stdout 也抓不到
	—— 看起来像"跑了一下就退出、什么都没打印"。其实进程还在后台跑。
    要拿结果有两个办法：`Start-Process -Wait`，或者直接读它的日志文件
    `%APPDATA%\Godot\app_userdata\桌宠\logs\godot.log`（`print()` 的内容都在里面）。

12. **`PopupMenu` 设勾选项的方法叫 `set_item_as_checkable`**，不叫 `set_item_checkable`
    （后者是 Godot 3 的名字，4 里没有，写了会在运行时才报
    `Nonexistent function`）。读回来的是 `is_item_checkable` / `is_item_checked`，
    勾选状态是 PopupMenu 自己存的另一套，改完运行时开关要记得 `_sync_toggle_menu()`。
	在这个版本里想确认 API 到底叫什么，用 `ClassDB.class_get_method_list("PopupMenu")`
    打一遍最快 —— 别照抄记忆里的名字。

    13. **同名函数和成员变量会让整个脚本解析失败，而且报错不点出重名**
        给 `pet_menu.gd` 加了个 `func _status()`，而那个文件里早就有 `var _status: Label`
		（AI 面板的状态文字）。报错长这样：`Could not preload resource script "res://scripts/ui/pet_menu.gd"`
		—— 只说"加载不了"，一个字没提重名，得自己挨个看改过的地方。
        加函数前先扫一眼同名的变量。

    14. **`PackedStringArray` 在这个版本里没有 `join`**
		`PackedStringArray(out).join("\n")` 直接解析失败（`Cannot find member "join"`）。
        拿它拼 `OS.execute` 的多行输出时手写循环拼。想确认某个类型到底有哪些方法，
        用 `--check-only --script <脚本>` 过一个，比跑起来快得多。

	15. **辅助进程会因为"一次没找到窗口"就悄悄退出**
    `Tick()` 返回 `DEAD`（找不到宠物窗口）时原来是**立刻**结束进程 —— 而窗口重建、过渡态
    都可能瞬时如此。它一死，任务栏隐藏的自愈、托盘图标、置顶维持**一起**静默失效，外面看到
	的只是"某个功能不灵了"，而且进程名是 `powershell`，很难联想到它。
    现在连续 ~8 秒都找不到才收摊；Godot 侧每 0.5 秒用 `OS.is_process_running` 查一次，
    真死了立刻重拉（带冷却和次数上限）。

15. **在 GDScript 字符串里写 PowerShell 正则 = 双层转义地狱**
	`-split '\s+'` 写在 `"""..."""` 里，落盘之后就变成 `-split '\\s+'`，PowerShell 把它当成
	"字面反斜杠 + 字母 s"，于是**根本没分割**：想读的 3 个字段被当成 1 个，三个意愿全读成
    false，自愈和托盘通知一起静默失效（查了很久才想到去看落盘文件）。
    现在**避开反斜杠**：写文件那头用单个空格，读的时候 `-split ' '` 就够了。

16. **PowerShell 脚本的 `param()` 少声明参数 = 静默失效**
    `watch` 模式要用到 5 个参数，而 `param()` 只声明了 3 个 —— `$Arg4`/`$Arg5` 因此全是
    `$null`。读取那一步包在 `try/catch` 里，异常被默默吞掉，表现**完全不像参数问题**：
	"托盘图标是系统默认图标"和"菜单开着收不到通知（于是菜单又被她盖住）"两个功能各自坏掉，
    查了很久才想到去看参数个数。
    现在 `watch` 开头先检查参数齐不齐，不齐就把 `ARGS-MISSING` 写进状态文件再退出。
    教训：给辅助脚本加参数时，`param()` 一定要同步。

17. **`--export-release` 的预设名带空格时，参数要整串传**
     `Start-Process -ArgumentList @('--export-release','Windows Desktop', $out)` 会被按空格
     拼开，Godot 收到的是 `-preset Windows`，报 `Invalid export preset name: Windows`，
	 然后**什么都不导出** —— 而目录里那个旧 exe 还在，特别容易误以为"导出成功了"
     （我就在这上面误判过一次：`pet.exe` 的修改时间还停在几十分钟前）。
	 正确写法是整串传：`-ArgumentList '--headless --path "…" --export-release "Windows Desktop" "…\pet.exe"'`，
     或者直接用 `导出exe.bat`。**导出后一定看一眼 exe 的修改时间。**

18. **`:=` 从一个返回 Variant 的表达推断类型会直接报错**
    这个项目把那条警告当错误，所以 `var x := _find(...)`（`_find` 返回 Variant）会报
	`Cannot infer the type of "x" because the value doesn't have a set type`。
    最容易踩的是**在无类型数组上循环**：`for it in items:` 里的 `it.text`、`it.importance`
    全是 Variant，于是 `var n := it.importance * 0.5` 这种写法成片报错 ——
    显式写 `var n: float = ...` 就行。
    另外 **GDScript 的内部类看不到外层作用域**：内部类里调不到外层的静态函数
	（`Item.retention()` 就是这么改成"由外层拿字段代算"的）。

19. **改提示词要用眼睛看整份拼出来的结果**
	给"常识参考"那段加预算裁剪时，我在两处各拼了一次，于是整块常识在提示词里
    **重复出现两遍** —— 这种错在聊天里根本看不出来（她照样答得好好的，只是每次多烧一份 token）。
    所以 `tools/probe_memory.gd` 会把整份人设原文打印出来；改完人设先跑它扫一眼。

20. **规则抽取必须防问句**
	"你还记得我**叫什么**吗？"命中了"我叫…"那条规则，抓回"什么吗"就写进了档案卡，
	从此她认定"主人的名字是什么吗"。修法是给捕获到的值加一张否定表（什么/啥/谁/哪里/多少…）
    和长度上限 —— 规则抽取**宁可漏也不能错**：错的那条会一直留在提示词里，漏掉的下次还能再抓。

---
