#!/usr/bin/env bash
set -euo pipefail

BACKEND_ROOT="${STATV2_BACKEND_ROOT:-/opt/statv2-uploader}"
SITE_ROOT="${STATV2_SITE_ROOT:-/var/www/statv2}"
OBJECTS_ROOT="${STATV2_OBJECTS_ROOT:-/var/lib/statv2/objects}"
SERVICE="${STATV2_SERVICE:-statv2-uploader}"
SKIP_RESTART="${STATV2_V26_SKIP_RESTART:-0}"

APP="$BACKEND_ROOT/app.py"
MULTI="$BACKEND_ROOT/multiobject.py"
SW="$SITE_ROOT/sw.js"
MJS="$SITE_ROOT/multiobject.js"

for f in "$APP" "$MULTI" "$SW" "$MJS"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: не найден файл: $f" >&2
    exit 1
  fi
done

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_v26_${STAMP}.tar.gz"
if [ "$SKIP_RESTART" = "1" ]; then
  BACKUP="/mnt/data/statv2_before_v26_test_${STAMP}.tar.gz"
fi
SUCCESS=0
BACKUP_DONE=0

rollback_on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$BACKUP_DONE" = "1" ] && [ "$SUCCESS" != "1" ]; then
    echo
    echo "===== V26 ERROR: ROLLBACK ====="
    tar -xzf "$BACKUP" -C / || true
    if [ "$SKIP_RESTART" != "1" ]; then
      systemctl restart "$SERVICE" || true
    fi
    echo "Файлы восстановлены из: $BACKUP"
  fi
  exit "$rc"
}
trap rollback_on_exit EXIT

echo "===== 1. BACKUP ====="
backup_files=("$APP" "$MULTI" "$SW" "$MJS")
if [ -f "$SITE_ROOT/db/overrides.json" ]; then
  backup_files+=("$SITE_ROOT/db/overrides.json")
