[English](../hermes-plugin-development.md) · [Русский](hermes-plugin-development.md)

# Разработка плагина-наблюдателя Hermes

Для обычной установки используйте [si-notch для Hermes](../../plugins/hermes/README.ru.md). Здесь описано, как поддерживаемый плагин связывает официальный API Hermes с si-notch и как расширять наблюдение, сохраняя поведение агента.

Плагину нужны `plugin.yaml` и `register(ctx)` в `__init__.py`. Подписка выполняется через `ctx.register_hook(name, callback)`. Обработчики принимают `**kwargs`, чтобы новые поля Hermes не ломали совместимость. Устанавливайте плагин в пользовательский каталог нужного профиля: project-local discovery не подходит как надёжный способ установки в gateway. Ориентируйтесь на [официальное руководство](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) и `hermes plugins --help` установленной версии.

## Готовая интеграция

| Файл | Назначение |
| --- | --- |
| [`plugin.yaml`](../../plugins/hermes/plugin.yaml) | Имя, версия и список хуков. |
| [`__init__.py`](../../plugins/hermes/__init__.py) | Регистрация, выборка разрешённых метаданных, lifecycle, идентичность профилей/сессий, presence и очередь числового расхода. |
| [`relay.py`](../../plugins/hermes/relay.py) | Самостоятельный Python-клиент локального или перенаправленного через SSH сокета. |
| [`configure.py`](../../plugins/hermes/configure.py) | Настройка только этого плагина, проверка доставки, осторожное восстановление устаревшего сокета. |
| `si-notch.json` | Настройки установленного профиля: `instanceId`, `displayName`, `showSessionText`, `socketPath`, необязательный `helperPath`. Пользовательский файл, не часть репозитория. |

На Mac: **Настройки → Подключение → Hermes → Подключить**, затем `hermes plugins enable si-notch` для нужного профиля и новый запрос. Для ручной установки: `configure.py setup --name "Local Hermes" --hide-text --socket "$HOME/.si-notch/run/events.sock"`. Локальный helper в стандартном месте обнаруживается автоматически. Удалённая установка выполняется через **Настройки → Remote SSH** либо штатную установку Hermes из README плагина. Через SSH приватный удалённый сокет перенаправляется на Mac; HTTP-сервер и ключ модели не нужны.

Не включайте два экземпляра для одного профиля. Настройка из приложения устанавливает код своей сборки; Git-установка Hermes закрепляет выбранную ревизию. Повторное применение настройки приложения заменяет этот код. При обновлении сохраните `instanceId`; при клонировании профиля на другую машину создайте отдельную идентичность.

## Правильный lifecycle

Реальные зарегистрированные обработчики:

| Callback Hermes | Поведение si-notch |
| --- | --- |
| `on_session_start` | Однократное начало сессии, доступные метаданные модели. |
| `pre_llm_call` | Начало пользовательского запроса, необязательный публичный фрагмент задачи. Возвращает `None`. |
| `pre_api_request` | Работа, текущие model/reasoning, фиксация родительского запроса дочернего вызова. |
| `pre_tool_call`, `post_tool_call` | Начало, завершение или ошибка инструмента. `session_id`, при его отсутствии — переданный `task_id`. Возвращает `None`. |
| `on_interim_message`, `post_llm_call` | Необязательный видимый текст ассистента; один `post_llm_call` ещё не завершает запрос. |
| `on_session_end` | Конец **запроса**: completed → completed; interrupted → waiting; явная ошибка либо `completed=False, interrupted=False` → failed. Отсутствующие признаки исхода остаются waiting/unknown. |
| `on_session_finalize` | Закрытие самой сессии и очистка временного состояния. |
| `subagent_start`, `subagent_stop` | Lifecycle ребёнка и связь с родителем. Ребёнок сообщает собственный расход. |
| `on_human_input_request`, `on_human_input_resolved` | Внимание с непрозрачным ID вопроса, затем продолжение работы. Канала ответа нет. |
| `post_api_request`, успешный `post_auxiliary_call` | Итоговые числовые счётчики вызова, постоянный ID и связь с задачей. |

`on_session_end` не означает закрытие разговора: [официальный контракт хуков](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) относит его к завершению запроса, включая прерывания и неуспешные исходы. Plugin callbacks `on_*` также отличаются от gateway events вроде `agent:start`: это другие загрузчики и payloads.

Передавайте имя инструмента и признаки результата, а не сырые `args`, вывод, историю диалога и скрытые рассуждения. Поддерживаемый плагин локально проверяет ограниченные признаки ошибки и структурированные todo, затем формирует разрешённые поля. Текст задачи и ассистента зависит от явной настройки профиля. Отсутствие поля не доказывает успех.

## Минимальный собственный observer

Можно скопировать [проверяемый Python-отправитель](../examples/custom-agent/agent.py) в каталог своего плагина под именем `agent.py`. Ниже — инструментальный observer для разработки. Он не заменяет полный lifecycle и очередь расхода готового плагина.

```yaml
# plugin.yaml
name: my-notch-observer
version: "0.1"
description: Report tool activity to a configured si-notch socket
provides_hooks:
  - pre_tool_call
  - post_tool_call
```

