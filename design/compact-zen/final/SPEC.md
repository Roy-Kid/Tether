# Tether · Page 6 最终设计规格

本文件是唯一实施依据；已整合全部讨论，旧版本不再适用。设计已定稿，应用功能尚未实施。范围为 macOS 工作区；iOS 保持现有导航与触控尺寸。

## 1. 窗口结构与对象关系

窗口顶部仅一条 36pt tab，与原生红绿灯同排，空白区域可拖动窗口。无第二层 tab、独立标题行、常驻 host 侧栏或操作工具栏。底部仅 24pt host 切换与连接状态。新建、分屏、放大、搜索、禅模式等操作放在 macOS 原生菜单栏和命令菜单中。

对象层级：Host → Terminal tab（稳定工作位置）→ 原始 shell 或 tmux session → window → pane。顶层 tab 不枚举 tmux windows，pane 只在内容区中展示。tab 主标签为可重命名的 Terminal 1 等，次标签展示当前 session/window。使用稳定 ID，不以显示名称作为身份。

首次点击其他 tab 只切换；再次单击已激活 tab 打开选择器，不要求连续双击。tab 的小下拉箭头始终可发现，直接点击也可选中该 tab 并打开菜单。重命名放到菜单，避免双击冲突。过多 tabs 横向滚动；当前 tab 自动进入可见范围；⌘P 提供完整可搜索列表。

独立插件如 Nerve 保留自己的顶层 tab、内容和插件上下文，不伪装为某主机的 shell，不显示无关的 tmux 菜单。

## 2. tmux 图形选择器

锚定在当前 terminal tab 下方，按当前 host 列出 Original shell、tmux sessions、Create session。打开选择器即刷新。session 行显示名称、window 数、活动 window 与选中标记。

- 多个 windows：点击 session 或悬停 200ms 展开二级菜单；窗口列表显示 index/name、pane 数与选中标记；选择 window 才执行 attach/select。session 行点击只展开，不提前修改远端。
- 一个 window：点击 session 直接进入；右方向键仍可展开一项子菜单。无有效 windows 或 session 已消失时显示不可用与刷新入口，不自动创建。
- 二级菜单保留 New window；session/window 的重命名、detach、end 在右键菜单与 macOS 菜单中。危险操作明确命名且确认。
- 鼠标可以从父菜单连续移动到子菜单，不因穿越间隙立即关闭；接近右边缘时向左展开。长列表滚动，当前选择可见。
- ↑↓ 或 Ctrl-N/P 移动高亮，→ 展开，← 返回，Enter 确认；Esc 先退出子菜单，再关闭根菜单并恢复终端焦点。j/k 保持菜单搜索字符。⌘P 用于跨层级搜索。
- 高亮、悬停、展开菜单均不 attach/select、不建立其他 host 的连接。仅在当前已连接 host 上通过只读操作发现 sessions/windows；保留缓存和加载/失败状态。
- 未安装 tmux 时明确说明，Original shell 继续可用。创建失败、断线、列表项消失均不静默创建替代对象。

这是一种借鉴 prefix+s 的插件图形选择器，不等于模拟或发送原生 prefix+s。原生 tmux 前缀行为需单独实测。

## 3. Host、tab 与连接生命周期

host picker 从左下角向上展开，包含搜索、已连接/其他主机。Add 与 Manage 为 icon-only，名称在 hover。连接状态用底栏圆点与图标表示，名称在 tooltip；部分连接失败不伪报全部 Connected。

切换 host 恢复该主机最后一次 tab/session/window/pane，保留已有工作。首次访问走正常连接/认证流程并打开一个原始 shell；取消不遗留孤立 tab。关闭最后一个 tab 后留在同一 host 的空状态，不自动新建，不跳到其他 host。

每个 terminal tab 拥有原始 shell 和其打开的 tmux attachments。在 Original shell 与 sessions 间切换不关闭原进程、不增加顶层 window tabs。每个 host/socket/session ID 只保留一个控制 attachment；若 session 已由另一个 tab 拥有，激活该 tab，再选择请求的 window，不重复附加。

