#!/usr/bin/env bash
set -euo pipefail

SITE="/var/www/statv2"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_v26_2_${STAMP}.tar.gz"

need(){ [ -f "$1" ] || { echo "ОШИБКА: нет файла $1" >&2; exit 1; }; }
need "$SITE/gate.html"
need "$SITE/sw.js"
need "$SITE/index.html"
need "$SITE/index_v2.html"
need "$SITE/multiobject.js"
need "$SITE/offline_v261.js"

echo "===== V26.2 BACKUP ====="
tar -czf "$BACKUP" -C "$SITE" gate.html sw.js index.html index_v2.html multiobject.js offline_v261.js
ls -lh "$BACKUP"

python3 - "$SITE" <<'PY'
from pathlib import Path
import re, sys

site = Path(sys.argv[1])

# ------------------------------------------------------------------
# gate.html: возвращаем проверенную старую схему: /api/session является
# источником истины для online/offline, но не ждём регистрацию SW.
# Service Worker сам быстро даёт offline:true при отсутствии сети.
# ------------------------------------------------------------------
gate = site / "gate.html"
s = gate.read_text(encoding="utf-8")
new_script = r'''<script>
(function(){
  var TIMEOUT_MS=5500;
  var TARGET="/index_v2.html";
  var FORCE_KEY="statv2_offline_force";
  var DEBUG=location.search.indexOf("debug=1")!==-1;
  var logLines=[];
  var fallbackTimer=null;

  function log(msg){
    if(!DEBUG)return;
    logLines.push(msg);
    var el=document.getElementById("debug");
    if(el){el.classList.remove("hidden");el.textContent=logLines.join("\n");}
  }
  function showOfflineChoice(){
    if(fallbackTimer){clearTimeout(fallbackTimer);fallbackTimer=null;}
    document.getElementById("checking").classList.add("hidden");
    document.getElementById("offlineChoice").classList.remove("hidden");
  }
  function showChecking(){
    document.getElementById("checking").classList.remove("hidden");
    document.getElementById("offlineChoice").classList.add("hidden");
    var hint=document.getElementById("checkingHint");
    var btn=document.getElementById("fallbackOfflineBtn");
    if(hint)hint.textContent="Проверяем подключение к серверу";
    if(btn)btn.classList.add("hidden");
    if(fallbackTimer)clearTimeout(fallbackTimer);
    fallbackTimer=setTimeout(function(){
      if(btn)btn.classList.remove("hidden");
      if(hint)hint.textContent="Если сети нет — откройте сохранённую офлайн-версию";
    },1800);
  }
  function setOfflineForce(v){
    try{if(v)sessionStorage.setItem(FORCE_KEY,"1");else sessionStorage.removeItem(FORCE_KEY);}catch(e){}
  }
  function goOnline(){
    setOfflineForce(false);
    location.replace(TARGET);
  }
  function goOffline(){
    setOfflineForce(true);
    location.replace(TARGET);
  }
  function checkConnection(){
    showChecking();
    log("--- V26.2 connection check ---");
    log("navigator.onLine="+navigator.onLine);
    log("SW controller="+(navigator.serviceWorker&&navigator.serviceWorker.controller?"yes":"no"));

    if(navigator.onLine===false){
      log("Browser reports offline");
      showOfflineChoice();
      return;
    }

    var ctrl=new AbortController();
    var timer=setTimeout(function(){
      try{ctrl.abort();}catch(e){}
      log("Gate timeout "+TIMEOUT_MS+"ms");
    },TIMEOUT_MS);

    fetch("/api/session?gate="+Date.now(),{
      cache:"no-store",
      credentials:"same-origin",
      signal:ctrl.signal
    }).then(function(res){
      return res.json().catch(function(){return null;}).then(function(data){
        return {res:res,data:data};
      });
    }).then(function(x){
      clearTimeout(timer);
      log("/api/session -> HTTP "+x.res.status+" "+JSON.stringify(x.data));
      if(x.data&&x.data.offline===true){
        showOfflineChoice();
      }else if(x.res.ok&&x.data){
        goOnline();
      }else{
        showOfflineChoice();
      }
    }).catch(function(e){
      clearTimeout(timer);
      log("Connection check failed: "+(e&&e.message||e));
      showOfflineChoice();
    });
  }

  document.getElementById("retryBtn").addEventListener("click",checkConnection);
  document.getElementById("offlineBtn").addEventListener("click",goOffline);
  document.getElementById("fallbackOfflineBtn").addEventListener("click",goOffline);

  /* Регистрация только в фоне. Проверка подключения от неё не зависит. */
  if("serviceWorker" in navigator){
    navigator.serviceWorker.register("/sw.js").then(function(reg){
      log("SW registered: "+reg.scope);
    }).catch(function(e){
      log("SW register failed: "+(e&&e.message||e));
    });
  }

  checkConnection();
})();
</script>'''
# Gate has a single script at the bottom; replace last script block only.
matches=list(re.finditer(r'<script>.*?</script>', s, flags=re.S|re.I))
if not matches:
    raise SystemExit("gate.html: script block not found")
