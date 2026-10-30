# 外部异步任务

通过 external 适配脚本接入远程打包、数据处理等耗时作业。脚本负责调用实际服务，TapDone 负责一次提交、定期查询、记录状态和校验最终结果，不内置服务地址或凭据。

## 任务配置

external 的 action 使用 `protocolVersion:2` 并添加：

```json
{
  "asyncOptions": {
    "pollIntervalSeconds": 5,
    "timeoutSeconds": 3600
  }
}
```

其余 executable、arguments、workingDirectory 和原 input 按实际适配器配置。每次调用脚本仍使用原命令环境、每次调用 timeoutSeconds，并受总截止时间约束。查询间隔为 2–300 秒，总超时为 1–86400 秒；未知 asyncOptions 字段拒绝导入。

配置不存在 asyncOptions 时保持普通 external 行为。设置编辑与 CLI 导出会保留已有异步配置，当前通过 JSON/AI 添加，尚无专用异步配置表单。

## 请求协议

使用原有 v2 stdin 包装。顶层 runID 是**本次脚本调用 ID**，每次查询都会变化，必须在该次返回中原样回传。任务 input 变为以下控制包装：

```json
{
  "protocolVersion": 2,
  "taskID": "build.remote",
  "runID": "本次调用ID",
  "input": {
    "operation": "submit",
    "parentRunID": "稳定的父运行ID",
    "payload": {"configuration": "Release"}
  }
}
```

首轮 operation 为 submit，之后为 poll，且 input 增加已保存的 jobID。payload 始终是任务原始 input；inputContract 校验 payload，不能用它约束控制包装。

submit 才能产生远程副作用。poll 必须只查询指定作业，绝不能再次触发创建/发布。若服务支持幂等键，适配脚本应将稳定的 parentRunID 用作提交幂等键。TapDone 不自动重试提交，也不保证外部服务自身幂等。

## 返回协议

每次 stdout 仍只输出一个 v2 对象，顶层 taskID/runID 必须匹配本次请求。ok 表示**适配器调用**成功，不代表远程作业完成。

提交成功：

```json
{
  "protocolVersion": 2,
  "taskID": "build.remote",
  "runID": "本次调用ID",
  "ok": true,
  "data": {"status": "submitted", "jobID": "build-123"}
}
```

查询中：`data` 为 `{status:"running",jobID:"build-123"}`，可增加字符串 message。

远程完成：

```json
{
  "protocolVersion": 2,
  "taskID": "build.remote",
  "runID": "本次查询调用ID",
  "ok": true,
  "data": {
    "status": "succeeded",
    "jobID": "build-123",
    "result": {"artifact": "build-123.zip"}
  }
}
```

outputContract 校验最终 result，而非中间的 data 控制对象。succeeded 必须包含 result，即使没有输出约束。远程失败返回 `data:{status:"failed",jobID:"build-123",message:"失败原因"}`，父运行标记失败。

data 仅允许 status、jobID、result、message；查询阶段 jobID 必须与已保存的作业一致，且不能再次返回 submitted。状态无效、身份不匹配、调用异常或无法校验产物时，父运行标记中断，停止推进，不自动提交新作业。

## 持久化与恢复

- 父运行保存到 `Runs/`；短期调用的记录保存在 `Runs/Steps/`。父日志链接每次调用日志。
- 确认作业后，先原子保存 jobID、总截止时间和下次查询时间，再发起后续查询。
- 正常退出时暂停查询，已有 waitingExternal 作业在下次启动继续查询同一 jobID；软件更新同样允许暂停和恢复查询。
- 若退出时尚未确认 jobID，标记中断，不自动重新提交。服务可能已接收提交，应人工检查。
- 重启不会延长总截止时间。调用中收到超期结果也不接受为成功。
- 超时只表示未在截止时间内取得有效最终结果，不代表远程作业被取消。
- “停止跟踪”停止本地查询，将记录标记中断，不调用远程取消接口。

适配脚本由本机程序执行。TapDone 校验协议和返回结构，但不能证明脚本遵守“poll 只查询”的约定；应只配置可信脚本，服务侧权限和幂等仍由实际接入控制。当前不实现远程取消、回调 Webhook、自动重试、账户授权或云端凭据管理。
