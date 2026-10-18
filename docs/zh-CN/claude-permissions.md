[English](../claude-permissions.md) · [Русский](../ru/claude-permissions.md) · [简体中文](claude-permissions.md)

# Claude 权限桥接

此可选桥接在 si-notch 中显示较短的工具请求，并向 Claude 返回一次允许或拒绝决定。普通状态 hooks 不处理权限决定。

替换绝对路径后，将 [配置示例](../examples/claude-permissions.json) 合并到 Claude 设置。只替换 si-notch 原有的只读 `PermissionRequest` 处理器，保留其他 hooks。同时运行两个 si-notch 处理器可能取消待处理卡片。在 Claude 的 `/hooks` 页面确认条目。

支持 Bash、Read、Write、Edit、MultiEdit 和 NotebookEdit。完整紧凑输入必须在 240 个字符内。较长请求及交互式工具仍在 Claude 自身界面处理。

每个请求使用新的 ID，等待期限为 70 秒。超时、取消、应用未运行或响应无效时不返回决定，由 Claude 的普通权限流程继续处理。不会添加永久权限规则。

允许、拒绝、ID 匹配和错误路径已有模拟测试覆盖。真实 Claude 权限请求的往返流程尚未测试。