m=matches[-1]
s=s[:m.start()]+new_script+s[m.end():]
gate.write_text(s,encoding="utf-8")

# ------------------------------------------------------------------
# sw.js: старый рабочий принцип + новая безопасность V25/V26.
# - shell network-first -> cache fallback
# - /api/session has synthetic offline response
# - other /api and /db are NEVER shared-cached
# ------------------------------------------------------------------
sw = site / "sw.js"
sw.write_text(r'''/* STATV2 PWA V26.2 — old proven offline flow + multiobject isolation */
const CACHE_NAME = 'statv2-pwa-v13';
const CACHE_PREFIX = 'statv2-pwa-';
const PRECACHE = [
  '/gate.html',
  '/index.html',
  '/index_v2.html',
  '/offline_v261.js',
  '/multiobject.js',
  '/object_media_v12.js',
  '/admin_v13.js',
  '/admin_v14.js'
];

self.addEventListener('install', function(e) {
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      return Promise.all(PRECACHE.map(function(url) {
        return cache.add(new Request(url, {cache:'reload'})).catch(function(err) {
          console.warn('precache failed:', url, err);
          return null;
        });
      }));
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', function(e) {
  e.waitUntil(
    caches.keys().then(function(keys) {
      return Promise.all(
        keys
          .filter(function(k){ return k.indexOf(CACHE_PREFIX) === 0 && k !== CACHE_NAME; })
          .map(function(k){ return caches.delete(k); })
      );
    }).then(function(){ return clients.claim(); })
  );
});

function offlineSessionResponse(){
  return new Response(JSON.stringify({
    ok:true,
    authenticated:false,
    offline:true
  }),{
    status:200,
    headers:{'Content-Type':'application/json','Cache-Control':'no-store'}
  });
}

function cachedShell(request, fallbackPath) {
  return caches.open(CACHE_NAME).then(function(cache) {
    return cache.match(request, {ignoreSearch:true}).then(function(hit) {
      if(hit) return hit;
      if(fallbackPath) return cache.match(fallbackPath, {ignoreSearch:true});
      return null;
    });
  });
}

self.addEventListener('fetch', function(e) {
  var url = new URL(e.request.url);
  if(url.origin !== self.location.origin) return;

  /*
    Это ключевой принцип старого рабочего офлайна:
    gate спрашивает /api/session. Если сервер недоступен, SW быстро
    отвечает offline:true вместо бесконечного ожидания сети.
  */
  if(url.pathname === '/api/session') {
    var sessionNetwork = fetch(e.request.clone()).catch(function(){
      return offlineSessionResponse();
    });
    var sessionTimeout = new Promise(function(resolve){
      setTimeout(function(){ resolve(offlineSessionResponse()); }, 3500);
    });
    e.respondWith(Promise.race([sessionNetwork, sessionTimeout]));
    return;
  }

  /*
    Остальные API и объектные базы не кладём в общий CacheStorage.
    Данные объектов хранятся в IndexedDB с object+access scope.
  */
  if(
    url.pathname.startsWith('/api/') ||
    url.pathname.startsWith('/db/') ||
    url.pathname === '/health'
  ) {
    return;
  }

  if(e.request.mode === 'navigate') {
    var fallbackPath = (url.pathname === '/' || url.pathname === '/gate.html')
      ? '/gate.html'
      : '/index_v2.html';

    var network = fetch(e.request.clone()).then(function(res) {
      if(res && res.ok) {
        var copy=res.clone();
        caches.open(CACHE_NAME).then(function(cache) {
          var key=(url.pathname === '/') ? '/gate.html' : e.request;
          cache.put(key,copy).catch(function(){});
        });
      }
      return res;
    });

    var timeout = new Promise(function(resolve) {
      setTimeout(function(){ resolve(null); }, 3000);
    });

    e.respondWith(
      Promise.race([network,timeout]).then(function(res) {
        if(res) return res;
        return cachedShell(e.request,fallbackPath).then(function(hit) {
          if(hit) return hit;
          return network;
        });
      }).catch(function() {
        return cachedShell(e.request,fallbackPath).then(function(hit) {
          return hit || new Response(
            '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><body style="background:#04080f;color:#eef4ff;font-family:sans-serif;padding:40px;text-align:center"><h2>Офлайн-копия ещё не подготовлена</h2><p>Откройте сайт один раз с интернетом.</p></body>',
            {status:200,headers:{'Content-Type':'text/html; charset=utf-8'}}
          );
        });
      })
    );
    return;
  }

  var otherNetwork = fetch(e.request.clone()).then(function(res) {
    if(res && res.ok) {
      var copy=res.clone();
      caches.open(CACHE_NAME).then(function(cache){
        cache.put(e.request,copy).catch(function(){});
      });
    }
    return res;
  });

  e.respondWith(
    otherNetwork.catch(function() {
      return cachedShell(e.request).then(function(hit) {
        return hit || new Response('Offline',{status:503});
      });
    })
  );
});
''', encoding="utf-8")

