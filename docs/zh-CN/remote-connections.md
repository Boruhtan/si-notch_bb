[English](../remote-connections.md) · [Русский](../ru/remote-connections.md) · [简体中文](remote-connections.md)

# SSH 连接

**设置 → 远程 SSH** 将远程 Unix 套接字转发到 Mac 的本地套接字。一次支持一个主机。远程主机需要 Python 3，并允许 SSH stream-local forwarding。

先通过普通 SSH 确认主机密钥可信且密钥认证可用。在 si-notch 源码目录运行：

```sh
ssh user@host 'install -d -m 700 "$HOME/.si-notch/run" "$HOME/.local/bin"'
scp scripts/remote-relay.py user@host:.local/bin/si-notchctl
ssh user@host 'chmod 700 "$HOME/.local/bin/si-notchctl"'
```

在设置中输入 `user@host` 或 SSH 别名，以及远程套接字的**绝对路径**，例如 `/home/user/.si-notch/run/events.sock`。点击 **连接**。

在远程智能体的 shell 中运行：

```sh
export SI_NOTCH_SOCKET="$HOME/.si-notch/run/events.sock"
export SI_NOTCH_CLI="$HOME/.local/bin/si-notchctl"
"$SI_NOTCH_CLI" emit '{"event":"agent.working","session_id":"remote-test","provider":"custom","title":"Remote test"}'
```

套接字目录必须属于 SSH 用户且权限为 0700，套接字权限必须为 0600。只连接可信账户，因为它们可以向应用发送事件和决定请求。

连接失败时，检查认证、已知主机密钥、转发策略以及套接字路径是否已被占用。si-notch 不会替换现有套接字。断开连接或退出应用会关闭隧道。[测试范围](parity.md)。