fi
if [ -d "$OBJECTS_ROOT" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && backup_files+=("$f")
  done < <(find "$OBJECTS_ROOT" -type f -name 'overrides.json' -print 2>/dev/null || true)
fi
tar -czf "$BACKUP" -- "${backup_files[@]}"
chmod 600 "$BACKUP"
BACKUP_DONE=1
echo "Backup: $BACKUP"

echo
echo "===== 2. PATCH BACKEND / FRONTEND ====="
python3 - "$APP" "$MULTI" "$SW" "$MJS" <<'PY'
from pathlib import Path
import re
import sys

app, multi, sw, mjs = map(Path, sys.argv[1:5])

# ---------------- app.py ----------------
s = app.read_text(encoding="utf-8")

if "STATV2 V26: старые встроенные подрядные учётки удалены." not in s:
    pattern = re.compile(
        r"# Организационные админки\. Живут на сервере и не зависят от обновления базы\.\n"
        r"ORG_ADMIN_ACCOUNTS = \{.*?\n\}\n",
        re.S,
    )
    replacement = (
        "# STATV2 V26: старые встроенные подрядные учётки удалены.\n"
        "# Объектные ограниченные учётки хранятся только в приватных org_accounts.json.\n"
        "ORG_ADMIN_ACCOUNTS = {}\n"
    )
    s, count = pattern.subn(replacement, s, count=1)
    if count != 1:
        raise SystemExit("V26: не найден старый ORG_ADMIN_ACCOUNTS")

# Старый single-object /api/login больше не должен уметь авторизовывать кого-либо.
if "legacy single-object authentication removed" not in s:
    start = s.find('@APP.post("/api/login")\ndef api_login():')
    end = s.find('\n\n@APP.get("/api/session")', start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найден legacy api_login")
    new_login = '''@APP.post("/api/login")
def api_login():
    # STATV2 V26: legacy single-object authentication removed.
    # multiobject.multiobject_before_request() handles every real /api/login.
    # This is only a fail-closed fallback if the multiobject module is unavailable.
    return error("Мультиобъектная авторизация не активна", 503)
'''
    s = s[:start] + new_login + s[end:]

# Старый before_request login-hook полностью выключаем.
if "legacy login hook permanently disabled" not in s:
    start = s.find('@APP.before_request\ndef statv2_stat_admin_login_hook():')
    end = s.find('\n\n@APP.after_request\ndef statv2_add_filter_fields_to_session_response', start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найден legacy login hook")
    new_hook = '''@APP.before_request
def statv2_stat_admin_login_hook():
    # STATV2 V26: legacy login hook permanently disabled.
    # Login is handled only by multiobject.multiobject_before_request().
    return None
'''
    s = s[:start] + new_hook + s[end:]

# Глобальные предложения читать/удалять может только глобальный admin_stat.
def protect_suggestion_function(text: str, func_name: str) -> str:
    marker = f"def {func_name}("
    pos = text.find(marker)
    if pos < 0:
        raise SystemExit(f"V26: не найдена функция {func_name}")
    next_route = text.find("\n@APP.route(", pos + len(marker))
    if next_route < 0:
        next_route = len(text)
    segment = text[pos:next_route]
    if "or session.get('object_admin')" in segment:
        return text
    old = "if session.get('role') != 'stat_admin':"
    if old not in segment:
        raise SystemExit(f"V26: не найден guard в {func_name}")
    segment = segment.replace(
        old,
        "if session.get('role') != 'stat_admin' or session.get('object_admin'):",
        1,
    )
    return text[:pos] + segment + text[next_route:]

s = protect_suggestion_function(s, "api_delete_suggestion")
s = protect_suggestion_function(s, "api_get_suggestions")

# Старый раздел "Исправления"/overrides отсутствует во frontend и больше не поддерживается.
if "legacy single-object overrides / joint-search subsystem removed" not in s:
    start = s.find("OVERRIDES_FILE = '/var/www/statv2/db/overrides.json'")
    end = s.find('\nif __name__ == "__main__":', start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найден legacy overrides block")
    removed = s[start:end]
    required = (
        "apply_overrides_to_shards",
        "/api/stat_admin/overrides",
        "/api/stat_admin/joint_search",
    )
    if not all(x in removed for x in required):
        raise SystemExit("V26: overrides block отличается от ожидаемого")
    replacement = (
        "# STATV2 V26: legacy single-object overrides / joint-search subsystem removed.\n"
        "# The current UI has no \"Исправления\" section and no route depends on this code.\n"
    )
    s = s[:start] + replacement + s[end:]

app.write_text(s, encoding="utf-8")

# ---------------- multiobject.py ----------------
s = multi.read_text(encoding="utf-8")

# Удаляем monkey-patch, который существовал только ради старого login-hook.
if "No /api/login monkey-patching is needed" not in s:
    start = s.find("# Старый before_request для ограниченных учёток был глобальным.")
    end = s.find("\ndef _multi_refresh_material_groups_from_object():", start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найден старый login monkey-patch")
    replacement = (
        "# STATV2 V26: legacy app.py login paths are fail-closed/disabled.\n"
        "# No /api/login monkey-patching is needed; _handle_login() below is the only auth flow.\n"
    )
    s = s[:start] + replacement + s[end:]

# Overrides удалены — объектный context больше их не переключает.
s = s.replace('        core.OVERRIDES_FILE = str(dummy / "overrides.json")\n', '')
s = s.replace('    core.OVERRIDES_FILE = str(data_root / "overrides.json")\n', '')

# Defense in depth: object-admin не должен видеть/удалять глобальные предложения.
if "global suggestions inbox belongs only to global admin_stat" not in s:
    needle = '''    if session.get("object_admin"):
        own_id = str(session.get("current_object") or "")
'''
    replacement = '''    if session.get("object_admin"):
        # STATV2 V26: global suggestions inbox belongs only to global admin_stat.
        if request.path == "/api/suggestions" and request.method == "GET":
            return core.error("Нет доступа", 403)
        if request.method == "DELETE" and re.match(r"^/api/suggestion/\\d+$", request.path):
            return core.error("Нет доступа", 403)

        own_id = str(session.get("current_object") or "")
'''
    if needle not in s:
        raise SystemExit("V26: не найден object_admin guard")
    s = s.replace(needle, replacement, 1)

multi.write_text(s, encoding="utf-8")

# ---------------- sw.js ----------------
s = sw.read_text(encoding="utf-8")
if "старые /api/* fallback-ветки удалены" not in s:
    start_marker = "  // /api/session\n"
    end_marker = "  // Всё остальное — та же схема: waitUntil сразу, respondWith отдельно\n"
    start = s.find(start_marker)
    end = s.find(end_marker, start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найдены мёртвые API-ветки sw.js")
    s = (
        s[:start]
        + "  // STATV2 V26: старые /api/* fallback-ветки удалены — API уже bypass выше.\n\n"
        + s[end:]
    )
sw.write_text(s, encoding="utf-8")

# ---------------- multiobject.js ----------------
s = mjs.read_text(encoding="utf-8")
if "одноразовая миграция V25.1 завершена" not in s:
    start = s.find("async function multiClearLegacyOffline(){")
    end = s.find("\n\n/* Кэшируем объектные файлы", start)
    if start < 0 or end < 0:
        raise SystemExit("V26: не найден V25.1 one-time SW reset")
    replacement = '''async function multiClearLegacyOffline(){
  /* STATV2 V26: одноразовая миграция V25.1 завершена.
     Service Worker и его cache больше не удаляем при запуске. */
  return;
}'''
    s = s[:start] + replacement + s[end:]

s = s.replace(
    "/* Сохраняем инженеров через текущую серверную сессию; Basic остаётся только как fallback. */",
    "/* Сохраняем инженеров только через текущую серверную сессию. */",
)
mjs.write_text(s, encoding="utf-8")
PY

echo
echo "===== 3. REMOVE LEGACY OVERRIDE DATA ====="
rm -f "$SITE_ROOT/db/overrides.json"
if [ -d "$OBJECTS_ROOT" ]; then
  find "$OBJECTS_ROOT" -type f -name 'overrides.json' -delete 2>/dev/null || true
fi

echo
echo "===== 4. STATIC CHECKS ====="
python3 -m py_compile \
  "$APP" \
  "$MULTI" \
  "$BACKEND_ROOT/v25_access.py" \
  "$BACKEND_ROOT/upload_async.py" \
  "$BACKEND_ROOT/upload_worker.py"

if command -v node >/dev/null 2>&1; then
  node --check "$SW"
  node --check "$MJS"
else
  echo "node: not installed on server; JS files were syntax-checked before release"
fi

python3 - "$APP" <<'PY'
import ast
import sys
p = sys.argv[1]
tree = ast.parse(open(p, encoding="utf-8").read(), p)
found = []
for node in ast.walk(tree):
    if isinstance(node, ast.Dict):
        for key, value in zip(node.keys, node.values):
            if (
                isinstance(key, ast.Constant)
                and key.value == "password"
                and isinstance(value, ast.Constant)
                and isinstance(value.value, str)
                and value.value
            ):
                found.append(getattr(value, "lineno", 0))
if found:
    raise SystemExit("Hardcoded password string literals remain at lines: " + ", ".join(map(str, found)))
print("Hardcoded password string literals in app.py: 0")
PY

LEGACY_ACCOUNTS="$(grep -Ec 'NGTS_01|NOVA_01|GALA_01|SSPI_01' "$APP" || true)"
OVERRIDE_REFS="$({ grep -REc 'OVERRIDES_FILE|apply_overrides_to_shards|/api/stat_admin/overrides|/api/stat_admin/joint_search' "$BACKEND_ROOT" --include='*.py' 2>/dev/null || true; } | awk -F: '{s+=$NF} END{print s+0}')"
DEAD_SW_API="$(grep -Ec "url\.pathname === '/api/session'|// Остальные API" "$SW" || true)"

[ "$LEGACY_ACCOUNTS" = "0" ] || { echo "ERROR: legacy account names remain" >&2; exit 1; }
[ "$OVERRIDE_REFS" = "0" ] || { echo "ERROR: override code references remain: $OVERRIDE_REFS" >&2; exit 1; }
[ "$DEAD_SW_API" = "0" ] || { echo "ERROR: dead SW API branches remain" >&2; exit 1; }

grep -q 'legacy single-object authentication removed' "$APP"
grep -q 'legacy login hook permanently disabled' "$APP"
grep -q "or session.get('object_admin')" "$APP"
grep -q 'global suggestions inbox belongs only to global admin_stat' "$MULTI"
grep -q 'одноразовая миграция V25.1 завершена' "$MJS"

# ВАЖНО: V26 намеренно НЕ меняет логику связывания сварщика между объектами по клейму.
grep -q 'pending_type.*welder_stamp' "$MULTI"
grep -q '_find_welder_by_stamp(auth_db, stamp)' "$MULTI"

echo "Legacy built-in contractor accounts: 0"
echo "Legacy overrides/joint-search refs: 0"
echo "Dead Service Worker API branches: 0"
echo "Welder cross-object stamp linking: preserved"
echo "Global login uniqueness: NOT added (by request)"

if [ "$SKIP_RESTART" != "1" ]; then
  echo
  echo "===== 5. RESTART ====="
  systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE"
  echo "Service: active"

  echo
  echo "===== 6. HEALTH ====="
  curl -fsS --max-time 15 http://127.0.0.1:5088/health
  echo

  echo
  echo "===== 7. ROUTE CHECK ====="
  CODE_OVR="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5088/api/stat_admin/overrides || true)"
  CODE_JS="$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:5088/api/stat_admin/joint_search?vik_request=V26TEST' || true)"
  echo "overrides route HTTP: $CODE_OVR"
  echo "joint_search route HTTP: $CODE_JS"
  [ "$CODE_OVR" = "404" ] || { echo "ERROR: overrides route still exists" >&2; exit 1; }
  [ "$CODE_JS" = "404" ] || { echo "ERROR: joint_search route still exists" >&2; exit 1; }
fi

SUCCESS=1
trap - EXIT

echo
echo "====================================================="
echo "STATV2 V26 FOUNDATION CLEANUP УСТАНОВЛЕН"
echo "====================================================="
echo "  • связывание сварщика между объектами по клейму НЕ изменено"
echo "  • legacy single-object login удалён/закрыт"
echo "  • старый раздел Исправления/overrides удалён"
echo "  • global Предложения доступны на чтение/удаление только admin_stat"
echo "  • старые встроенные подрядные пароли удалены из app.py"
echo "  • других hardcoded password-строк в app.py не найдено"
echo "  • мёртвые Service Worker API-ветки удалены"
echo "  • одноразовый V25.1 SW-reset удалён"
echo "  • Топ сварщиков подрядчика НЕ изменён"
echo "  • глобальную уникальность логинов V26 НЕ добавляет"
echo "Backup: $BACKUP"
echo "====================================================="
