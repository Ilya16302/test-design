#!/usr/bin/env bash
set -euo pipefail

APP_DIR=/opt/statv2-uploader
AUTH_ROOT=/opt/statv2-auth
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_auth_repair_v6_${TS}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$APP_DIR/upload_worker.py" \
  "$AUTH_ROOT/objects.json" \
  "$AUTH_ROOT/objects" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. REPAIR PRIVATE AUTH FOR НОРИЛЬСК ====="
cd "$APP_DIR"
./venv/bin/python - <<'PY'
import gzip
import hashlib
import json
import os
import zipfile
from pathlib import Path

import app as core
import multiobject as multi

registry = multi.read_registry().get("objects", {})

matches = [(oid, obj) for oid, obj in registry.items() if str(obj.get("name") or "").strip().casefold() == "норильск"]
if len(matches) != 1:
    raise SystemExit(f"Ожидался ровно один объект 'Норильск', найдено: {len(matches)}")

oid, obj = matches[0]
private_root = multi._object_private_root(oid)
private_root.mkdir(parents=True, exist_ok=True)
private_auth = private_root / "auth.json.gz"

print("OBJECT:", oid, "=>", obj.get("name"))
print("TARGET:", private_auth)

raw = None
source = None
jobs_root = Path("/var/lib/statv2/upload_jobs")

# Сначала пробуем взять ровно тот auth, который был загружен браузером.
packages = sorted(jobs_root.glob("*/database.zip"), key=lambda p: p.stat().st_mtime, reverse=True) if jobs_root.exists() else []
for package in packages:
    status_path = package.parent / "status.json"
    try:
        status = json.loads(status_path.read_text(encoding="utf-8")) if status_path.exists() else {}
    except Exception:
        status = {}
    if str(status.get("object_id") or "") != oid:
        continue
    try:
        with zipfile.ZipFile(package, "r") as z:
            names = z.namelist()
            auth_names = [n for n in names if n == "auth.json.gz" or n == "db/auth.json.gz" or n.endswith("/db/auth.json.gz")]
            if not auth_names:
                continue
            candidate = z.read(auth_names[0])
        data = json.loads(gzip.decompress(candidate).decode("utf-8"))
        if any(str(w.get("login") or "") == "test_csk5" for w in data.get("welders", [])):
            raw = candidate
            source = f"{package} :: {auth_names[0]}"
            break
    except Exception:
        continue

# Если upload job уже был очищен — восстанавливаем точный тестовый auth,
# который использовался при создании тестовой базы.
if raw is None:
    password = "123456"
    ph = hashlib.sha256(password.encode("utf-8")).hexdigest()
    data = {
        "meta": {
            "generated_at": "2026-08-21T10:05:00",
            "period_start": "2026-08-08",
            "period_end": "2026-08-20",
            "counts": {"welders": 3, "joints": 12, "events": 12},
        },
        "auth": {},
        "welders": [
            {
                "id": "test-welder-entr",
                "name": "Абдирайимов Аббос Эркинович",
                "stamp": "ENTR",
                "login": "test_entr",
                "password_plain": password,
                "password_hash": ph,
                "shard": "shard_00.json.gz",
                "organization": "ТЕСТ-ПОДРЯДЧИК",
                "shift": "Смена 1",
                "position": "Поле",
                "responsible": "Тестовый прораб №1",
                "status": "В работе",
            },
            {
                "id": "test-welder-csk5",
                "name": "Кузнецов Илья Сергеевич",
                "stamp": "CSK5",
                "login": "test_csk5",
                "password_plain": password,
                "password_hash": ph,
                "shard": "shard_00.json.gz",
                "organization": "ТЕСТ-ПОДРЯДЧИК",
                "shift": "Смена 2",
                "position": "Цех",
                "responsible": "Тестовый прораб №2",
                "status": "В работе",
            },
            {
                "id": "test-welder-zafar",
                "name": "Абдирахмонов Зафар Нормуродович",
                "stamp": "",
                "login": "test_zafar",
                "password_plain": password,
                "password_hash": ph,
                "shard": "shard_00.json.gz",
                "organization": "ТЕСТ-ПОДРЯДЧИК",
                "shift": "Смена 1",
                "position": "Поле",
                "responsible": "Тестовый прораб №1",
                "status": "В работе",
            },
        ],
    }
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    raw = gzip.compress(payload, compresslevel=9, mtime=0)
    source = "встроенная резервная копия тестового auth"

# Validate before publishing.
data = json.loads(gzip.decompress(raw).decode("utf-8"))
by_login = {str(w.get("login") or ""): w for w in data.get("welders", [])}
for login in ("test_csk5", "test_entr", "test_zafar"):
    if login not in by_login:
        raise SystemExit(f"В auth отсутствует {login}")
    w = by_login[login]
    if not core.verify_password("123456", w.get("password_hash", ""), w.get("password_plain", "")):
        raise SystemExit(f"Пароль не прошёл проверку для {login}")

