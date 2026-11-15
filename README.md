<p align="center"><img src="assets/AppIcon.png" width="112" alt="微空间图标"></p>

# 微空间

macOS 微信存储整理工具：查看空间占用，按聊天清理附件，或在“其他文件”中逐项整理，支持多账号切换。独立第三方项目，非微信官方产品。

## 下载安装

**已发布下载为 v0.3.2 预览版；当前源码与本地安装包为 v0.3.9。最低部署版本 macOS 14.0。** 在苹果菜单 →「关于本机」查看芯片，选择对应安装包：

| 芯片 | 下载 |
| --- | --- |
| Intel | [Intel DMG（x86_64）](https://github.com/xbzzoo/WXStorageCleanUp/releases/download/v0.3.2/WXStorageCleanUp-0.3.2-macOS-x86_64.dmg) |
| Apple M 系列 | [Apple Silicon DMG（arm64）](https://github.com/xbzzoo/WXStorageCleanUp/releases/download/v0.3.2/WXStorageCleanUp-0.3.2-macOS-arm64.dmg) |

ZIP、SHA-256 校验文件及更新说明见 [Release](https://github.com/xbzzoo/WXStorageCleanUp/releases/tag/v0.3.2)。Intel 无法运行 arm64 包，架构不匹配时更换安装包即可。

1. 打开 DMG，将 `WXStorageCleanUp.app` 拖入 **Applications（应用程序）**，复制后推出磁盘映像。
2. 从「应用程序」启动。预览版尚未 Apple 公证；若被拦截，尝试打开后在「系统设置 → 隐私与安全性」点击「仍要打开」，详见 [Apple 说明](https://support.apple.com/zh-cn/102445)。
3. 点击「扫描本机微信」。需要聊天名称和消息归属时，打开「连接聊天索引」并选择账号。
4. 选择附件、核对预览，退出微信后清理。

首次自动连接需 Xcode 或 Command Line Tools（`xcode-select --install`），并需本人在临时微信窗口完成登录确认，请提前保存草稿。扫描及手动整理附件无需 Homebrew 或开发工具。

微信登录后仍停在连接中、需要定位本机 `keys.json` 或手动导入时，见 [连接排查与本地密钥操作指引](docs/connection-guide.md)。

当前源码为 [v0.3.9 整目录清理版](docs/releases/v0.3.9.md)，包含旧版 Command Line Tools 调试兼容、连接诊断、临时微信容器目录与退出修复，以及附件列表交互调整；上方 GitHub 下载链接仍为已发布的 v0.3.2。

升级前退出旧版。新版安装为 `微空间.app`，确认运行正常后可删除旧 `WXStorageCleanUp.app`；已有 `微空间.app` 时直接替换，账号连接和操作记录保留。

## 使用须知

- **清理仅移入废纸篓，核对并清空相应项目后才可能释放空间。** 清空后无法通过本工具恢复；共享硬链接、APFS 快照等可能继续占用空间。
- 保留文字消息和微信数据库；“其他文件”中的附件可能仍被聊天使用，请按需选择。总占用与聊天附件统计口径不同。
- 聊天数据和密钥仅在本机处理。Intel 版已在 Rosetta 下验证，Intel 真机及 macOS 14 / 15 尚未实机回归。

## 源码运行

需要 Swift 5.10+ 和 Xcode 开发工具：

```sh
swift run WXStorageCleanUp
swift test
python3 scripts/package_app.py --arch x86_64  # Apple Silicon 改为 arm64
```

打包会下载并校验依赖源码，生成应用、DMG 和 ZIP；首次构建需数分钟。

[验证记录](docs/validation.md) · [发布说明](docs/releases/v0.3.9.md) · [图标设计](docs/icon-design.md)
