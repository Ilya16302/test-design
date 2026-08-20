#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/statv2-uploader"
SITE_DIR="/var/www/statv2"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_loader_v4_${TS}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$APP_DIR/multiobject.py" \
  "$SITE_DIR/multiobject.js" \
  "$SITE_DIR/index_v2.html" \
  /etc/systemd/system/statv2-uploader.service 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. RAW .GZ RESPONSES ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/statv2-uploader/multiobject.py')
s=p.read_text(encoding='utf-8')
old='''    return send_file(target, as_attachment=False, max_age=0, conditional=True)'''
new='''    # .json.gz — это УЖЕ gzip-файл. Не помечаем его как HTTP Content-Encoding:gzip,
    # иначе браузер распакует тело автоматически, а Content-Length останется размером
    # сжатого файла. Из-за этого прогресс может улетать далеко за 100%.
    if target.name.lower().endswith(".gz"):
        response = send_file(
            target,
            mimetype="application/gzip",
            as_attachment=False,
            max_age=0,
            conditional=True,
        )
        response.headers.pop("Content-Encoding", None)
        return response
    return send_file(target, as_attachment=False, max_age=0, conditional=True)'''
if new in s:
    print('Backend raw-gzip patch already present')
elif old in s:
    s=s.replace(old,new,1)
    p.write_text(s,encoding='utf-8')
    print('Backend raw-gzip patch installed')
else:
    raise SystemExit('Не найдена ожидаемая строка send_file в multiobject.py')
PY

echo "===== 3. FRONTEND LOADER/CACHE PATCH ====="
cat >> "$SITE_DIR/multiobject.js" <<'JS'

/* STATV2 LOADER + CACHE V4 */
(function(){
  if(window.__STATV2_LOADER_CACHE_V4__) return;
  window.__STATV2_LOADER_CACHE_V4__=true;

  /* Никогда не показываем 460% даже если прокси прислал странные заголовки. */
  var _v4SetLoad=setLoad;
  setLoad=function(title,p,details=""){
    p=Number(p);
    if(!Number.isFinite(p))p=0;
    p=Math.max(0,Math.min(100,p));
    return _v4SetLoad(title,p,details);
  };

  /* Старый кэш мог сохранить уже распакованное тело при размере сжатого файла.
     Проверяем фактический размер Blob, а не только служебное поле записи. */
  cacheMetaOk=function(rec,meta){
    if(!rec||!rec.blob||!meta)return false;
    if(meta.sha256&&rec.sha256!==meta.sha256)return false;
    if(meta.size_bytes){
      var expected=Number(meta.size_bytes)||0;
      if(expected&&Number(rec.size_bytes)!==expected)return false;
      if(expected&&Number(rec.blob.size)!==expected)return false;
    }
    return true;
  };

  /* В однообъектной версии эта функция после ЛЮБОГО входа тихо скачивала все
     admin-shard'ы в Service Worker cache. В мультиобъектной схеме это запрещаем.
     Каждый файл кэшируется только тогда, когда он реально понадобился текущей роли. */
  migrateIndexedDbToSwCache=async function(){ return; };

  /* Более понятная шкала:
       manifest             5%
       admin summary      8–16%
       данные            16–88%
       индексы / СПК     91–100%
     Для сварщика скачивается только его один shard. */
  loadShardFile=async function(shardPath,idx=0,total=1){
    var url=shardPath.startsWith("db/")?shardPath:"db/"+shardPath;
    var start=16+idx/Math.max(total,1)*72;
    var end=16+(idx+1)/Math.max(total,1)*72;
    var isWelder=(currentRole==="welder"&&total===1);
    var title=isWelder?"Загрузка данных сварщика…":`Загрузка части ${idx+1} из ${total}…`;

    if(loadedShardCache.has(url)){
      setLoad(title,end,"Данные уже открыты в этой сессии");
      return loadedShardCache.get(url);
    }
    var meta=dbFileMeta(url);
    var part=await loadJsonUrl(url,start,end,title,meta);
    loadedShardCache.set(url,part);
    return part;
  };

  /* Защита от transparent HTTP decompression у внешнего прокси.
     Если Content-Encoding всё-таки появился, Content-Length с потоком сравнивать нельзя. */
  fetchBlobWithProgress=async function(url,startPct=8,endPct=70,title="Загрузка…",meta=null){
    meta=meta||dbFileMeta(url);
    var cacheKey=multiDbUrl(url);
    var cached=await getCachedBlob(cacheKey,meta);
    if(cached){
      var mb=((cached.size||0)/1024/1024).toFixed(1);
      setLoad("Открываю из кэша…",endPct,`${mb} МБ · ${title.replace(/…$/,'')}`);
      return cached;
    }

    setLoad(title,startPct,"Подключаюсь к серверу…");
    var res=await fetch(cacheKey,{cache:"no-store",credentials:"same-origin"});
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
        chunks.push(step.value);got+=step.value.length;
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

    setLoad(title,endPct,`Получено ${(blob.size/1024/1024).toFixed(1)} МБ`);
    await putCachedBlob(cacheKey,blob,meta);
    return blob;
  };

  /* Однократно выбрасываем старый общий offline-cache, который мог содержать
     admin-shard'ы от прежней однообъектной логики. IndexedDB неверные записи
     автоматически перестанут проходить cacheMetaOk и будут перезаписаны. */
  (async function(){
    try{
      var marker="statv2-loader-cache-v4-cleaned";
      if(localStorage.getItem(marker)==="1")return;
      if("caches" in window)await caches.delete("statv2-offline-v5");
      localStorage.setItem(marker,"1");
    }catch(e){console.warn("V4 cache cleanup",e);}
  })();
})();
JS

