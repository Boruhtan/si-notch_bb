# Tested revision

Plugin version: **1.6**. App release: **0.4.10**.

Immutable runtime source: [`05ab16ff4306e3a466502372aa0d8d95b89b0810`](https://github.com/eugeneb1ack/si-notch/tree/05ab16ff4306e3a466502372aa0d8d95b89b0810/plugins/hermes).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 05ab16ff4306e3a466502372aa0d8d95b89b0810 --no-enable
```

The application bundles these exact runtime files. Native PluginManager and TodoStore on the remote macOS Hermes host produced model, reasoning, session cwd, task, subagent and activity events through an isolated SSH-forwarded Unix socket. The test used synthetic lifecycle inputs and no model call. Eight existing enabled profiles loaded plugin 1.6 through the app setup protocol with no configuration actions and with native reload confirmation.

The native Hermes installation handler installed this immutable source into an empty temporary profile and updated it again with the standard installer checks enabled. All four runtime hashes matched, plugin settings survived replacement, and the eight production configuration files remained byte-identical. The full CLI bootstrap in a fresh data root timed out while preparing its Python environment; the handler check used the existing Hermes interpreter.

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `4e431583bc6499bbc04eb3fe34f02e0f9a5cd98236acc31bfc4fcd2c414c2c91` |
| `plugin.yaml` | `8f41d8e7b2d192be59ed3d27d6ab19bd7036d68530e80dd914124699e16a6b82` |
| `relay.py` | `96939a4aca0e194207fdbd9fc6a24e99c9a0222fbd1a223a5cfc71958da5e3f2` |
| `configure.py` | `eed5b0c81a73a8aefa33c2e7fb226539b6d98ac0ffeeb9db971e6bc273ce06f8` |

All six Display detail switches were checked on native card bitmap exports, with local reducer, helper/socket and adapter regression coverage. Request bodies, reasoning text, child goals/summaries and unrelated tool content are excluded. Task titles follow the profile text-sharing preference.

A successful installation or synthetic event does not establish every real model turn. Other Hermes versions and platforms may omit metadata; actual values are shown only when the runtime supplies them.
