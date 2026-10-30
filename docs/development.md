# 开发与实现说明

本文记录 TapDone 的工程配置、交互规则和实现细节。面向使用者的介绍见 [README](../README.md)。

原生 macOS 鼠标快捷 Dock。Swift + SwiftUI + AppKit，软件更新使用 Sparkle，任务执行和 CLI 不依赖额外框架。

## 开始

使用 Xcode 15 或更新版本打开 `TapDone.xcodeproj`，选择 TapDone scheme。最低支持 macOS 13。发布使用免费 ad-hoc 签名，无需 Apple Developer 账号；Bundle Identifier 为 `dev.sidetap.SideTap`。

## 交互

- 启动显示管理主界面：左侧导航与分类任务树，右侧任务详情和编辑工作区；菜单栏按分类提供全部任务，可直接执行。
- 在“边缘唤出”中选择上、下、左、右边缘或四个角之一，设置触发范围（2–120 点）和停留时间（0.1–2 秒）。默认左边缘、12 点、0.4 秒。
- 只检测鼠标是否处于触发区域，不检测滑动、幅度或速度。边缘范围为条带宽度，角落范围为正方形边长；区域内移动不重置计时，离开区域后重新计时。
- 上下边缘展示横向 Dock，左右边缘展示居中的竖向 Dock；角落展示靠近对应角落的竖向 Dock。名称标签始终朝屏幕内侧显示。
- 点击任务或移开鼠标后自动收起；拖动、打开菜单及操作设置窗口内部时暂停识别。鼠标移出设置窗口即可使用，无需关闭设置。
- Dock 仅展示勾选的任务，设置和菜单栏展示全部任务；所有设置自动保存。
- 多屏按鼠标所在屏幕识别，切换屏幕后重新计时。屏幕之间共享的边缘需要在范围内停留，不会阻止鼠标跨屏。

## 代码组织

- `App`：生命周期、菜单栏与边缘区域停留识别。
- `Core`：动作模型、动作包模型预留与持久化设置。
- `Services`：内置动作执行。
- `Windows`：浮动 Dock 窗口、定位和自动收起。
- `Views`：图标列与设置界面。

当前使用鼠标位置采样，不拦截输入；无需鼠标滑动或触控板手势。已支持 AI 任务 JSON 导入和 CLI；全局快捷键、完整动作包导出及多步骤工作流尚未接入。

工程未启用 App Sandbox；免费发行不做 Apple 公证，首次安装可能需要在系统设置中允许打开。图标与开源许可证仍待完善。

## 任务组织

设置中的“任务”页展示两层结构：分类 → 子任务。分类可添加、重命名、删除和排序；子任务可添加、编辑、跨分类移动、删除和在分类内排序。

每个子任务有独立的“显示在 Dock”开关，新任务默认不加入 Dock。Dock 只显示勾选的子任务，按分类顺序及分类内任务顺序排列；分类本身不出现在 Dock。不勾选任何任务时不弹出空 Dock。

分类、任务和 Dock 选择存储在 `~/Library/Application Support/SideTap/library.json`。首次启动自动迁移旧版 UserDefaults 的 `taskLibrary` 或 `quickActions`，保留旧数据。删除分类会在确认后移除分类内全部任务及其 Dock 引用。

## Dock 外观

底座使用 AppKit 的 NSVisualEffectView 做窗口后方毛玻璃，背景尺寸固定，不随悬停伸缩。尺寸精确预留一个图标放大至 1.45 倍的空间，加上其余原尺寸图标、4 点间距、左右各 10 点及上下各 12 点 padding。仅悬停图标放大，相邻图标保持原尺寸，采用无过冲的平滑过渡。横向与竖向 Dock 使用同一尺寸规则，超出屏幕可用长度时滚动。

应用和文件夹使用系统高清图标。任务名称以独立浮动标签显示在 Dock 朝屏幕内部的一侧，移出按钮或收起 Dock 时消失，不依赖系统 tooltip 延迟。长名称省略显示，标签不拦截鼠标。

## AI 添加任务

应用内“设置 → AI 接入”提供随应用打包的 `tapdone` CLI 路径。AI 可通过 CLI 查询、校验、添加或更新任务，应用自动同步；也可在“任务”页导入 JSON 文件。创建任务不执行任务。

```bash
tapdone tasks list
tapdone tasks validate --file examples/development-tasks.json
tapdone tasks apply --file examples/development-tasks.json
```

具体 CLI 调用、独立构建方式、JSON 协议、存储迁移和并发规则见 [AI 接入说明](ai-integration.md)。提供 [JSON Schema](task.schema.json)、[示例任务](../examples)和 [AI Skill](../.agents/skills/tapdone-tasks/SKILL.md)。目前支持应用、网址、文件夹、文件以及本机命令/脚本；命令包含工作目录、环境变量和超时配置。设置的“运行记录”提供状态、退出码、日志及停止操作。流程编排和人工复核见 [流程说明](workflows.md)。

