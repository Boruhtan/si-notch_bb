[English](remote-connections.md) · [Русский](ru/remote-connections.md) · [简体中文](zh-CN/remote-connections.md)

# SSH connections

**Settings → Remote SSH** manages multiple independently named connections. Add a connection, choose a name, and enter an SSH host or alias. Existing single-host settings migrate without automatically reconnecting.

**Check connection** verifies SSH login using existing keys and `known_hosts`. It does not open a tunnel, install files or verify the server's forwarding policy. **Connect** starts reverse Unix-socket forwarding and enables **Connect automatically at launch**. **Disconnect** stops the connection and turns automatic reconnection off. Quitting the app preserves the startup choice. You can change that choice independently, including after a failed connection. Previously saved connections need one Connect or an explicit startup check after upgrading; new connections stay off until requested. Host and socket edits require disconnecting first. Two active connections cannot share the same host and socket path.

Connections appear as collapsible groups in **Agents**, with their configured profiles inside. Rename a connection at any time or uncheck **Show in Agents**. Removing a connection closes its tunnel and removes its local settings; it does not uninstall the remote plugin. To disable remote reporting, deselect profiles and apply those changes before removing the connection.

## Set up Hermes profiles

1. Establish trusted key-based SSH access first. Password prompts and unknown host-key acceptance are not handled by the app.
2. Click **Check profiles**. The app uses Hermes' existing Python environment to inspect profile names and plugin metadata. It returns no credentials, transcripts or configuration contents.
3. Select profiles, edit their display names, and optionally enable **Show task and assistant messages**. The advanced paths support nonstandard Hermes installations.
4. Click **Preview changes**, review the profiles and file/configuration counts, then **Apply plugin changes**. A changed selection or remote configuration requires a new preview. Backups remain on the remote host, and the result shows their directory.
5. Use the inspected absolute remote socket path and click **Connect**. If setup ran before connecting, a profile's next turn supplies fresh presence information.

Setup installs the bundled observer and portable relay, preserves other plugin settings and hooks, and asks Hermes to reload its plugins. A profile without a running gateway loads the plugin on its next start. Interrupted setup requires **Check profiles** before another apply; configuration changes are not silently replayed.

Profiles remain listed without active tasks. Online means a recent event, rather than proof that an idle process still runs. A connected SSH tunnel does not by itself establish profile activity.

## Events and privacy

The observer sends lifecycle changes, tool names, tool start/finish/failure, and input-wait notifications. Optional text includes a brief task description, visible assistant updates and the final answer. Text sharing defaults to off for a new setup. Task descriptions are limited to 1,600 characters; updates and answers to 4,000. Tool arguments, tool results, history and private reasoning are excluded. Approval events are notifications; the plugin never approves a request.

Profile identity and native session IDs are hashed to separate profiles and hosts. Local settings own grouping and display names. Expand a session card to view the activity history, including completed tool calls.

## Other remote agents

The portable `scripts/remote-relay.py` can be installed as `~/.local/bin/si-notchctl` (mode 0700). Create `~/.si-notch/run` with mode 0700 and set the absolute remote socket path in the app. In the agent's environment:

```sh
export SI_NOTCH_SOCKET="$HOME/.si-notch/run/events.sock"
export SI_NOTCH_CLI="$HOME/.local/bin/si-notchctl"
"$SI_NOTCH_CLI" emit '{"event":"agent.working","session_id":"remote-test","provider":"custom","title":"Remote test"}'
```

Connect only trusted accounts: they can send events and explicit decision requests. Existing sockets are not replaced. Check authentication, the known host key, forwarding policy and an occupied socket path if connection fails. Quitting the app stops all its tunnels. [Verification scope](parity.md).

[Standalone Hermes plugin, native installation and ready-to-use setup prompt](../plugins/hermes/README.md).
