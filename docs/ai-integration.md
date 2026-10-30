# AI 与 TapDone 任务接口

## CLI 获取方式

Xcode 的 TapDone scheme 会同时构建 TapDoneCLI 并打包到 `TapDone.app/Contents/Helpers/tapdone`。在设置的“AI 接入”页复制实际路径，然后使用带引号的完整路径调用。无需运行额外服务。主命令现为 `tapdone`；应用同时保留 `Contents/Helpers/sidetap` 软链接兼容旧接入，已有任务库不迁移目录。

也可以在源码目录按需自行构建独立 CLI：

```bash
swift build -c release --product tapdone
.build/release/tapdone help
```

如需使用简短命令，可自行把生成的可执行文件安装到 PATH 中的目录。此工程不自动修改 PATH 或全局 AI 配置。

## 命令

```bash
tapdone paths
tapdone schema
tapdone categories list
tapdone tasks list
tapdone tasks validate --file task.json
tapdone tasks apply --file task.json --if-revision 3
tapdone tasks update development.open-tapdone --dock true --if-revision 4
```

`--if-revision` 可选，但推荐 AI 在读取任务库后携带，以免覆盖过期编辑。`validate` 也可携带该参数。CLI 只负责管理任务，不提供运行任务命令。

所有命令的 stdout 都是 JSON（`schema` 直接输出 JSON Schema）；其他成功结果有 `ok: true`。失败返回 `ok: false`、`error.code`、中文 `error.message` 和退出码 1。`--file -` 从 stdin 读取，支持单任务或数组。限制 16 MB，批次 ID 不可重复。

可用 `--library-dir /absolute/config/directory` 显式选择独立任务库；应用固定使用正常用户目录，独立库不会自动显示在当前应用中。

## 任务格式

完整规范见 [task.schema.json](task.schema.json)，也可运行 `tapdone schema` 获取同一规范。示例在 [examples](../examples)。`schemaVersion` 是交换格式版本，`formatVersion` 是内部任务库版本，二者不要混用。

| action.type | 必需字段 | 说明 |
|---|---|---|
| `application` | `bundleIdentifier` | 如 `com.apple.Terminal`；检查标识格式，实际能否打开由执行时判断 |
| `website` | `url` | 必须是 HTTP/HTTPS 完整网址 |
| `folder` | `path` | 已存在目录 |
| `file` | `path` | 已存在文件或文件包，例如 `.xcodeproj`、`.app` |
| `open` | `path` | 自动根据目标解析为 folder/file |
| `command` | `command`、`workingDirectory` | 后台本机命令，可选 timeoutSeconds、environment |
| `external` | `executable`、`workingDirectory` | 通用外部程序接口，可选 arguments、任意 JSON input、执行选项 |

路径必须为绝对路径或 `~/` 开头；保存时规范化为本机绝对路径，不进行变量插值或 Shell 求值。`command` 与 `external` 分别允许各自的命令/程序及执行选项；其他类型不可混入这些字段，未知字段会报错。SF Symbol 图标检查名称长度，不保证当前系统存在该符号。

`id` 是稳定标识，`apply` 以 ID 更新，其他任务不受影响。`category` 使用分类名称匹配，不存在则创建；同名分类超过一个时返回 `AMBIGUOUS_CATEGORY`。更新可改变所属分类，保留旧的任务说明；名称、目标、图标由输入定义替换。`showInDock` 省略时新任务不加入 Dock、已有任务保留选择。显式 true/false 则修改选择。任务顺序在同分类更新时保留，移至其他分类时放在末尾。

## 存储与并发

默认文件为 `~/Library/Application Support/SideTap/library.json`。GUI 与 CLI 使用同一套 TaskRepository，通过独立 `library.lock` 文件进行跨进程互斥，持锁读取最新数据后修改，并以原子替换保存。每次实际变更递增 revision；完全相同的内容不会递增。

首次使用时，文件不存在才读取旧版 UserDefaults 的 `taskLibrary` 或 `quickActions`；原数据保持不动。CLI 兼容当前默认 Bundle Identifier `dev.sidetap.SideTap`；自定义 Bundle Identifier 后，应先启动应用迁移。坏文件和不支持的版本会报错，不会以默认配置覆盖。