新 terminal 新建顶层 tab；新 tmux window 仅在 session 中创建并选择。非当前内容不得抢焦点、误 resize 活动 window，或因远端更新跳回另一个 host。远端删除当前 window 时显示已结束/选择其他 window，而非保留一个可操作的假窗口。

同一目标的连接请求合并；迟到的连接成功/失败不得夺回用户已移走的焦点。tmux reconnect 不制造可见或隐藏的额外 shell tab。应用负责保存 connection lease，直到最后一个消费者释放；不为整理 UI 而杀掉用户原始 shell。

## 4. 原生菜单与键盘

所有入口调用同一命令分发器、共享可用状态，macOS 菜单不是应用窗口内的一排仿制按钮。

| 位置 | 操作与快捷键 |
|---|---|
| File | New terminal ⌘N；Change host ⌘⇧H；Close tab ⌘W |
| Edit | 平台原生复制、粘贴、撤销、重做 |
| View | Command menu Ctrl⇧P（兼容 ⌘⇧P）；Quick switch ⌘P；Inspector；Zen ⌘⇧Z |
| Terminal | Rename terminal；Reconnect（new shell）／New terminal，依状态可用 |
| tmux | Attach/Create/Detach session；New window ⌘⇧N；Split left/right ⌘\；Split top/bottom ⌘⇧\；Zoom/Restore pane ⌘⇧Return |
| tmux | Focus pane ⌘⌥H/J/K/L；Previous/next window；Rename；End pane/window/session |
| Window | Previous/next 顶层 tab ⌘⌥←/→；All workspaces；平台窗口操作 |
| Help | Keyboard shortcuts 与帮助 |

Ctrl⇧P 打开可搜索的命令菜单，不是把焦点移到系统菜单栏。这是明确保留的 Control 快捷键，必须在终端编码前拦截且不发送终端字节；⌘⇧P 是额外别名。其余未声明的终端按键继续透传。

⌘P 搜索已知 host、tab、session/window、独立插件，结果展示完整路径和类型；空搜索显示最近使用项目。选择 window 一次跳转到对应 owner tab 和 window。搜索不连接所有保存的主机来遍历 sessions。

菜单打开时只移动高亮，Enter 才执行，Esc 取消并恢复原焦点。模态弹窗、文本编辑和 IME 优先；例如输入框中 ⌘⇧Z 仍为重做。Vim hjkl、Esc、Ctrl-W 等不被全局 Vim 模式接管。选择器按键不泄漏给终端。macOS ⌘Q、⌘, 等保留平台语义。

## 5. Pane、禅模式与恢复

点击 pane 聚焦，活动 pane 有细边标记。视觉分隔线保持细，但拖动区域 6pt，并显示方向光标。分割新 pane 后由服务器确认再转移焦点，进行中的重复操作抑制。普通 shell 不支持原生分屏，相关命令禁用并说明需先 attach tmux，不能暗中转换现有 shell。

pane zoom 使用真实 tmux 状态，与 Zen 独立。Zen 隐藏 tabs、status 和 inspector，保留系统最小窗口框架和当前 panes，不自动全屏。鼠标通过系统 View → Exit Zen Mode 退出；Ctrl⇧P、⌘⇧Z 继续可用。取消旧方案的悬停退出按钮。跨 host 切换时短暂显示目的地，保留窗口上下文；退出恢复当前内容和原 inspector 可见性，不撤销 Zen 内的导航。

区分 Connecting、Needs authentication、Connected、Disconnected、Ended。断线保留最后画面作为只读快照并暂停输入，不缓冲或重放按键。错误、认证、重连条在 Zen 中仍可见。后台失败标记状态，不强制切屏。

tmux 重新附加同一 session ID；消失时明确让用户另选或显式创建。普通终端重连提示会打开 new shell，不声称恢复原进程。每次只有一个重连请求，可取消；成功仅在当前仍查看该工作区时恢复输入焦点。

## 6. 关闭与危险操作

