https://github.com/user-attachments/assets/52cdd435-e6e2-4eb0-9136-d9001ee9d0f5

[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# si-notch

Задачи AI-агентов в чёлке Mac.

## Возможности

- Отдельные списки сессий и состояния подключения агентов.
- Статусы, сообщения, инструменты и подагенты. У каждого агента свой цвет.
- Анимированные питомцы и необязательные звуковые уведомления.
- Codex, Pi, Claude Code, OpenCode, Hermes, Gemini CLI, Copilot CLI, Cursor Agent и свои агенты.
- Локальный API и подключение через SSH.

## Установка

Скачайте DMG из [Releases](https://github.com/eugeneb1ack/si-notch/releases/latest), откройте его и перенесите `si-notch.app` в Applications.
Подключение агентов — **Настройки → Подключение**.

macOS 14+, Apple Silicon. Текущая сборка подписана ad hoc, без notarization. Сборка для Intel не проверена.

[Подключение агентов](docs/ru/agent-integrations.md) · [API](docs/ru/architecture.md) · [SSH](docs/ru/remote-connections.md) · [Статус функций](docs/ru/parity.md)

Обновления проверяются при запуске и каждые шесть часов. Скачать, проверить и установить новую версию можно в **Настройки → О приложении**. Доступны стабильный и бета-каналы. [Публикация обновлений](docs/ru/updates.md).

## Поддерживаемые языки

Английский, русский, упрощённый китайский.

## Сборка

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/build-dmg.sh
```

Нужны Xcode 26+, Python 3 и Node.js. Результат: `build/si-notch-macos-arm64-0.4.6.dmg` и `build/si-notch.zip`.

## Данные и лицензия

Данные сессий обрабатываются локально. История сохраняет на этом Mac запросы, ответы и доступные тексты команд без их вывода. По умолчанию — до 1 000 записей и 200 МБ. В Настройках → История можно изменить оба лимита, отключить запись или очистить архив. Старые переписки не импортируются.

[si-notch Source License 1.0](LICENSE) разрешает изучение, установку, сборку, изменение и бесплатное распространение. Продажа приложения и его модификаций запрещена. Основа лицензии — MIT с дополнительным запретом продажи.

Связь: [dis/root](https://disroot.website/).

[Плагины агентов](plugins/README.md) · [Hermes: установка и готовый промпт](plugins/hermes/README.ru.md)
