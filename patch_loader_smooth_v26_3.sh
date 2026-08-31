#!/usr/bin/env bash
set -euo pipefail

SITE=/var/www/statv2
INDEX="$SITE/index_v2.html"
MULTI="$SITE/multiobject.js"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_v26_3_${STAMP}.tar.gz"

for f in "$INDEX" "$MULTI"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "===== V26.3 BACKUP ====="
tar -czf "$BACKUP" -C "$SITE" index_v2.html multiobject.js

echo "===== PATCH ====="
python3 - "$INDEX" "$MULTI" <<'PY'
from pathlib import Path
import sys

index = Path(sys.argv[1])
multi = Path(sys.argv[2])

# 1) Remove a forced synchronous layout read from every progress update.
s = index.read_text(encoding='utf-8')
old = '''  var el=$("loadElectrode");
  if(el){
    var bar=$("loadBar").parentElement;
    var w=bar.offsetWidth||300;
    el.style.left=(pct/100*w-6)+"px";
    el.style.display=pct<=0||pct>=100?"none":"block";
  }'''
new = '''  var el=$("loadElectrode");
  if(el){
    /* V26.3: no offsetWidth read here. Reading layout after changing loadBar.width
       forced WebKit/Chrome to synchronously recalculate layout on every update. */
    el.style.left="calc("+pct+"% - 6px)";
    el.style.display=pct<=0||pct>=100?"none":"block";
  }'''
if old in s:
    s = s.replace(old, new, 1)
elif 'V26.3: no offsetWidth read here' not in s:
    raise SystemExit('index_v2.html: setLoad anchor not found')
index.write_text(s, encoding='utf-8')

# 2) Restore the proven cache-hit animation from the old production site.
s = multi.read_text(encoding='utf-8')
marker = '/* STATV2 INDEXEDDB CACHE V5 START */'
pos = s.find(marker)
if pos < 0:
    raise SystemExit('multiobject.js: V5 marker not found')
head, tail = s[:pos], s[pos:]

helper_anchor = '''  function v5ObjectCacheKey(url){
    var oid=String(multiObjectId||"no-object");
    return "statv2-object::"+oid+"::scope::"+String(multiAccessCacheScope||"anon")+"::"+v5CleanDbPath(url);
  }
'''
helper = helper_anchor + '''
  /* V26.3: the old production site intentionally animated a cache hit before
     parsing JSON. Without this yield the code jumps to the next shard and JSON.parse
     can block the main thread before Safari paints the CSS transition. */
  async function v263AnimateCachedProgress(startPct,endPct,title,details){
    var start=Number(startPct),end=Number(endPct);
    if(!Number.isFinite(start))start=0;
    if(!Number.isFinite(end))end=start;
    start=Math.max(0,Math.min(100,start));
    end=Math.max(0,Math.min(100,end));
    if(end<=start||typeof requestAnimationFrame!=="function"){
      setLoad(title,end,details);return;
    }
    await new Promise(function(resolve){
      var duration=320,startTime=null,done=false;
      var safety=setTimeout(function(){
        if(done)return;done=true;setLoad(title,end,details);resolve();
      },850);
      function frame(ts){
        if(done)return;
        if(startTime===null)startTime=ts;
        var t=Math.min((ts-startTime)/duration,1);
        /* smoothstep: smooth start/finish without overshoot */
        var e=t*t*(3-2*t);
        setLoad(title,start+(end-start)*e,details);
        if(t<1)requestAnimationFrame(frame);
        else{done=true;clearTimeout(safety);resolve();}
      }
      requestAnimationFrame(frame);
    });
  }
'''
if 'function v263AnimateCachedProgress' not in tail:
    if helper_anchor not in tail:
        raise SystemExit('multiobject.js: cache key anchor not found')
    tail = tail.replace(helper_anchor, helper, 1)

old_hit = '''    if(cached){
      var mb=((cached.size||meta?.size_bytes||0)/1024/1024).toFixed(1);
      setLoad("Открываю из кэша…",endPct,`${mb} МБ · ${title.replace(/…$/,'')}`);
      console.info("STATV2 V5 cache HIT",cacheKey,meta?.sha256||"");
      return cached;
    }'''
new_hit = '''    if(cached){
      var mb=((cached.size||meta?.size_bytes||0)/1024/1024).toFixed(1);
      await v263AnimateCachedProgress(
        startPct,endPct,"Открываю из кэша…",`${mb} МБ · ${title.replace(/…$/,'')}`
      );
      console.info("STATV2 V5 cache HIT",cacheKey,meta?.sha256||"");
      return cached;
    }'''
if old_hit in tail:
    tail = tail.replace(old_hit, new_hit, 1)
elif 'await v263AnimateCachedProgress(' not in tail:
    raise SystemExit('multiobject.js: V5 cache HIT anchor not found')

# 3) Yield one paint before synchronous JSON.parse. This does not alter data,
#    only gives the browser a chance to draw the last progress frame.
end_marker = '/* STATV2 INDEXEDDB CACHE V5 END */'
# Some versions have no explicit END marker; insert near diagnostic function end is riskier.
# Override loadJsonUrl immediately after V5 IIFE instead, using a unique footer marker.
footer = '})();\n\n'
# Find end of the V5 IIFE by locating statv2CacheV5Info then the next "})();".
diag = tail.find('window.statv2CacheV5Info=async function()')
if diag < 0:
    raise SystemExit('multiobject.js: V5 diagnostic anchor not found')
close = tail.find('})();', diag)
if close < 0:
    raise SystemExit('multiobject.js: V5 IIFE end not found')
close += len('})();')
post = '''

/* STATV2 V26.3 JSON PAINT YIELD */
loadJsonUrl=async function(url,startPct=8,endPct=70,title="Загрузка…",meta=null){
  var blob=await fetchBlobWithProgress(url,startPct,endPct,title,meta);
  var text=await blobToTextMaybeGzip(blob);
  if(typeof requestAnimationFrame==="function"){
    await new Promise(function(resolve){requestAnimationFrame(function(){resolve();});});
  }
  return JSON.parse(text);
};'''
if 'STATV2 V26.3 JSON PAINT YIELD' not in tail:
    tail = tail[:close] + post + tail[close:]

multi.write_text(head + tail, encoding='utf-8')
PY

echo "===== STATIC CHECKS ====="
grep -n 'V26.3: no offsetWidth' "$INDEX"
grep -n 'v263AnimateCachedProgress' "$MULTI"
grep -n 'STATV2 V26.3 JSON PAINT YIELD' "$MULTI"

# Basic JS parse check if node exists; node is not required on the server.
if command -v node >/dev/null 2>&1; then
  node --check "$MULTI"
fi

echo "===== NGINX ====="
nginx -t

echo "===== DONE ====="
echo "STATV2 V26.3 SMOOTH CACHE LOADER УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Backend/service restart not required (frontend-only)."
