#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Запусти скрипт от root" >&2
  exit 1
fi

STAT_ADMIN_PASS="${STAT_ADMIN_PASS:-}"
GLOBAL_ADMIN_PASS="${GLOBAL_ADMIN_PASS:-}"
if [ -z "$STAT_ADMIN_PASS" ]; then
  read -rsp "Пароль для admin_stat: " STAT_ADMIN_PASS
  echo
fi
if [ -z "$GLOBAL_ADMIN_PASS" ]; then
  read -rsp "Пароль для глобального admin: " GLOBAL_ADMIN_PASS
  echo
fi
if [ -z "$STAT_ADMIN_PASS" ] || [ -z "$GLOBAL_ADMIN_PASS" ]; then
  echo "Пароли не должны быть пустыми." >&2
  exit 2
fi

APP_DIR="/opt/statv2-uploader"
SITE_DIR="/var/www/statv2"
AUTH_DIR="/opt/statv2-auth"
OBJECTS_DIR="/var/lib/statv2/objects"
MARKER="/var/lib/statv2/.multiobject_v1_initialized"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_multi_${STAMP}.tar.gz"

echo "===== 1. РЕЗЕРВНАЯ КОПИЯ ====="
tar -czf "$BACKUP" \
  "$SITE_DIR" \
  "$APP_DIR" \
  "$AUTH_DIR" \
  /etc/nginx/sites-available/statv2 \
  /etc/systemd/system/statv2-uploader.service \
  2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. ОСТАНАВЛИВАЕМ BACKEND ====="
systemctl stop statv2-uploader || true

mkdir -p /var/lib/statv2 "$AUTH_DIR" "$OBJECTS_DIR"

if [ ! -f "$MARKER" ]; then
  echo "===== 3. ПЕРВОЕ ОБНУЛЕНИЕ СТАРОЙ ОДНООБЪЕКТНОЙ СХЕМЫ ====="
  rm -rf "$OBJECTS_DIR"
  mkdir -p "$OBJECTS_DIR"

  # Удаляем старые базы/объектные данные фронтенда.
  rm -rf \
    "$SITE_DIR/db" \
    "$SITE_DIR/uploads_backup" \
    "$SITE_DIR/id_cards" \
    "$SITE_DIR/engineers.json"

  # В auth-каталоге сохраняем только Flask secret, чтобы не сбрасывать ключ приложения.
  find "$AUTH_DIR" -mindepth 1 -maxdepth 1 ! -name 'flask_secret_key.txt' -exec rm -rf {} +

  echo "Старые объекты, базы и объектные учётки удалены."
else
  echo "===== 3. ОБНУЛЕНИЕ УЖЕ ВЫПОЛНЯЛОСЬ РАНЕЕ ====="
  echo "Объекты текущей мультиобъектной версии НЕ удаляю."
fi

mkdir -p "$AUTH_DIR/objects" "$OBJECTS_DIR"
chmod 700 "$AUTH_DIR" "$AUTH_DIR/objects"

if [ ! -f "$MARKER" ]; then
  cat > "$AUTH_DIR/objects.json" <<'JSON'
{
  "version": 2,
  "objects": {}
}
JSON
elif [ ! -f "$AUTH_DIR/objects.json" ]; then
  echo "ВНИМАНИЕ: marker есть, а objects.json отсутствует. Создаю пустой реестр." >&2
  cat > "$AUTH_DIR/objects.json" <<'JSON'
{
  "version": 2,
  "objects": {}
}
JSON
else
  echo "Существующий objects.json сохраняю без изменений."
fi
chmod 600 "$AUTH_DIR/objects.json"

echo "===== 4. ПИШЕМ MULTIOBJECT BACKEND ====="
cat > "$APP_DIR/multiobject.py" <<'PY'
#!/usr/bin/env python3
import gzip
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
from datetime import datetime
from pathlib import Path

from flask import jsonify, request, send_file, session

import app as core

APP = core.APP
AUTH_ROOT = Path(os.environ.get("STATV2_AUTH_ROOT", "/opt/statv2-auth")).resolve()
OBJECTS_ROOT = Path(os.environ.get("STATV2_OBJECTS_ROOT", "/var/lib/statv2/objects")).resolve()
REGISTRY_PATH = Path(os.environ.get("STATV2_OBJECTS_REGISTRY", str(AUTH_ROOT / "objects.json"))).resolve()
OBJECT_AUTH_ROOT = AUTH_ROOT / "objects"
GLOBAL_ADMIN_LOGIN = os.environ.get("STATV2_GLOBAL_ADMIN_LOGIN", "admin")
GLOBAL_ADMIN_PASS = os.environ.get("STATV2_GLOBAL_ADMIN_PASS", "")

AUTH_ROOT.mkdir(parents=True, exist_ok=True)
OBJECTS_ROOT.mkdir(parents=True, exist_ok=True)
OBJECT_AUTH_ROOT.mkdir(parents=True, exist_ok=True)

# Старых встроенных объектных учёток в новой схеме нет.
core.ORG_ADMIN_ACCOUNTS = {}
core.SPK_OBJECTS_PATH = REGISTRY_PATH


def _now():
    return datetime.now().isoformat(timespec="seconds")


def _norm(value):
    return core.norm_login(value)


def _hash_password(password):
    return hashlib.sha256(str(password or "").encode("utf-8")).hexdigest()


def _verify_hash(password, expected):
    expected = str(expected or "")
    return bool(expected) and hmac.compare_digest(_hash_password(password), expected)


def _empty_registry():
    return {"version": 2, "objects": {}}


def _default_ranges():
    cfg = getattr(core, "DEFAULT_MATERIAL_RANGE_CONFIG", {}) or {}
    diam = list(cfg.get("diam") or ["0-50", "50-150", "150-выше"])
    thick = [list(x) for x in (cfg.get("thick") or [["0-4", "4-выше"], ["0-6", "6-выше"], ["0-8", "8-выше"]])]
    while len(diam) < 3:
        diam.append("")
    diam = diam[:3]
    while len(thick) < 3:
        thick.append(["", ""])
    thick = [(x + ["", ""])[:2] for x in thick[:3]]
    return {"diam": diam, "thick": thick}


def read_registry():
    try:
        if REGISTRY_PATH.exists():
            data = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("objects"), dict):
                data.setdefault("version", 2)
                return data
    except Exception:
        pass
    return _empty_registry()


def write_registry(payload):
    if not isinstance(payload, dict):
        payload = _empty_registry()
    payload.setdefault("version", 2)
    payload.setdefault("objects", {})
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = REGISTRY_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(REGISTRY_PATH)
    try:
        REGISTRY_PATH.chmod(0o600)
    except Exception:
        pass


# Подменяем старый SPK-реестр: больше никакого встроенного agkh-smk.
def statv2_default_spk_objects_payload():
    return _empty_registry()


def statv2_read_spk_objects():
    return read_registry()


def statv2_write_spk_objects(payload):
    write_registry(payload)


core.statv2_default_spk_objects_payload = statv2_default_spk_objects_payload
core.statv2_read_spk_objects = statv2_read_spk_objects
core.statv2_write_spk_objects = statv2_write_spk_objects

# Старый before_request для ограниченных учёток был глобальным. В мультиобъектной
# схеме логин этих учёток обрабатывается ниже с поиском по объектам. На остальных
# маршрутах старая функция продолжает работать уже в контексте выбранного объекта.
_original_all_org_accounts = core.statv2_all_org_accounts
def _multi_all_org_accounts():
    try:
        if request.path == "/api/login":
            return {}
    except Exception:
        pass
    return _original_all_org_accounts()
core.statv2_all_org_accounts = _multi_all_org_accounts

