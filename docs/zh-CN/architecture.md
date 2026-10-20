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
- 当前会话状态保存在内存中；独立的本地文本存档可在清除已完成卡片及重启后保留。偏好设置使用 UserDefaults。

运行 `si-notchctl --help` 查看 `run`、`hook`、`notify`、`paths` 和 `status`。

## 代理可用性

Sessions 显示工作、等待、审批、完成和失败的任务。空闲连接与没有任务上下文的 Codex 记录只显示在 Agents 中，同一提供者只占一行。Online 表示原生应用正在运行或最近两分钟内收到事件；较早记录显示「最近在线」。已安装不等于在线。

来源标记为 `internal` 或 `subagent` 的 Codex 会话不会出现在任务列表中。自定义及未分类来源仍可显示。API 客户端可以通过可选字段 `is_internal_session` 标记内部会话，也可以在初始事件之后补充该标记。

## 本地文本历史

历史是 Sessions 中最后一个筛选项，位于 All、Working、Attention 和 Done 之后，没有当前卡片时也可使用。每条记录保存一个请求/轮次、助手回复和可用命令文本。Desktop、Codex 本地记录和 Pi 文件提供明确的文本项。其他集成仅保存原本已共享的文本；不会开启远程内容共享或恢复缺失的命令。不保存工具输出、推理、附件和权限请求数据，不导入旧对话。

私有 JSON 文件及元数据索引位于 `~/Library/Application Support/si-notch/History`，权限为 0700/0600。文件操作在串行后台队列执行，每页显示 50 条记录，打开时才读取内容，最多缓存八条正文。不轮询存档，不使用空闲计时器；文本更新最多合并两秒，结束事件和正常退出会保存缓冲区。

默认上限为 1,000 条记录和 200 MiB（包括索引）。自定义范围为 1–10,000 条和 1–2,048 MiB；超出任一上限会删除最旧记录。索引还受 4 MiB 上限约束。每个文本项最多 16,384 字符，每条记录最多 256 KiB；长记录保留请求及最新文本，并显示缩短提示。搜索覆盖请求标题、项目和提供方。清除历史会取消延迟写入并阻止旧轮次的迟到快照恢复记录。关闭记录功能会保留现有历史。常见令牌和密码会被隐藏，但文本仍可能包含私人信息。

自定义事件可提供 `history_items` 数组，每项为 `{ "id": "stable-item-id", "role": "user|assistant|command", "text": "public text" }`。使用稳定项目 ID 更新流式文本，为每个新请求使用新的 `turn_id`。最多 64 项及 128 KiB 文本，且须满足传输总量限制。不要提供命令输出或通用参数字典。
