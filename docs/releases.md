# TapDone 发布与自动更新

## 已接入的更新机制

应用通过 Sparkle 2.10.1 检查更新，依赖固定到该版本。菜单栏和设置的“软件更新”页提供检查入口，默认每天自动检查；用户可关闭。第一阶段禁用自动下载/静默安装，下载和安装均使用 Sparkle 的确认窗口。

安装前暂停启动新任务。已有命令或外部扩展继续运行，全部结束后才继续安装；Sparkle 的 relaunch delegate 与应用退出回调均设置了等待机制。安装前使用任务库的跨进程锁保存最新备份到 `~/Library/Application Support/SideTap/Backups/`。备份失败会暂停安装，修复存储后可点“继续安装”。普通退出仍按原逻辑停止运行中的任务。

更新只替换应用包，内置 CLI 随同更新；任务库、scripts、Logs、Backups 均在应用包之外。当前任务库格式未变化，没有增加新格式迁移。后续修改任务库格式时仍需独立编写兼容迁移，不能把备份等同于迁移实现。更新协议与脚本热更新相互独立，AI 的脚本修改不会被应用升级覆盖。

## 首次配置

应用使用默认订阅地址：

```text
https://yunqiworks.github.io/TapDone/appcast.xml
```

此地址需通过下面的 GitHub Pages 发布流程启用；仓库里提供的 `updates/appcast.xml` 是空模板，未包含虚假下载或版本条目。正式订阅由发布脚本使用真实包信息生成并签名。

1. 在 GitHub 仓库 Settings → Pages 中将 Source 设为 **GitHub Actions**。如使用自定义域名，需要同时调整客户端订阅地址和发布脚本中的地址生成规则。
2. 本流程无需 Apple Developer 账号、证书或公证，只需配置下表中的 Sparkle 公私钥。
3. 用 Sparkle 官方 `generate_keys` 为 TapDone 生成一次 EdDSA 密钥。工具随 Sparkle SPM 二进制包提供，也可从官方 2.10.1 release 获取。建议独立 Keychain account：

```bash
/path/to/Sparkle/bin/generate_keys --account SideTap
/path/to/Sparkle/bin/generate_keys --account SideTap -p
```

第二条输出公钥，填入仓库变量 `SPARKLE_PUBLIC_KEY`。如需导出供 CI 使用，由你在本机执行：

```bash
/path/to/Sparkle/bin/generate_keys --account SideTap -x /secure/location/sidetap-private.key
```

把文件中的原始 Base64 内容保存为 `SPARKLE_PRIVATE_KEY` Secret（不要再额外进行 Base64 编码），之后按自己的密钥保管方式保存并移除临时导出文件。不要把私钥放进源码、配置文件或聊天。工具默认保留 Keychain 中已有的密钥；不要为每个版本生成新的密钥。

此工程不会自动生成密钥、导出钥匙串或修改 GitHub Secrets。没有有效公钥时，应用不启动自动更新，会显示配置尚未完成，并提供 GitHub Releases 入口。

### GitHub 仓库 Variables

| 名称 | 内容 |
|---|---|
| `SPARKLE_PUBLIC_KEY` | Sparkle 生成的 Base64 公钥 |

### GitHub Actions Secrets

| 名称 | 内容 |
|---|---|
| `SPARKLE_PRIVATE_KEY` | generate_keys 导出的 Base64 私钥文本 |

私钥通过 stdin 交给 Sparkle 签名工具，敏感工具错误不回显原始输出。更新包会用应用配置的公钥再次验证，避免密钥错配。CI 不访问 Apple 账号，不导入证书，不创建临时钥匙串。

## 本机开发配置

Sparkle 使用 SwiftPM 的动态框架嵌入机制。Debug 配置单独关闭 library validation，以便本地 ad-hoc 签名开发包加载该框架；Release 使用免费的 ad-hoc 签名并关闭 Hardened Runtime，避免无 Team ID 的签名触发 Sparkle library validation；不使用 Apple 证书或公证。

`Config/Version.xcconfig` 保存展示版本和构建号，当前为 `0.2.3` / `5`。`Config/Updates.xcconfig` 保存更新地址和默认空公钥。需要让开发包检查真实更新时，可创建被 Git 忽略的 `Config/Updates.local.xcconfig`，配置同一公钥；该文件只放公钥，不放私钥或证书。

CI 通过 xcodebuild 参数注入公钥、版本和订阅地址，覆盖本机配置。开发包与正式版需保持 Bundle Identifier `dev.sidetap.SideTap` 一致才能延续数据位置和更新身份。首个配置了更新公钥的发布版本仍需用户手动下载安装一次；此前未配置公钥的开发包不会自动获得更新能力。

## 发布步骤

