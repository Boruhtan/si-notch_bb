# Contributing

For bugs, include the si-notch version, macOS version, agent, reproduction steps and expected behavior. Remove private session content and credentials from logs or screenshots.

Keep pull requests focused on one change. Explain the behavior it changes and how it was checked. For interface changes, include before/after screenshots. For fixes, add a regression test when it can reproduce the failure.

## Development

Requires Xcode 26+, Python 3 and Node.js on macOS.

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/verify-release.sh
```

`Sources/SINotch` contains the app, `SINotchCore` the session model and presentation policy, `SINotchTransport` local IPC, and `NotchCLI` the command-line helper. Agent adapters are in `scripts/adapters`; the distributable Hermes plugin is in `plugins/hermes`.

For a new producer, start with the [custom-agent contract](docs/custom-agents.md) and its [isolated Python example](docs/examples/custom-agent/agent.py). For Hermes callbacks, use the [plugin developer guide](docs/hermes-plugin-development.md). Run `python3 docs/examples/custom-agent/test_agent.py` to validate the example without a live account or app. Document whether an integration observes attention or actually owns a response channel; do not claim end-to-end verification from fixtures alone.

Follow the surrounding Swift, Python or JavaScript style. Keep user-facing strings in all three localization catalogs. Preserve existing agent configuration when adding integrations. Approval responses must remain tied to the pending request and its deadline.

Do not commit credentials, local configuration, session recordings or build output. See [verification](docs/verification.md) for optional integration and UI checks and [updates](docs/updates.md) for release packaging.

Contributions are distributed under the repository’s [license](LICENSE).
