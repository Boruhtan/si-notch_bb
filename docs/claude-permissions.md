[English](claude-permissions.md) · [Русский](ru/claude-permissions.md) · [简体中文](zh-CN/claude-permissions.md)

# Claude permission bridge

This optional bridge displays a small tool request in si-notch and returns a single Allow or Deny decision to Claude. Ordinary status hooks do not do this.

Merge the [configuration example](examples/claude-permissions.json) into Claude settings, replacing the absolute paths. Replace only si-notch’s existing observation-only `PermissionRequest` handler; keep other hooks. Running both si-notch handlers can cancel the pending card. Verify the entry in Claude’s `/hooks` screen.

Supported tools: Bash, Read, Write, Edit, MultiEdit and NotebookEdit. The complete compact input must fit within 240 characters. Larger inputs and interactive tools stay in Claude’s own UI.

Each request has a fresh ID and a 70-second deadline. Timeout, cancellation, missing app or an invalid reply returns no decision, leaving Claude’s normal permission flow in charge. No persistent permission rule is added.

Allow/deny, ID matching and error paths have fixture coverage. A real Claude permission roundtrip has not been tested.