⌘W 关闭整个 terminal tab；若选择器打开则仅先关闭选择器。关闭 tab 时：结束其原始 shell，detach 其 owned tmux sessions，远端 tmux 任务继续。原始 shell 仍存活时用系统确认框，标题为动作（Close Terminal N?），按钮为 Cancel / Close，默认 Cancel；仅在该 tab 仍挂着 tmux 时加一行 “tmux stays on the host.”。已结束的 shell 无需重复确认。不能可靠判断是否还有后台任务，因此不宣称检测到空闲 shell。对话框不解释菜单、不对比 Detach/End。

显式 Detach session 只脱离指定 attachment，返回原始 shell；若原始 shell 已结束则显示该状态，不偷偷新建。End pane/window/session 是独立的远端破坏操作，系统确认标题为 End this window/pane/session?，按钮为 End。普通 tab 关闭不等于 kill tmux window。

关闭后选择同 host 最近使用 tab；没有则保留该 host 的空状态，不写教程句、不放操作按钮。原生窗口关闭与应用退出不能绕过 live-shell 确认；OS 无法取消的终止按现有生命周期尽力清理。

## 7. 配套界面与外观

Manage hosts、连接认证、Create tmux session 以独立 sheet 呈现；Settings 使用 macOS Settings 窗口；Inspector 从 View 菜单按需打开。修改主机仍遵守原有 ~/.ssh/config 保留未知配置、localhost 不可删除等规则。密码/密钥与 host-key trust 仍遵循现有安全语义，不因视觉设计改变认证逻辑。

窗口内 chrome（tab 附件、状态栏、选择器、浮层）只使用图标，名称放在 hover tooltip；不在窗口里写句子。原生菜单和命令菜单仍用文字。Alert、confirmation 与 sheet：标题是动作，按钮是动词；只有按钮说不清的后果才加一行。禁止说明书、菜单路径、替代操作教学。布局保持 compact：36pt tab、24pt host bar，无第二工具栏。

UI 使用系统语义颜色和原生字体，浅色/深色、增大对比度随系统变化；终端字号不因 compact 缩小。Figma 是深色静态状态稿，使用 Inter / JetBrains Mono 作为导入渲染替代字体；这些不是应用字体配置。草稿中的主机、代码与终端输出均为示例，不是实际连接或测试结果。无可点击原型或 Auto Layout 完成度承诺。

## 8. 实施边界与验收

- 应用层管理显式 host/workspace ownership、焦点和可见性；tmux 插件提供可选、带默认实现的 session/window 导航能力，其他插件保持单 workspace 兼容。不得向 Rust SDK 引入应用布局概念。
- 添加只读 session/window metadata 查询时复用现有 connection/tmux 边界；不能为了显示菜单先 attach/select。保持会话视图身份，避免重建终端和重启任务。
- 单独验证 control-mode 输入直送 pane 时原生 tmux prefix 的真实行为；不假设“不拦截键”就等于完整 tmux 客户端兼容，更不能增加未约定的全局前缀模拟器。
- 自动验证 ownership、重复连接、同 host 关闭、延迟完成、焦点恢复、菜单状态及 macOS Ctrl⇧P/IME 输入路由；本地 tmux 集成覆盖 attach/select/resize/detach/reconnect。
- 鼠标独立完成连接、树状选择、创建 window、分屏、拖动、放大、重连与退出 Zen；Vim 保持 hjkl/Esc/Ctrl-W；快捷键完成同一流程。
- 检查单/多/空/消失 session、无 tmux、右边缘子菜单、长名称、20 tabs、认证取消、断线后输入屏蔽、错误状态。
- 860×520 与 1100×700 检查深浅色、原生红绿灯、窗口拖动、VoiceOver、焦点、减少动态效果。运行 app 与 TetherFrontend 的 Swift 测试；connection API 如有修改再运行相关 SDK 检查。不测试写入真实 keychain。

先完成状态模型和连接 ownership，再实现单条顶部 tab、菜单树和命令入口，最后接入 Zen/恢复及实机验收。保留项目其他未提交改动，不做无关清理。
