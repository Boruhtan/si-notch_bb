[English](../remote-connections.md) · [Русский](remote-connections.md) · [简体中文](../zh-CN/remote-connections.md)

# Подключение через SSH

**Настройки → Удалённый SSH** перенаправляет удалённый Unix-сокет в локальный сокет Mac. Поддерживается один хост. На удалённой машине нужны Python 3 и разрешённый SSH stream-local forwarding.

Сначала проверьте обычное SSH-подключение с доверенным ключом хоста и авторизацией по ключу. Из каталога исходников si-notch:

```sh
ssh user@host 'install -d -m 700 "$HOME/.si-notch/run" "$HOME/.local/bin"'
scp scripts/remote-relay.py user@host:.local/bin/si-notchctl
ssh user@host 'chmod 700 "$HOME/.local/bin/si-notchctl"'
```

В настройках укажите `user@host` или SSH-псевдоним и **абсолютный** удалённый путь, например `/home/user/.si-notch/run/events.sock`. Нажмите **Подключить**.

В оболочке удалённого агента:

```sh
export SI_NOTCH_SOCKET="$HOME/.si-notch/run/events.sock"
export SI_NOTCH_CLI="$HOME/.local/bin/si-notchctl"
"$SI_NOTCH_CLI" emit '{"event":"agent.working","session_id":"remote-test","provider":"custom","title":"Remote test"}'
```

Каталог сокета должен принадлежать SSH-пользователю с правами 0700, сокет — с правами 0600. Подключайте доверенные учётные записи: они смогут передавать события и запросы решений в приложение.

При ошибке проверьте авторизацию, ключ хоста, разрешение перенаправления и занятый путь сокета. si-notch не заменяет существующий сокет. Отключение или выход из приложения закрывает туннель. [Статус проверки](parity.md).