### 命令任务

AI 可通过 `action.type: "command"` 添加本机打包或其他脚本。示例见 [local-build.json](../examples/local-build.json)，执行规则见 [AI 接入说明](ai-integration.md#本机命令与脚本)。保存不会执行，点击任务后后台运行，同一任务运行中不重复启动。全部任务的运行记录跨重启保存，输出日志保存在 `~/Library/Application Support/SideTap/Logs/`。

### 不重新编译的外部扩展

`external` 是稳定的通用程序接口：AI 在 `tapdone paths` 返回的脚本目录中生成实现，通过任务配置指定程序、参数和任意 JSON input。TapDone 负责启动、日志、结果、超时与停止，具体功能由脚本提供。脚本更新在下一次执行生效，不需重启或重新编译应用。只需首次更新到包含此接口的版本。

详细协议见 [external-protocol.md](external-protocol.md)，随源码提供 [toolbox 扩展示例](../examples/extensions/toolbox)。将示例目录复制到 `scripts/toolbox` 后，按实际环境确认解释器路径，再通过 CLI 导入其中的 task.json。设置支持编辑通用程序及 JSON 参数，运行记录可查看结构化结果。

## 软件更新与发布

菜单栏和设置的“软件更新”页接入 Sparkle 2.10.1，支持自动检查与手动确认安装。任务运行中会延后安装，完成后备份任务库并重启；应用、内置 CLI 一起更新，外部脚本与配置保持独立。

免费发布流程、GitHub Pages 和 Sparkle 更新密钥配置见 [发布与更新说明](releases.md)。尚未配置签名公钥时，更新功能会显示未启用；源码不包含私钥或证书。工作流仅在推送发布标签或手动发布时构建，普通代码提交不触发运行时测试。

## 名称与兼容性

产品名称为“即达 · TapDone”，应用包为 `TapDone.app`。工程为 `TapDone.xcodeproj`，源码目录为 `TapDone/`，scheme/应用 target 为 `TapDone`，CLI target 为 `TapDoneCLI`，SwiftPM 模块为 `TapDoneCore`，主命令为 `tapdone`，AI Skill 为 `tapdone-tasks`。GitHub 仓库使用 `YunQiWorks/TapDone`，Pages 更新地址为 `https://yunqiworks.github.io/TapDone/appcast.xml`。

以下旧标识专用于兼容，不代表产品仍使用旧名称：

- Bundle Identifier 保持 `dev.sidetap.SideTap`；数据目录与 UserDefaults 身份保持原值，已有任务、运行记录和图标不会因为改名而换到空目录。
- 应用内 `Contents/Helpers/sidetap` 是指向 `tapdone` 的兼容软链接，SwiftPM 仍提供旧名产品。旧的完整 CLI 路径可以继续使用。
- 外部脚本环境同时提供 `TAPDONE_*` 和同值的 `SIDETAP_*` 协议变量，均由应用设置。
- 更新地址配置保留 `SIDETAP_UPDATE_FEED_URL` 键，已有本机覆盖文件不必重配；Sparkle 钥匙串账号 `SideTap` 与发布队列标识也保持兼容，公私钥不变。
- 历史发布说明保留当时的名称，已发布的签名订阅不因源码改名而重写。

任务执行模型、严格返回协议和后续流程编排边界见 [任务执行架构](task-execution-architecture.md)。


## 管理主界面

主窗口默认 1040 × 760，最小 820 × 600，可调整窗口与侧栏宽度，保存窗口尺寸和位置。使用原生侧栏材质，跟随系统深浅色。

- 左侧固定入口：全部任务、活动、流程、运行记录；底部“设置”集中边缘唤出、AI 接入与软件更新。顶部新建菜单支持添加分类、任务和 JSON 导入。
- 分类可展开/收起，任务显示图标、Dock 标记与运行状态点；搜索匹配任务/分类名称，支持全部、Dock、最近 20 个有记录的任务筛选。分类与任务的右键菜单保留重命名、执行、排序和删除入口。
- 右侧分类/全部任务显示可执行的任务概览。选择任务后显示大图标、名称、执行按钮、Dock 开关和最近运行；高级执行配置默认折叠，JSON 输入输出按需展开，环境变量仅显示数量。
- 添加和编辑任务直接在右侧工作区完成，继续使用 revision 乐观并发校验。切换内容会提示放弃草稿；保存失败保留草稿，外部移除当前内容时显示重新选择入口。
- 此轮保留现有流程、活动、运行记录和设置内容，接入新导航；没有重做流程编辑器或灵动岛窗口。


主界面的窗口生命周期统一由 AppKit 的 AppDelegate 管理，SwiftUI 只作为 NSHostingView 内容，不注册额外的 Settings 或 WindowGroup scene。启动、菜单栏入口与系统重新打开 App 都复用同一个窗口，窗口最小化时会先恢复。AppKit 同时提供原生编辑菜单以保留复制、粘贴、撤销等快捷键。
