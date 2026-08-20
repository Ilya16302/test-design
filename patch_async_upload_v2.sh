#!/usr/bin/env bash
set -euo pipefail

APP_DIR=/opt/statv2-uploader
SITE_DIR=/var/www/statv2
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_async_upload_${TS}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$APP_DIR/app.py" \
  "$APP_DIR/multiobject.py" \
  "$SITE_DIR/index_v2.html" \
  "$SITE_DIR/sw.js" \
  /etc/systemd/system/statv2-uploader.service \
  /etc/nginx/sites-available/statv2 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 1B. STOP OLD UPLOAD WORKER ====="
systemctl stop statv2-uploader || true

echo "===== 2. ASYNC UPLOAD API ====="
cat > "$APP_DIR/upload_async.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from flask import jsonify, request, session

import app as core
import multiobject as multi

APP = core.APP
UPLOAD_ROOT = Path("/var/lib/statv2/upload_sessions").resolve()
JOBS_ROOT = Path("/var/lib/statv2/upload_jobs").resolve()
WORKER = Path("/opt/statv2-uploader/upload_worker.py").resolve()
ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
MAX_CHUNK_BYTES = 16 * 1024 * 1024

UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
JOBS_ROOT.mkdir(parents=True, exist_ok=True)


def _error(message, status=400):
    return jsonify({"ok": False, "error": str(message)}), status


def _allowed():
    return str(session.get("role") or "") in ("stat_admin", "updater")


def _context_object():
    oid = str(session.get("current_object") or "").strip()
    if not oid:
        return ""
    if oid not in multi.read_registry().get("objects", {}):
        return ""
    return oid


def _valid_upload_id(value):
    value = str(value or "").strip()
    return value if ID_RE.fullmatch(value) else ""


def _session_dir(oid, upload_id):
    return UPLOAD_ROOT / oid / upload_id


def _job_dir(job_id):
    return JOBS_ROOT / job_id


def _write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


@APP.post("/api/upload_db_chunk")
def upload_db_chunk():
    if not _allowed():
        return _error("Нет доступа", 401)
    oid = _context_object()
    if not oid:
        return _error("Сначала выберите объект", 409)

    upload_id = _valid_upload_id(request.form.get("upload_id"))
    if not upload_id:
        return _error("Некорректный upload_id")

    try:
        index = int(request.form.get("index", "-1"))
        total = int(request.form.get("total", "0"))
    except Exception:
        return _error("Некорректный номер части")

    if total < 1 or total > 10000 or index < 0 or index >= total:
        return _error("Некорректная нумерация частей")

    chunk = request.files.get("chunk")
    if not chunk:
        return _error("Часть файла не получена")

    content_len = request.content_length or 0
    if content_len > MAX_CHUNK_BYTES + 2 * 1024 * 1024:
        return _error("Слишком большая часть файла", 413)

    root = _session_dir(oid, upload_id)
    parts = root / "parts"
    parts.mkdir(parents=True, exist_ok=True)
    meta_path = root / "meta.json"

    filename = os.path.basename(str(request.form.get("filename") or "database.zip"))
    if not filename.lower().endswith(".zip"):
        return _error("Нужен zip-архив")

    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            return _error("Повреждена сессия загрузки", 409)
        if str(meta.get("object_id")) != oid or int(meta.get("total") or 0) != total:
            return _error("Параметры загрузки изменились", 409)
    else:
        _write_json(meta_path, {
            "object_id": oid,
            "upload_id": upload_id,
            "filename": filename,
            "total": total,
        })

    part = parts / f"{index:06d}.part"
    tmp = parts / f"{index:06d}.tmp"
    chunk.save(tmp)
    size = tmp.stat().st_size
    if size > MAX_CHUNK_BYTES:
        tmp.unlink(missing_ok=True)
        return _error("Слишком большая часть файла", 413)
    tmp.replace(part)

    return jsonify({"ok": True, "index": index, "total": total, "size": size})


