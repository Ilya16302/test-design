#!/usr/bin/env python3
"""
StatV2 — точечный патч 3 багов из аудита V27_TABLES_AUDIT_20260902:
  1) /api/upload_idcards — был мёртв всегда (authorized() всегда False)
  2) /api/idcards_manifest — отдавался без проверки сессии
  3) /api/idcards/<stamp>/<filename> — PDF отдавался без проверки сессии

Запуск на сервере:
  python3 apply_security_patch.py /путь/к/вашему/app.py

Скрипт:
  - делает бэкап рядом (app.py.bak_YYYYmmdd_HHMMSS)
  - ищет ТОЧНЫЙ оригинальный текст и заменяет его на патченный
  - если текст не найден (файл уже пропатчен или отличается) — ничего не трогает и говорит об этом
"""
import sys
import shutil
from datetime import datetime
from pathlib import Path

PATCHES = [
    (
        '@APP.post("/api/upload_idcards")\n'
        'def upload_idcards():\n'
        '    if not authorized():\n'
        '        return error("Нет доступа", 401)\n',
        '@APP.post("/api/upload_idcards")\n'
        'def upload_idcards():\n'
        '    # V25 patch: authorized() отключён (см. комментарий выше), но роут\n'
        '    # оставался единственной точкой доступа — из-за этого он был мёртв\n'
        '    # для всех. Разрешаем как и остальные stat_admin-роуты миграции.\n'
        '    if not authorized() and str(session.get("role") or "") != "stat_admin":\n'
        '        return error("Нет доступа", 401)\n'
    ),
    (
        '@APP.get("/api/idcards_manifest")\n'
        'def idcards_manifest():\n'
        '    if not IDCARDS_MANIFEST.exists():\n',
        '@APP.get("/api/idcards_manifest")\n'
        'def idcards_manifest():\n'
        '    # Security patch: раньше манифест ID-карт отдавался без проверки сессии.\n'
        '    if not str(session.get("role") or ""):\n'
        '        return error("Нет доступа", 401)\n'
        '    if not IDCARDS_MANIFEST.exists():\n'
    ),
    (
        '@APP.get("/api/idcards/<stamp>/<path:filename>")\n'
        'def idcard_file(stamp, filename):\n'
        '    safe_stamp = Path(stamp).name\n',
        '@APP.get("/api/idcards/<stamp>/<path:filename>")\n'
        'def idcard_file(stamp, filename):\n'
        '    # Security patch: раньше PDF ID-карты отдавался без проверки сессии.\n'
        '    if not str(session.get("role") or ""):\n'
        '        return error("Нет доступа", 401)\n'
        '    safe_stamp = Path(stamp).name\n'
    ),
]

def main():
    if len(sys.argv) != 2:
        print("Использование: python3 apply_security_patch.py /путь/к/app.py")
        sys.exit(1)

    target = Path(sys.argv[1]).resolve()
    if not target.is_file():
        print(f"Файл не найден: {target}")
        sys.exit(1)

    text = target.read_text(encoding="utf-8")
    original_text = text

    applied = 0
    already = 0
    missing = 0

    for i, (old, new) in enumerate(PATCHES, start=1):
        if new in text:
            print(f"[{i}/3] Похоже, уже пропатчено — пропускаю.")
            already += 1
            continue
        if old not in text:
            print(f"[{i}/3] ВНИМАНИЕ: не нашёл ожидаемый оригинальный фрагмент. "
                  f"Файл на сервере отличается от версии из аудита — пропускаю этот патч, "
                  f"остальные проверю.")
            missing += 1
            continue
        if text.count(old) != 1:
            print(f"[{i}/3] ВНИМАНИЕ: фрагмент встречается {text.count(old)} раз(а), "
                  f"а не 1 — на всякий случай пропускаю, чтобы не сломать не то место.")
            missing += 1
            continue
        text = text.replace(old, new, 1)
        applied += 1
        print(f"[{i}/3] Патч применён.")

    if applied == 0:
        print("\nНичего не изменено (см. предупреждения выше). Файл не тронут.")
        sys.exit(0 if missing == 0 else 2)

    backup = target.with_name(target.name + ".bak_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
    shutil.copy2(target, backup)
    print(f"\nБэкап оригинала сохранён: {backup}")

    target.write_text(text, encoding="utf-8")
    print(f"Файл обновлён: {target}")

    # Быстрая проверка синтаксиса
    try:
        compile(text, str(target), "exec")
        print("Синтаксис файла в порядке (py_compile прошёл).")
    except SyntaxError as e:
        print("!!! СИНТАКСИЧЕСКАЯ ОШИБКА ПОСЛЕ ПАТЧА — откатываю из бэкапа:", e)
        shutil.copy2(backup, target)
        sys.exit(3)

    print(f"\nГотово: применено патчей — {applied}, уже было — {already}, пропущено — {missing}.")
    print("Дальше: перезапустите сервис (systemctl restart <ваш-сервис-gunicorn>).")

if __name__ == "__main__":
    main()