def _multi_refresh_material_groups_from_object():
    try:
        payload = read_registry()
        obj = payload.get("objects", {}).get(str(getattr(core, "SPK_DEFAULT_OBJECT_ID", "") or ""))
        groups = obj.get("material_groups") if isinstance(obj, dict) else []
    except Exception:
        groups = []
    new_groups = []
    new_raw = {}
    new_colors = {}
    for g in groups or []:
        if not isinstance(g, dict):
            continue
        key = str(g.get("key") or g.get("name") or "").strip()
        if not key:
            continue
        new_groups.append(key)
        new_raw[key] = list(g.get("codes") or [])
        new_colors[key] = str(g.get("color") or "#6ab3ff")
    core.MATERIAL_GROUPS = tuple(new_groups)
    core.MATERIAL_GROUP_RAW = new_raw
    core.MATERIAL_GROUP_COLORS = new_colors
    core.MATERIAL_GROUP_LOOKUP = {
        core.norm_material_key(code): group
        for group, codes in new_raw.items()
        for code in codes
    }

core.refresh_material_groups_from_object = _multi_refresh_material_groups_from_object


def _public_object(object_id, obj=None):
    object_id = str(object_id or "").strip()
    if obj is None:
        obj = read_registry().get("objects", {}).get(object_id) or {}
    if not isinstance(obj, dict):
        obj = {}
    generated_at = ""
    manifest = OBJECTS_ROOT / object_id / "db" / "manifest.json"
    if manifest.exists():
        try:
            generated_at = str(json.loads(manifest.read_text(encoding="utf-8")).get("generated_at") or "")
        except Exception:
            generated_at = ""
    admin_login = ""
    cred = _read_object_admin(object_id)
    if cred:
        admin_login = str(cred.get("login") or "")
    result = {
        "id": object_id,
        "name": str(obj.get("name") or object_id),
        "created_at": str(obj.get("created_at") or ""),
        "daily_spk": obj.get("daily_spk") if isinstance(obj.get("daily_spk"), dict) else {},
        "material_groups": obj.get("material_groups") if isinstance(obj.get("material_groups"), list) else [],
        "base_ranges": obj.get("base_ranges") if isinstance(obj.get("base_ranges"), dict) else _default_ranges(),
        "generated_at": generated_at,
        "has_database": bool(manifest.exists()),
        "admin_login": admin_login,
    }
    return result


def _object_data_root(object_id):
    return (OBJECTS_ROOT / str(object_id)).resolve()


def _object_private_root(object_id):
    return (OBJECT_AUTH_ROOT / str(object_id)).resolve()


def _object_admin_path(object_id):
    return _object_private_root(object_id) / "object_admin.json"


def _read_object_admin(object_id):
    p = _object_admin_path(object_id)
    try:
        if p.exists():
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
    except Exception:
        pass
    return {}


