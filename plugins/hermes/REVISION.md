# Tested revision

Plugin version: **1.5**.

Immutable runtime source: [`fb8396cb8a846d1f2c3b57228a5582a0450a9289`](https://github.com/eugeneb1ack/si-notch/tree/fb8396cb8a846d1f2c3b57228a5582a0450a9289/plugins/hermes).

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref fb8396cb8a846d1f2c3b57228a5582a0450a9289 --no-enable
```

The native Hermes installer downloaded this exact subdirectory revision in an isolated `HERMES_HOME` on macOS. It found the plugin under `plugins/si-notch`, left it disabled as requested, and its files matched the source hashes below. `configure.py setup` succeeded with text sharing disabled and a private socket directory. The production Hermes configuration hash stayed unchanged.

| File | SHA-256 |
| --- | --- |
| `__init__.py` | `e0a1871b54b64fcf973635a234dad958577f209d1762d37a9f17ead5e3739068` |
| `plugin.yaml` | `38f616518f107ecb21becb2eb03209bb16fa4c966873d4b1df5c0599a33a3e67` |
| `relay.py` | `96939a4aca0e194207fdbd9fc6a24e99c9a0222fbd1a223a5cfc71958da5e3f2` |
| `configure.py` | `eed5b0c81a73a8aefa33c2e7fb226539b6d98ac0ffeeb9db971e6bc273ce06f8` |

The installed package's bundled relay also acknowledged a presence event through an isolated Unix test peer. The native install remained disabled throughout that packaging check.

The same runtime source was then loaded in three existing profiles on a remote macOS Hermes host (revision `2ef69b1ae6571d5a2e02d4efa1ec044075326e6e`). On si-notch `0.4.9-beta.1`, the actual UI showed three separate Working/terminal cards, two sequential terminal calls in each, final text and Done. Task and final text were verified; interim text depends on the runtime emitting its message hook. Profile configuration and unrelated hooks were preserved.

The current documentation can be newer than this runtime pin. Installer success proves installation, not a live model turn or the Mac UI. Follow the README's acknowledged delivery check and new-session smoke test for your own host and profile. Other platforms and Hermes versions are not established by this macOS check.
