# Real-session smoke test

After enabling the plugin and connecting si-notch, paste this into a **new Hermes session** of the chosen profile. Use another profile for a second independent session.

```text
Run a small si-notch display test in this session.
First send a visible assistant message: "si-notch: starting tool check".
Run exactly one terminal call containing only: sleep 8; printf 'SI_NOTCH_STEP_1_OK\n'
Then send a visible assistant message: "si-notch: first tool finished".
Run exactly one more terminal call containing only: sleep 8; printf 'SI_NOTCH_STEP_2_OK\n'
Finally answer exactly: "si-notch: two tools completed".
Do not read or change files, memory, configuration, services or other sessions. Do not use the network, delegation, messaging services or other tools. This is a new isolated test task, not project work.
```

On the Mac verify: task text (when enabled), Working with terminal, both start/finish entries under Activity, final text and Done. Interim messages depend on the host emitting its visible-message hook. If a turn finishes but nothing appears, check SSH transport before running more model turns.
