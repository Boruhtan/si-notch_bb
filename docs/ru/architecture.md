[English](../architecture.md) · [Русский](architecture.md) · [简体中文](../zh-CN/architecture.md)

# Локальный API

Встроенный helper отправляет JSON в `~/.si-notch/run/events.sock`. Используйте постоянный `session_id` и имя своего агента в `provider`.

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl emit \
  '{"event":"agent.working","session_id":"my-task","provider":"custom","title":"Check build","message":"Running tests"}'
```

Основные события: `session.start`, `agent.working`, `agent.waiting`, `agent.completed`, `agent.failed`, `session.end`, `tool.start`, `tool.finish`. Дополнительные поля: `title`, `message`, `cwd`, `tool_name`, `model`, `id`, `sequence`. Уникальные ID событий и порядковые номера защищают от дублей и запоздалых обновлений. Передавайте одинаковый `turn_id` из разных наблюдателей одного хода, чтобы исключить повторные звуки; следующий ход должен иметь новый ID. Допустимые поля определены в [AgentEvent.swift](../../Sources/SINotchCore/AgentEvent.swift).

## Решения

```sh
~/Applications/si-notch.app/Contents/Helpers/si-notchctl request \
  '{"session_id":"my-task","provider":"custom","message":"Allow this action?"}' --timeout 60
```

`request` ждёт ответ только на текущий запрос. Коды выхода: **0** — разрешение/ответ, **1** — отказ, **2** — неверные данные, тайм-аут или разрыв связи. Вызывающий агент должен сам исполнить решение. si-notch не выполняет запрошенное действие.

## Транспорт и код

- Размер JSON — до 128 КиБ; `emit` ждёт подтверждение до одной секунды.
- Права сокета и каталога — 0600 и 0700, доступ только тому же пользователю. Поддерживаются до 16 клиентов и восьми ожидающих запросов.
- Другой сокет задаётся через `SI_NOTCH_SOCKET` или `--socket /absolute/path`.
- `SINotchCore` — состояния и разбор событий; `SINotchTransport` — IPC; `SINotch` — AppKit/SwiftUI и наблюдение за агентами.
- Сессии и история действий хранятся в памяти, настройки — в UserDefaults.

Другие команды: `si-notchctl --help` — `run`, `hook`, `notify`, `paths`, `status`.

## Доступность агентов

В Sessions отображаются задачи: работа, ожидание, разрешение, завершение и ошибка. Подключённые агенты без задачи и записи Codex без контекста показываются только в Agents. Несколько сессий одного провайдера имеют одну строку подключения. Online означает запущенное приложение или событие за последние две минуты; более старые данные отмечаются «Был на связи». Установка сама по себе не означает подключение.

Сессии Codex с источником `internal` или `subagent` исключаются из списка задач. Свои и неопределённые источники остаются доступными. Клиент API может пометить служебную сессию полем `is_internal_session`, в том числе после первых событий.
