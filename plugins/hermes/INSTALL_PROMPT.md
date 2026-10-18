# Install with a Hermes agent

Fill the profile and display name; choose whether task/assistant text may be sent to your Mac. Give this to Hermes **on the remote machine**. You still connect and verify the UI on your Mac.

```text
Install the si-notch observer plugin for this Hermes machine.
Profile: <default or an explicitly chosen existing profile>
Display name: <name to show in si-notch>
Share task and assistant text: no

Use https://github.com/eugeneb1ack/si-notch/tree/v0.4.10/plugins/hermes as the source. Read its README and REVISION.md and use exactly the tested 40-character commit in REVISION.md. Do not install a mutable branch tip or substitute another repository.

You may inspect Hermes version/help, the selected profile's real home, plugin metadata and the private socket path. Do not read or print .env files, tokens, passwords, SSH keys, histories, memories or unrelated configuration. Preserve existing hooks, notify settings, model/provider settings and approval policy. Do not create credentials or persistent services. If the profile/name/text choice is missing, ask one short question; do not silently choose or enable all profiles.

Review the plugin source, then use the installed Hermes CLI's native plugin installer for eugeneb1ack/si-notch/plugins/hermes with --ref <the tested full SHA> --no-enable in exactly this profile. Keep the normal scan/consent checks; do not bypass them. If an install already exists, inspect its provenance and back up its own settings before proposing an update; do not overwrite another integration.

Run the installed configure.py setup with the chosen display name, --hide-text unless I explicitly chose text sharing, and the intended private absolute Unix socket path. Preserve the stable instanceId and other settings; record any backup path. Then enable only si-notch through the native CLI for this profile. Confirm the actual activation result; if the host cannot reload it, tell me to open a new session after this turn. Do not restart unrelated services or automatically approve requests.

Give me the exact SSH host/alias and absolute remote socket path to enter in si-notch Settings → Remote SSH. Tell me to click Connect; Check connection checks login only. Run configure.py check after I connect. If the socket is missing, wait for my connection. If it is stale, present repair-socket preview and obtain my permission before --apply; preserve it under a backup name, never delete an active/held socket or weaken forwarding policy.

After delivery is acknowledged, give me the smoke test in SMOKE_TEST_PROMPT.md to run in a new session. Only perform its bounded sleep/printf terminal calls and visible messages when I request that test. Report source revision, profile, plugin version, settings/socket/backup paths, activation, and the acknowledged check separately. A successful command or native completed run does not establish what my Mac UI displays; ask me to verify task text, tool history, final text and Done there. Do not claim completion while activation or UI verification is unknown.
```
