[English](../verification.md) · [Русский](../ru/verification.md) · [简体中文](verification.md)

# 测试

在 macOS 上从仓库根目录运行检查，需要 Xcode 26+、Python 3 和 Node.js。

## 自动检查

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/verify-release.sh
```

测试脚本运行 Swift 测试、本地化检查、CLI 冒烟测试以及 JavaScript/Python 适配器测试。构建验证会检查 ZIP 内容和解压后应用的代码签名。[GitHub Actions](../../.github/workflows/ci.yml) 还会构建 DMG。

## 界面检查

将 ZIP 解压到临时目录，在 macOS 图形会话中运行界面导出工具：

```sh
si_notch_check_dir="$(mktemp -d /tmp/si-notch-check.XXXXXX)"
ditto -x -k build/si-notch.zip "$si_notch_check_dir"
"$si_notch_check_dir/si-notch.app/Contents/MacOS/si-notch" --qa-export "$si_notch_check_dir/qa"
```

导出工具检查窗口几何、布局、会话状态、透明度和 IPC，并在输出目录中保存报告、截图和音频样本。检查三种语言的截图，以及两种显示缩放比例下的伙伴状态。

添加 `--qa-display-only` 可通过原生面板检查仅在有会话时显示的行为，并导出三种语言的显示设置，包括完整滚动内容。此模式不会启动代理服务。

静态截图不能衡量动画流畅度或合成器帧率。请手动检查悬停、收起、Mission Control、全屏应用和显示器切换，并通过实际使用的音频设备试听提示音。

## 更新安装

使用上面解压的应用运行：

```sh
python3 scripts/smoke-update.py "$si_notch_check_dir/si-notch.app"
```

此检查需要 macOS 图形会话。脚本创建临时签名应用，检查替换、启动和回滚，并拒绝被修改的压缩包。

## 发布文件

```sh
scripts/build-dmg.sh
```

打开 DMG，检查应用和 Applications 快捷方式。将下载文件与发布中的 `SHA256SUMS` 核对。

集成测试范围和已知限制见[功能状态](parity.md)。签名与打包步骤见[更新说明](updates.md#发布版本)。
