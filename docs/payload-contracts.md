# 任务输入输出约束

external 任务可在 action 中声明 `inputContract` 和 `outputContract`，支持 v1 与 v2 返回协议。新自动化任务建议使用 v2，额外校验返回结果是否属于本次运行。

这是有明确边界的 JSON Schema 子集，不是完整 JSON Schema 引擎。不支持的字段会报错，不能加入 pattern、format、$ref、oneOf 等字段后假定它们会生效。

## 配置示例

下面是 action 片段；需要结合实际程序、脚本路径及工作目录配置，不会自动安装解释器或生成脚本。

```json
{
  "type": "external",
  "protocolVersion": 2,
  "executable": "/usr/bin/python3",
  "arguments": ["main.py"],
  "workingDirectory": "~/Library/Application Support/SideTap/scripts/build",
  "input": {"configuration": "Release"},
  "inputContract": {
    "type": "object",
    "properties": {"configuration": {"type": "string", "minLength": 1}},
    "required": ["configuration"]
  },
  "outputContract": {
    "type": "object",
    "properties": {
      "artifact": {"type": "string", "minLength": 1},
      "sizeBytes": {"type": "integer", "minimum": 1}
    },
    "required": ["artifact", "sizeBytes"]
  }
}
```

输出约束验证最终返回的 `data`，不是整个协议对象。例如成功返回还必须包含本次 protocolVersion、taskID、runID、ok，以及符合约束的 data。artifact 的非空字符串约束不验证文件真实存在、路径权限或产物真实性；后续流程应单独要求对应的业务证据或人工复核。

## 支持范围

| type | 可用字段 |
|---|---|
| object | properties、required、additionalProperties |
| array | items（必须指定） |
| string | minLength、maxLength |
| number、integer | minimum、maximum |
| boolean、null | 无其他字段 |

所有约束都必须有 type。对象默认禁止未声明字段，若确需扩展可显式设置 additionalProperties:true。required 中的名称必须在 properties 中声明，且不可重复。

嵌套最多 12 层，每个对象最多声明 128 个属性，单个约束编码后最多 64 KB。长度使用 Unicode 标量数，长度上下限为 0–1048576 的整数；数值上下限必须有限，且下限不能大于上限。约束中的 null 与缺失字段不同：有输出约束时，data 必须存在，显式 data:null 仅匹配 type:null。

## 校验时机与失败行为

- 导入和 CLI 校验时检查约束定义和输入，真正启动 external 时再次检查输入。
- 输入无效时不启动进程。
- 只有进程和协议均报告成功后才校验成功输出；输出无效会将运行标记失败，summary 包含数据路径及原因。
- 无效输出不进入 TaskRun.output，原始 stdout 仍留在日志结果文件中供排查。
- 未声明约束的旧任务保持兼容；旧任务的 succeeded 不自动具备完整业务输出保证。
- CLI 导出会包含约束；设置编辑已有任务会保留它们。目前没有可视化约束编辑器，可通过任务 JSON 和 AI 添加。

上下游编排尚未接入。后续流程必须检查运行状态、协议身份和节点输出约束，不能只检查进程退出码，也不能把打开请求的 systemAccepted 当作业务产物。
