#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="/var/www/statv2"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_idb_cache_v5_${TS}.tar.gz"

JS="$SITE_DIR/multiobject.js"
HTML="$SITE_DIR/index_v2.html"

if [[ ! -f "$JS" || ! -f "$HTML" ]]; then
  echo "Не найдены $JS или $HTML"
  exit 1
fi

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" "$JS" "$HTML" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. REMOVE OLD V5 BLOCK IF PRESENT ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2/multiobject.js')
s=p.read_text(encoding='utf-8')
start='/* STATV2 INDEXEDDB CACHE V5 START */'
end='/* STATV2 INDEXEDDB CACHE V5 END */'
while start in s and end in s:
    a=s.index(start)
    b=s.index(end,a)+len(end)
    s=s[:a].rstrip()+"\n"+s[b:].lstrip()
p.write_text(s,encoding='utf-8')
print('Старый V5-блок удалён/не найден')
PY

echo "===== 3. INSTALL V5 CACHE LOGIC ====="
cat >> "$JS" <<'JS'

/* STATV2 INDEXEDDB CACHE V5 START */
(function(){
  if(window.__STATV2_IDB_CACHE_V5__) return;
  window.__STATV2_IDB_CACHE_V5__=true;

  /*
    V5 rules:
    - manifest.json всегда проверяем по сети: он маленький и сообщает SHA актуальной базы;
    - большой файл хранится в IndexedDB;
    - ключ IndexedDB явно содержит object_id, поэтому АГХК и Норильск не пересекаются;
    - актуальность файла определяет SHA256 из manifest, а не фактический Blob.size;
      размер Blob может отличаться после преобразований браузером/прокси;
    - при новой базе изменившийся SHA автоматически заставляет скачать только нужный файл заново.
  */

  function v5CleanDbPath(url){
    var s=String(url||"");
    try{
      if(/^https?:\/\//i.test(s)) s=new URL(s,location.href).pathname;
    }catch(e){}
    s=s.split("?")[0].split("#")[0];
    s=s.replace(/^\/+/,"").replace(/^db\//,"");
    return s;
  }

  function v5ObjectCacheKey(url){
    var oid=String(multiObjectId||"no-object");
    return "statv2-object::"+oid+"::"+v5CleanDbPath(url);
  }

  /* Делаем ошибки записи IndexedDB видимыми, а не молча проглатываем их. */
  idbPut=async function(rec){
    var db=await openDbCache();
    if(!db)return false;
    return new Promise(function(resolve){
      try{
        var tx=db.transaction(DB_CACHE_STORE,"readwrite");
        tx.objectStore(DB_CACHE_STORE).put(rec);
        tx.oncomplete=function(){resolve(true)};
        tx.onerror=function(){console.warn("IndexedDB write error",tx.error);resolve(false)};
        tx.onabort=function(){console.warn("IndexedDB write aborted",tx.error);resolve(false)};
      }catch(e){
        console.warn("IndexedDB write exception",e);
        resolve(false);
      }
    });
  };

  /* SHA из server manifest — основной version key. Blob.size намеренно не сравниваем. */
  cacheMetaOk=function(rec,meta){
    if(!rec||!rec.blob||!meta)return false;
    if(rec.object_id && String(rec.object_id)!==String(multiObjectId||""))return false;
    if(meta.sha256 && String(rec.sha256||"")!==String(meta.sha256))return false;
    if(!meta.sha256 && meta.size_bytes && Number(rec.size_bytes)!==Number(meta.size_bytes))return false;
    return true;
  };

  getCachedBlob=async function(key,meta){
    if(!meta)return null;
    var rec=await idbGet(key);
    if(!cacheMetaOk(rec,meta))return null;
    return rec.blob;
  };

  putCachedBlob=async function(key,blob,meta){
    if(!meta||!blob)return false;
    var rec={
      url:key,
      object_id:String(multiObjectId||""),
      path:v5CleanDbPath(key),
      blob:blob,
      sha256:String(meta.sha256||""),
      size_bytes:Number(meta.size_bytes)||Number(blob.size)||0,
      blob_size:Number(blob.size)||0,
      saved_at:new Date().toISOString()
    };
    var ok=await idbPut(rec);
    if(!ok)return false;

    /* Сразу читаем запись обратно. Это ловит запреты/сбои IndexedDB уже при первом входе. */
    var verify=await idbGet(key);
    var valid=cacheMetaOk(verify,meta);
    if(!valid)console.warn("IndexedDB verification failed",{key:key,meta:meta,record:verify});
    return valid;
  };

  fetchBlobWithProgress=async function(url,startPct=8,endPct=70,title="Загрузка…",meta=null){
    meta=meta||dbFileMeta(url);

    var cacheKey=v5ObjectCacheKey(url);
    var fetchUrl=multiDbUrl(url);
    var cached=await getCachedBlob(cacheKey,meta);

    if(cached){
      var mb=((cached.size||meta?.size_bytes||0)/1024/1024).toFixed(1);
      setLoad("Открываю из кэша…",endPct,`${mb} МБ · ${title.replace(/…$/,'')}`);
      console.info("STATV2 V5 cache HIT",cacheKey,meta?.sha256||"");
      return cached;
    }

    console.info("STATV2 V5 cache MISS",cacheKey,meta?.sha256||"");
    setLoad(title,startPct,"Скачиваю актуальные данные с сервера…");

    var res=await fetch(fetchUrl,{cache:"no-store",credentials:"same-origin"});
    if(!res.ok){
      var msg="HTTP "+res.status;
      try{var er=await res.json();msg=er.error||msg}catch(e){}
      throw new Error(msg);
    }

    var contentEncoding=String(res.headers.get("content-encoding")||"").toLowerCase();
    var headerLen=Number(res.headers.get("content-length"))||0;
    var lengthIsTrustworthy=headerLen>0&&!contentEncoding;
    var blob;

    if(res.body?.getReader){
      var reader=res.body.getReader(),chunks=[],got=0;
      while(true){
        var step=await reader.read();
        if(step.done)break;
        chunks.push(step.value);
        got+=step.value.length;
        if(lengthIsTrustworthy){
          var ratio=Math.max(0,Math.min(1,got/headerLen));
          setLoad(title,startPct+ratio*(endPct-startPct),
            `Скачано ${(got/1024/1024).toFixed(1)} из ${(headerLen/1024/1024).toFixed(1)} МБ`);
        }else{
          setLoad(title,startPct,`Скачано ${(got/1024/1024).toFixed(1)} МБ`);
        }
      }
      blob=new Blob(chunks,{type:res.headers.get("content-type")||"application/gzip"});
    }else{
      blob=await res.blob();
    }

    setLoad(title,endPct,`Получено ${(blob.size/1024/1024).toFixed(1)} МБ · сохраняю в кэш`);
    var saved=await putCachedBlob(cacheKey,blob,meta);
    if(saved){
      console.info("STATV2 V5 cache SAVED",cacheKey,meta?.sha256||"");
    }else{
      console.warn("STATV2 V5 cache NOT SAVED",cacheKey);
    }
    return blob;
  };

  /* Для проверки из DevTools при необходимости: await statv2CacheV5Info() */
  window.statv2CacheV5Info=async function(){
    var db=await openDbCache();
    if(!db)return {ok:false,error:"IndexedDB unavailable"};
    return new Promise(function(resolve){
      var tx=db.transaction(DB_CACHE_STORE,"readonly");
      var req=tx.objectStore(DB_CACHE_STORE).getAll();
      req.onsuccess=function(){
        var rows=(req.result||[]).map(function(r){
          return {key:r.url,object_id:r.object_id||"",sha256:r.sha256||"",size_bytes:r.size_bytes||0,blob_size:r.blob?.size||0,saved_at:r.saved_at||""};
        });
        resolve({ok:true,count:rows.length,rows:rows});
      };
      req.onerror=function(){resolve({ok:false,error:String(req.error||"read error")})};
    });
  };
})();
/* STATV2 INDEXEDDB CACHE V5 END */
JS

echo "===== 4. BUMP FRONTEND VERSION ====="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
s2=re.sub(r'/multiobject\.js\?v=[^"\']+', '/multiobject.js?v=20260820-5', s)
if s2==s and '/multiobject.js?v=20260820-5' not in s:
    s2=s.replace('/multiobject.js"','/multiobject.js?v=20260820-5"')
p.write_text(s2,encoding='utf-8')
print('multiobject.js version -> 20260820-5')
PY

echo "===== 5. CHECK ====="
grep -n "STATV2 INDEXEDDB CACHE V5 START" "$JS"
grep -n "multiobject.js?v=20260820-5" "$HTML" | head -3 || true

if command -v node >/dev/null 2>&1; then
  node --check "$JS"
  echo "JavaScript: OK"
else
  echo "node не установлен — синтаксис Node не проверяем"
fi

echo "===== 6. NGINX RELOAD ====="
nginx -t
systemctl reload nginx

echo
echo "=============================================="
echo "INDEXEDDB CACHE V5 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Первый вход после V5 скачает shard ОДИН РАЗ."
echo "Второй вход при той же базе должен показать: Открываю из кэша…"
echo "=============================================="