1. 写好 `release-notes/<版本号>.md`，递增 `Config/Version.xcconfig` 的版本和构建号。
2. 提交代码并推送新的稳定标签，例如 `v0.2.0`。标签必须符合 `v数字.数字.数字`，本阶段不提供 beta 通道。
3. `.github/workflows/release.yml` 在 macOS runner 上运行 `scripts/release/prepare_release.py`：
   - 检查配置，校验 Sparkle 工具包 SHA-256。
   - 读取并验证现有订阅签名，确保新版本和构建号递增。
   - Archive 时关闭 Xcode 自动签名，同时构建 arm64 与 x86_64，内含 CLI 和 Sparkle。
   - 从 Archive 复制应用，对 Mach-O 程序、嵌套框架与应用由内向外执行 ad-hoc 签名，校验完整性，再生成最终 ZIP；不使用 Developer ID 导出或 Apple 公证。
   - 对 ZIP 做 Sparkle 签名，并用配置公钥核验。
   - 生成仅包含最新版的 appcast，嵌入更新说明，签名并验证订阅文件。
4. 工作流将 ZIP、SHA256SUMS、appcast.xml 发布到 GitHub Releases，再由 Pages job 发布已签名的订阅文件。
5. Pages 部署成功后，自动清理旧 Release 及其附件，只保留最新发布和用户明确指定封存的版本；源码标签及提交保留。发布或更新源部署失败时，不清理旧版。

### 封存版本

`.github/archived-releases.json` 保存用户明确要求封存的版本标签，默认 `[]`。例如用户指定封存 `v0.2.3` 后，将其加入数组。每次发布前更新名单，清理任务按本次发布标签中的名单执行。封存版本保留 Release 和附件，但不加入自动更新订阅；订阅始终指向最新版。未封存的旧安装包会在下一次成功发布后删除。

发布构建号使用 `1000 + GITHUB_RUN_NUMBER`，避免低于现有开发构建；必须一直递增。如仓库迁移或重建工作流导致计数重置，应调整基数，发布脚本会拒绝低于现有源的构建号。每次正式发布也需要更高的展示版本号。工作流串行发布，不覆盖已存在的 Release；标签已存在但无 Release 时可手动运行 workflow 并填写标签。

发布流程未在本次实现中运行，也未触发应用构建或安装。待配置好 Sparkle 密钥和 Pages 后，由发布标签触发。

## 订阅和签名

更新包与 appcast 都要求签名，客户端启用 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`。发布脚本先校验 ad-hoc 应用，再打 ZIP，再对最终 ZIP 做 EdDSA 签名；订阅签名完成后不能再次格式化或改动 XML。更新说明嵌入签名后的订阅，无需单独的说明文件签名。

更新源 HTTPS 失败或已有签名不通过时会中止发布，不会静默丢弃历史条目。首次订阅地址返回 404 时才使用空模板。已有私钥轮换不在自动发布流程内，需按 Sparkle 官方密钥轮换规则单独处理。

## 首次安装与系统提示

此免费发行方式没有 Apple Developer ID 和公证。Ad-hoc 签名只保证包内代码结构完整；Sparkle EdDSA 签名用于验证更新来源，不能替代 Apple 公证。用户首次下载后可能被 Gatekeeper 拦截，确认来自本仓库后，可在“系统设置 → 隐私与安全性”中允许打开；具体提示取决于 macOS 版本和设备管理策略。不要全局关闭 Gatekeeper。

先将 TapDone.app 解压并放到 `/Applications`，再打开。应用内更新仍需用户确认；EdDSA 校验并不保证所有 macOS 环境都不会额外显示系统提示。旧开发包若没有嵌入公钥，需手动安装此版本一次。没有 Apple 身份作为备用信任链，务必保管同一套 Sparkle 私钥，密钥丢失不能靠生成新密钥让已安装客户端自动信任新版本。

## 故障处理

- **本机没有公钥**：应用显示发布配置未完成；先配置公钥并重新构建，不能把空值或示例公钥当成可用配置。
- **Pages 部署失败**：已发布的安装包仍可下载；检查仓库 Pages Source 和 `github-pages` 环境的分支/标签部署策略，修复后重跑失败的 Pages job，不要重新覆盖已发布的 Release。
- **Archive / 打包失败**：CI 会保存 `.release/*.log` 作为失败构建日志，不上传私钥。
- **更新前备份失败**：先修复配置目录写入权限或空间，再点击继续安装。
- **新版本出现问题**：用户可手动安装已封存的先前签名版本；未封存版本的 Release 和安装包会被清理。没有实现自动回滚；若新格式任务库不兼容旧版，先保留当前数据，再选用 Backups 中的副本进行人工恢复。

官方参考：[Sparkle 接入](https://sparkle-project.org/documentation/)、[发布更新](https://sparkle-project.org/documentation/publishing/)、[GitHub Pages 工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

工作流手动运行时可勾选 `prepare_only`，使用所选分支完成打包和签名校验，但不创建 Release 或部署 Pages。正式发布始终使用对应标签中的源码。失败日志会显示非敏感工具输出末尾，并上传 `.release/*.log` 供排查。
