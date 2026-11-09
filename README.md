# Winlay 键桥

Winlay 是一款 macOS 菜单栏键盘映射工具，适合希望在 Mac 上使用 Windows 键盘的人。你可以为不同的键盘分别设置单键映射，让它们使用符合自己习惯的修饰键布局。

> 项目仍处于早期阶段。请在自己的键盘、连接方式和常用应用中验证实际按键与恢复行为。

## 下载与安装

**[下载 Winlay v9（macOS Intel，ZIP）](https://github.com/Songh0918/Winlay/raw/refs/heads/main/dist/v9/Winlay-v9-macos-intel.zip)**

1. 下载并解压 ZIP，将 `Winlay.app` 拖到“应用程序”文件夹。
2. 打开 Winlay，通过菜单栏的键盘图标进入设置。
3. 在“设备”中选择键盘，在“按键”中检查或调整映射，再点击“启用 Mac 键位布局”。
4. 如需撤销，在 Winlay 中选择“暂停并恢复当前键盘”；正常退出应用时也会尝试恢复。

需要 **macOS 15 或更高版本**。当前下载包是 **Intel（x86_64）构建**；Apple Silicon 可能需要 Rosetta 2，尚未经过实际验证。应用使用临时签名，**未使用 Apple Developer ID 签名或公证**，首次打开时 macOS 可能阻止运行。确认下载来源后，可按照系统“隐私与安全性”中的提示操作。

可使用 [SHA256SUMS](dist/v9/SHA256SUMS) 校验下载文件：

```sh
shasum -a 256 Winlay-v9-macos-intel.zip
```

开发构建编号为 `v9`；当前应用包内部版本号仍为 `1.0`。

## 功能

- **按设备设置**：为标识完整且可区分的键盘分别保存规则，支持同时启用多把键盘。
- **单键映射**：选择 Windows 输入键和 Mac 输出键，逐条添加、删除或启用规则。
- **默认布局**：左右 Alt 映射为 Command，左右 Win 映射为 Option；Ctrl 保持 Control。默认布局下，可用 Alt+C、Alt+V 等执行对应的 Mac 快捷键。
- **恢复机制**：写入映射前保存恢复记录；暂停、正常退出或下次启动时尝试恢复原有映射。检测到不安全的冲突时不会强行覆盖。
- **状态检查**：查看键盘及连接状态，手动检查系统中的映射；设备重连后提示恢复。
- **通用设置**：调整设备列表刷新间隔，控制程序坞及菜单栏图标，设置登录时启动。登录项是否可用受系统和应用签名方式影响。

## 目前的限制

- 当前支持的是**单键映射**；自定义组合快捷键、应用例外以及断线后自动重新应用尚未实现。
- 设备必须提供完整且可区分的厂商、产品和位置标识；2.4 GHz 接收器可能显示为 USB，鼠标也可能暴露键盘接口。更换 USB 接口后，可能需要重新选择设备。
- 多接口设备、蓝牙、USB、2.4 GHz、内置键盘以及休眠唤醒的行为可能因设备和系统而异，尚未全面验证。
- 设备列表刷新间隔只影响连接状态的刷新，不改变每次按键或快捷键的响应速度。
- 断线后保留恢复记录；重新连接后请先恢复，再重新启用。若映射已被其他程序更改，Winlay 会停止自动覆盖。
- 单键映射使用 macOS 的 HID 服务；Winlay 不监听、记录或上传按键内容。配置及恢复记录保存在本机 `~/Library/Application Support/Winlay/`。

## 从源码构建

安装 Apple Command Line Tools，在项目目录运行：

```sh
bash scripts/build-app.sh
```

脚本根据当前 Mac 的处理器架构编译并生成 `dist/Winlay.app`，使用临时签名。它也会尝试创建 DMG；如果系统不能创建磁盘映像，已生成的 `.app` 仍可使用。已有同名产物时脚本会停止，请先移走旧产物，或传入其他输出目录。

也可以使用 Xcode 打开 `Winlay.xcodeproj` 并选择 Winlay scheme。核心模型测试使用 `swift test`；运行测试需要可用的 XCTest 环境，部分仅安装 Command Line Tools 的环境可能缺少 XCTest。

## 更新记录与反馈

各开发版本的变更见 [CHANGELOG.md](CHANGELOG.md)。遇到问题或提出建议，请通过 [GitHub Issues](https://github.com/Songh0918/Winlay/issues) 反馈，并注明系统版本、键盘型号、连接方式和复现步骤；请勿提交密码或其他敏感信息。

## 许可证

[MIT License](LICENSE)