def _write_object_admin(object_id, login, password):
    p = _object_admin_path(object_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({
        "login": str(login or "").strip(),
        "password_hash": _hash_password(password),
        "updated_at": _now(),
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    p.chmod(0o600)


def _load_auth_for_object(object_id):
    p = _object_private_root(object_id) / "auth.json.gz"
    if not p.exists():
        return None
    try:
        with gzip.open(p, "rt", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _find_welder_by_stamp(auth_db, stamp):
    stamp_n = str(stamp or "").strip().upper()
    if not stamp_n or not isinstance(auth_db, dict):
        return None
    for w in auth_db.get("welders", []):
        if str((w or {}).get("stamp") or "").strip().upper() == stamp_n:
            return w
    return None


def _find_welder_login_matches(login, password):
    login_n = _norm(login)
    matches = []
    for object_id, obj in read_registry().get("objects", {}).items():
        auth_db = _load_auth_for_object(object_id)
        if not auth_db:
            continue
        for w in auth_db.get("welders", []):
            if _norm((w or {}).get("login")) != login_n:
                continue
            if core.verify_password(password, (w or {}).get("password_hash", ""), (w or {}).get("password_plain", "")):
                matches.append((object_id, obj, w))
                break
    return matches


def _candidate(object_id, obj=None):
    po = _public_object(object_id, obj)
    return {
        "id": po["id"],
        "name": po["name"],
        "generated_at": po["generated_at"],
        "has_database": po["has_database"],
    }


def _all_candidates():
    rows = []
    for object_id, obj in read_registry().get("objects", {}).items():
        rows.append(_candidate(object_id, obj))
    rows.sort(key=lambda x: (str(x.get("name") or "").casefold(), x["id"]))
    return rows


def _apply_object_context(object_id):
    registry = read_registry().get("objects", {})
    object_id = str(object_id or "").strip()
    if not object_id or object_id not in registry:
        dummy = Path("/var/lib/statv2/no-object").resolve()
        core.DB_TARGET = dummy / "db"
        core.BACKUP_ROOT = dummy / "uploads_backup"
        core.PRIVATE_AUTH_PATH = AUTH_ROOT / "__no_object_auth.json.gz"
        core.ENGINEERS_FILE = dummy / "engineers.json"
        core.IDCARDS_ROOT = dummy / "id_cards"
        core.IDCARDS_MANIFEST = core.IDCARDS_ROOT / "manifest.json"
        core.DYNAMIC_ORG_ACCOUNTS_PATH = AUTH_ROOT / "__no_object_org_accounts.json"
        core.SPK_CONTRACTORS_PATH = AUTH_ROOT / "__no_object_contractors.json"
        core.SPK_BACKLOG_HISTORY_PATH = AUTH_ROOT / "__no_object_spk_daily_backlog.json"
        core.WELDER_PHOTOS_ROOT = AUTH_ROOT / "__no_object_welder_photos"
        core.WELDER_PHOTOS_MANIFEST = core.WELDER_PHOTOS_ROOT / "manifest.json"
        core.SUGG_FILE = str(AUTH_ROOT / "suggestions.json")
        core.OVERRIDES_FILE = str(dummy / "overrides.json")
        return False

    data_root = _object_data_root(object_id)
    private_root = _object_private_root(object_id)
    data_root.mkdir(parents=True, exist_ok=True)
    private_root.mkdir(parents=True, exist_ok=True)

    core.DB_TARGET = data_root / "db"
    core.BACKUP_ROOT = data_root / "uploads_backup"
    core.PRIVATE_AUTH_ROOT = private_root
    core.PRIVATE_AUTH_PATH = private_root / "auth.json.gz"
    core.ENGINEERS_FILE = data_root / "engineers.json"
    core.IDCARDS_ROOT = data_root / "id_cards"
    core.IDCARDS_MANIFEST = core.IDCARDS_ROOT / "manifest.json"
    core.DYNAMIC_ORG_ACCOUNTS_PATH = private_root / "org_accounts.json"
    core.SPK_CONTRACTORS_PATH = private_root / "spk_contractors.json"
    core.SPK_BACKLOG_HISTORY_PATH = private_root / "spk_daily_backlog.json"
    core.WELDER_PHOTOS_ROOT = private_root / "welder_photos"
    core.WELDER_PHOTOS_MANIFEST = core.WELDER_PHOTOS_ROOT / "manifest.json"
    core.SUGG_FILE = str(AUTH_ROOT / "suggestions.json")
    core.OVERRIDES_FILE = str(data_root / "overrides.json")
    core.SPK_DEFAULT_OBJECT_ID = object_id

    # upload_db в старом коде читает STATV2_AUTH_ROOT непосредственно из env.
    os.environ["STATV2_AUTH_ROOT"] = str(private_root)
    return True


def _current_object():
    object_id = str(session.get("current_object") or "").strip()
    obj = read_registry().get("objects", {}).get(object_id)
    return object_id, obj


def _set_object_session(object_id):
    obj = read_registry().get("objects", {}).get(object_id)
    if not isinstance(obj, dict):
        return None
    session["current_object"] = object_id
    session["current_object_name"] = str(obj.get("name") or object_id)
    _apply_object_context(object_id)
    return obj


def _clear_pending():
    for key in (
        "pending_type", "pending_stamp", "pending_matches", "pending_candidates",
    ):
        session.pop(key, None)


def _restricted_account_for_object(object_id, login, password):
    p = _object_private_root(object_id) / "org_accounts.json"
    try:
        if not p.exists():
            return None
        data = json.loads(p.read_text(encoding="utf-8"))
        cfg = (data or {}).get(str(login or "").strip().upper()) if isinstance(data, dict) else None
        if not isinstance(cfg, dict):
            return None
        if not hmac.compare_digest(str(password or ""), str(cfg.get("password") or "")):
            return None
        return cfg
    except Exception:
        return None


def _object_admin_match(login, password):
    login_n = _norm(login)
    for object_id in read_registry().get("objects", {}):
        cred = _read_object_admin(object_id)
        if _norm(cred.get("login")) == login_n and _verify_hash(password, cred.get("password_hash")):
            return object_id, cred
    return None


def _login_response_for_admin(object_id, cfg=None, contractor=None):
    obj = _set_object_session(object_id)
    session["role"] = "admin"
    session["login"] = str(session.get("login") or "")
    session.pop("object_admin", None)
    session.pop("org_filter", None)
    session.pop("org_title", None)
    session.pop("account_filter_type", None)
    session.pop("account_filter_value", None)
    session.pop("account_filter_title", None)
    session.pop("spk_contractor_id", None)
    payload = {
        "ok": True,
        "role": "admin",
        "object": _candidate(object_id, obj),
        "meta": core.safe_public_meta(),
    }
    if cfg:
        ftype = str(cfg.get("filter_type") or "organization")
        fvalue = str(cfg.get("filter_value") or "")
        title = str(cfg.get("title") or fvalue)
        session["account_filter_type"] = ftype
        session["account_filter_value"] = fvalue
        session["account_filter_title"] = title
        payload.update({
            "account_filter_type": ftype,
            "account_filter_value": fvalue,
            "account_filter_title": title,
        })
        if ftype == "organization":
            session["org_filter"] = fvalue
            session["org_title"] = title
            payload["org_filter"] = fvalue
            payload["org_title"] = title
        if contractor:
            cid = str(contractor.get("id") or "")
            session["spk_contractor_id"] = cid
            payload["spk_contractor_id"] = cid
    _clear_pending()
    return jsonify(payload)


def _handle_login():
    data = request.get_json(silent=True) or request.form or {}
    login = str(data.get("login") or "").strip()
    password = str(data.get("password") or "")
    if not login or not password:
        return core.error("Введите логин и пароль", 400)

    # admin_stat обрабатывает более ранний hook из app.py. Если пароль неверен,
    # не даём старому однообъектному логину уйти искать auth.json.gz.
    if _norm(login) == _norm(core.STAT_ADMIN_LOGIN):
        return core.error("Логин или пароль не подошли", 401)

    # admin_update оставляем старому маршруту.
    if hmac.compare_digest(login, core.UPLOAD_USER) and hmac.compare_digest(password, core.UPLOAD_PASS):
        return None

    # Глобальный admin: сначала выбор объекта.
    if hmac.compare_digest(login, GLOBAL_ADMIN_LOGIN) and hmac.compare_digest(password, GLOBAL_ADMIN_PASS):
        session.clear()
        session["role"] = "admin_pending"
        session["login"] = GLOBAL_ADMIN_LOGIN
        session["pending_type"] = "global_admin"
        candidates = _all_candidates()
        session["pending_candidates"] = [c["id"] for c in candidates]
        return jsonify({
            "ok": True,
            "role": "admin_pending",
            "needs_object_selection": True,
            "candidates": candidates,
        })

    # Управляющая учётка конкретного объекта.
    object_admin = _object_admin_match(login, password)
    if object_admin:
        object_id, _ = object_admin
        session.clear()
        obj = _set_object_session(object_id)
        session["role"] = "stat_admin"
        session["login"] = login
        session["object_admin"] = True
        _clear_pending()
        return jsonify({
            "ok": True,
            "role": "stat_admin",
            "object_admin": True,
            "object": _candidate(object_id, obj),
            "meta": core.safe_public_meta(),
        })

    # Ограниченные объектные учётки.
    restricted_matches = []
    for object_id, obj in read_registry().get("objects", {}).items():
        cfg = _restricted_account_for_object(object_id, login, password)
        if cfg:
            restricted_matches.append((object_id, obj, cfg))
    if len(restricted_matches) == 1:
        object_id, obj, cfg = restricted_matches[0]
        session.clear()
        session["login"] = login
        _set_object_session(object_id)
        contractor = None
        try:
            for item in core.statv2_read_spk_contractors():
                if str(item.get("account_login") or "").strip().upper() == login.upper():
                    contractor = item
                    break
        except Exception:
            contractor = None
        return _login_response_for_admin(object_id, cfg, contractor)
    if len(restricted_matches) > 1:
        return core.error("Одинаковая ограниченная учётка найдена на нескольких объектах. Измените логин одной из учёток.", 409)

    # Сварщик: сначала проверяем логин+пароль по закрытым auth всех объектов.
    matches = _find_welder_login_matches(login, password)
    if not matches:
        try:
            core.audit_event("login_failed", login=login, role="", ok=False)
        except Exception:
            pass
        return core.error("Логин или пароль не подошли", 401)

    with_stamp = next((m for m in matches if str((m[2] or {}).get("stamp") or "").strip()), None)
    session.clear()
    session["login"] = login

    if with_stamp:
        stamp = str(with_stamp[2].get("stamp") or "").strip().upper()
        candidates = []
        for object_id, obj in read_registry().get("objects", {}).items():
            auth_db = _load_auth_for_object(object_id)
            if _find_welder_by_stamp(auth_db, stamp):
                candidates.append(_candidate(object_id, obj))
        candidates.sort(key=lambda x: (str(x.get("name") or "").casefold(), x["id"]))
        session["role"] = "welder_pending"
        session["pending_type"] = "welder_stamp"
        session["pending_stamp"] = stamp
        session["pending_candidates"] = [c["id"] for c in candidates]
        return jsonify({
            "ok": True,
            "role": "welder_pending",
            "needs_object_selection": True,
            "welder_stamp": stamp,
            "candidates": candidates,
        })

    # Без клейма: если credentials относятся ровно к одному объекту — сразу вход.
    unique = {}
    for object_id, obj, w in matches:
        unique[object_id] = (obj, w)
    if len(unique) == 1:
        object_id, (obj, w) = next(iter(unique.items()))
        _set_object_session(object_id)
        session["role"] = "welder"
        session["welder_id"] = str(w.get("id") or "")
        _clear_pending()
        return jsonify({
            "ok": True,
            "role": "welder",
            "welder_id": str(w.get("id") or ""),
            "shard": str(w.get("shard") or ""),
            "name": str(w.get("name") or ""),
            "object": _candidate(object_id, obj),
            "meta": core.safe_public_meta(),
        })

    candidates = [_candidate(object_id, pair[0]) for object_id, pair in unique.items()]
    candidates.sort(key=lambda x: (str(x.get("name") or "").casefold(), x["id"]))
    session["role"] = "welder_pending"
    session["pending_type"] = "welder_no_stamp"
    session["pending_matches"] = {
        object_id: {"id": str(pair[1].get("id") or ""), "shard": str(pair[1].get("shard") or "")}
        for object_id, pair in unique.items()
    }
    session["pending_candidates"] = [c["id"] for c in candidates]
    return jsonify({
        "ok": True,
        "role": "welder_pending",
        "needs_object_selection": True,
        "candidates": candidates,
    })


def _object_admin_allowed_path(path):
    if path == "/api/stat_admin/objects" and request.method == "GET":
        return True
    allowed_prefixes = (
        "/api/stat_admin/objects/",
        "/api/stat_admin/accounts",
        "/api/stat_admin/contractors",
        "/api/engineers",
        "/api/upload_db",
        "/api/upload_idcards",
        "/api/idcards",
        "/api/upload_welder_photos",
        "/api/welder_photo",
        "/api/multi/",
    )
    return any(path.startswith(p) for p in allowed_prefixes)


@APP.before_request
def multiobject_before_request():
    object_id = str(session.get("current_object") or "").strip()
    _apply_object_context(object_id)

    if request.path == "/api/login" and request.method == "POST":
        return _handle_login()

    # Объектный администратор не имеет доступа к глобальному журналу,
    # предложениям и чужим объектам, даже если вручную набрать URL.
    if session.get("object_admin"):
        own_id = str(session.get("current_object") or "")
        if request.path == "/api/stat_admin/objects" and request.method == "GET":
            obj = read_registry().get("objects", {}).get(own_id)
            return jsonify({"ok": True, "objects": [_public_object(own_id, obj)] if obj else []})
        m = re.match(r"^/api/stat_admin/objects/([^/]+)/", request.path)
        if m and m.group(1) != own_id:
            return core.error("Нет доступа к этому объекту", 403)
        if request.path.startswith("/api/stat_admin/") and not _object_admin_allowed_path(request.path):
            return core.error("Нет доступа", 403)

    # Объектные API нельзя вызывать до выбора объекта.
    contextual = (
        request.path.startswith("/api/engineers")
        or request.path.startswith("/api/upload_db")
        or request.path.startswith("/api/upload_idcards")
        or request.path.startswith("/api/idcards")
        or request.path.startswith("/api/upload_welder_photos")
        or request.path.startswith("/api/welder_photo")
    )
    if contextual and not object_id:
        return core.error("Сначала выберите объект", 409)

    # Не даём создать одинаковую ограниченную учётку на разных объектах.
    if request.path == "/api/stat_admin/accounts" and request.method == "POST":
        data = request.get_json(silent=True) or request.form or {}
        login = str(data.get("login") or "").strip().upper()
        if login:
            reserved = {_norm(core.STAT_ADMIN_LOGIN), _norm(GLOBAL_ADMIN_LOGIN), _norm(core.UPLOAD_USER)}
            if _norm(login) in reserved:
                return core.error("Этот логин зарезервирован системой", 400)
            current_id = str(session.get("current_object") or "")
            for oid in read_registry().get("objects", {}):
                if oid == current_id:
                    continue
                p = _object_private_root(oid) / "org_accounts.json"
                try:
                    existing = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
                except Exception:
                    existing = {}
                if login in existing:
                    return core.error("Такой логин уже используется ограниченной учёткой другого объекта", 400)
                cred = _read_object_admin(oid)
                if _norm(cred.get("login")) == _norm(login):
                    return core.error("Такой логин используется управляющей учёткой другого объекта", 400)

    return None


@APP.get("/api/multi/objects")
def multi_list_objects():
    if str(session.get("role") or "") != "stat_admin":
        return core.error("Нет доступа", 401)
    registry = read_registry().get("objects", {})
    if session.get("object_admin"):
        oid = str(session.get("current_object") or "")
        obj = registry.get(oid)
        rows = [_public_object(oid, obj)] if obj else []
    else:
        rows = [_public_object(oid, obj) for oid, obj in registry.items()]
        rows.sort(key=lambda x: (str(x.get("name") or "").casefold(), x["id"]))
    return jsonify({"ok": True, "objects": rows, "object_admin": bool(session.get("object_admin"))})


@APP.post("/api/multi/objects")
def multi_create_object():
    if str(session.get("role") or "") != "stat_admin" or session.get("object_admin"):
        return core.error("Нет доступа", 403)
    data = request.get_json(silent=True) or request.form or {}
    name = str(data.get("name") or "").strip()
    admin_login = str(data.get("admin_login") or "").strip()
    admin_password = str(data.get("admin_password") or "")
    if not name:
        return core.error("Введите название объекта", 400)
    if not admin_login:
        return core.error("Введите логин управляющей учётки", 400)
    if not admin_password:
        return core.error("Введите пароль управляющей учётки", 400)
    if len(name) > 160 or len(admin_login) > 100 or len(admin_password) > 256:
        return core.error("Слишком длинное значение", 400)

    reserved = {_norm(core.STAT_ADMIN_LOGIN), _norm(GLOBAL_ADMIN_LOGIN), _norm(core.UPLOAD_USER)}
    if _norm(admin_login) in reserved:
        return core.error("Этот логин зарезервирован системой", 400)

    payload = read_registry()
    objects = payload.setdefault("objects", {})
    for oid, obj in objects.items():
        if str(obj.get("name") or "").strip().casefold() == name.casefold():
            return core.error("Объект с таким названием уже существует", 400)
        cred = _read_object_admin(oid)
        if _norm(cred.get("login")) == _norm(admin_login):
            return core.error("Такой логин управляющей учётки уже используется", 400)
        p = _object_private_root(oid) / "org_accounts.json"
        try:
            dyn = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
        except Exception:
            dyn = {}
        if any(_norm(k) == _norm(admin_login) for k in dyn):
            return core.error("Такой логин уже используется ограниченной учёткой", 400)

    object_id = "obj-" + secrets.token_hex(6)
    obj = {
        "id": object_id,
        "name": name,
        "created_at": _now(),
        "daily_spk": {"allowed_reject_rate": None, "average_ndt_percent": None, "organization": ""},
        "material_groups": [],
        "base_ranges": _default_ranges(),
    }
    objects[object_id] = obj
    write_registry(payload)
    _object_data_root(object_id).mkdir(parents=True, exist_ok=True)
    _object_private_root(object_id).mkdir(parents=True, exist_ok=True)
    _write_object_admin(object_id, admin_login, admin_password)
    return jsonify({"ok": True, "object": _public_object(object_id, obj)})


@APP.delete("/api/multi/objects/<object_id>")
def multi_delete_object(object_id):
    if str(session.get("role") or "") != "stat_admin" or session.get("object_admin"):
        return core.error("Нет доступа", 403)
    payload = read_registry()
    objects = payload.setdefault("objects", {})
    if object_id not in objects:
        return core.error("Объект не найден", 404)
    objects.pop(object_id, None)
    write_registry(payload)
    shutil.rmtree(_object_data_root(object_id), ignore_errors=True)
    shutil.rmtree(_object_private_root(object_id), ignore_errors=True)
    if str(session.get("current_object") or "") == object_id:
        session.pop("current_object", None)
        session.pop("current_object_name", None)
    return jsonify({"ok": True})


@APP.post("/api/multi/select_management_object")
def multi_select_management_object():
    if str(session.get("role") or "") != "stat_admin":
        return core.error("Нет доступа", 401)
    data = request.get_json(silent=True) or request.form or {}
    object_id = str(data.get("object_id") or "").strip()
    if session.get("object_admin") and object_id != str(session.get("current_object") or ""):
        return core.error("Нет доступа к этому объекту", 403)
    obj = _set_object_session(object_id)
    if not obj:
        return core.error("Объект не найден", 404)
    return jsonify({"ok": True, "object": _public_object(object_id, obj)})


@APP.post("/api/multi/clear_management_object")
def multi_clear_management_object():
    if str(session.get("role") or "") != "stat_admin" or session.get("object_admin"):
        return core.error("Нет доступа", 403)
    session.pop("current_object", None)
    session.pop("current_object_name", None)
    _apply_object_context("")
    return jsonify({"ok": True})


@APP.post("/api/multi/select_object")
def multi_select_object():
    data = request.get_json(silent=True) or request.form or {}
    object_id = str(data.get("object_id") or "").strip()
    candidates = session.get("pending_candidates") or []
    if object_id not in candidates:
        return core.error("Этот объект недоступен", 403)
    obj = read_registry().get("objects", {}).get(object_id)
    if not obj:
        return core.error("Объект не найден", 404)

    pending_type = str(session.get("pending_type") or "")
    login = str(session.get("login") or "")
    if pending_type == "global_admin" and str(session.get("role") or "") == "admin_pending":
        session.clear()
        session["login"] = GLOBAL_ADMIN_LOGIN
        session["role"] = "admin"
        _set_object_session(object_id)
        return jsonify({"ok": True, "role": "admin", "object": _candidate(object_id, obj), "meta": core.safe_public_meta()})

    if str(session.get("role") or "") != "welder_pending":
        return core.error("Нет ожидающего выбора объекта", 409)

    w = None
    if pending_type == "welder_stamp":
        stamp = str(session.get("pending_stamp") or "")
        w = _find_welder_by_stamp(_load_auth_for_object(object_id), stamp)
    elif pending_type == "welder_no_stamp":
        m = (session.get("pending_matches") or {}).get(object_id) or {}
        target_id = str(m.get("id") or "")
        auth_db = _load_auth_for_object(object_id) or {}
        for item in auth_db.get("welders", []):
            if str((item or {}).get("id") or "") == target_id:
                w = item
                break
    if not w:
        return core.error("Сварщик на выбранном объекте не найден", 404)

    session.clear()
    session["login"] = login
    session["role"] = "welder"
    session["welder_id"] = str(w.get("id") or "")
    _set_object_session(object_id)
    return jsonify({
        "ok": True,
        "role": "welder",
        "welder_id": str(w.get("id") or ""),
        "shard": str(w.get("shard") or ""),
        "name": str(w.get("name") or ""),
        "object": _candidate(object_id, obj),
        "meta": core.safe_public_meta(),
    })


@APP.get("/api/multi/pending")
def multi_pending():
    role = str(session.get("role") or "")
    if role not in ("admin_pending", "welder_pending"):
        return jsonify({"ok": True, "pending": False})
    ids = session.get("pending_candidates") or []
    registry = read_registry().get("objects", {})
    rows = [_candidate(oid, registry.get(oid)) for oid in ids if oid in registry]
    return jsonify({"ok": True, "pending": True, "role": role, "candidates": rows})


@APP.get("/db/<path:relpath>")
def multi_db_file(relpath):
    role = str(session.get("role") or "")
    object_id, obj = _current_object()
    if role not in ("admin", "welder") or not object_id or not obj:
        return core.error("Нет доступа", 401)
    rel = str(relpath or "").replace("\\", "/").lstrip("/")
    if not rel or rel.lower() == "auth.json.gz" or rel.endswith("/auth.json.gz"):
        return core.error("Нет доступа", 403)
    root = (OBJECTS_ROOT / object_id / "db").resolve()
    target = (root / rel).resolve()
    if not str(target).startswith(str(root) + os.sep) and target != root:
        return core.error("Недопустимый путь", 400)
    if not target.exists() or not target.is_file():
        return core.error("Файл не найден", 404)
    return send_file(target, as_attachment=False, max_age=0, conditional=True)


# Старый save_engineers проверяет только Basic. Эту функцию маршрута заменить уже поздно,
# поэтому разрешение для stat_admin обеспечивается миграционным патчем в app.py.


@APP.after_request
def multiobject_after_request(response):
    try:
        if request.path in ("/api/login", "/api/session") and response.is_json:
            data = response.get_json(silent=True)
            if isinstance(data, dict):
                oid = str(session.get("current_object") or "")
                obj = read_registry().get("objects", {}).get(oid)
                data["object_admin"] = bool(session.get("object_admin"))
                if oid and obj:
                    data["current_object"] = oid
                    data["current_object_name"] = str(obj.get("name") or oid)
                    data["object"] = _candidate(oid, obj)
                response.set_data(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
                response.headers["Content-Type"] = "application/json; charset=utf-8"
    except Exception:
        pass
    return response
PY
chmod 600 "$APP_DIR/multiobject.py"

echo "===== 5. ПИШЕМ MULTIOBJECT FRONTEND ====="
cat > "$SITE_DIR/multiobject.js" <<'JS'
/* STATV2 MULTIOBJECT V1 */
var multiObjectId="";
var multiObjectName="";
var multiIsObjectAdmin=false;
var multiObjects=[];

function multiEsc(v){return escapeHtml(v==null?"":v)}
function multiDbDate(v){
  var s=String(v||"").slice(0,10);
  return s?dateRu(s):"База не загружена";
}
function multiDbUrl(url){
  var s=String(url||"");
  if(!multiObjectId)return s;
  var join=s.indexOf("?")>=0?"&":"?";
  return s+join+"object="+encodeURIComponent(multiObjectId);
}
function multiApplyObject(obj){
  obj=obj||{};
  multiObjectId=String(obj.id||obj.current_object||"");
  multiObjectName=String(obj.name||obj.current_object_name||"");
  SPK_OBJECT_ID=multiObjectId;
  SPK_OBJECT_NAME=multiObjectName;
  if(multiObjectId){
    var status=$("dbStatus");
    if(status)status.style.display="flex";
  }
}
function multiResetClientDb(){
  MANIFEST=null;AUTH=null;DB=null;currentWelder=null;selectedWelder=null;
  loadedShardCache.clear();
  welderByLogin=new Map();authByLogin=new Map();welderById=new Map();
  adminRowCache={};adminOptionsCache={};spkPrecalc=null;
}
async function multiClearLegacyOffline(){
  try{
    if("serviceWorker" in navigator){
      var regs=await navigator.serviceWorker.getRegistrations();
      for(var i=0;i<regs.length;i++)await regs[i].unregister();
    }
    if("caches" in window){
      var names=await caches.keys();
      for(var j=0;j<names.length;j++){
        if(/statv2|welding/i.test(names[j]))await caches.delete(names[j]);
      }
    }
  }catch(e){console.warn("multi cache cleanup",e);}
}

/* Кэшируем объектные файлы под отдельным ключом, чтобы два объекта не смешались. */
async function fetchBlobWithProgress(url,startPct=8,endPct=70,title="Загрузка…",meta=null){
  meta=meta||dbFileMeta(url);
  var cacheKey=multiDbUrl(url);
  var cached=await getCachedBlob(cacheKey,meta);
  if(cached){
    var mb=((cached.size||meta?.size_bytes||0)/1024/1024).toFixed(1);
    setLoad("Открываю из кэша…",endPct,`${url} · ${mb} МБ`);
    return cached;
  }
  setLoad(title,startPct,url);
  var res=await fetch(cacheKey,{cache:"no-store",credentials:"same-origin"});
  if(!res.ok){
    var msg="HTTP "+res.status;
    try{var er=await res.json();msg=er.error||msg}catch(e){}
    throw new Error(msg);
  }
  var len=Number(res.headers.get("content-length"))||0;
  var blob;
  if(res.body?.getReader){
    var reader=res.body.getReader(),chunks=[],got=0;
    while(true){
      var step=await reader.read();
      if(step.done)break;
      chunks.push(step.value);got+=step.value.length;
      if(len)setLoad(title,startPct+got/len*(endPct-startPct),`Скачано ${(got/1024/1024).toFixed(1)} из ${(len/1024/1024).toFixed(1)} МБ`);
    }
    blob=new Blob(chunks,{type:res.headers.get("content-type")||"application/gzip"});
  }else blob=await res.blob();
  await putCachedBlob(cacheKey,blob,meta);
  return blob;
}

/* В новой схеме manifest загружается только ПОСЛЕ выбора объекта. */
async function loadDb(){
  if(!multiObjectId)throw new Error("Сначала выберите объект");
  multiResetClientDb();
  setLoad("Загружаю объект…",5,multiObjectName||multiObjectId);
  var res=await fetch(multiDbUrl("db/manifest.json"),{cache:"no-store",credentials:"same-origin"});
  if(!res.ok){
    var msg="База объекта не загружена";
    try{var d=await res.json();msg=d.error||msg}catch(e){}
    throw new Error(msg);
  }
  MANIFEST=await res.json();
  applyMaterialGroupsFromManifest();
  DB={meta:MANIFEST||{},auth:{},welders:[],welder_events:{},joints:[]};
  setupDefaultPeriods();
  var generated=(MANIFEST.generated_at||"").slice(0,10);
  setStatus(`Обновление<br><b>${dateRu(generated)}</b>`,"ok");
  return MANIFEST;
}

function multiEnsureChooser(){
  var old=document.getElementById("multiObjectChooser");
  if(old)return old;
  document.body.insertAdjacentHTML("beforeend",`
    <div id="multiObjectChooser" class="hidden" style="position:fixed;inset:0;z-index:2500;background:rgba(5,10,18,.84);backdrop-filter:blur(12px);display:none;align-items:center;justify-content:center;padding:20px;">
      <div class="glass" style="width:min(720px,96vw);max-height:90vh;overflow:auto;padding:26px;">
        <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:18px;">
          <div><div class="muted" style="font-size:12px;font-weight:800;text-transform:uppercase;letter-spacing:.08em;">Статистика сварщиков</div><h2 style="margin:6px 0 0;">Выберите объект</h2></div>
          <button class="ghost small" type="button" onclick="multiCancelChooser()">Выйти</button>
        </div>
        <div id="multiObjectChooserList" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;"></div>
        <div id="multiObjectChooserMsg" class="muted" style="margin-top:14px;"></div>
      </div>
    </div>`);
  return document.getElementById("multiObjectChooser");
}
function multiCancelChooser(){
  fetch("/api/logout",{method:"POST",credentials:"same-origin"}).catch(()=>{});
  var el=multiEnsureChooser();el.style.display="none";el.classList.add("hidden");
  revealLoginFields();
  $("loginMsg").textContent="Введите логин и пароль";
}
function multiShowChooser(data){
  var el=multiEnsureChooser();
  var list=document.getElementById("multiObjectChooserList");
  var rows=(data&&data.candidates)||[];
  list.innerHTML=rows.map(function(o){var noDb=o.has_database===false;return `
    <button type="button" class="glass" data-object-id="${multiEsc(o.id)}" ${noDb?"disabled":""} style="text-align:left;padding:18px;border-radius:18px;cursor:${noDb?"not-allowed":"pointer"};min-height:112px;opacity:${noDb?".58":"1"};">
      <div style="font-size:18px;font-weight:900;margin-bottom:10px;">${multiEsc(o.name||o.id)}</div>
      <div class="muted" style="font-size:12px;">Последняя база</div>
      <div style="font-size:14px;font-weight:800;margin-top:3px;">${multiEsc(multiDbDate(o.generated_at))}</div>
    </button>`}).join("");
  document.getElementById("multiObjectChooserMsg").textContent=rows.length?"":"Доступных объектов пока нет.";
  list.querySelectorAll("[data-object-id]").forEach(function(btn){
    btn.addEventListener("click",function(){multiSelectObject(btn.dataset.objectId,btn);});
  });
  el.classList.remove("hidden");el.style.display="flex";
}
async function multiSelectObject(objectId,button){
  if(button)button.disabled=true;
  var msg=document.getElementById("multiObjectChooserMsg");
  if(msg)msg.textContent="Открываю объект…";
  try{
    var data=await apiJson("/api/multi/select_object",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({object_id:objectId})});
    await multiEnterRole(data);
    var el=multiEnsureChooser();el.style.display="none";el.classList.add("hidden");
  }catch(e){
    if(msg)msg.textContent="Ошибка: "+(e.message||e);
    if(button)button.disabled=false;
  }
}

async function multiEnterRole(data){
  data=data||{};
  if(data.object)multiApplyObject(data.object);
  adminOrgFilter=data.org_filter||"";
  adminAccountFilterType=data.account_filter_type||"";
  adminAccountFilterValue=data.account_filter_value||"";
  currentSpkContractorId=data.spk_contractor_id||"";

  if(data.role==="stat_admin"){
    currentRole="stat_admin";
    multiIsObjectAdmin=!!data.object_admin;
    enterStatAdmin();
    return;
  }
  if(data.role==="updater"){
    currentRole="updater";enterUpdater();return;
  }
  if(data.role==="admin"){
    currentRole="admin";currentWelder=null;selectedWelder=null;
    $("loginMsg").textContent="Загружаю базу объекта…";
    await loadDb();
    await ensureAdminDbLoaded();
    enterAdmin();
    return;
  }
  if(data.role==="welder"){
    currentRole="welder";
    $("loginMsg").textContent="Загружаю данные сварщика…";
    await loadDb();
    var w=await ensureWelderShardLoaded({id:data.welder_id,shard:data.shard});
    currentWelder=w;
    openWelder(w,false);
    return;
  }
  throw new Error("Неизвестная роль пользователя");
}

async function doLogin(){
  var login=$("loginInput").value.trim(),pass=$("passwordInput").value;
  if(!login||!pass){$("loginMsg").innerHTML='<span class="error">Введите логин и пароль.</span>';return;}
  multiObjectId="";multiObjectName="";SPK_OBJECT_ID="";SPK_OBJECT_NAME="";multiIsObjectAdmin=false;multiResetClientDb();
  collapseLoginFields();
  $("loginMsg").textContent="Проверяю логин и пароль…";
  try{
    var data=await apiJson("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({login:login,password:pass}),timeoutMs:10000});
    if(data.needs_object_selection||data.role==="admin_pending"||data.role==="welder_pending"){
      revealLoginFields();
      $("loginMsg").textContent="Выберите объект";
      multiShowChooser(data);
      return;
    }
    await multiEnterRole(data);
  }catch(e){
    revealLoginFields();
    $("loginMsg").innerHTML='<span class="error">'+multiEsc(e.message||e)+'</span>';
  }
}

async function tryRestoreSession(){
  if(restoreAttempted)return;
  restoreAttempted=true;
  try{
    var s=await apiJson("/api/session",{timeoutMs:10000});
    if(!s.authenticated){revealLoginFields();return;}
    if(s.role==="admin_pending"||s.role==="welder_pending"){
      var p=await apiJson("/api/multi/pending");
      revealLoginFields();multiShowChooser(p);return;
    }
    if(s.object){multiApplyObject(s.object);}
    if(s.role==="stat_admin"){
      currentRole="stat_admin";multiIsObjectAdmin=!!s.object_admin;enterStatAdmin();return;
    }
    if(s.role==="updater"){currentRole="updater";enterUpdater();return;}
    if(s.role==="admin"){
      adminOrgFilter=s.org_filter||"";adminAccountFilterType=s.account_filter_type||"";adminAccountFilterValue=s.account_filter_value||"";currentSpkContractorId=s.spk_contractor_id||"";
      currentRole="admin";await loadDb();await ensureAdminDbLoaded();enterAdmin();return;
    }
    if(s.role==="welder"){
      currentRole="welder";await loadDb();
      var w=await ensureWelderShardLoaded({id:s.welder_id,shard:s.shard});currentWelder=w;openWelder(w,false);return;
    }
    revealLoginFields();
  }catch(e){console.warn("restore",e);revealLoginFields();}
}

/* ---------- Управление объектами ---------- */
function multiEnsureCreateObjectModal(){
  if(document.getElementById("multiCreateObjectModal"))return;
  document.body.insertAdjacentHTML("beforeend",`
    <div id="multiCreateObjectModal" class="hidden" style="position:fixed;inset:0;z-index:2600;background:rgba(0,0,0,.72);display:none;align-items:center;justify-content:center;padding:20px;">
      <div class="glass" style="width:min(560px,96vw);padding:24px;">
        <h3 style="margin:0 0 18px;">Добавить объект</h3>
        <label>Название объекта</label><input id="multiNewObjectName" autocomplete="off" placeholder="Например Норильск" style="width:100%;margin-bottom:12px;">
        <label>Логин управляющей учётки</label><input id="multiNewObjectLogin" autocomplete="off" placeholder="Например norilsk_admin" style="width:100%;margin-bottom:12px;">
        <label>Пароль управляющей учётки</label><input id="multiNewObjectPassword" type="password" autocomplete="new-password" placeholder="Пароль" style="width:100%;margin-bottom:16px;">
        <div style="display:flex;gap:10px;justify-content:flex-end;"><button class="ghost small" type="button" onclick="multiCloseCreateObject()">Отмена</button><button class="small" type="button" onclick="multiCreateObject()">Создать</button></div>
        <div id="multiCreateObjectMsg" class="muted" style="margin-top:12px;"></div>
      </div>
    </div>`);
}
function multiOpenCreateObject(){
  multiEnsureCreateObjectModal();
  ["multiNewObjectName","multiNewObjectLogin","multiNewObjectPassword"].forEach(id=>{var e=$(id);if(e)e.value="";});
  $("multiCreateObjectMsg").textContent="";
  var m=$("multiCreateObjectModal");m.style.display="flex";m.classList.remove("hidden");
  setTimeout(()=>$("multiNewObjectName")?.focus(),50);
}
function multiCloseCreateObject(){var m=$("multiCreateObjectModal");if(m){m.style.display="none";m.classList.add("hidden");}}
async function multiCreateObject(){
  var name=$("multiNewObjectName").value.trim(),login=$("multiNewObjectLogin").value.trim(),password=$("multiNewObjectPassword").value;
  var msg=$("multiCreateObjectMsg");
  if(!name||!login||!password){msg.textContent="Заполните все три поля.";return;}
  msg.textContent="Создаю объект…";
  try{
    await apiJson("/api/multi/objects",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:name,admin_login:login,admin_password:password})});
    multiCloseCreateObject();await multiRefreshObjects();
  }catch(e){msg.textContent="Ошибка: "+(e.message||e);}
}
function multiRenderObjectCards(){
  var tabs=$("statObjectTabs");if(!tabs)return;
  var html=multiObjects.map(function(o){return `
    <button class="stat-object-card" type="button" data-multi-object="${multiEsc(o.id)}">
      <span class="stat-object-card-icon" aria-hidden="true">🏗️</span>
      <span class="stat-object-card-copy"><span class="stat-object-card-kicker">Объект строительства</span><strong>${multiEsc(o.name)}</strong><span class="stat-object-card-description">База: ${multiEsc(multiDbDate(o.generated_at))}</span></span>
      <span class="stat-object-card-arrow" aria-hidden="true">→</span>
    </button>`}).join("");
  if(!multiIsObjectAdmin){
    html+=`<button class="stat-object-card" type="button" id="multiAddObjectCard"><span class="stat-object-card-icon" aria-hidden="true">＋</span><span class="stat-object-card-copy"><span class="stat-object-card-kicker">Новый объект</span><strong>Добавить объект</strong><span class="stat-object-card-description">Название и управляющая учётка</span></span><span class="stat-object-card-arrow">→</span></button>`;
  }
  if(!html)html='<div class="glass" style="padding:24px;"><b>Объектов пока нет</b><div class="muted" style="margin-top:6px;">Создайте первый объект.</div></div>';
  tabs.innerHTML=html;
  tabs.querySelectorAll("[data-multi-object]").forEach(function(btn){btn.onclick=function(){openStatAdminObject(btn.dataset.multiObject);};});
  $("multiAddObjectCard")?.addEventListener("click",multiOpenCreateObject);
}
async function multiRefreshObjects(){
  ensureStatAdminView();
  var data=await apiJson("/api/multi/objects");
  multiIsObjectAdmin=!!data.object_admin;
  multiObjects=data.objects||[];
  multiRenderObjectCards();
  if(multiIsObjectAdmin&&multiObjects.length){
    await openStatAdminObject(multiObjects[0].id);
  }
}
function multiUpdateObjectLabels(obj){
  if(!obj)return;
  var back=$("statObjectBackRow");
  var h=back?.querySelector("h3");if(h)h.textContent=obj.name||obj.id;
  var contractor=$("statContractorObject");if(contractor)contractor.value=obj.name||obj.id;
  var head=$("statObjectListHead")?.querySelector("p");if(head)head.textContent="Настройки, учётки и параметры СПК для выбранного объекта";
}
async function openStatAdminObject(objectId){
  objectId=String(objectId||"");if(!objectId)return;
  try{
    var data=await apiJson("/api/multi/select_management_object",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({object_id:objectId})});
    var obj=data.object||multiObjects.find(x=>String(x.id)===objectId)||{id:objectId,name:objectId};
    multiApplyObject(obj);multiUpdateObjectLabels(obj);statAdminObjectId=objectId;
    renderStatAdminSection();
    $("engPhoneBtn")?.classList.remove("hidden");
    await Promise.allSettled([loadStatObjectSettings(),loadStatAccounts(),loadStatContractors(),engOpenManager()]);
  }catch(e){alert("Не удалось открыть объект: "+(e.message||e));}
}
async function closeStatAdminObject(){
  if(multiIsObjectAdmin)return;
  try{await apiJson("/api/multi/clear_management_object",{method:"POST"});}catch(e){}
  statAdminObjectId="";multiObjectId="";multiObjectName="";SPK_OBJECT_ID="";SPK_OBJECT_NAME="";
  $("engPhoneBtn")?.classList.add("hidden");
  renderStatAdminSection();
  await multiRefreshObjects();
}
function renderStatAdminSection(){
  var visits=statAdminSection==="visits"&&!multiIsObjectAdmin;
  var objects=statAdminSection==="objects"||multiIsObjectAdmin;
  var suggestions=statAdminSection==="suggestions"&&!multiIsObjectAdmin;
  $("auditStatsBlock")?.classList.toggle("hidden",!visits);
  $("statAuditLogBlock")?.classList.toggle("hidden",!visits);
  $("statObjectManagementBlock")?.classList.toggle("hidden",!objects);
  $("suggViewBlock")?.classList.toggle("hidden",!suggestions);
  if(objects){
    var objectOpen=!!statAdminObjectId;
    $("statObjectListHead")?.classList.toggle("hidden",objectOpen);
    $("statObjectTabs")?.classList.toggle("hidden",objectOpen);
    $("statObjectAgkhPanel")?.classList.toggle("hidden",!objectOpen);
    $("statObjectBackRow")?.classList.toggle("hidden",!objectOpen||multiIsObjectAdmin);
  }
  renderMainHeaderMenu();
}
var _multiOriginalMainHeaderMenuDefinitions=mainHeaderMenuDefinitions;
mainHeaderMenuDefinitions=function(){
  if(currentRole==="stat_admin"&&multiIsObjectAdmin)return [["objects","Управление объектом"]];
  return _multiOriginalMainHeaderMenuDefinitions();
};
function enterStatAdmin(){
  _stopGrinderSparks();ensureStatAdminView();
  statAdminSection=multiIsObjectAdmin?"objects":"visits";statAdminObjectId="";
  $("loginView").classList.add("hidden");$("appView").classList.remove("hidden");$("logoutBtn").classList.remove("hidden");
  $("adminView")?.classList.add("hidden");$("welderView")?.classList.add("hidden");$("updaterView")?.classList.add("hidden");$("statAdminView").classList.remove("hidden");$("hero").classList.add("hidden");
  $("engPhoneBtn")?.classList.add("hidden");
  renderStatAdminSection();syncAdminHeaderNavigation();
  if(!multiIsObjectAdmin){loadStatAuditLog();loadAuditStats();suggLoadList();}
  multiRefreshObjects().catch(function(e){console.warn(e);});
}

/* Сохраняем инженеров через текущую серверную сессию; Basic остаётся только как fallback. */
async function engSave(){
  var status=$("engMgrStatus");status.textContent="Сохранение…";
  var data=engCollectForm();
  try{
    var r=await fetch("/api/engineers",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify(data)});
    var d=await r.json();
    if(r.ok&&d.ok)status.textContent="Сохранено ✔";else status.textContent="Ошибка: "+(d.error||("HTTP "+r.status));
  }catch(e){status.textContent="Ошибка сети";}
}