# Не плодим блок при повторном запуске: если он уже был, оставляем только первый.
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2/multiobject.js')
s=p.read_text(encoding='utf-8')
mark='/* STATV2 LOADER + CACHE V4 */'
parts=s.split(mark)
if len(parts)>2:
    s=parts[0]+mark+parts[1]
    p.write_text(s,encoding='utf-8')
    print('Duplicate V4 blocks removed')
else:
    print('Frontend V4 block present')
PY

echo "===== 4. CACHE-CONTROL FOR MULTIOBJECT.JS ====="
# Обновляем version query, чтобы браузер точно забрал новый внешний JS.
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
import re
s2=re.sub(r'/multiobject\.js\?v=[^"\']+', '/multiobject.js?v=20260820-4', s)
if s2==s and '/multiobject.js?v=20260820-4' not in s:
    s2=s.replace('/multiobject.js"','/multiobject.js?v=20260820-4"')
p.write_text(s2,encoding='utf-8')
print('multiobject.js version -> 20260820-4')
PY

echo "===== 5. PYTHON CHECK ====="
"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/app.py" "$APP_DIR/multiobject.py"
echo "Python: OK"

echo "===== 6. JS CHECK ====="
node_bin="$(command -v node || true)"
if [[ -n "$node_bin" ]]; then
  "$node_bin" --check "$SITE_DIR/multiobject.js"
  echo "JavaScript: OK"
else
  echo "node не установлен — пропускаю node --check"
fi

echo "===== 7. RESTART ====="
systemctl restart statv2-uploader
sleep 2

echo "===== 8. STATUS ====="
systemctl --no-pager --full status statv2-uploader | sed -n '1,25p'

echo "===== 9. HEALTH ====="
curl -sS http://127.0.0.1:5088/health
echo

echo "===== 10. RAW GZIP HEADER CHECK ====="
# Без авторизованной browser-сессии /db вернёт 401 — это нормально.
# Проверяем, что код с явным application/gzip установлен.
grep -n 'mimetype="application/gzip"' "$APP_DIR/multiobject.py" || true

echo
echo "=============================================="
echo "LOADER/CACHE V4 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Сделай Ctrl+F5 и проверь вход сварщика и admin."
echo "=============================================="
