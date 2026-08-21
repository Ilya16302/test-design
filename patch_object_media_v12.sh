#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/statv2-uploader"
SITE_DIR="/var/www/statv2"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_object_media_v12_${STAMP}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$APP_DIR/multiobject.py" \
  "$SITE_DIR/index_v2.html" \
  "$SITE_DIR/multiobject.js" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. BACKEND PHOTO META ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/statv2-uploader/multiobject.py')
s=p.read_text(encoding='utf-8')
marker='# STATV2 OBJECT MEDIA V12'
if marker not in s:
    block=r'''

# STATV2 OBJECT MEDIA V12
PHOTO_META_FILE_V12 = "media_meta_v12.json"

def _media_photo_root_v12(object_id):
    return _object_private_root(object_id) / "welder_photos"

def _media_photo_manifest_v12(object_id):
    return _media_photo_root_v12(object_id) / "manifest.json"

def _media_photo_meta_path_v12(object_id):
    return _media_photo_root_v12(object_id) / PHOTO_META_FILE_V12

def _media_photo_rel_v12(value):
    if isinstance(value, dict):
        value = value.get("path") or value.get("file") or ""
    return str(value or "").replace("\\", "/").strip()

def _media_photo_sync_v12(object_id):
    root = _media_photo_root_v12(object_id)
    manifest_path = _media_photo_manifest_v12(object_id)
    meta_path = _media_photo_meta_path_v12(object_id)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    except Exception:
        manifest = {}
    try:
        old = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    except Exception:
        old = {}
    out = {"__version__": str(manifest.get("__version__") or "0")}
    changed = str(old.get("__version__") or "") != out["__version__"]
    root_resolved = root.resolve()
    for raw_stamp, raw_value in manifest.items():
        if str(raw_stamp).startswith("__"):
            continue
        stamp = str(raw_stamp or "").strip().upper()
        rel = _media_photo_rel_v12(raw_value)
        if not stamp or not rel:
            continue
        target = (root / rel).resolve()
        if not str(target).startswith(str(root_resolved)) or not target.is_file():
            continue
        st = target.stat()
        prev = old.get(stamp) if isinstance(old.get(stamp), dict) else {}
        same = (
            str(prev.get("path") or "") == rel
            and int(prev.get("size_bytes") or -1) == int(st.st_size)
            and int(prev.get("mtime_ns") or -1) == int(st.st_mtime_ns)
        )
        entry = {
            "path": rel,
            "uploaded_at": (
                str(prev.get("uploaded_at") or "") if same
                else datetime.utcfromtimestamp(st.st_mtime).isoformat(timespec="seconds") + "Z"
            ),
            "sha256": str(prev.get("sha256") or "") if same else "",
            "size_bytes": int(st.st_size),
            "mtime_ns": int(st.st_mtime_ns),
        }
        out[stamp] = entry
        if not same:
            changed = True
    old_keys = {str(k) for k in old if not str(k).startswith("__")}
    new_keys = {str(k) for k in out if not str(k).startswith("__")}
    if old_keys != new_keys:
        changed = True
    if changed or not meta_path.exists():
        root.mkdir(parents=True, exist_ok=True)
        tmp = meta_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(meta_path)
        try: meta_path.chmod(0o600)
        except Exception: pass
    return out

def _media_photo_sha_v12(object_id, stamp, meta):
    entry = meta.get(stamp)
    if not isinstance(entry, dict):
        return entry
    if entry.get("sha256"):
        return entry
    root = _media_photo_root_v12(object_id)
    target = (root / str(entry.get("path") or "")).resolve()
    if not target.is_file() or not str(target).startswith(str(root.resolve())):
        return entry
    h = hashlib.sha256()
    with target.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk: break
            h.update(chunk)
    entry["sha256"] = h.hexdigest()
    meta[stamp] = entry
    path = _media_photo_meta_path_v12(object_id)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    try: path.chmod(0o600)
    except Exception: pass
    return entry

@APP.get("/api/multi/photo_meta/<stamp>")
def multi_photo_meta_v12(stamp):
    object_id, obj = _current_object()
    if not object_id or not obj:
        return core.error("Сначала выберите объект", 409)
    safe_stamp = core._welder_photo_norm_stamp(Path(stamp).name)
    if not safe_stamp:
        return core.error("Клеймо не указано", 400)
    allowed, welder = core._welder_photo_request_allowed(safe_stamp)
    if not allowed:
        if welder is None:
            return jsonify({"ok": True, "exists": False, "object_id": object_id, "stamp": safe_stamp})
        return core.error("Нет доступа", 403)
    meta = _media_photo_sync_v12(object_id)
    entry = meta.get(safe_stamp)
    if not isinstance(entry, dict):
        return jsonify({"ok": True, "exists": False, "object_id": object_id, "stamp": safe_stamp, "version": meta.get("__version__", "0")})
    entry = _media_photo_sha_v12(object_id, safe_stamp, meta)
    return jsonify({
        "ok": True,
        "exists": True,
        "object_id": object_id,
        "object_name": str(obj.get("name") or object_id),
        "stamp": safe_stamp,
        "uploaded_at": str(entry.get("uploaded_at") or ""),
        "sha256": str(entry.get("sha256") or ""),
        "size_bytes": int(entry.get("size_bytes") or 0),
        "version": str(meta.get("__version__") or "0"),
    })

@APP.after_request
def multi_object_media_after_request_v12(response):
    try:
        if request.path == "/api/upload_welder_photos" and 200 <= int(response.status_code) < 300:
            object_id = str(session.get("current_object") or "").strip()
            if object_id:
                _media_photo_sync_v12(object_id)
    except Exception as exc:
        print("OBJECT MEDIA V12 sync warning:", repr(exc))
    return response
'''
    s=s.rstrip()+block+'\n'
    p.write_text(s,encoding='utf-8')
    print('Backend V12 appended')
