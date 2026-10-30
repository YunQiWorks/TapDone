# 任务执行架构

目标：任务定义、运行实例、流程编排和界面展示互相独立。增加自定义图标或灵动岛时不修改执行器；异步提交不等同于执行成功；上下游仅消费通过校验的输出；复核绑定指定运行和产物。

## 已落地：运行实例与返回校验

- `TaskRun` 保存运行 ID、任务定义快照、状态、结构化输出与有序状态事件；编辑任务不会改变已开始运行的定义。
- `TaskExecutionCoordinator` 是应用的统一执行入口，Dock、菜单栏、设置通过 AppStore 使用它。所有现有类型（应用、网址、文件夹、文件、命令、external）均创建 TaskRun，保留已有的 `commandRuns` 观察接口兼容更新安装等待机制。
- 统一入口按任务类型选择打开执行器或进程执行器，两者共用一个历史仓库。打开请求成功的输出为 `{systemAccepted:true}`，仅表示系统接受请求；失败时记录错误，不能代表后续业务结果。
- 只有进程任务显示停止按钮。退出时未完成的系统打开请求记录为中断，不虚构“取消成功”；迟到回调不能覆盖已结束记录。
- 每次运行保存在应用数据目录 `Runs/<runID>.json`，格式版本为 1。目录 0700、文件 0600，通过同目录临时文件与 rename 原子替换。副作用启动前必须先保存初始记录。
- `running` 只能结束为 `succeeded`、`failed`、`cancelled`、`timedOut`、`interrupted`。重复结束被拒绝，终态不会被迟到回调覆盖。
- 重启时尚无最终结果的历史运行标记 `interrupted`；不把丢失结果当成功，不自动重试，也不盲目接管旧 PID。异常退出时，系统中可能仍有子进程或远程作业，需要人工检查。
- 原有 external v1 协议默认保留。显式设置 `action.protocolVersion: 2` 时启用严格返回协议：必须是单个 JSON 对象，版本、taskID、runID 必须匹配，未知顶层字段会被拒绝。
- 输出超过 1 MB、缺失或格式错误、身份不匹配均失败。进程非零退出不能因 JSON 返回 `ok: true` 而成功。
- `command` 的成功只表示进程退出码为零；v1 成功表示进程退出码为零且返回 ok。现已支持 external 输入输出约束；未声明约束的旧任务仍不能视为满足任意业务条件；流程任务要求 v2 与输入输出约束。
- 记录保存失败会反馈存储错误，不将任务真实结果篡改为另一种业务结果。恢复时遇到损坏记录会明确报错并保留文件。

## external v2

任务导入仍使用 schemaVersion 1；新增可选 action.protocolVersion，与任务文件格式版本分开。

```json
{
  "type": "external",
  "protocolVersion": 2,
  "executable": "/usr/bin/python3",
  "arguments": ["main.py"],
  "workingDirectory": "~/Library/Application Support/SideTap/scripts/example",
  "input": {}
}
```

stdin 为 `{protocolVersion:2,taskID,runID,input}`，环境变量 TAPDONE_PROTOCOL_VERSION 为 2。程序必须原样回传本次 taskID、runID：

```json
{
  "protocolVersion": 2,
  "taskID": "example.task",
  "runID": "从请求中原样复制",
  "ok": true,
  "message": "处理完成",
  "data": {"artifact": "产物标识"}
}
```

stdout 仅输出这一份 JSON，日志写 stderr。普通 v2 是最终结果协议；配置 asyncOptions 后通过结构化 data 适配远程异步状态。中途进度事件尚未接入。

## 后续接入顺序

1. 已完成统一执行入口：打开应用、网址、文件也创建实例，区分系统接收请求与业务完成。工作流子运行也走同一入口，发布完整运行快照供展示层订阅。
2. 已完成 external 输入输出约束：支持有限、可校验的类型描述，未知规则拒绝，启动前校验输入，成功结束前校验 data。见 [约束说明](payload-contracts.md)。后续将约束接到流程输入映射、执行器能力声明与扩展字段保留。
3. 已接入外部异步：通过 v2 适配器区分 submit/poll，保存作业 ID、轮询状态与总截止时间；重启只恢复查询，停止跟踪不等于远程取消。见 [异步任务](remote-async-tasks.md)。远程取消与回调接入尚未实现。
4. 已接入流程：有向无环图校验、冻结配置、输入映射、串行调度和持久化节点状态；失败阻断下游，重启暂停、不自动重跑。见 [流程说明](workflows.md)。
5. 复核调度与设置界面已接入：绑定流程运行、上游运行 ID、产物摘要及复核人/时间/理由，批准后解锁依赖节点；上下文变化拒绝复用收据。
6. 已接入展示协议：自定义资源图标、只读 RunActivity 摘要、节点进度和待复核入口；设置活动列表订阅统一状态，展示偏好独立于执行参数，不让外部脚本注入原生视图代码。

自定义图片图标已接入设置、Dock、菜单栏任务列表；参见 [展示配置](task-presentation.md)。统一运行展示摘要与活动列表已接入；流程 Dock 入口和灵动岛窗口未实现，属于后续界面扩展。
