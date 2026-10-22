[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch for Hermes

Show remote Hermes sessions in your Mac's notch: tasks, visible assistant messages, tool names and start/finish/failure events, completion, and separate profiles in Agents.

Plugin **1.10**. Use **si-notch 0.4.26 or newer**, an existing trusted SSH login with Unix-socket forwarding, and Python 3.10+ on the Hermes machine. The plugin uses the standard library and the existing Hermes interpreter; no pip packages, model credentials, TCP listener or additional service are needed.

Model and reasoning are taken from the current native API request. The session project comes from Hermes’ session-cwd API. Structured todo_list results and subagent lifecycle hooks supply tasks and child status. Task titles follow the existing text-sharing choice; raw requests, reasoning text and other tool content are excluded. Each field is controlled independently in Display → Session details. Older Hermes versions may omit fields.

## Recommended: configure from si-notch

1. Install si-notch 0.4.11 or newer on the Mac, or update through **Settings → About**.
2. Open **Settings → Remote SSH → Add connection**. Enter a name and SSH host/alias. **Check connection** verifies login only.
3. Click **Check profiles**. Choose the profiles, edit their display names, and choose whether to share task/assistant text.
4. **Preview changes → Apply plugin changes** installs the bundled observer and relay with remote backups. Check the result; a profile without a running gateway loads the plugin on its next start.
5. Click **Connect**. A successful SSH check alone does not start forwarding. Keep the Mac app and connection running, then start a new Hermes task.
6. Open **Sessions** for tasks and expand a card for tool history. **Agents → your connection** lists the configured profiles even when no task is running.

Profile discovery reads the default Hermes home and existing named profile directories. No profile names or count are predefined. Choose only the profiles to connect; each keeps its own identity and text-sharing setting.

The app installs the adapter bundled with that app version. For a Git-pinned native installation, use the alternative below and manage its code with Hermes. Reapplying app-managed setup replaces the adapter with the app's bundled version; choose one code-update method per profile.

## Native Hermes installation

This directory is a complete Hermes plugin, named `si-notch`. Its own `relay.py` works without executable permission, using Hermes' Python. Install it in the profile that will run the tasks, not in a project-local `.hermes` directory.

Use the tested immutable revision in [REVISION.md](REVISION.md):

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 856b403c633c248ae14b0e80abd9339f637996cb --no-enable
```

For a named profile, put `-p PROFILE` before `plugins` in each Hermes command. The command pins the full tested revision. The source is this repository, not an entry in the Hermes plugin catalog. Review it before enabling; retain the normal installer checks and consent prompts.

For the default Hermes home, configure the installed plugin:

```sh
python3 "$HOME/.hermes/plugins/si-notch/configure.py" setup --name "Remote Hermes" --hide-text
hermes plugins enable si-notch
```

For a custom or named profile, use its actual Hermes home in the `configure.py` path, and enable with `hermes -p PROFILE plugins enable si-notch`. Use a Python interpreter from your existing Hermes installation if `python3` is unavailable.

`setup` merges only that plugin's `si-notch.json`, creates a private socket directory if needed, and preserves the old settings in a backup before changing them. It does not edit Hermes `config.yaml`, hooks, `.env`, models, approval policy or services. Native `plugins enable` owns activation. Check its output for a successful reload; otherwise start a new Hermes session after the current turn finishes.

To share text, use `--show-text`; to turn it off, use `--hide-text`. `--socket /absolute/private/events.sock` selects another socket. Existing helper settings remain intact; `--bundled-relay` explicitly selects the included relay. `SI_NOTCH_CLI`, when set, remains an override and should point to the intended executable.

On the Mac, add the SSH host and the **absolute socket path printed by setup**, then click **Connect**. If this is a native install, **Check profiles** discovers its settings; applying app-managed changes is optional and can replace its pinned code.

## Check delivery and run a real task

For a native installation, with the Mac connected:

```sh
python3 "$HOME/.hermes/plugins/si-notch/configure.py" check
```

App-managed profiles may not contain `configure.py`; after Connect, use the new-session smoke test directly. The diagnostic CLI commands in this guide belong to the native package.

`state: delivered` means the Mac acknowledged a presence event. It creates no task and proves no model/tool lifecycle. Run the [smoke-test prompt](SMOKE_TEST_PROMPT.md) in a **new session** of the enabled profile. Verify the task description, `Working · terminal`, two completed tool calls in Activity, final text, and Done. Repeat in another profile; the cards and Agents rows should remain separate.

The [installation prompt](INSTALL_PROMPT.md) can perform the remote half for you; [Russian version](INSTALL_PROMPT.ru.md). The agent reports remote checks and asks you to verify the Mac UI; it cannot infer UI success from a completed run.

## Privacy and behavior

Text sharing defaults to off. Enabled text includes a task excerpt (up to 1,600 characters), visible assistant updates and final answers (up to 4,000 each). Updates appear when Hermes emits their hooks; the plugin does not stream every token. Arguments, tool results, history, hidden reasoning and credentials are excluded. Tool outcome flags are inspected locally to classify failures; their content is never forwarded. Activity retains the app's most recent 12 entries.

Profile and session IDs are hashed. `instanceId` is the stable local profile identity; preserve it across upgrades and use a different one when cloning a profile to another machine. Display names are labels in si-notch. Input/approval events are notifications; decisions stay in Hermes. Delivery is bounded and fails open when the Mac is disconnected; lifecycle events are not queued or replayed. Numeric usage uses the durable queue described below. Plugin 1.8 announces profile presence every 30 seconds while loaded, using the same transport. The heartbeat creates no task, does not refresh task progress, and stops on plugin unload or reload. It restores presence after the Mac reconnects or restarts; presence expires after 120 seconds without delivery. Heartbeats require Hermes’ native `on_unload` API; older runtimes keep only the startup announcement and lifecycle events.

## Troubleshooting and recovery

- **No socket / `not_connected`:** open si-notch Remote SSH and click **Connect**, after checking the host and absolute path. SSH login and forwarding are separate checks.
- **`stale_socket` / forwarding fails with exit 255 after restart:** si-notch 0.4.12 automatically preserves an unused private socket and retries after a rejected forward. This uses the configured remote Python path and requires `lsof`; active or unsafe sockets are left unchanged. For older versions, disconnect this connection on the Mac, then run:

  ```sh
  python3 "$HOME/.hermes/plugins/si-notch/configure.py" repair-socket
  python3 "$HOME/.hermes/plugins/si-notch/configure.py" repair-socket --apply
  ```

  The first command previews. The second requires connection refusal, private ownership/permissions, no holder in `lsof`, and an unchanged inode. It renames the stale socket to a backup, preserving it. It refuses a live or held socket. If `lsof` is unavailable, it makes no change. Reconnect on the Mac and run `check` again. Never delete an occupied socket or enable `StreamLocalBindUnlink` globally.
- **`relay_failed`:** inspect the bounded error, confirm the configured helper/socket, and check that si-notch is running and unpaused. Do not weaken SSH host-key checks or socket permissions.
- **Tools appear but messages do not:** enable text for this profile and start a new turn. A silent model or a runtime that emits no interim-message hook will provide task/final text without interim updates.
- **Configured profile is Installed/Last seen:** it is listed but has no fresh event. A connected tunnel does not prove a profile is active. With plugin 1.8 loaded, allow one heartbeat interval after reconnecting. The Agents group reports SSH state separately; profile rows distinguish presence from active work.
- **Update or disable:** select a new full revision explicitly using the native installer; back up `si-notch.json` first and preserve its identity. `hermes plugins disable si-notch` stops new reporting after reload; it does not stop the Mac tunnel. Disconnect separately. Avoid forcing replacement from an unrelated source.

## Verification scope

Tested on remote macOS with si-notch 0.4.9-beta.1: three real API sessions in distinct profiles, overlapping tools, two sequential terminal calls per session, task/final text and Done in the actual UI. Automated tests cover privacy, hook mappings (including `task_id`), failed tools, profile isolation, relay round trips, idempotent settings, backups and stale-socket recovery. Linux/other Hermes releases and every entry point require their own real-turn check; native install/transport success is not a substitute.

[Hermes plugin documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) · [Hook contract](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) · [SSH configuration](../../docs/remote-connections.md) · [License](LICENSE).

## Token usage (plugin 1.9)

`post_api_request` and successful `post_auxiliary_call` observations send only normalized token counters and hashed request/turn identity. Input includes cache reads and writes; output includes reasoning. Replayed deliveries use the same request identity. Child hooks include the hashed child session identity so Usage can group descendants without adding their totals to the parent twice. No prices or raw provider response are sent. Older Hermes runtimes without these hooks leave usage unknown. Existing remote history is not imported; plugin 1.9 failed open while disconnected. Plugin 1.10 adds the bounded durable queue described below.

The application collects these new events after the installed plugin is updated. Updating the bundled source alone does not change an already-running remote plugin.


### Task usage and offline delivery (plugin 1.10)

Each request carries a stable opaque ID and, when supplied by Hermes, its own turn and parent turn. A reused child retains the parent of its in-flight request. Only numeric usage, opaque IDs, model, profile label and timestamps enter the private `usage-outbox`; prompts, results and credentials are excluded. The queue keeps at most 2,000 records of 8 KiB, retries in the background and removes a record only after the application acknowledges a durable journal commit. Overflow marks subsequent records incomplete. Requests to the model are never retried by this plugin.

Input includes Hermes's separately reported cache reads and writes. Reasoning is already part of output; it is never added twice. Missing historical remote requests are not reconstructed. The existing SSH Unix-socket transport and profile settings are retained.