# ------------------------------------------------------------------
# index.html больше не должен содержать старую single-object offline логику.
# Это запасной URL, который всегда ведёт в единый gate.
# ------------------------------------------------------------------
idx = site / "index.html"
idx.write_text(r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex">
<title>СМК · Статистика сварщиков</title>
<style>
html,body{height:100%;margin:0;background:#04080f;color:#eef4ff;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif}
body{display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;box-sizing:border-box}
a{color:#6ab3ff}
</style>
</head>
<body>
<div>Открываю сайт…<br><small><a href="/gate.html">Продолжить</a></small></div>
<script>
(function(){
  var q=location.search||"";
  var h=location.hash||"";
  location.replace('/gate.html'+q+h);
})();
</script>
</body>
</html>
''', encoding="utf-8")

# ------------------------------------------------------------------
# multiobject: если прямой заход в index_v2 попал офлайн, synthetic
# /api/session должен перевести страницу в тот же offline state, что gate.
# ------------------------------------------------------------------
mo = site / "multiobject.js"
s = mo.read_text(encoding="utf-8")
old = '''    var s=await apiJson("/api/session",{timeoutMs:10000});
    multiSetAccessScope(s);
    if(!s.authenticated){multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();return;}'''
new = '''    var s=await apiJson("/api/session",{timeoutMs:10000});
    if(s&&s.offline===true){
      var _off=multiOfflineApi();
      if(_off)_off.setForce(true);
      _isOnline=false;if(typeof _updateOnlineStatus==="function")_updateOnlineStatus();
      multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();
      setLoad("Офлайн-режим",100,"Введите логин и пароль для сохранённого доступа");
      return;
    }
    multiSetAccessScope(s);
    if(!s.authenticated){multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();return;}'''
if old in s:
    s=s.replace(old,new,1)
elif 's&&s.offline===true' not in s:
    raise SystemExit("multiobject.js: tryRestoreSession pattern not found")
mo.write_text(s,encoding="utf-8")

# ------------------------------------------------------------------
# Keep shell cache version synchronized with sw.js.
# ------------------------------------------------------------------
iv2 = site / "index_v2.html"
s = iv2.read_text(encoding="utf-8")
if 'statv2-pwa-v12' in s:
    s=s.replace('statv2-pwa-v12','statv2-pwa-v13')
elif 'statv2-pwa-v13' not in s:
    raise SystemExit("index_v2.html: expected PWA cache marker not found")
iv2.write_text(s,encoding="utf-8")

# Version markers only; V26.1 profiles remain backward-compatible.
off = site / "offline_v261.js"
s = off.read_text(encoding="utf-8")
s=s.replace('/* STATV2 OFFLINE MULTIOBJECT V26.1','/* STATV2 OFFLINE MULTIOBJECT V26.2',1)
s=s.replace('version:261,','version:262,')
s=s.replace('version:261,','version:262,')
off.write_text(s,encoding="utf-8")
PY

echo
echo "===== STATIC CHECKS ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2')
checks={
 'SW v13': "statv2-pwa-v13" in (p/'sw.js').read_text(),
 'SW offline session': "offlineSessionResponse" in (p/'sw.js').read_text(),
 'Gate uses api/session': 'fetch("/api/session?gate="' in (p/'gate.html').read_text(),
 'Gate no SW wait': 'checkConnection();' in (p/'gate.html').read_text(),
 'Index redirects gate': "location.replace('/gate.html'" in (p/'index.html').read_text(),
 'Direct offline session handling': 's&&s.offline===true' in (p/'multiobject.js').read_text(),
 'Index shell v13': 'statv2-pwa-v13' in (p/'index_v2.html').read_text(),
}
for k,v in checks.items(): print(f"{k}: {'OK' if v else 'FAIL'}")
if not all(checks.values()): raise SystemExit(1)
PY

if command -v node >/dev/null 2>&1; then
  echo
  echo "===== JS SYNTAX ====="
  node --check "$SITE/sw.js"
  node --check "$SITE/offline_v261.js"
  node --check "$SITE/multiobject.js"
  echo "JS syntax: OK"
else
  echo "Node отсутствует на сервере — JS syntax check пропущен (статические проверки выполнены)."
fi

echo
echo "===== HTTP HEALTH ====="
curl -fsS http://127.0.0.1:5088/health || true
echo

echo "====================================================="
echo "STATV2 V26.2 OFFLINE OLD-LOGIC ADAPTATION УСТАНОВЛЕН"
echo "====================================================="
echo "  • gate снова проверяет /api/session, как старый рабочий сайт"
echo "  • Service Worker сам возвращает offline:true при недоступном сервере"
echo "  • бесконечного ожидания сети быть не должно"
echo "  • общий SW-cache НЕ хранит /db и остальные /api"
echo "  • объектные/ролевые DB-кэши остаются в IndexedDB"
echo "  • мультиобъектные offline-профили и PBKDF2 сохранены"
echo "  • старый single-object index.html удалён из offline-цепочки"
echo "Backup: $BACKUP"
echo "====================================================="