`validate` 检查路径和格式并在内存中预览变更，不保存 library.json；读取过程中可能创建配置目录和锁文件。`apply` 加锁后再次校验，全批成功才写入。GUI 监听配置目录以兼容原子替换，收到变化后刷新界面和菜单；已显示的 Dock 收起，下次唤出使用最新任务。编辑窗口携带打开时的 revision，冲突时保留草稿并提示重新打开，避免静默覆盖。

## 导入与 Skill

不具备本机命令能力的 AI 可以生成 JSON 文件，再由用户从设置的“任务”页导入。导入同样走共享校验和批量写入。

源码提供 [.agents/skills/tapdone-tasks](../.agents/skills/tapdone-tasks/SKILL.md)，可由支持项目级 Skill 的 AI 工具读取。也可按所用工具的安装方式复制整个技能目录。此版本不自动安装到全局、不发布 SkillHub，也不提供 MCP 服务。

## 本机命令与脚本

命令 JSON 使用 `action.type: "command"`，`action.command` 为 zsh 命令文本，`action.workingDirectory` 为已存在的绝对目录或 `~/` 路径。可选 `timeoutSeconds`（1–86400 秒，默认 300）及字符串字典 `environment`。示例见 [local-build.json](../examples/local-build.json)，请将示例命令替换为真实打包命令。

命令通过 `/bin/zsh -lc` 执行，包含登录 shell 配置，但不提供交互式终端输入，stdin 为 `/dev/null`。需要交互密码或人工确认的脚本需先调整为适用的执行方式。命令及环境变量保存在本机 library.json 中；工作目录在校验和实际启动时均检查，具体命令是否有效只能由执行结果判断，`validate` 不会运行它。

创建、导入、apply 不启动命令。由用户点击 Dock、菜单栏子任务或设置中的“执行”启动。运行中同一任务禁止重复启动。设置中的“运行记录”显示跨重启保存的状态、退出码、日志入口和停止按钮；退出应用会停止仍在运行的命令。

每次命令拥有独立进程组，取消/超时先发送 SIGTERM，一秒后对仍存在的进程组发送 SIGKILL；退出应用直接停止所有任务。主动自行脱离进程组的守护进程不属于此控制范围。stdout/stderr 直接合并写入配置目录 `Logs/<run-id>.log`，避免输出管道阻塞；日志持久保留，运行列表暂不跨应用重启恢复。停止状态为 cancelled，超时状态为 timedOut；普通命令按退出码判断成功或失败。

## 通用外部扩展

新增业务能力优先通过 `external` 接口，由 AI 生成脚本与 JSON input，而不是每次添加原生任务类型。协议与完整示例见 [通用外部扩展协议](external-protocol.md)。外部程序通过 stdin/stdout 交换版本化 JSON、通过 stderr 写日志，沿用运行状态、超时和停止控制；新增能力无需重新编译应用。首次获得该协议需要更新一次应用。

所有现有任务类型现在共用运行实例与持久化历史。打开应用、网站、文件的成功仅表示系统接受打开请求，不代表后续业务完成；这些请求不提供停止按钮。远程异步作业可通过 asyncOptions 配置，上下游流程可在设置“流程”页导入并执行。

为新任务声明 `action.inputContract`、`action.outputContract` 可提前约束输入和成功输出；新 external 推荐设置 `protocolVersion:2` 并原样回传 taskID、runID。仅支持 [约束说明](payload-contracts.md)列出的规则，不要生成未支持的 JSON Schema 关键字。

远程打包等异步任务参照 [异步任务协议](remote-async-tasks.md)，脚本必须区分 submit 与只查询的 poll；不要将提交确认当作最终成功，也不要在 poll 中重新提交。

流程定义的前置检查使用 `tapdone workflow validate --file <path|->`，节点须引用已存在且带输入输出约束的 v2 external。详见 [流程与复核模型](workflows.md)。该 CLI 命令仅校验；实际导入、执行和复核在设置“流程”页完成。
