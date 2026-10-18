[English](remote-connections.md) · [Русский](ru/remote-connections.md) · [简体中文](zh-CN/remote-connections.md)

# SSH connections

**Settings → Remote SSH** forwards a remote Unix socket to the Mac’s local socket. One host is supported at a time. The remote host needs Python 3 and SSH stream-local forwarding.

First establish a normal SSH connection with a trusted host key and key-based authentication. From the si-notch source directory:

```sh
ssh user@host 'install -d -m 700 "$HOME/.si-notch/run" "$HOME/.local/bin"'
scp scripts/remote-relay.py user@host:.local/bin/si-notchctl
ssh user@host 'chmod 700 "$HOME/.local/bin/si-notchctl"'
```

In Settings, enter `user@host` or an SSH alias and the **absolute** remote path, for example `/home/user/.si-notch/run/events.sock`. Click **Connect**.

In the remote agent’s shell:

```sh
export SI_NOTCH_SOCKET="$HOME/.si-notch/run/events.sock"
export SI_NOTCH_CLI="$HOME/.local/bin/si-notchctl"
"$SI_NOTCH_CLI" emit '{"event":"agent.working","session_id":"remote-test","provider":"custom","title":"Remote test"}'
```

The socket directory must be owned by the SSH user with mode 0700; the socket must use 0600. Connect only trusted accounts: they can send events and explicit decision requests to the app.

If connection fails, check authentication, the known host key, forwarding policy and an occupied socket path. si-notch does not replace an existing socket. Disconnecting or quitting stops the tunnel. [Test coverage](parity.md).