```python
# __init__.py; agent.py лежит рядом
import hashlib
import os
import threading
from .agent import Agent, BridgeError


def register(ctx):
    agents = {}
    lock = threading.Lock()
    endpoint = os.environ.get("SI_NOTCH_SOCKET")
    namespace = os.environ.get("MY_NOTCH_INSTANCE")
    if not endpoint or not namespace:
        return

    def report(kind, session_id=None, task_id=None, tool_name=None, **kwargs):
        identity = session_id or task_id
        if not isinstance(identity, str) or not identity or not isinstance(tool_name, str):
            return
        key = "observer-" + hashlib.sha256((namespace + "\0" + identity).encode()).hexdigest()
        with lock:
            agent = agents.get(key)
            if agent is None:
                if len(agents) >= 256:
                    return
                agent = agents[key] = Agent(endpoint, session=key)
            event = agent.event(kind, tool_name=tool_name[:128])
            # Пример не хранит sequence между reload и не знает ID запроса.
            event.pop("sequence", None)
            event.pop("turn_id", None)
            try:
                agent.deliver(event)
            except (OSError, ValueError, BridgeError):
                # В production добавьте ограниченную диагностику без личных
                # данных и backoff. Ошибка наблюдения не останавливает инструмент.
                pass
        return None

    def before_tool(**kwargs):
        report("tool.start", **kwargs)

    def after_tool(status=None, **kwargs):
        report("tool.failed" if status in ("error", "failed", "blocked") else "tool.finish", **kwargs)

    ctx.register_hook("pre_tool_call", before_tool)
    ctx.register_hook("post_tool_call", after_tool)
```

В процессе, который загружает этот тестовый плагин, задайте `SI_NOTCH_SOCKET` с абсолютным endpoint и `MY_NOTCH_INSTANCE` с постоянным уникальным ID профиля. Включите `hermes plugins enable my-notch-observer`, проверьте `hermes plugins list` и начните новый запрос. Пример не передаёт текст, не запускает worker и не отвечает пользователю. Для полноценных сессий, профилей, backoff, расхода задач и cleanup используйте готовый плагин. Два observer для одной сессии одновременно не нужны.

Наблюдение не должно возвращать разрешение, изменение аргументов инструмента или добавочный контекст. `pre_tool_call` и `pre_llm_call` могут менять поведение возвращаемыми значениями; si-notch возвращает `None`. Формат телеметрии и совместимость описаны в [observer API](https://hermes-agent.nousresearch.com/docs/developer-guide/observer-hooks).

## Параллельность и выгрузка

Разные сессии и инструменты могут вызывать hooks параллельно. Защищайте карты ID/счётчиков и ограничивайте I/O. Не держите общий lock во время долгого запроса к модели. Готовый плагин использует subprocess с ограниченным временем доставки и backoff; строка из хука никогда не исполняется через shell.

Для проекта используйте `ctx.session_cwd()` внутри callback сессии, если API доступен. `os.getcwd()` gateway-процесса не определяет каталог конкретного диалога. Model/reasoning берите из текущего запроса, а не из глобального значения по умолчанию, которое может быть переопределено.

До запуска worker зарегистрируйте `ctx.on_unload(dispose)`. При disable/reload остановите его и освободите ресурсы. В готовом плагине 30-секундный worker presence/retry запускается только при наличии этого API. Старые runtimes сохраняют стартовое presence и обычные lifecycle-события. Cleanup определён в [Hermes PluginContext](https://github.com/nousresearch/hermes-agent/blob/main/hermes_cli/plugins.py).

## Нормализация расхода

`post_api_request` передаёт нормализованный usage и `api_request_id`. Адаптер хеширует ID и переводит отдельные upstream input/cache buckets во входной счётчик, уже включающий cache. Reasoning входит в output и повторно не прибавляется. Каждый вызов сохраняет свой turn и родительский turn, зафиксированный до начала запроса переиспользуемого ребёнка. Успешные вспомогательные вызовы — отдельные факты расхода. Нет hooks/счётчиков — значение неизвестно; старая удалённая история не импортируется.

Приватный `usage-outbox` хранит ограниченные числовые записи, непрозрачные ID, model/profile labels и timestamps. Повторяется доставка до `usage_committed`, но не вызов модели. Повторный ID не увеличивает итог в приложении; переполнение отмечает данные как неполные. Сохраняйте очередь при обновлении. Перед удалением плагина решите, нужно ли сначала доставить накопленное. Поля, итоговые суммы и ACK описаны в [протоколе своих агентов](custom-agents.md#расход-токенов-без-повторного-учёта).

## Внимание не выдаёт разрешение

Текущий Hermes-плагин наблюдает human input, но не регистрирует approval transport, не отправляет ответы, не вызывает message API и не управляет инструментами. Он передаёт ID внимания, чтобы приложение направило пользователя в исходный чат/терминал Hermes. Не связывайте уведомительный hook с `si-notchctl request`, пока в самом агенте нет настоящего канала применения ответа к этому запросу. Такой канал обязан проверять точный pending request, действие, срок и однократность; таймаут и неопределённость не дают разрешения.

## Проверка изменений

```sh
python3 -m unittest discover -s Tests/adapters -p 'test_hermes*.py'
python3 docs/examples/custom-agent/test_agent.py
```

Первая команда проверяет callbacks, приватность, изоляцию профилей, очередь расхода, настройку и доставку на fixtures. Вторая — отдельного отправителя. Они не доказывают живой roundtrip интерфейса Hermes. Для него установите плагин в выбранный тестовый профиль, проверьте загрузку, подключите Mac и используйте [smoke-test prompt](../../plugins/hermes/SMOKE_TEST_PROMPT.md). Вручную проверьте Working → два завершённых инструмента → Done, отдельность второго профиля, необязательный текст и новый расход вызовов. На вопросы отвечайте в Hermes. Reconnect/unload проверяются отдельно; presence ACK или туннель не доказывают lifecycle модели.

В отчёте об ошибке укажите версию Hermes, плагина и способ установки. Установка, удаление и восстановление — в [README плагина](../../plugins/hermes/README.ru.md); фактическая область проверки — в [статусе функций](parity.md).
