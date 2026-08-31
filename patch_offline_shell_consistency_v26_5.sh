#!/usr/bin/env bash
set -euo pipefail

SITE="${STATV2_SITE_ROOT:-/var/www/statv2}"
INDEX="$SITE/index_v2.html"
GATE="$SITE/gate.html"
MULTI="$SITE/multiobject.js"
OFFLINE="$SITE/offline_v261.js"
SW="$SITE/sw.js"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_v26_5_${STAMP}.tar.gz"

for f in "$INDEX" "$GATE" "$MULTI" "$OFFLINE" "$SW"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "===== V26.5 BACKUP ====="
if [ "$SITE" = "/var/www/statv2" ]; then
  tar -czf "$BACKUP" -C "$SITE" index_v2.html gate.html multiobject.js offline_v261.js sw.js
  echo "Backup: $BACKUP"
else
  BACKUP="$SITE/.v26_5_test_backup_${STAMP}.tar.gz"
  tar -czf "$BACKUP" -C "$SITE" index_v2.html gate.html multiobject.js offline_v261.js sw.js
  echo "Test backup: $BACKUP"
fi

echo "===== PATCH ====="
python3 - "$INDEX" "$GATE" "$MULTI" "$OFFLINE" "$SW" <<'PY'
from pathlib import Path
import re, sys

index = Path(sys.argv[1])
gate = Path(sys.argv[2])
multi = Path(sys.argv[3])
offline = Path(sys.argv[4])
sw = Path(sys.argv[5])

VER = "20260831-265"
CACHE = "statv2-pwa-v15"

# ------------------------------------------------------------------
# 1) index_v2.html
#    - stop page JS from writing its own old/partial CacheStorage shell
#    - force a fresh SW script URL on Safari/iOS
#    - expose a READ-ONLY shell readiness check for the offline status line
# ------------------------------------------------------------------
s = index.read_text(encoding='utf-8')

s = re.sub(r'<script src="/offline_v261\.js\?v=[^"]+"></script>',
           f'<script src="/offline_v261.js?v={VER}"></script>', s, count=1)
s = re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>',
           f'<script src="/multiobject.js?v={VER}"></script>', s, count=1)

old_reg = '''if("serviceWorker" in navigator){
  window.addEventListener("load",function(){
    navigator.serviceWorker.register("/sw.js").catch(function(e){console.warn("SW register failed",e)});
  });
}'''
new_reg = f'''/* STATV2 V26.5: Service Worker is the ONLY owner of the offline shell cache. */
var STATV2_SW_URL="/sw.js?v={VER}";
var STATV2_SHELL_CACHE="{CACHE}";
var STATV2_CRITICAL_SHELL=[
  "/gate.html",
  "/index_v2.html",
  "/offline_v261.js?v={VER}",
  "/multiobject.js?v={VER}"
];

async function statv2CheckOfflineShellReady(){{
  try{{
    if(!("caches" in window))return false;
    var names=await caches.keys();
    if(names.indexOf(STATV2_SHELL_CACHE)<0)return false;
    var cache=await caches.open(STATV2_SHELL_CACHE);
    for(var i=0;i<STATV2_CRITICAL_SHELL.length;i++){{
      var hit=await cache.match(STATV2_CRITICAL_SHELL[i],{{ignoreSearch:true}});
      if(!hit)return false;
    }}
    return true;
  }}catch(e){{
    console.warn("offline shell readiness",e);
    return false;
  }}
}}
window.statv2CheckOfflineShellReady=statv2CheckOfflineShellReady;

if("serviceWorker" in navigator){{
  navigator.serviceWorker.addEventListener("controllerchange",function(){{
    /* Safari may keep the page that was loaded under the old worker alive.
       Reload exactly once when a NEW worker takes control while online. */
    if(!navigator.onLine)return;
    try{{
      if(sessionStorage.getItem("statv2-v265-controller-reload")==="1")return;
      sessionStorage.setItem("statv2-v265-controller-reload","1");
      location.reload();
    }}catch(e){{}}
  }});
  window.addEventListener("load",function(){{
    navigator.serviceWorker.register(STATV2_SW_URL,{{scope:"/"}}).then(function(reg){{
      try{{reg.update();}}catch(e){{}}
      [400,1400,3200].forEach(function(ms){{
        setTimeout(function(){{
          var o=window.STATV2_OFFLINE_V261;
          if(o&&o.updateStatus)o.updateStatus();
        }},ms);
      }});
    }}).catch(function(e){{console.warn("SW register failed",e)}});
  }});
}}'''
if old_reg in s:
    s = s.replace(old_reg, new_reg, 1)
elif 'STATV2 V26.5: Service Worker is the ONLY owner' not in s:
    raise SystemExit('index_v2.html: SW registration anchor not found')

