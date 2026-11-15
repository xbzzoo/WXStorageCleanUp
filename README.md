<p align="center"><img src="assets/AppIcon.png" width="144" alt="微空间应用图标"></p>

# 微空间 · WeChatStorage

一个本地运行的 macOS 微信存储管理工具：看清空间去向，按聊天、消息或未归属附件整理本地文件。

独立第三方项目，非微信官方产品。当前版本为 **v0.3.0 预览版**。

## 下载与安装

**预编译安装包要求 macOS 26.0 或更新版本、Apple Silicon（arm64）。Intel 不支持此安装包。**

- [下载 DMG 安装文件](https://github.com/xbzzoo/WeChatStorage/releases/download/v0.3.0/WeChatStorage-0.3.0-macOS-arm64.dmg)：打开后将「微空间.app」拖入 Applications。
- [下载 ZIP 应用包](https://github.com/xbzzoo/WeChatStorage/releases/download/v0.3.0/WeChatStorage-0.3.0-macOS-arm64.zip)：解压后将应用拖入「应用程序」。
- [发布说明与 SHA-256 校验文件](https://github.com/xbzzoo/WeChatStorage/releases/tag/v0.3.0)。

升级时先退出旧版，在 Applications 出现同名应用提示时选择「替换」，避免保留多个应用副本。替换应用不会删除微信数据和本工具的账号连接记录。

安装包使用本地 ad-hoc 签名，**尚未取得 Developer ID 签名或 Apple 公证**。首次打开可能被 Gatekeeper 阻止；确认下载来源后，可按 [Apple 官方说明](https://support.apple.com/102445)为该应用单独放行。无需关闭 SIP 或系统整体安全检查。

应用包已包含 SQLCipher、OpenSSL 和 Zstandard，扫描和手动整理附件无需安装 Homebrew。**首次自动连接聊天索引仍需要 Xcode 或 Command Line Tools 提供的系统 Python / LLDB，以及本人完成微信登录确认。**

## 可以做什么

| 功能 | 行为 |
| --- | --- |
| 空间概览 | 扫描微信 Data、xwechat_files 或单个账号目录，统计应用、附件、数据库及其他数据 |
| 聊天与消息 | 连接本地索引后显示聊天名称，按聊天或聊天内消息选择已匹配的附件 |
| 未归属附件 | 按账号列出尚未归集到聊天的附件，搜索、类型筛选、多选、查看文件位置 |
| 清理与恢复 | 预览后移入系统废纸篓，逐项记录结果；可恢复仍在废纸篓且原路径无冲突的项目 |
| 多账号 | 选择和切换本地账号，连接缓存与清理选择按账号隔离 |
| 自动连接 | 在私有临时微信副本中获取并验证当前账号所需密钥，创建只读索引快照 |

工具保留微信数据库和文字消息。按消息清理指移除消息对应的**本地附件**，不会删除消息条目或压缩微信数据库。

## 使用流程

1. 打开应用，点击「扫描本机微信」，或通过「选择目录」指定数据位置。遇到目录权限提示时按系统要求授权。
2. 在概览打开「连接聊天索引」，选择当前账号并执行自动连接；也可从应用菜单打开连接窗口。
3. 首次连接会请求原版微信退出，再打开临时副本。请提前保存草稿，在临时窗口进入对应账号，并按提示打开联系人及相关聊天。
4. 在聊天、消息或未归属附件列表选择文件，核对预览后移入废纸篓。清理执行前需要退出微信。
5. 清理完成弹窗会提示核对废纸篓。**移入废纸篓仍占空间；清空相应项目后才可能回收空间。** 清空后无法再通过本工具恢复。

临时微信使用本机账号数据，可能正常联网并更新缓存、登录状态；请仅用于登录和加载索引。工具只对自己的临时副本增加调试能力，不重签名已安装的原版微信，不调用 sudo，不关闭 SIP。

## 怎样理解占用与共享文件

- 总占用是扫描数据和应用本体的分配空间估算；聊天行展示已归集附件的逻辑大小，两者口径不同。
- 未归属只表示尚未识别聊天归属，**不代表无用文件**。视频、语音、转发媒体等索引映射尚未完整覆盖，不同微信构建的行为可能不同。
- 未归属附件允许清理选中的硬链接路径，其他链接保留。若还有其他链接，即使清空本次废纸篓项目，也不会释放该文件的数据空间。
- 聊天 / 消息清理仍保护未选消息引用及硬链接共享附件；手动文件清理不会自动扩大到同一文件的其他路径。
- APFS 克隆、快照和后台活动也会影响可回收空间，不能把文件大小直接当作实际释放量。

## 本地数据与隐私

本工具不上传聊天数据或密钥。扫描结果在内存中处理，连接密钥、明文索引快照和操作日志保存在本机私有目录下；目录权限 0700，敏感文件 0600。

「忘记账号连接」可删除对应连接缓存；连接窗口也可清除本工具创建的明文快照。导出的分析报告可能包含聊天名称和文件路径，请自行保管。

仓库和安装包不包含个人账号密钥、聊天数据库、扫描报告或操作日志。开发验证使用独立人工夹具。

## 从源码运行

Swift Package 的源码最低目标为 macOS 14，要求 Swift 5.10+。**预编译包的 macOS 26 下限来自所带依赖库**；自行构建时，打包脚本会检查全部二进制的实际部署版本并写入安装包信息。

```sh
swift run WeChatStorage
swift test
/usr/bin/python3 -m unittest discover -s Tests/Python -v
```

打包需要 Xcode 开发工具、Python 3.8+、SQLCipher 和 Zstandard：

```sh
brew install sqlcipher zstd
python3 scripts/package_app.py
```

输出：

- `build/微空间.app`
- `build/release/WeChatStorage-0.3.0-macOS-arm64.dmg`
- `build/release/WeChatStorage-0.3.0-macOS-arm64.zip`
- `build/release/SHA256SUMS.txt`

构建脚本生成完整 `.icns`，复制依赖和许可说明，执行本地签名校验，并创建带 Applications 链接的 DMG。它不安装应用，也不修改微信。正式 Developer ID 签名与公证需要发行者自己的证书和凭据。

开发布局检查可运行 `build/微空间.app/Contents/MacOS/WeChatStorage --layout-check build/LayoutChecks`。该入口只使用人工演示数据，覆盖完整窗口、导航、清理选择和完成提示，不连接真实微信。

[验证记录](docs/validation.md) · [图标设计与生成提示词](docs/icon-design.md) · [发布说明](docs/releases/v0.3.0.md)