@APP.post("/api/upload_db_finalize")
def upload_db_finalize():
    if not _allowed():
        return _error("Нет доступа", 401)
    oid = _context_object()
    if not oid:
        return _error("Сначала выберите объект", 409)

    data = request.get_json(silent=True) or {}
    upload_id = _valid_upload_id(data.get("upload_id"))
    if not upload_id:
        return _error("Некорректный upload_id")

    root = _session_dir(oid, upload_id)
    meta_path = root / "meta.json"
    if not meta_path.exists():
        return _error("Сессия загрузки не найдена", 404)

    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        total = int(meta.get("total") or 0)
    except Exception:
        return _error("Повреждена сессия загрузки", 409)

    if str(meta.get("object_id")) != oid or total < 1:
        return _error("Некорректная сессия загрузки", 409)

    parts = root / "parts"
    missing = [i for i in range(total) if not (parts / f"{i:06d}.part").exists()]
    if missing:
        preview = ", ".join(str(x + 1) for x in missing[:10])
        return _error("Не загружены части: " + preview, 409)

    job_id = upload_id
    job = _job_dir(job_id)
    job.mkdir(parents=True, exist_ok=True)
    status_path = job / "status.json"
    _write_json(status_path, {
        "ok": True,
        "job_id": job_id,
        "object_id": oid,
        "state": "queued",
        "progress": 56,
        "message": "Архив получен. Запускаю обработку на сервере…",
    })

    log_path = job / "worker.log"
    log_fh = open(log_path, "ab", buffering=0)
    try:
        subprocess.Popen(
            [sys.executable, str(WORKER), oid, job_id],
            cwd=str(Path(core.__file__).resolve().parent),
            stdin=subprocess.DEVNULL,
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    except Exception as exc:
        log_fh.close()
        _write_json(status_path, {
            "ok": False,
            "job_id": job_id,
            "object_id": oid,
            "state": "error",
            "progress": 0,
            "error": "Не удалось запустить обработчик: " + str(exc),
        })
        return _error("Не удалось запустить обработку", 500)
    finally:
        try:
            log_fh.close()
        except Exception:
            pass

    return jsonify({"ok": True, "accepted": True, "job_id": job_id}), 202


@APP.get("/api/upload_db_status/<job_id>")
def upload_db_status(job_id):
    if not _allowed():
        return _error("Нет доступа", 401)
    oid = _context_object()
    if not oid:
        return _error("Сначала выберите объект", 409)
    job_id = _valid_upload_id(job_id)
    if not job_id:
        return _error("Некорректный job_id")

    status_path = _job_dir(job_id) / "status.json"
    if not status_path.exists():
        return _error("Задание не найдено", 404)
    try:
        data = json.loads(status_path.read_text(encoding="utf-8"))
    except Exception:
        return _error("Не удалось прочитать состояние задания", 500)
    if str(data.get("object_id") or "") != oid:
        return _error("Нет доступа к этому заданию", 403)
    return jsonify(data)
PY
chmod 600 "$APP_DIR/upload_async.py"

echo "===== 3. BACKGROUND WORKER ====="
cat > "$APP_DIR/upload_worker.py" <<'PY'
#!/usr/bin/env python3
import fcntl
import gzip
import json
import shutil
import sys
import tempfile
import traceback
from datetime import datetime
from pathlib import Path

import app as core
import multiobject as multi

UPLOAD_ROOT = Path("/var/lib/statv2/upload_sessions").resolve()
JOBS_ROOT = Path("/var/lib/statv2/upload_jobs").resolve()


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: upload_worker.py OBJECT_ID JOB_ID")
    oid, job_id = sys.argv[1], sys.argv[2]
    session_root = UPLOAD_ROOT / oid / job_id
    job_root = JOBS_ROOT / job_id
    status_path = job_root / "status.json"
    job_root.mkdir(parents=True, exist_ok=True)

    def status(state, progress, message="", error="", **extra):
        payload = {
            "ok": state != "error",
            "job_id": job_id,
            "object_id": oid,
            "state": state,
            "progress": int(progress),
            "message": message,
        }
        if error:
            payload["error"] = error
        payload.update(extra)
        atomic_json(status_path, payload)

    registry = multi.read_registry().get("objects", {})
    if oid not in registry:
        status("error", 0, error="Объект больше не существует")
        return 2

    meta_path = session_root / "meta.json"
    if not meta_path.exists():
        status("error", 0, error="Не найдены данные загруженного архива")
        return 2
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    total = int(meta.get("total") or 0)
    parts_root = session_root / "parts"

    object_root = multi._object_data_root(oid)
    object_root.mkdir(parents=True, exist_ok=True)
    lock_path = object_root / ".upload.lock"

    with open(lock_path, "a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            status("error", 0, error="Для этого объекта уже обрабатывается другая база")
            return 3

        multi._apply_object_context(oid)
        db_target = object_root / "db"
        backup_root = object_root / "uploads_backup"
        private_root = multi._object_private_root(oid)
        private_auth = private_root / "auth.json.gz"
        backup_root.mkdir(parents=True, exist_ok=True)
        private_root.mkdir(parents=True, exist_ok=True)

        auth_was_present = private_auth.exists()
        backup_path = None
        published = False

        try:
            status("processing", 57, "Собираю загруженные части архива…")
            package = job_root / "database.zip"
            with open(package, "wb") as out:
                for i in range(total):
                    part = parts_root / f"{i:06d}.part"
                    if not part.exists():
                        raise ValueError(f"Не найдена часть архива {i + 1} из {total}")
                    with open(part, "rb") as src:
                        shutil.copyfileobj(src, out, length=1024 * 1024)
                    if total > 1:
                        status("processing", 57 + int((i + 1) / total * 4), f"Собираю архив: {i + 1}/{total}")

            with tempfile.TemporaryDirectory(prefix="statv2_async_") as tmp_name:
                tmp = Path(tmp_name)
                extracted = tmp / "extracted"
                new_db_tmp = tmp / "db_new"
                extracted.mkdir()

                status("processing", 62, "Распаковываю архив…")
                core.safe_extract_zip(package, extracted)
                db_dir = core.find_db_dir(extracted)
                core.validate_db_dir(db_dir)

                status("processing", 66, "Копирую новую базу во временную область…")
                shutil.copytree(db_dir, new_db_tmp)

                snapshot_path = new_db_tmp / "spk_backlog_snapshot.json"
                spk_snapshot = None
                if snapshot_path.exists():
                    spk_snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
                    if not isinstance(spk_snapshot, dict):
                        raise ValueError("Некорректный spk_backlog_snapshot.json")

                auth_file = new_db_tmp / "auth.json.gz"
                if not auth_file.exists():
                    raise ValueError("В архиве нет auth.json.gz — без него сервер не сможет проверять вход")

                old_auth_backup = tmp / "old_auth.json.gz"
                if private_auth.exists():
                    shutil.copy2(private_auth, old_auth_backup)

                status("processing", 69, "Сохраняю закрытую базу авторизации…")
                auth_tmp = private_root / ("auth.json.gz.new." + job_id)
                shutil.copy2(auth_file, auth_tmp)
                auth_tmp.chmod(0o600)
                auth_tmp.replace(private_auth)

                def read_gz(path):
                    with gzip.open(path, "rt", encoding="utf-8") as f:
                        return json.load(f)

                def write_gz(path, data):
                    with gzip.open(path, "wt", encoding="utf-8") as f:
                        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))

                def strip_secrets(obj):
                    if isinstance(obj, dict):
                        for key in ("login", "password_plain", "password_hash", "admin_password_hash"):
                            obj.pop(key, None)
                        if isinstance(obj.get("auth"), dict):
                            obj["auth"] = {}
                        for value in obj.values():
                            strip_secrets(value)
                    elif isinstance(obj, list):
                        for value in obj:
                            strip_secrets(value)

                gz_files = list(new_db_tmp.rglob("*.json.gz"))
                count = len(gz_files)
                if not count:
                    raise ValueError("В базе не найдено ни одного .json.gz файла")

                for idx, gz in enumerate(gz_files, 1):
                    data = read_gz(gz)
                    strip_secrets(data)
                    write_gz(gz, data)
                    pct = 70 + int(idx / count * 20)
                    status("processing", pct, f"Очищаю публичную базу: {idx}/{count}")

                core.chmod_tree(new_db_tmp)

                status("processing", 92, "Публикую новую базу объекта…")
                if db_target.exists():
                    backup_path = backup_root / ("db_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
                    shutil.move(str(db_target), str(backup_path))

                try:
                    shutil.move(str(new_db_tmp), str(db_target))
                    published = True

                    manifest_path = db_target / "manifest.json"
                    manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
                    manifest_data["base_version"] = datetime.utcnow().strftime("%Y%m%d%H%M%S")

                    obj = multi.read_registry().get("objects", {}).get(oid) or {}
                    manifest_data["material_groups"] = obj.get("material_groups") or []
                    manifest_data["base_ranges"] = obj.get("base_ranges") or multi._default_ranges()
                    manifest_path.write_text(
                        json.dumps(manifest_data, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf-8",
                    )

                    if spk_snapshot:
                        core.statv2_merge_spk_backlog_snapshot(spk_snapshot)
                except Exception:
                    if db_target.exists():
                        shutil.rmtree(db_target, ignore_errors=True)
                    if backup_path and backup_path.exists():
                        shutil.move(str(backup_path), str(db_target))
                    published = False
                    raise

                generated_at = str(manifest_data.get("generated_at") or "")
                snapshot_date = str((spk_snapshot or {}).get("date") or "")

            shutil.rmtree(session_root, ignore_errors=True)
            status(
                "done",
                100,
                "База обновлена. Закрытый auth сохранён, публичная db очищена от логинов и паролей.",
                generated_at=generated_at,
                backup=str(backup_path) if backup_path else "",
                spk_snapshot_date=snapshot_date,
            )
            return 0

        except Exception as exc:
            # Если публикация не состоялась, возвращаем прежний auth.
            try:
                old_auth_backup = Path(locals().get("old_auth_backup", ""))
                if not published:
                    if old_auth_backup and old_auth_backup.exists():
                        shutil.copy2(old_auth_backup, private_auth)
                        private_auth.chmod(0o600)
                    elif not auth_was_present and private_auth.exists():
                        private_auth.unlink()
            except Exception:
                pass
            trace = traceback.format_exc()
            (job_root / "traceback.log").write_text(trace, encoding="utf-8")
            status("error", 0, error=str(exc), message="Обработка базы завершилась ошибкой")
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 700 "$APP_DIR/upload_worker.py"

echo "===== 4. IMPORT ASYNC MODULE ====="
python3 - <<'PY'
from pathlib import Path
p = Path('/opt/statv2-uploader/multiobject.py')
s = p.read_text(encoding='utf-8')
marker = '# === STATV2 ASYNC UPLOAD V2 ==='
if marker not in s:
    s = s.rstrip() + f'''\n\n{marker}\nimport upload_async\n'''
p.write_text(s, encoding='utf-8')
PY

echo "===== 5. PATCH FRONTEND ====="
python3 - <<'PY'
from pathlib import Path
p = Path('/var/www/statv2/index_v2.html')
s = p.read_text(encoding='utf-8')
start = s.find('function uploadDbPackage(){')
end = s.find('function enterUpdater(){', start)
if start < 0 or end < 0:
    raise SystemExit('Не найден старый uploadDbPackage()')
new = r'''function uploadDbPackage(){
  const file=$("updateArchiveInput")?.files?.[0];
  if(!file){setUploadLoad("Архив не выбран",0,"Сначала выберите zip-архив базы.");return}
  if(!file.name.toLowerCase().endsWith(".zip")){setUploadLoad("Ошибка загрузки",0,"Нужен zip-архив.");return}

  const CHUNK_SIZE=5*1024*1024;
  const total=Math.max(1,Math.ceil(file.size/CHUNK_SIZE));
  const uploadId=(crypto?.randomUUID?.()||(`up_${Date.now()}_${Math.random().toString(36).slice(2)}`)).replace(/[^A-Za-z0-9_-]/g,"");

  const sleep=ms=>new Promise(r=>setTimeout(r,ms));

  function sendChunk(index,attempt=1){
    return new Promise((resolve,reject)=>{
      const start=index*CHUNK_SIZE;
      const end=Math.min(file.size,start+CHUNK_SIZE);
      const blob=file.slice(start,end);
      const xhr=new XMLHttpRequest();
      const fd=new FormData();
      fd.append("upload_id",uploadId);
      fd.append("index",String(index));
      fd.append("total",String(total));
      fd.append("filename",file.name);
      fd.append("chunk",blob,`chunk_${index}.bin`);
      xhr.open("POST","/api/upload_db_chunk",true);
      xhr.withCredentials=true;
      xhr.upload.onprogress=e=>{
        if(!e.lengthComputable)return;
        const sent=Math.min(file.size,start+e.loaded);
        const pct=Math.max(1,Math.min(55,Math.round(sent/file.size*55)));
        setUploadLoad("Загружаю архив…",pct,`Часть ${index+1} из ${total} · ${(sent/1024/1024).toFixed(1)} из ${(file.size/1024/1024).toFixed(1)} МБ`);
      };
      xhr.onload=()=>{
        let data={};
        try{data=JSON.parse(xhr.responseText||"{}")}catch(e){}
        if(xhr.status>=200&&xhr.status<300&&data.ok){resolve(data);return}
        const msg=data.error||(`HTTP ${xhr.status}`);
        if(attempt<3){sleep(800*attempt).then(()=>sendChunk(index,attempt+1).then(resolve,reject));return}
        reject(new Error(msg));
      };
      xhr.onerror=()=>{
        if(attempt<3){sleep(800*attempt).then(()=>sendChunk(index,attempt+1).then(resolve,reject));return}
        reject(new Error("Сетевая ошибка при отправке части "+(index+1)));
      };
      xhr.send(fd);
    });
  }

  async function pollJob(jobId){
    for(;;){
      await sleep(1500);
      const res=await fetch(`/api/upload_db_status/${encodeURIComponent(jobId)}?t=${Date.now()}`,{credentials:"same-origin",cache:"no-store"});
      let data={};
      try{data=await res.json()}catch(e){throw new Error(`HTTP ${res.status}`)}
      if(!res.ok||!data.ok&&data.state!=="error")throw new Error(data.error||(`HTTP ${res.status}`));
      if(data.state==="error")throw new Error(data.error||"Ошибка обработки базы");
      const pct=Math.max(56,Math.min(100,Number(data.progress)||56));
      if(data.state==="done"){
        setUploadLoad("База обновлена",100,data.message||"База успешно опубликована.");
        loadedShardCache.clear?.();
        welderPhotoForceClearCache();
        return data;
      }
      setUploadLoad("Обрабатываю базу…",pct,data.message||"Обработка продолжается на сервере. Страницу можно не держать открытой.");
    }
  }

  (async()=>{
    setUploadLoad("Загружаю архив…",1,`${file.name} · ${(file.size/1024/1024).toFixed(1)} МБ`);
    for(let i=0;i<total;i++)await sendChunk(i);
    setUploadLoad("Архив загружен",56,"Запускаю фоновую обработку на сервере…");

    const res=await fetch("/api/upload_db_finalize",{
      method:"POST",
      credentials:"same-origin",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({upload_id:uploadId})
    });
    let data={};
    try{data=await res.json()}catch(e){throw new Error(`HTTP ${res.status}`)}
    if(!res.ok||!data.ok)throw new Error(data.error||(`HTTP ${res.status}`));
    await pollJob(data.job_id);
  })().catch(e=>{
    setUploadLoad("Ошибка загрузки",0,e?.message||String(e));
  });
}
'''
s = s[:start] + new + s[end:]
p.write_text(s, encoding='utf-8')
PY

echo "===== 6. BUMP SERVICE WORKER CACHE ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2/sw.js')
s=p.read_text(encoding='utf-8')
import re
s=re.sub(r"const CACHE_NAME = 'statv2-pwa-v\\d+';", "const CACHE_NAME = 'statv2-pwa-v9';", s)
p.write_text(s,encoding='utf-8')
PY

echo "===== 7. PYTHON CHECK ====="
"$APP_DIR/venv/bin/python" -m py_compile \
  "$APP_DIR/app.py" \
  "$APP_DIR/multiobject.py" \
  "$APP_DIR/upload_async.py" \
  "$APP_DIR/upload_worker.py"
echo "Python: OK"

echo "===== 8. JS CHECK ====="
# Node может быть не установлен; проверим хотя бы, что новая функция и endpoints присутствуют.
grep -q '/api/upload_db_chunk' "$SITE_DIR/index_v2.html"
grep -q '/api/upload_db_finalize' "$SITE_DIR/index_v2.html"
grep -q '/api/upload_db_status/' "$SITE_DIR/index_v2.html"
echo "Frontend patch: OK"

echo "===== 9. RESTART ====="
systemctl restart statv2-uploader
sleep 2

if ! systemctl is-active --quiet statv2-uploader; then
  systemctl --no-pager --full status statv2-uploader || true
  journalctl -u statv2-uploader -n 100 --no-pager || true
  exit 1
fi

echo "===== 10. STATUS ====="
systemctl --no-pager --full status statv2-uploader | head -25

echo "===== 11. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health
echo

echo "===== 12. ROUTES ====="
"$APP_DIR/venv/bin/python" - <<'PY'
import sys
sys.path.insert(0,'/opt/statv2-uploader')
import app
rules=sorted(str(r) for r in app.APP.url_map.iter_rules() if 'upload_db' in str(r))
print('\n'.join(rules))
need={'/api/upload_db_chunk','/api/upload_db_finalize','/api/upload_db_status/<job_id>'}
if not need.issubset(set(rules)):
    raise SystemExit('Не все async upload routes зарегистрированы')
PY

echo
echo "=============================================="
echo "ASYNC/CHUNKED UPLOAD V2 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Обнови страницу Ctrl+F5 и загрузи базу снова."
echo "=============================================="
