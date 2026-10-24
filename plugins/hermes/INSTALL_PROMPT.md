# Install or update with a Hermes agent

Use this on the machine running the selected Hermes profiles, either your Mac or an SSH host. Fill the fields once; a list authorizes only the listed profiles.

```text
Install or update the official si-notch observer.
Location: <local Mac or remote SSH host/alias>
Existing profile(s): <default, a named profile, or an explicit list>
Display name(s): <one label per profile>
Share task and assistant text: no

Read https://github.com/eugeneb1ack/si-notch/tree/v0.4.31/plugins/hermes/README.md and REVISION.md from that same release. Use the exact tested 40-character runtime SHA recorded there, not main, a tag passed to --ref, another repository, or a stale cached guide.

1. Inspect the installed Hermes version and plugins --help, and resolve each selected profile's real home. Use the native Hermes plugin installer for eugeneb1ack/si-notch/plugins/hermes with --ref <tested full SHA> --no-enable, scoped with -p PROFILE or the exact HERMES_HOME. Keep the normal scan and consent checks. Do not create a new Hermes installation, edit hooks/notify/model/provider/approval settings, read credentials or histories, or restart unrelated services.

2. For an existing official install, back up only its plugin settings and pending usage-outbox outside the plugin directory; preserve provenance, instanceId, socket/helper paths, text preference and unknown settings. Update in place using the installed CLI's supported pinned-reinstall path after reviewing its scan. Do not remove/reinstall, replace another source, or discard local state. If the installed CLI cannot preserve it, stop at that concrete incompatibility. Reuse a working 1.12 runtime with the new Mac app until the plugin update can be applied safely.

3. Run configure.py setup separately in every selected profile with its chosen --name and private socket path. For a fresh profile, use --hide-text unless I chose sharing. On an update, omit text/helper/socket options unless I requested a change. Preserve instanceId on every update. Different profiles, including local profiles, must have different IDs; names may match. Never copy si-notch.json or usage-outbox from another profile. Only for an explicitly selected new clone with an accidentally copied ID, use setup --new-instance on that clone; keep the original untouched and do not migrate its pending accounting.

4. On a local Mac, keep si-notch running and use its native si-notchctl helper. The standard app locations are discovered automatically; for a custom app location set --helper to that app's Contents/Helpers/si-notchctl. No SSH or second agent service is needed. On a remote host, use the printed absolute socket path in si-notch Settings → Remote SSH and click Connect. One connection carries that host's profiles; do not create a second tunnel to the same endpoint or edit the Mac's internal socket paths.

5. Enable only the selected si-notch profile through the native CLI and inspect activation. If it cannot reload, finish this turn and start a new session. Run configure.py check, allow one 30-second heartbeat interval, and report source SHA, profile/name, plugin version, backup, activation and delivery separately. A receipt proves delivery, not task execution or Mac UI behavior. Verify each profile independently in Agents; a disconnected host must not make another profile online. Run SMOKE_TEST_PROMPT.md only when I request its bounded task test. Do not auto-approve actions or submit answers.

If the socket is absent, start/connect the app. For a stale socket use repair-socket preview; obtain permission before --apply and never delete an active socket or weaken SSH checks. Ask one short question only if the location, selected profiles, names or a required choice are missing. Do not configure unrelated profiles.
```
