[English](../agent-integrations.md) · [Русский](../ru/agent-integrations.md) · [简体中文](agent-integrations.md)

# 连接智能体

打开 **设置 → 连接 → 重新扫描**，选择智能体并检查配置。扫描检查应用、可执行文件路径及常见版本管理器目录，不会启动或安装智能体。

**适配器已配置** 表示文件已准备好；**已收到事件** 才表示成功接收了智能体事件。连接后请启动新会话，已有会话可能需要重新加载。

## 打开会话

点击会话卡片即可打开对应的 Codex 任务或原始终端、编辑器。箭头用于展开详情。切换应用后面板保持展开，直到鼠标离开。本地 helper 根据调用进程的环境识别 Ghostty、Terminal、iTerm、VS Code、Cursor、WezTerm、Warp 和 Zed。这会激活应用，但不会选择指定的终端标签页。仅从文件发现的会话可能需要收到适配器事件后才能获取应用地址。

自定义集成可提供 `terminal_bundle_id`（例如 `com.mitchellh.ghostty`）或 `target_url`。支持 `codex://threads/<UUID>` 及 VS Code、Cursor、Zed 的本地文件链接。命令和扩展链接会被拒绝。SSH 事件不会自动推断本地终端。

## Codex 和 Pi

Codex Desktop 会话通过本地 IPC 自动发现；CLI 会话也可从本地日志发现。**连接 Codex** 会核对内容后添加并授权八个内置 CLI hooks，同时保留现有 hooks 和 `notify`。授权失败时，请在 Codex CLI 的 `/hooks` 页面查看条目。Desktop 协议可能随 Codex 更新而变化。

本地 Desktop 会话发现无需等待推理日志。原生文件事件可发现旧日期目录中恢复的 CLI 会话，活动文件仍会持续轮询。已移除八个 Desktop 订阅和十六个 rollout 文件的限制。仅打开已完成的 Desktop 历史记录不会创建任务卡片。完全本地的 Work 使用同一集成；真实会话的验证范围见[功能状态](parity.md)。此集成不支持云端 Work 和 dots。

本地 Work 卡片显示 **Work** 和公文包图标；Codex 保留名称和代码图标。区分依据是原生产品元数据，在提示或标题中提及 Work 不会改变标记。即使之前的 CLI 进程已退出，新发现的轮次仍可恢复该会话。

**连接 Pi** 将内置扩展注册到 `~/.pi/agent/settings.json`。在已有会话中执行 `/reload` 或重启 Pi。

内置 PermissionRequest hook 仅在确认当前轮次使用人工审核时，为支持的请求提供 **允许一次** 和 **拒绝**。自动审核沿用原有流程，不显示刘海权限提示。适配器只读取所提供会话记录末尾的有界元数据，并核对会话和轮次；格式不稳定、数据缺失或不匹配时回退到 Codex，不根据全局设置猜测当前审核者。决定前可查看完整工具输入。每个决定仅绑定一个请求，截止时间为 70 秒，不会创建永久授权。缺失、过期、过大或不支持的请求回退到 Codex 原有权限流程。升级旧 hooks 后，请重新连接 Codex：仅将 si-notch 自有权限 hook 的超时改为 80 秒，更新后的 hook 需要授权。参见[验证范围](parity.md)。

## Claude Code、Gemini CLI、Copilot CLI 和 Cursor

点击 **连接** 将内置适配器合并到以下配置中。现有设置和 hooks 会保留，修改的文件旁会生成备份。无效 JSON、已禁用的 hooks 或冲突的旧适配器需要手动检查。这些集成不需要 Python。

| 智能体 | 用户配置 |
| --- | --- |
| Claude Code | `~/.claude/settings.json` |
| Gemini CLI | `~/.gemini/settings.json` |
| Copilot CLI | `~/.copilot/hooks/si-notch.json` |
| Cursor | `~/.cursor/hooks.json` |

权限决定仍由智能体处理。[可选 Claude 权限桥接](claude-permissions.md) 需要单独配置。组织策略和工作区信任可能阻止 hooks 运行；si-notch 不会覆盖这些限制。

## OpenCode 和 Hermes

**连接 OpenCode** 将内置插件复制到 `~/.config/opencode/plugins/`。重启 OpenCode 即可加载。若项目目录中已有该插件，请先删除项目级副本。

**连接 Hermes** 将内置插件复制到 `~/.hermes/plugins/si-notch/`。在 Hermes 中启用，然后重启会话：

```sh
hermes plugins enable si-notch
```

两个插件都会保存已安装 helper 的绝对路径，包括自定义应用位置。手动安装的副本也会检查 `/Applications` 和 `~/Applications`。可用 `SI_NOTCH_CLI` 指定其他路径。

应用环境中的绝对路径 `CLAUDE_CONFIG_DIR`、`COPILOT_HOME`、`XDG_CONFIG_HOME` 和 `HERMES_HOME` 会被采用。Finder 不会继承终端的 shell 配置。使用自定义目录或 Hermes 配置档时，请检查界面显示的目标路径，必要时单独配置该档案。

## 自定义 API 和远程智能体

自定义集成通过 [JSON API](architecture.md) 发送会话事件。在其他主机上运行的智能体使用 [SSH 中继](remote-connections.md)。

若会话未显示，请重新加载适配器、开始新一轮交互，并查看 **设置 → 诊断**。使用其中显示的 helper 路径检查事件接收情况：

```sh
/Applications/si-notch.app/Contents/Helpers/si-notchctl status
```

[测试范围](parity.md)。协议文档：[Claude](https://code.claude.com/docs/en/hooks)、[Pi](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md)、[OpenCode](https://opencode.ai/docs/plugins/)、[Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins)、[Gemini](https://geminicli.com/docs/hooks/)、[Copilot](https://docs.github.com/en/copilot/reference/hooks-reference)、[Cursor](https://cursor.com/docs/hooks)。

开发指南：[自定义智能体（英文）](../custom-agents.md) · [俄文](../ru/custom-agents.md) · [Hermes 插件开发（英文）](../hermes-plugin-development.md)。包含生命周期、身份、用量、请求期限和隔离的套接字测试。