repair = private_root / "auth.json.gz.v6-repair"
repair.write_bytes(raw)
repair.chmod(0o600)
os.replace(repair, private_auth)
private_auth.chmod(0o600)

print("SOURCE:", source)
print("SAVED:", private_auth)
print("SIZE:", private_auth.stat().st_size)
print("AUTH WELDERS:", len(data.get("welders", [])))

print("\nLOGIN SEARCH:")
for login in ("test_csk5", "test_entr", "test_zafar"):
    found = multi._find_welder_login_matches(login, "123456")
    print(login, "=>", len(found), "match(es)")
    for foid, fobj, w in found:
        print("  ", fobj.get("name"), "|", w.get("name"), "| stamp:", repr(w.get("stamp")))
PY

echo "===== 3. HARDEN FUTURE ASYNC UPLOADS ====="
python3 - <<'PY'
from pathlib import Path
p = Path('/opt/statv2-uploader/upload_worker.py')
s = p.read_text(encoding='utf-8')
marker = '# STATV2 PRIVATE AUTH HARDENING V6'
if marker in s:
    print('V6 worker hardening уже установлен')
else:
    old1 = '''                auth_file = new_db_tmp / "auth.json.gz"\n                if not auth_file.exists():\n                    raise ValueError("В архиве нет auth.json.gz — без него сервер не сможет проверять вход")\n\n                old_auth_backup = tmp / "old_auth.json.gz"\n'''
    new1 = '''                auth_file = new_db_tmp / "auth.json.gz"\n                if not auth_file.exists():\n                    raise ValueError("В архиве нет auth.json.gz — без него сервер не сможет проверять вход")\n\n                # STATV2 PRIVATE AUTH HARDENING V6\n                # Держим закрытый auth в памяти до конца публикации. Публичная копия\n                # ниже очищается от логинов/паролей, поэтому после sanitize брать её уже нельзя.\n                private_auth_payload = auth_file.read_bytes()\n\n                old_auth_backup = tmp / "old_auth.json.gz"\n'''
    if old1 not in s:
        raise SystemExit('Не найден участок auth_file в upload_worker.py')
    s = s.replace(old1, new1, 1)

    old2 = '''                    shutil.move(str(new_db_tmp), str(db_target))\n                    published = True\n\n                    manifest_path = db_target / "manifest.json"\n'''
    new2 = '''                    shutil.move(str(new_db_tmp), str(db_target))\n                    published = True\n\n                    # V6: после успешной публикации ещё раз атомарно восстанавливаем\n                    # закрытый auth из исходного архива и сразу проверяем его наличие.\n                    auth_final_tmp = private_root / ("auth.json.gz.final." + job_id)\n                    auth_final_tmp.write_bytes(private_auth_payload)\n                    auth_final_tmp.chmod(0o600)\n                    auth_final_tmp.replace(private_auth)\n                    if not private_auth.exists() or private_auth.stat().st_size == 0:\n                        raise RuntimeError("Закрытый auth.json.gz не сохранился после публикации")\n\n                    manifest_path = db_target / "manifest.json"\n'''
    if old2 not in s:
        raise SystemExit('Не найден участок публикации db в upload_worker.py')
    s = s.replace(old2, new2, 1)
    p.write_text(s, encoding='utf-8')
    print('V6 worker hardening installed')
PY

echo "===== 4. PYTHON CHECK ====="
cd "$APP_DIR"
./venv/bin/python -m py_compile upload_worker.py multiobject.py app.py
./venv/bin/python - <<'PY'
import multiobject as multi
obj = [(oid, o) for oid, o in multi.read_registry().get('objects', {}).items() if str(o.get('name') or '').casefold() == 'норильск']
assert len(obj) == 1, obj
oid, o = obj[0]
p = multi._object_private_root(oid) / 'auth.json.gz'
print('Норильск:', oid)
print('auth exists:', p.exists())
assert p.exists() and p.stat().st_size > 0
for login in ('test_csk5','test_entr','test_zafar'):
    m = multi._find_welder_login_matches(login, '123456')
    print(login, '=>', len(m))
    assert any(x[0] == oid for x in m), (login, m)
print('Python/login check: OK')
PY

echo "===== 5. HEALTH ====="
curl -sS http://127.0.0.1:5088/health || true
echo

echo "=============================================="
echo "AUTH REPAIR / UPLOAD HARDENING V6 ГОТОВО"
echo "Backup: $BACKUP"
echo "Можно сразу пробовать test_csk5 / 123456"
echo "=============================================="
