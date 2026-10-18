[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch Hermes 插件

将远程 Hermes 的任务、可见助手消息、工具开始/结束/失败、最终回答与完成状态显示在 Mac 刘海中；Agents 按连接分组显示各配置。

插件 **1.6**。需要 **si-notch 0.4.10 或更新版本**、可信 SSH 密钥登录及 Unix 套接字转发、远程 Python 3.10+。仅使用标准库与现有解释器，无需 pip 依赖、模型凭据、TCP 监听器或新服务。

模型和推理模式来自当前原生 API 请求，会话项目来自 Hermes 的会话目录 API。任务来自结构化 todo_list 结果，子代理状态来自其生命周期事件。任务标题遵循现有文本共享设置；完整请求、推理文本及其他工具内容不会传输。可在 Display → Session details 中独立控制每个字段。旧版 Hermes 可能不提供部分字段。

## 推荐：通过 si-notch 设置

1. 在 Mac 安装 si-notch 0.4.10 或更新版本，或通过 **Settings → About** 更新。
2. **Remote SSH → Add connection**：填写连接名称与 SSH 主机/别名。**Check connection** 只验证登录。
3. **Check profiles**：选择配置、显示名称及是否共享消息文本。
4. **Preview changes → Apply plugin changes**：安装应用内置插件及中继，保留远程备份。检查实际激活结果；未运行网关的配置会在下次启动时加载。
5. 点击 **Connect** 后启动新任务。SSH 登录验证成功不代表已开启转发。
6. 在 **Sessions** 展开卡片查看工具历史；**Agents → 连接名称** 列出没有活动任务的配置。

配置发现读取默认 Hermes 目录和现有命名配置目录，不预设名称或数量。仅选择需要连接的配置；每个配置保留独立身份和文本共享设置。

应用设置安装该应用版本内置的适配器。若采用固定 Git 版本的原生安装，请用 Hermes 管理代码更新。再次应用应用内设置会替换为应用内置版本，每个配置应选择一种代码更新方式。

## Hermes 原生安装

此目录是名为 `si-notch` 的完整插件。内置 `relay.py` 通过 Python 运行，不依赖可执行权限。使用 [REVISION.md](REVISION.md) 中经验证的 40 位提交 SHA：

```sh
hermes plugins install eugeneb1ack/si-notch/plugins/hermes --ref 15df9693d98c9cc47c55d3fc1a5e843e908392d1 --no-enable
python3 "$HOME/.hermes/plugins/si-notch/configure.py" setup --name "Remote Hermes" --hide-text
hermes plugins enable si-notch
```

命令固定到经验证的完整 SHA。这是从本仓库安装，不是 Hermes 插件目录条目。保留原生扫描与确认流程。命名配置需在每个 Hermes 命令的 `plugins` 前加 `-p PROFILE`，并使用该配置实际 home 中的 `configure.py` 路径。不要安装到项目本地 `.hermes`。

`setup` 仅合并插件自己的 `si-notch.json`，必要时创建私有套接字目录，并在修改前备份旧设置。它不修改 Hermes 配置、hooks、`.env`、模型、批准策略或服务。激活由原生 `plugins enable` 完成；无法热加载时，请在本轮结束后打开新会话。

`--show-text` / `--hide-text` 控制文本；`--socket /absolute/private/events.sock` 选择其他套接字；`--bundled-relay` 明确选择内置中继，否则保留现有 helper。已设置的 `SI_NOTCH_CLI` 仍优先使用。Mac 端填写 setup 输出的绝对套接字路径并点击 Connect。

## 验证与隐私

原生 Git 安装在连接后运行：

```sh
python3 "$HOME/.hermes/plugins/si-notch/configure.py" check
```

由应用设置的配置可能没有 `configure.py`，连接后可直接运行新会话测试。本指南的诊断 CLI 属于原生安装包。

`state: delivered` 表示 Mac 确认收到 presence 事件，不会创建任务。随后在新会话运行 [测试提示词](SMOKE_TEST_PROMPT.md)，在 Mac 验证任务、`Working · terminal`、两次工具完成记录、最终回答及 Done。不同配置应保持独立。[安装提示词](INSTALL_PROMPT.md) · [俄语版本](INSTALL_PROMPT.ru.md)。

新配置默认关闭文本共享。任务最多 1600 字符，可见更新及最终回答各最多 4000 字符；仅在 Hermes 触发对应 hook 时发送，不逐 token 转发。不发送工具参数/结果、历史、私密推理或凭据。仅在本地检查结果标志来分类错误。Activity 保留最近 12 条。稳定 `instanceId` 应在升级时保留，克隆到其他主机时应更换。批准决定仍由 Hermes 管理。断开连接时限时失败，不排队或重放事件。

## 故障处理

- `not_connected`：检查主机和绝对路径，并在 Mac 点击 Connect。
- `stale_socket` 或重启后转发错误 255：先断开 Mac 连接，运行 `configure.py repair-socket` 预览，再明确执行 `configure.py repair-socket --apply`。仅在连接被拒绝、权限/所有者正确、`lsof` 无持有进程且 inode 未变时，将旧套接字重命名为备份。不会移动活动套接字；缺少 `lsof` 时不会修改。之后重新连接并 check。
- `relay_failed`：检查 helper、套接字及 si-notch 是否运行/暂停。不要降低 host-key 检查或目录权限。
- 只有工具没有消息：为该配置开启文本并开始新一轮；部分模型或入口不触发中间消息 hook。
- Installed/Last seen 仅表示没有新事件。SSH 连接本身不能证明配置活动。
- 更新时明确选择新完整 SHA 并保留设置和身份。`hermes plugins disable si-notch` 在重载后停止上报，SSH 隧道需单独断开。

已在远程 macOS 与 si-notch 0.4.9-beta.1 中验证三个真实 API 配置会话、并行运行、每会话两次 terminal、任务/最终文本及 Done。自动化测试覆盖隐私、hooks、错误、隔离、中继、设置、备份和套接字恢复。Linux、其他 Hermes 版本与入口仍需各自实测。

[Hermes 插件文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) · [Hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) · [许可证](LICENSE)。