else:
    print('Backend V12 already present')
PY

echo "===== 3. FRONTEND OBJECT MEDIA ====="
cat > "$SITE_DIR/object_media_v12.js" <<'JS'
/* STATV2 OBJECT MEDIA V12 */
(function(){
  function oid(){
    try{return String(multiObjectId||SPK_OBJECT_ID||"").trim()}catch(e){return ""}
  }
  function stampText(v){return String(v||"").trim().toUpperCase()}
  function photoMetaKey(stamp){return "statv2-photo-meta-v12::"+oid()+"::"+stampText(stamp)}
  function photoMemoryKey(stamp,meta){
    return oid()+"::"+stampText(stamp)+"::"+String(meta?.sha256||meta?.uploaded_at||meta?.version||"0")
  }
  function savePhotoMeta(stamp,meta){
    try{localStorage.setItem(photoMetaKey(stamp),JSON.stringify(meta||{}))}catch(e){}
  }
  function readPhotoMeta(stamp){
    try{return JSON.parse(localStorage.getItem(photoMetaKey(stamp))||"null")}catch(e){return null}
  }
  async function fetchPhotoMeta(stamp){
    stamp=stampText(stamp);
    if(!stamp||!oid())return null;
    try{
      const r=await fetch("/api/multi/photo_meta/"+encodeURIComponent(stamp)+"?object="+encodeURIComponent(oid()),{
        cache:"no-store",credentials:"same-origin"
      });
      if(!r.ok)throw new Error("HTTP "+r.status);
      const m=await r.json();
      savePhotoMeta(stamp,m);
      return m;
    }catch(e){
      return readPhotoMeta(stamp);
    }
  }

  welderPhotoSyncDbCacheVersion=async function(){
    /* V12: фото больше не инвалидируются версией базы. Их версия своя. */
  };

  welderPhotoUrl=function(stamp,meta){
    const q=new URLSearchParams();
    q.set("object",oid());
    q.set("pv",String(meta?.sha256||meta?.uploaded_at||meta?.version||"0"));
    return "/api/welder_photo/"+encodeURIComponent(stampText(stamp))+"?"+q.toString();
  };

  welderPhotoGetObjectUrl=async function(stamp){
    stamp=stampText(stamp);
    if(!stamp||!oid())return null;
    const meta=await fetchPhotoMeta(stamp);
    if(!meta||meta.exists===false)return null;
    const memKey=photoMemoryKey(stamp,meta);
    if(welderPhotoObjectUrls.has(memKey))return welderPhotoObjectUrls.get(memKey);
    if(welderPhotoLoads.has(memKey))return welderPhotoLoads.get(memKey);
    const promise=(async()=>{
      const url=welderPhotoUrl(stamp,meta);
      let response=null;
      try{
        if("caches" in window){
          const cache=await caches.open(WELDER_PHOTO_CACHE_NAME);
          response=await cache.match(url);
          if(!response&&navigator.onLine){
            const fresh=await fetch(url,{cache:"no-store",credentials:"same-origin"});
            if(fresh.status===404)return null;
            if(!fresh.ok)throw new Error("HTTP "+fresh.status);
            await cache.put(url,fresh.clone());
            response=fresh;
          }
        }else if(navigator.onLine){
          response=await fetch(url,{cache:"force-cache",credentials:"same-origin"});
          if(response.status===404)return null;
          if(!response.ok)throw new Error("HTTP "+response.status);
        }
        if(!response)return null;
        const blob=await response.blob();
        if(!blob.size)return null;
        const objectUrl=URL.createObjectURL(blob);
        welderPhotoObjectUrls.set(memKey,objectUrl);
        return objectUrl;
      }finally{
        welderPhotoLoads.delete(memKey);
      }
    })();
    welderPhotoLoads.set(memKey,promise);
    return promise;
  };

  welderPhotoForceClearCache=async function(){
    const objectId=oid();
    try{
      for(const [key,url] of Array.from(welderPhotoObjectUrls.entries())){
        if(!objectId||String(key).startsWith(objectId+"::")){
          try{URL.revokeObjectURL(url)}catch(e){}
          welderPhotoObjectUrls.delete(key);
        }
      }
      for(const key of Array.from(welderPhotoLoads.keys())){
        if(!objectId||String(key).startsWith(objectId+"::"))welderPhotoLoads.delete(key);
      }
      if("caches" in window){
        const cache=await caches.open(WELDER_PHOTO_CACHE_NAME);
        const requests=await cache.keys();
        for(const req of requests){
          const u=new URL(req.url);
          if(!objectId||u.searchParams.get("object")===objectId)await cache.delete(req);
        }
      }
      if(objectId){
        for(let i=localStorage.length-1;i>=0;i--){
          const k=localStorage.key(i)||"";
          if(k.startsWith("statv2-photo-meta-v12::"+objectId+"::"))localStorage.removeItem(k);
        }
      }
    }catch(e){console.warn("Очистка объектного кэша фото:",e)}
    welderPhotoResetAccountUi();
  };

  const legacyIcGet=icCacheGet, legacyIcSet=icCacheSet;
  function icScopedKey(k){return String(k)+"::object::"+(oid()||"no-object")}
  icCacheGet=function(k){
    try{return JSON.parse(localStorage.getItem(icScopedKey(k))||"null")}catch(e){return null}
  };
  icCacheSet=function(k,v){
    try{localStorage.setItem(icScopedKey(k),JSON.stringify(v))}catch(e){}
  };
  window.statv2IdCardUrl=function(path){
    const version=icCacheGet(IDCARDS_VER_KEY)||"0";
    const q=new URLSearchParams();
    q.set("object",oid());
    q.set("iv",String(version||"0"));
    return window.location.origin+"/api/idcards/"+path+"?"+q.toString();
  };

  try{
    if(!localStorage.getItem("statv2-object-media-v12-cleaned")){
      localStorage.removeItem("idcards_manifest_v1");
      localStorage.removeItem("idcards_version_v1");
      localStorage.removeItem(WELDER_PHOTO_DB_VERSION_KEY);
      localStorage.setItem("statv2-object-media-v12-cleaned","1");
    }
  }catch(e){}
})();
JS
chmod 644 "$SITE_DIR/object_media_v12.js"