/* Имя объекта в имени Excel. */
makeExcelExportFilename=function(withMaterials=false){
  var d=new Date(),pad=n=>String(n).padStart(2,"0"),kind=withMaterials?" с материалами":"",name=multiObjectName||"Объект";
  return`Статистика по сварщикам ${name}${kind} ${pad(d.getDate())}.${pad(d.getMonth()+1)}.${d.getFullYear()} ${pad(d.getHours())}.${pad(d.getMinutes())}.${pad(d.getSeconds())}.xlsm`;
};

async function multiBootstrap(){
  await multiClearLegacyOffline();
  var lb=document.querySelector("#loginView .load-box");if(lb)lb.style.display="none";
  var dbs=$("dbStatus");if(dbs)dbs.style.display="none";
  $("engPhoneBtn")?.classList.add("hidden");
  setLoad("Вход готов",100,"Введите логин и пароль");
  revealLoginFields();
  restoreAttempted=false;
  await tryRestoreSession();
}

multiBootstrap();
JS
chmod 644 "$SITE_DIR/multiobject.js"

echo "===== 6. ПАТЧИМ app.py И index_v2.html ====="
python3 - <<'PY'
from pathlib import Path
import re

app = Path('/opt/statv2-uploader/app.py')
html = Path('/var/www/statv2/index_v2.html')

