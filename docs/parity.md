[English](parity.md) · [Русский](ru/parity.md) · [简体中文](zh-CN/parity.md)

# Feature status

Available features and verification scope for 0.4.10-beta.1 on Apple Silicon. Automated adapter tests use controlled inputs; they do not establish compatibility with every agent version or a complete model session.

| Feature | Availability and verification |
| --- | --- |
| Panel interaction | Hover activation, delayed dismissal and automatic expansion for active input requests. Geometry, timers, cancellation and request handling have automated coverage; hover feel requires manual checking. |
| Session navigation | Opens Codex task links or the originating app. Routing and failure handling are tested; selecting a specific terminal tab is not supported. |
| Codex Desktop | Session details over local IPC. Live event delivery and session recovery after restart are tested. |
| Codex CLI | Local session detection and hooks. Live lifecycle events and hook setup are tested. |
| Pi | Extension integration tested with Pi 1.2.0, a local mock model and a real shell tool. |
| OpenCode | Plugin loading and session start/end tested with 2.0.32. Helper discovery has automated coverage; model tool and permission events remain unverified. |
| Hermes | Remote API model turns, parallel sessions, task/final text and terminal events verified on one macOS host. Plugin setup and profile isolation have automated coverage. Other agent versions and entry points remain unverified. |
| Claude Code, Gemini CLI, Copilot CLI, Cursor | Configuration merging, backups and hook events have automated coverage. Complete model sessions remain unverified. |
| Custom API | Event delivery, duplicates, timeouts and request/reply are tested. |
| SSH | External-host forwarding and relay delivery verified on one macOS host. Multiple independent tunnel controllers, SSH checks, saved profiles and migration have automated coverage. Three live beta profile cards, tool activity and completion were checked in the actual UI. |
| Interface | Layout, session states, transparency, companions and three languages have automated coverage. |
| Display preferences | Session-only visibility, manual opening, completed-task retention, scoped default reset and fixed compact width have automated coverage. Native panel visibility and settings bitmap exports are checked with local fixtures; physical display and fullscreen combinations still require manual validation. |
| Session metadata | Model and reasoning are visible on unexpanded cards. All six detail switches have bitmap checks. Hermes plugin 1.6 uses native request metadata, session cwd, todo-list results and subagent hooks; Pi and OpenCode supply available model metadata. Supplied metadata and missing fields remain distinct. |
| Sounds | Levels, fades, mute controls, duplicate suppression and parallel sessions are tested. |
| Codex account limits | Read-only CLI requests and manual refresh are tested. |
| Updates | Stable/beta selection, Ed25519 verification, replacement, launch and rollback are tested. Builds are ad hoc signed and not notarized. |

## Manual validation

Physical audio output, hover feel, Mission Control, all multi-monitor/no-notch/fullscreen combinations and macOS 14–15 rendering require manual validation. Static screenshots do not measure compositor frame rate.

## Not supported

Exact terminal-tab navigation, automatic quiet mode for Focus/lock/screen sharing, Bark, Docker relay, Claude Desktop/Cowork and other providers' account limits.

[Testing instructions](verification.md).
