[English](../architecture.md) · [Русский](../ru/architecture.md) · [简体中文](architecture.md)

# 本地 API

内置 helper 将 JSON 发送至 `~/.si-notch/run/events.sock`。使用稳定的 `session_id`，并将智能体名称填入 `provider`。

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl emit \
  '{"event":"agent.working","session_id":"my-task","provider":"custom","title":"Check build","message":"Running tests"}'
```

常用事件：`session.start`、`agent.working`、`agent.waiting`、`agent.completed`、`agent.failed`、`session.end`、`tool.start`、`tool.finish`。可选字段包括 `title`、`message`、`cwd`、`tool_name`、`model`、`id` 和 `sequence`。唯一事件 ID 和顺序号用于过滤重复、过期的更新。同一回合的不同观察源应使用相同的 `turn_id` 以消除重复提示音；下一回合使用新的 ID。支持的字段见 [AgentEvent.swift](../../Sources/SINotchCore/AgentEvent.swift)。

## 请求决定

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl request \
  '{"session_id":"my-task","provider":"custom","message":"Allow this action?"}' --timeout 60
```

`request` 仅等待当前请求的响应。退出码：**0** 表示允许或回答，**1** 表示拒绝，**2** 表示输入无效、超时或断开连接。调用方负责执行返回的决定，si-notch 不执行请求中的操作。

## 传输与代码

- JSON 最大为 128 KiB；`emit` 最多等待一秒接收确认。
- 套接字和目录权限分别为 0600 和 0700，仅允许同一用户访问。最多支持 16 个客户端和 8 个待处理请求。
- 通过 `SI_NOTCH_SOCKET` 或 `--socket /absolute/path` 指定其他套接字。
- `SINotchCore` 处理会话状态和解析；`SINotchTransport` 处理 IPC；`SINotch` 包含 AppKit/SwiftUI 界面和会话监听。
- 会话与操作记录保存在内存中，偏好设置使用 UserDefaults。

运行 `si-notchctl --help` 查看 `run`、`hook`、`notify`、`paths` 和 `status`。

## 代理可用性

Sessions 显示工作、等待、审批、完成和失败的任务。空闲连接与没有任务上下文的 Codex 记录只显示在 Agents 中，同一提供者只占一行。Online 表示原生应用正在运行或最近两分钟内收到事件；较早记录显示「最近在线」。已安装不等于在线。

来源标记为 `internal` 或 `subagent` 的 Codex 会话不会出现在任务列表中。自定义及未分类来源仍可显示。API 客户端可以通过可选字段 `is_internal_session` 标记内部会话，也可以在初始事件之后补充该标记。