s = app.read_text(encoding='utf-8')
# Убираем предыдущий импорт патча, если скрипт запускается повторно.
s = re.sub(r'\n?# === STATV2 MULTIOBJECT V1 IMPORT ===\nimport multiobject\s*\n?', '\n', s)

old = '''def save_engineers():\n    if not authorized():\n        return error("Нет доступа", 401)'''
new = '''def save_engineers():\n    if not authorized() and str(session.get("role") or "") != "stat_admin":\n        return error("Нет доступа", 401)'''
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('Не нашёл ожидаемый блок save_engineers() в app.py')

s = s.rstrip() + '''\n\n# === STATV2 MULTIOBJECT V1 IMPORT ===\nimport multiobject\n'''
app.write_text(s, encoding='utf-8')

h = html.read_text(encoding='utf-8')
h = h.replace('const SPK_OBJECT_ID="agkh-smk";', 'let SPK_OBJECT_ID="";')
h = h.replace('const SPK_OBJECT_NAME="АГХК-СМК";', 'let SPK_OBJECT_NAME="";')
h = h.replace('<strong>АГХК-СМК</strong>', '<strong>Объект не выбран</strong>')
h = h.replace('к объекту АГХК-СМК.', 'к выбранному объекту.')
h = h.replace('<h3>АГХК-СМК</h3>', '<h3>Объект</h3>')
h = h.replace('return`Статистика по сварщикам АГХК${kind} ', 'return`Статистика по сварщикам ${SPK_OBJECT_NAME||"Объект"}${kind} ')