echo "===== 4. PATCH ID-CARD URL + SCRIPT TAG ====="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
old="var pdfUrl=window.location.origin+'/api/idcards/'+p;"
new="var pdfUrl=window.statv2IdCardUrl?window.statv2IdCardUrl(p):(window.location.origin+'/api/idcards/'+p);"
if old in s:
    s=s.replace(old,new,1)
elif new not in s:
    raise SystemExit('Не найден URL ID-карты')
s=re.sub(r'\s*<script src="/object_media_v12\.js\?v=[^"]+"></script>\s*','\n',s)
tag='<script src="/object_media_v12.js?v=20260821-12"></script>\n'
needle=re.search(r'<script src="/multiobject\.js\?v=[^"]+"></script>\s*',s)
if not needle:
    raise SystemExit('Не найден multiobject.js')
pos=needle.end()
s=s[:pos]+tag+s[pos:]
p.write_text(s,encoding='utf-8')
print('Frontend V12 connected')
PY

echo "===== 5. BACKFILL PHOTO DATES ====="
cd "$APP_DIR"
./venv/bin/python - <<'PY'
import multiobject as m
objects=m.read_registry().get('objects',{})
for oid,obj in objects.items():
    meta=m._media_photo_sync_v12(oid)
    count=len([k for k in meta if not str(k).startswith('__')])
    print(f"{obj.get('name',oid)}: фото в meta = {count}")
PY

echo "===== 6. CHECK ====="
./venv/bin/python -m py_compile app.py multiobject.py upload_async.py upload_worker.py
grep -q 'STATV2 OBJECT MEDIA V12' "$APP_DIR/multiobject.py"
grep -q 'STATV2 OBJECT MEDIA V12' "$SITE_DIR/object_media_v12.js"
grep -q 'object_media_v12.js?v=20260821-12' "$SITE_DIR/index_v2.html"
echo "Checks: OK"

echo "===== 7. RESTART ====="
systemctl restart statv2-uploader
sleep 2
systemctl is-active --quiet statv2-uploader

echo "===== 8. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health
echo

echo "===== 9. ROUTE CHECK ====="
./venv/bin/python - <<'PY'
import app
for r in sorted(str(x) for x in app.APP.url_map.iter_rules()):
    if 'photo_meta' in r:
        print(r)
PY

echo
echo "=============================================="
echo "OBJECT MEDIA V12 ГОТОВ"
echo "Backup: $BACKUP"
echo "Сделай Ctrl+F5."
echo "=============================================="
