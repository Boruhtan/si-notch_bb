#!/usr/bin/env python3
"""Check si-notch UI catalog parity and guard against untranslated app-owned copy."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = root / "Sources" / "SINotch"
resource = source / "Resources"
languages = ("en", "ru", "zh-Hans")
entry = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";$', re.M)
literal = re.compile(r'"(?:\\.|[^"\\])*"')
errors = []
keys_by_language = {}
for language in languages:
    path = resource / f"{language}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    entries = entry.findall(text)
    keys = [key for key, _ in entries]
    if len(keys) != len(set(keys)):
        errors.append(f"{path}: duplicate keys")
    keys_by_language[language] = set(keys)
    if not entries:
        errors.append(f"{path}: no entries")
for language in languages[1:]:
    missing = keys_by_language["en"] - keys_by_language[language]
    extra = keys_by_language[language] - keys_by_language["en"]
    if missing or extra:
        errors.append(f"{language}: missing {sorted(missing)}, extra {sorted(extra)}")

all_source = "\n".join(path.read_text(encoding="utf-8") for path in source.glob("*.swift"))
used = set(re.findall(r'L10n\.tr\("((?:\\.|[^"\\])*)"', all_source))
for key in re.findall(r'L10n\.count\("([^"]+)"', all_source):
    used.update(f"{key}.{suffix}" for suffix in ("one", "few", "many", "other"))
for key in ("Все", "В работе", "Внимание", "Готово", "Агент ожидает ответа"):
    used.add(key)
for key in sorted(used - keys_by_language["en"]):
    errors.append(f"missing catalog key: {key}")

# These are stable internal filter IDs or app-authored event examples stored as
# catalog keys so they can be translated only at the view boundary.
raw_app_keys = {
    "Все", "В работе", "Внимание", "Готово", "Агент ожидает ответа",
    "Вы отклонили действие", "Вы выбрали ответ. Ожидаем событие агента.",
    "Вы разрешили этот запрос. Ожидаем событие агента.",
    "Новая панель агентов", "Проверяю сборку и тесты…", "Дизайн настроек",
    "Готово. Добавлены настройки и проверки состояния.", "Выбрать следующий шаг",
    "Нужен ваш ответ в терминале",
}
for path in source.glob("*.swift"):
    if path.name in ("L10n.swift", "QAExporter.swift"):
        continue
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for match in literal.finditer(line):
            value = match.group()[1:-1]
            if not re.search("[А-Яа-яЁё]", value):
                continue
            if line[:match.start()].endswith("L10n.tr("):
                continue
            if path.name in ("AppMain.swift", "IslandView.swift") and value in raw_app_keys:
                continue
            errors.append(f"untranslated literal: {path.name}:{number}: {value[:80]}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Localization catalogs match ({len(keys_by_language['en'])} keys); all app-owned Cyrillic UI literals are accounted for.")