# Убираем автоматическую загрузку единственной базы до входа.
h = re.sub(r'\nloadDb\(\);\n', '\n/* MULTIOBJECT: база загружается только после выбора объекта */\n', h, count=1)

# Удаляем старое подключение нашего файла при повторном запуске.
h = re.sub(r'\s*<script src="/multiobject\.js\?v=[^"]+"></script>\s*', '\n', h)
script_tag = '<script src="/multiobject.js?v=20260820-1"></script>\n'
if '</body>' not in h:
    raise SystemExit('В index_v2.html не найден </body>')
h = h.replace('</body>', script_tag + '</body>', 1)
html.write_text(h, encoding='utf-8')
PY

echo "===== 7. SYSTEMD ENV ====="
mkdir -p /etc/statv2
cat > /etc/statv2/statv2.env <<ENV
STATV2_STAT_ADMIN_LOGIN=admin_stat
STATV2_STAT_ADMIN_PASS=$STAT_ADMIN_PASS
STATV2_GLOBAL_ADMIN_LOGIN=admin
STATV2_GLOBAL_ADMIN_PASS=$GLOBAL_ADMIN_PASS
STATV2_OBJECTS_ROOT=/var/lib/statv2/objects
STATV2_OBJECTS_REGISTRY=/opt/statv2-auth/objects.json
STATV2_AUTH_ROOT=/opt/statv2-auth
ENV
chmod 600 /etc/statv2/statv2.env

