<p align="center"><img src="assets/AppIcon.png" width="112" alt="微空间图标"></p>

# 微空间

macOS 微信存储整理工具：查看空间占用，按聊天清理附件，或在“其他文件”“历史版本数据”中逐项整理，支持多账号切换。独立第三方项目，非微信官方产品。

## 下载安装

**当前版本为 v0.3.14，最低部署版本 macOS 14.0。** 在苹果菜单 →「关于本机」查看芯片，选择对应安装包：

| 芯片 | 下载 |
| --- | --- |
| Intel | [Intel DMG（x86_64）](https://github.com/xbzzoo/WXStorageCleanUp/releases/download/v0.3.14/Weikongjian-0.3.14-macOS-x86_64.dmg) |
| Apple M 系列 | [Apple Silicon DMG（arm64）](https://github.com/xbzzoo/WXStorageCleanUp/releases/download/v0.3.14/Weikongjian-0.3.14-macOS-arm64.dmg) |

ZIP、兼容性说明和 SHA-256 校验文件见 [Release](https://github.com/xbzzoo/WXStorageCleanUp/releases/tag/v0.3.14)。本地构建产物位于 `build/release/`，文件名使用“微空间”前缀。Intel 请选择 x86_64 包。
1. 打开 DMG，将 `微空间.app` 拖入 **Applications（应用程序）**，复制后推出磁盘映像。
2. 从「应用程序」启动。预览版尚未 Apple 公证；若被拦截，尝试打开后在「系统设置 → 隐私与安全性」点击「仍要打开」，详见 [Apple 说明](https://support.apple.com/zh-cn/102445)。
3. 点击「扫描本机微信」。扫描完成后，未连接的账号会自动打开聊天连接面板，也可随时点击顶部账号旁的「连接聊天」。
4. 选择附件、核对预览，退出微信后清理。

首次自动连接需 Xcode 或 Command Line Tools（`xcode-select --install`），并需本人在临时微信窗口完成登录确认，请提前保存草稿。扫描及手动整理附件无需 Homebrew 或开发工具。

微信登录后仍停在连接中时，见 [自动连接指引](docs/connection-guide.md)。连接面板仅提供自动获取密钥并连接。

当前改动见 [v0.3.14 发布说明](docs/releases/v0.3.14.md)。升级前退出应用，将新的 `微空间.app` 替换到「应用程序」中，账号连接和操作记录保留。

## 使用须知

- **清理仅移入废纸篓，核对并清空相应项目后才可能释放空间。** 清空后无法通过本工具恢复；共享硬链接、APFS 快照等可能继续占用空间。
- 保留文字消息和微信数据库（在“历史版本数据”中手动勾选的旧版数据除外）；“其他文件”中的附件可能仍被聊天使用，请按需选择。
- 空间概览统计微信的全部占用（数据容器、应用程序、扩展与共享容器），按账号、内置浏览器与小程序、插件、日志、缓存等模块细分，各模块之和等于总占用。统一按磁盘实际占用计算，硬链接只计一次；“聊天与消息”“其他文件”的合计与概览中对应模块一致。
- 扫描微信 `Data` 目录时，旧版微信（3.x）遗留的聊天图片、视频、语音和文件会按聊天并入对应会话，并随“清理聊天附件”一起移入废纸篓。其余旧版数据（数据库、未对应到新版账号的旧版账号等）归入“历史版本数据”，可在同名页面按文件夹浏览；只有旧版账号文件夹（`<版本>/<32 位哈希>`）内的项目可以勾选并移入废纸篓，已并入聊天的旧版附件保留在原位。清理前请确认需要的旧聊天记录已能在新版微信中查看或已备份。旧版消息未解密，因此只计入聊天占用，不出现在消息列表中。
- 聊天数据和密钥仅在本机处理。每个已连接账号只保留当前使用的一份只读索引快照，重新连接、连接失败或忘记连接后，多余快照会自动删除。Intel 版已在 Rosetta 下验证，Intel 真机及 macOS 14 / 15 尚未实机回归。

## 源码运行

需要 Swift 5.10+ 和 Xcode 开发工具：

```sh
swift run WXStorageCleanUp
swift test
python3 scripts/package_app.py --arch x86_64  # Apple Silicon 改为 arm64
```

打包会下载并校验依赖源码，生成应用、DMG 和 ZIP；首次构建需数分钟。

[验证记录](docs/validation.md) · [发布说明](docs/releases/v0.3.14.md) · [图标设计](docs/icon-design.md)