# Remove the old HTML-only cache writer. It was still hardcoded to v13 and could
# recreate a partial cache containing index_v2 but not multiobject.js.
start = s.find('var _shellSilentRefreshDone = false;')
end_marker = '// STATV2 V26.1: legacy offline credentials / shared DB CacheStorage migration removed.'
end = s.find(end_marker, start) if start >= 0 else -1
replacement = '''/* STATV2 V26.5: legacy page-side shell cache writers removed.
   sw.js atomically owns gate + index + offline module + multiobject module. */
function silentlyRefreshOfflineShell(){
  /* compatibility no-op: registration/update above handles the shell */
  return;
}
function refreshOfflineShellInBackground(){ return; }

'''
if start >= 0 and end >= 0:
    s = s[:start] + replacement + s[end:]
elif 'legacy page-side shell cache writers removed' not in s:
    raise SystemExit('index_v2.html: legacy shell cache writer block not found')

# Make the fail-safe message describe an actually incomplete shell, not imply that
# the DB/profile itself was not saved.
s = s.replace(
    'Модуль входа не загрузился. Подключитесь к интернету и обновите страницу.',
    'Офлайн-оболочка загрузилась не полностью. Подключитесь к интернету, откройте сайт один раз и дождитесь статуса «Офлайн-режим готов».',
    1
)
index.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 2) gate.html: same versioned SW URL, explicit update attempt.
# ------------------------------------------------------------------
s = gate.read_text(encoding='utf-8')
old = '''navigator.serviceWorker.register("/sw.js").then(function(reg){
      log("SW registered: "+reg.scope);
    }).catch(function(e){'''
new = f'''navigator.serviceWorker.register("/sw.js?v={VER}",{{scope:"/"}}).then(function(reg){{
      log("SW registered: "+reg.scope);
      try{{reg.update();}}catch(e){{}}
    }}).catch(function(e){{'''
if old in s:
    s = s.replace(old, new, 1)
elif f'/sw.js?v={VER}' not in s:
    raise SystemExit('gate.html: SW registration anchor not found')
gate.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 3) offline_v261.js: green READY means BOTH data profile and critical JS shell.
#    Previously the status only checked IndexedDB/profile data, which is why it
#    could say READY even when multiobject.js was absent from Safari's PWA cache.
# ------------------------------------------------------------------
s = offline.read_text(encoding='utf-8')
s = s.replace('/* STATV2 OFFLINE MULTIOBJECT V26.4', '/* STATV2 OFFLINE MULTIOBJECT V26.5', 1)

anchor = '''  async function updateStatus(preferredProfile){
    var el=document.getElementById('offlineReadyStatus');
    if(!el)return;
    try{'''
repl = '''  async function updateStatus(preferredProfile){
    var el=document.getElementById('offlineReadyStatus');
    if(!el)return;
    try{
      var shellReady=true;
      if(typeof window.statv2CheckOfflineShellReady==='function'){
        shellReady=await window.statv2CheckOfflineShellReady();
      }'''
if anchor in s:
    s = s.replace(anchor, repl, 1)
elif 'var shellReady=true;' not in s:
    raise SystemExit('offline_v261.js: updateStatus anchor not found')

old_pref = '''        if(rr.ready){
          var d=String(preferredProfile.manifest&&preferredProfile.manifest.generated_at||'').slice(0,10);
          if(typeof window.dateRu==='function')d=window.dateRu(d);
          el.textContent='✅ Офлайн-режим готов · '+String(preferredProfile.object&&preferredProfile.object.name||'Объект')+(d?' · база '+d:'');
          el.dataset.state='ready';el.style.color='var(--green)';
          return;
        }'''
new_pref = '''        if(rr.ready){
          var d=String(preferredProfile.manifest&&preferredProfile.manifest.generated_at||'').slice(0,10);
          if(typeof window.dateRu==='function')d=window.dateRu(d);
          if(!shellReady){
            el.textContent='⚠️ Данные объекта сохранены · офлайн-модуль ещё обновляется';
            el.dataset.state='warn';el.style.color='var(--yellow, #f5a623)';
            return;
          }
          el.textContent='✅ Офлайн-режим готов · '+String(preferredProfile.object&&preferredProfile.object.name||'Объект')+(d?' · база '+d:'');
          el.dataset.state='ready';el.style.color='var(--green)';
          return;
        }'''
if old_pref in s:
    s = s.replace(old_pref, new_pref, 1)
elif 'Данные объекта сохранены · офлайн-модуль ещё обновляется' not in s:
    raise SystemExit('offline_v261.js: preferred ready block not found')

old_rows = '''      if(readyCount){
        el.textContent='✅ Офлайн-режим готов · сохранено профилей: '+readyCount;
        el.dataset.state='ready';el.style.color='var(--green)';
      }else if(rows.length){'''
new_rows = '''      if(readyCount){
        if(!shellReady){
          el.textContent='⚠️ Данные сохранены · офлайн-модуль ещё обновляется';
          el.dataset.state='warn';el.style.color='var(--yellow, #f5a623)';
        }else{
          el.textContent='✅ Офлайн-режим готов · сохранено профилей: '+readyCount;
          el.dataset.state='ready';el.style.color='var(--green)';
        }
      }else if(rows.length){'''