python3 - <<'PY'
from pathlib import Path
p=Path('/etc/systemd/system/statv2-uploader.service')
s=p.read_text(encoding='utf-8')
line='EnvironmentFile=-/etc/statv2/statv2.env'
if line not in s:
    needle='WorkingDirectory=/opt/statv2-uploader\n'
    if needle not in s:
        raise SystemExit('В service не найден WorkingDirectory')
    s=s.replace(needle, needle+'\n'+line+'\n', 1)
p.write_text(s, encoding='utf-8')
PY

echo "===== 8. NGINX: /db/ ТЕПЕРЬ ИДЁТ ЧЕРЕЗ FLASK ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/nginx/sites-available/statv2')
s=p.read_text(encoding='utf-8')
marker='    # MULTIOBJECT DB PROXY\n'
if marker not in s:
    block='''    # MULTIOBJECT DB PROXY\n    location ^~ /db/ {\n        proxy_pass http://127.0.0.1:5088;\n        proxy_http_version 1.1;\n        proxy_connect_timeout 60s;\n        proxy_read_timeout 900s;\n        proxy_send_timeout 900s;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n\n'''
    needle='    location /api/ {'
    if needle not in s:
        raise SystemExit('В nginx-конфиге не найден location /api/')
    s=s.replace(needle, block+needle, 1)
