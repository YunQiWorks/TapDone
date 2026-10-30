# TapDone 通用外部扩展协议 v1

TapDone 只维护调用接口，具体功能放在外部脚本或程序中。新增服务器打包、文件处理或其他自动化能力时，由 AI 编写脚本和 JSON 配置，无需给 TapDone 增加 Swift 任务类型。脚本内容在每次执行时读取，修改脚本后下一次执行立即使用新实现。

此接口需首次更新应用以获得 `external` 支持；之后在该协议内新增或修改能力不需重新编译 TapDone。运行时、第三方依赖和系统权限仍由实际脚本所用环境提供，不自动安装解释器或包。

## 文件布局与添加流程

先运行 `sidetap paths` 获取 `scripts` 目录。推荐每个扩展一个文件夹：

```text
~/Library/Application Support/SideTap/scripts/project-build/
├── main.py
└── task.json
```

AI 写入或更新脚本，生成任务 JSON，执行 `tasks validate` 后再 `tasks apply`。任务 ID 稳定，分类与 Dock 规则沿用现有协议。不存在脚本编译缓存，不需重启应用。正在运行的进程保持自己的运行状态，代码更新不会替换已启动的进程。

## 任务配置

```json
{
  "schemaVersion": 1,
  "id": "build.project",
  "category": "打包",
  "name": "项目打包",
  "icon": "hammer",
  "showInDock": true,
  "action": {
    "type": "external",
    "executable": "/usr/bin/python3",
    "arguments": ["main.py"],
    "workingDirectory": "~/Library/Application Support/SideTap/scripts/project-build",
    "timeoutSeconds": 1800,
    "input": {
      "project": "example",
      "configuration": "Release"
    }
  }
}
```

`executable` 必须是已存在且可执行的程序，使用绝对路径或 `~/` 开头。`workingDirectory` 必须是已存在的目录。`arguments` 是字符串数组，直接作为 argv 传入，不做 Shell、环境变量或波浪号展开；参数中的相对文件路径由程序按工作目录解析。`input` 可为任意 JSON 值，默认 `{}`，最大编码体积 1 MB；大整数标识建议使用字符串。`timeoutSeconds` 默认 300，范围 1–86400。`environment` 可配置字符串环境变量，沿用命令任务规则。

`external` 不经过隐式 Shell。需要 Shell 脚本时明确选择 `/bin/zsh` 或 `/bin/bash` 并把脚本路径放入 arguments；Python、Node、可执行二进制同理。已有不支持协议的命令行工具可由一个小型适配脚本调用，也可继续使用原有 `command` 类型。

## 输入

程序启动后从 stdin 读取 UTF-8 JSON，并读取到 EOF：

```json
{
  "protocolVersion": 1,
  "taskID": "build.project",
  "runID": "每次运行的唯一标识",
  "input": {"project": "example", "configuration": "Release"}
}
```

运行环境还提供 `SIDETAP_PROTOCOL_VERSION`、`SIDETAP_TASK_ID`、`SIDETAP_RUN_ID`。保留字段由 TapDone 设置，不被自定义 environment 覆盖。输入通过临时文件连接到 stdin；常规运行结束或启动失败后清理。

## 输出

stdout **只输出一个完整的 UTF-8 JSON 结果**，不要把日志、进度或提示文字混入 stdout：

```json
{
  "protocolVersion": 1,
  "ok": true,
  "message": "打包完成",
  "data": {"artifactPath": "/path/to/package.zip"}
}
```

`protocolVersion` 和 `ok` 必需；`message` 与 `data` 可省略。`data` 可为任意 JSON 数据。扩展内部可增加新字段和能力，TapDone 无需认识业务字段。日志、调试信息和进度写 stderr。程序以退出码 0 且 `ok: true` 才判定成功；非零退出码、`ok: false`、无效结果或大于 1 MB 的结果均判为失败。终止或超时优先显示对应状态。

“运行记录”展示状态和 message，并提供“查看结果”和“查看日志”。stdout 原始结果保存在 `Logs/<run-id>.result.json`；stderr 与运行信息保存在 `Logs/<run-id>.log`。不自动打开 data 中的地址或执行 data 中的指令。输出日志和结果文件保留以便排查，运行列表仅保留本次启动。

## AI 扩展边界

新业务功能应优先作为外部扩展实现：生成脚本、设置 input 和 arguments，通过 CLI 添加任务。TapDone 无需枚举 Jenkins、SSH、HTTP、图片处理等每一种业务。保存和校验不会执行脚本；实际执行由用户点击任务触发。应用自己的新窗口交互、原生权限流程或执行协议变更仍属于应用功能开发。

设置中可编辑可执行程序、参数 JSON、输入 JSON、工作目录、超时；环境变量由 AI 配置并在界面编辑时保留。完整 AI 操作说明见项目 Skill，入门示例见 [toolbox](../examples/extensions/toolbox)。