if old_rows in s:
    s = s.replace(old_rows, new_rows, 1)
elif 'Данные сохранены · офлайн-модуль ещё обновляется' not in s:
    raise SystemExit('offline_v261.js: ready count block not found')

s = s.replace('version:264,\n    setPending:setPending,', 'version:265,\n    setPending:setPending,', 1)
offline.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 4) multiobject.js: diagnostic marker. No auth/data behavior change.
# ------------------------------------------------------------------
s = multi.read_text(encoding='utf-8')
if 'window.__STATV2_MULTIOBJECT_READY__=true;' not in s:
    marker = 'var multiOfflineChooserProfiles=[];'
    if marker not in s:
        raise SystemExit('multiobject.js: startup marker not found')
    s = s.replace(marker, marker+'\nwindow.__STATV2_MULTIOBJECT_READY__=true;', 1)
multi.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 5) sw.js: v15 atomic cache, exact versioned critical modules.
# ------------------------------------------------------------------
s = sw.read_text(encoding='utf-8')
s = re.sub(r'/\* STATV2 PWA V26\.[0-9]+[^*]*\*/',
           '/* STATV2 PWA V26.5 — atomic offline shell owned only by Service Worker */',
           s, count=1)
s = re.sub(r"const CACHE_NAME = 'statv2-pwa-v\d+';", f"const CACHE_NAME = '{CACHE}';", s, count=1)

# Replace critical/optional arrays irrespective of whether source is V26.4 or V26.2-ish.
arr_start = s.find('const CRITICAL_PRECACHE = [')
if arr_start < 0:
    raise SystemExit('sw.js: CRITICAL_PRECACHE not found (V26.4 required)')
install_start = s.find("self.addEventListener('install'", arr_start)
if install_start < 0:
    raise SystemExit('sw.js: install block not found')
new_arrays = f'''const CRITICAL_PRECACHE = [
  '/gate.html',
  '/index_v2.html',
  '/offline_v261.js?v={VER}',
  '/multiobject.js?v={VER}'
];
const OPTIONAL_PRECACHE = [
  '/index.html',
  '/object_media_v12.js?v=20260824-25',
  '/admin_v13.js?v=20260824-25',
  '/admin_v14.js?v=20260824-25'
];

'''
s = s[:arr_start] + new_arrays + s[install_start:]

# Keep existing atomic install code, but it currently consumes the arrays above.
# Add message-based diagnostics for future support/installers.
msg_marker = "function offlineSessionResponse(){"
if 'STATV2_CHECK_OFFLINE_SHELL' not in s:
    msg = '''self.addEventListener('message', function(e){
  var data=e.data||{};
  if(data.type!=='STATV2_CHECK_OFFLINE_SHELL')return;
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
      return Promise.all(CRITICAL_PRECACHE.map(function(url){
        return cache.match(url,{ignoreSearch:true});
      }));
    }).then(function(rows){
      var ready=rows.every(Boolean);
      if(e.ports&&e.ports[0])e.ports[0].postMessage({ok:true,ready:ready,cache:CACHE_NAME});
    }).catch(function(err){
      if(e.ports&&e.ports[0])e.ports[0].postMessage({ok:false,ready:false,error:String(err)});
    })
  );
});

'''
    if msg_marker not in s:
        raise SystemExit('sw.js: message insertion marker not found')
    s = s.replace(msg_marker, msg + msg_marker, 1)
sw.write_text(s, encoding='utf-8')
PY

echo "===== STATIC CHECKS ====="
grep -n 'STATV2 V26.5: Service Worker is the ONLY owner' "$INDEX"
grep -n 'statv2-pwa-v15' "$INDEX" "$SW"
grep -n '/sw.js?v=20260831-265' "$INDEX" "$GATE"
grep -n 'офлайн-модуль ещё обновляется' "$OFFLINE"
grep -n '__STATV2_MULTIOBJECT_READY__' "$MULTI"

if grep -n 'var HTML_CACHE = "statv2-pwa-v13"' "$INDEX"; then
  echo "ERROR: stale v13 page-side shell cache writer still exists"
  exit 1
else
  echo "Stale page-side v13 shell cache writer: 0"
fi

if command -v node >/dev/null 2>&1; then
  node --check "$MULTI"
  node --check "$OFFLINE"
  node --check "$SW"
fi

if [ "$SITE" = "/var/www/statv2" ]; then
  echo "===== NGINX ====="
  nginx -t
fi

echo "===== DONE ====="
echo "STATV2 V26.5 OFFLINE SHELL CONSISTENCY УСТАНОВЛЕН"
echo "  • старый page-side cache v13 больше не создаётся"
echo "  • Service Worker один владеет offline shell"
echo "  • critical shell: gate + index + offline_v261 + multiobject — атомарно"
echo "  • Safari получает принудительно новый /sw.js?v=20260831-265"
echo "  • зелёный статус теперь означает: данные И JS-модули реально сохранены"
echo "  • PWA cache: statv2-pwa-v15"
echo "Backup: $BACKUP"