p.write_text(s, encoding='utf-8')
PY

# На ПЕРВОМ успешном запуске фиксируем пустой реестр. На повторных запусках его не трогаем.
# Исправляем логику создания objects.json: если marker уже существовал до запуска, backup текущего
# реестра должен был остаться. Для текущей первой миграции это просто пустой реестр.

chown -R root:root "$APP_DIR" "$AUTH_DIR" /var/lib/statv2
chmod 755 /var/lib/statv2 "$OBJECTS_DIR"


echo "===== 9. ПРОВЕРКА СИНТАКСИСА ====="
"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/app.py" "$APP_DIR/multiobject.py"
nginx -t

echo "===== 10. ЗАПУСК ====="
systemctl daemon-reload
systemctl restart statv2-uploader
systemctl reload nginx
touch "$MARKER"

sleep 2

echo "===== 11. STATUS ====="
systemctl --no-pager --full status statv2-uploader | sed -n '1,28p'

echo
echo "===== 12. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health; echo

echo
echo "===== 13. SESSION ====="
curl -fsS http://127.0.0.1/api/session; echo

echo
echo "===== 14. OBJECT REGISTRY ====="
cat /opt/statv2-auth/objects.json

echo
echo "=============================================="
echo "MULTIOBJECT V1 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Открой: http://83.147.244.6"
echo "Вход: admin_stat / (пароль из STAT_ADMIN_PASS)"
echo "=============================================="
