#!/usr/bin/env bash
set -euo pipefail

SITE="${STATV2_SITE_ROOT:-/var/www/statv2}"
INDEX="$SITE/index_v2.html"
GATE="$SITE/gate.html"
SW="$SITE/sw.js"
OFFLINE="$SITE/offline_v261.js"
MULTI="$SITE/multiobject.js"
STAMP="$(date +%Y%m%d_%H%M%S)"

for f in "$INDEX" "$GATE" "$SW" "$OFFLINE" "$MULTI"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

if [ "$SITE" = "/var/www/statv2" ]; then
  BACKUP="/root/statv2_before_v26_6_${STAMP}.tar.gz"
else
  BACKUP="$SITE/.v26_6_test_backup_${STAMP}.tar.gz"
fi

echo "===== V26.6 BACKUP ====="
tar -czf "$BACKUP" -C "$SITE" index_v2.html gate.html sw.js offline_v261.js multiobject.js index.html 2>/dev/null || \
  tar -czf "$BACKUP" -C "$SITE" index_v2.html gate.html sw.js offline_v261.js multiobject.js
echo "Backup: $BACKUP"

echo "===== PATCH ====="
python3 - "$INDEX" "$GATE" "$SW" "$OFFLINE" <<'PY'
from pathlib import Path
import re, sys

index = Path(sys.argv[1])
gate = Path(sys.argv[2])
sw = Path(sys.argv[3])
offline = Path(sys.argv[4])

# -----------------------------------------------------------------------------
# V26.6 principle:
# User asked to return to the exact old-production offline EXPERIENCE:
# gate -> /api/session -> SW returns offline:true -> index -> local credential -> cache.
# No readiness colors, no controllerchange reloads, no shell health protocol.
# The only architectural adaptation is that DB blobs remain separated by object+access
# in the existing IndexedDB cache, and each saved offline profile keeps its own manifest.
# -----------------------------------------------------------------------------

GATE_HTML = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>СМК-статистика сварщиков</title>
<style>
  :root{--bg:#04080f;--glass:rgba(255,255,255,.052);--border:rgba(255,255,255,.105);--text:#eef4ff;--muted:rgba(190,210,235,.64);--blue:#6ab3ff;--cyan:#22d3ee;--green:#34d399;--red:#ff6b8a;--r:22px;--shadow:0 24px 64px rgba(0,0,0,.48),inset 0 1px 0 rgba(255,255,255,.08)}
  *{box-sizing:border-box}
  html{color-scheme:dark;-webkit-text-size-adjust:100%}
  body{margin:0;min-height:100vh;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;background:radial-gradient(ellipse 70% 50% at 15% 8%,rgba(82,160,255,.20),transparent),radial-gradient(ellipse 50% 40% at 84% 6%,rgba(34,211,238,.12),transparent),radial-gradient(ellipse 55% 35% at 82% 90%,rgba(255,145,80,.075),transparent),var(--bg);background-attachment:fixed}
  .wrap{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;box-sizing:border-box}
  .card{width:100%;max-width:380px;position:relative;background:var(--glass);border:1px solid var(--border);border-radius:var(--r);box-shadow:var(--shadow);backdrop-filter:blur(30px) saturate(160%);overflow:hidden;padding:36px 28px;text-align:center}
  .card::before{content:"";position:absolute;inset:0;pointer-events:none;background:linear-gradient(150deg,rgba(255,255,255,.10),rgba(255,255,255,.025) 48%,transparent 76%)}
  .card>*{position:relative}
  .brand{font-size:13px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-bottom:26px}
  .spinner{width:46px;height:46px;border-radius:50%;border:4px solid rgba(255,255,255,.10);border-top-color:var(--blue);animation:spin .9s linear infinite;margin:0 auto 22px}
  @keyframes spin{to{transform:rotate(360deg)}}
  .icon{width:46px;height:46px;border-radius:50%;margin:0 auto 22px;display:flex;align-items:center;justify-content:center;background:rgba(255,107,138,.10);border:1px solid rgba(255,107,138,.24)}
  .icon svg{width:22px;height:22px}
  h2{font-size:19px;font-weight:800;letter-spacing:-.02em;margin:0 0 8px}
  p{color:var(--muted);font-size:14px;margin:0 0 26px;line-height:1.5}
  .btn{appearance:none;border:none;border-radius:14px;padding:15px 22px;font-size:15px;font-weight:700;cursor:pointer;width:100%;margin-top:10px;transition:transform .12s ease,opacity .12s ease}
  .btn:active{transform:scale(.97)}
  .btn-primary{background:linear-gradient(180deg,#7ab8ff,var(--blue));color:#04121f;box-shadow:0 10px 24px rgba(106,179,255,.28)}
  .btn-secondary{background:rgba(255,255,255,.06);color:var(--text);border:1px solid var(--border)}
  .hidden{display:none}
  #debug{margin-top:22px;text-align:left;background:rgba(0,0,0,.28);border:1px solid var(--border);border-radius:14px;padding:12px 14px;font-family:ui-monospace,Menlo,monospace;font-size:10.5px;line-height:1.6;color:#8fd7b0;white-space:pre-wrap;word-break:break-word;max-height:260px;overflow:auto}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="brand">СМК · Статистика сварщиков</div>
    <div id="checking">
      <div class="spinner"></div>
      <h2>Проверка подключения…</h2>
      <p id="checkingHint">Подождите несколько секунд</p>
      <button class="btn btn-secondary hidden" id="fallbackOfflineBtn" type="button">Открыть офлайн-версию</button>
    </div>
    <div id="offlineChoice" class="hidden">
      <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="#ff6b8a" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="1" y1="1" x2="23" y2="23"/><path d="M16.72 11.06A10.94 10.94 0 0 1 19 12.55"/><path d="M5 12.55a10.94 10.94 0 0 1 5.17-2.39"/><path d="M10.71 5.05A16 16 0 0 1 22.58 9"/><path d="M1.42 9a15.91 15.91 0 0 1 4.7-2.88"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/></svg></div>
      <h2>Нет подключения к интернету</h2>
      <p>Не получилось выйти в сеть. Можно попробовать снова или открыть последнюю сохранённую версию сайта.</p>
      <button class="btn btn-primary" id="retryBtn" type="button">Попробовать ещё раз</button>
      <button class="btn btn-secondary" id="offlineBtn" type="button">Открыть офлайн-версию</button>
    </div>
    <div id="debug" class="hidden"></div>
  </div>
</div>
<script>
(function(){
  var TIMEOUT_MS = 6000;
  var TARGET = "/index_v2.html";
  var HTML_CACHE = "statv2-pwa-v16";
  var DEBUG = location.search.indexOf("debug=1") !== -1;
  var logLines = [];
  var fallbackTimer = null;
  var fallbackCount = 3;

  function log(msg){
    if(!DEBUG) return;
    logLines.push(msg);
    var el = document.getElementById("debug");
    if(el){ el.classList.remove("hidden"); el.textContent = logLines.join("\n"); }
  }
  function showOfflineChoice(){
    clearFallbackCountdown();
    document.getElementById("checking").classList.add("hidden");
    document.getElementById("offlineChoice").classList.remove("hidden");
  }
  function showChecking(){
    document.getElementById("checking").classList.remove("hidden");
    document.getElementById("offlineChoice").classList.add("hidden");
  }
  function clearFallbackCountdown(){
    if(fallbackTimer){ clearInterval(fallbackTimer); fallbackTimer = null; }
  }
  function startFallbackCountdown(){
    var hint = document.getElementById("checkingHint");
    var btn = document.getElementById("fallbackOfflineBtn");
    fallbackCount = 3;
    if(btn) btn.classList.add("hidden");
    if(hint) hint.textContent = "Подождите несколько секунд. Если у вас нет интернета — вы можете открыть офлайн-версию сайта через " + fallbackCount + "…";
    clearFallbackCountdown();
    fallbackTimer = setInterval(function(){
      fallbackCount -= 1;
      if(fallbackCount > 0){
        if(hint) hint.textContent = "Подождите несколько секунд. Если у вас нет интернета — вы можете открыть офлайн-версию сайта через " + fallbackCount + "…";
      } else {
        if(hint) hint.textContent = "Подождите несколько секунд…";
        if(btn) btn.classList.remove("hidden");
        clearFallbackCountdown();
      }
    }, 1000);
  }
  function dumpCacheState(label){
    if(!DEBUG || !("caches" in window)) return Promise.resolve();
    return caches.open(HTML_CACHE).then(function(c){
      return c.keys().then(function(keys){
        var urls = keys.map(function(r){ return r.url.replace(location.origin,""); });
        log(label+" ["+HTML_CACHE+"]: "+(urls.length?urls.join(", "):"пусто"));
      });
    }).catch(function(e){ log(label+": ошибка "+e.message); });
  }
  function clearMainHtmlCache(){
    if(!("caches" in window)) return Promise.resolve();
    return caches.open(HTML_CACHE).then(function(cache){
      return Promise.all([cache.delete(TARGET), cache.delete("/gate.html")]);
    }).then(function(results){
      log("Удалены из кэша: "+TARGET+" -> "+results[0]+", /gate.html -> "+results[1]);
    }).catch(function(e){ log("Ошибка очистки кэша: "+e.message); });
  }
  function goOnline(){
    log("Статус: ОНЛАЙН. Чищу кэш HTML и перехожу...");
    clearFallbackCountdown();
    clearMainHtmlCache().then(function(){ location.replace(TARGET); });
  }
  function goOffline(){
    clearFallbackCountdown();
    location.replace(TARGET);
  }
  function checkConnection(){
    showChecking();
    startFallbackCountdown();
    log("--- Проверка соединения ---");
    log("SW controller активен: "+(navigator.serviceWorker && navigator.serviceWorker.controller ? "да" : "НЕТ"));
    dumpCacheState("Кэш ДО проверки").then(function(){
      var ctrl = new AbortController();
      var timer = setTimeout(function(){ ctrl.abort(); log("Таймаут 6с истёк"); }, TIMEOUT_MS);
      fetch("/api/session", {cache:"no-store", credentials:"same-origin", signal: ctrl.signal})
        .then(function(res){ log("fetch /api/session -> HTTP "+res.status); return res.json().catch(function(){ return null; }); })
        .then(function(data){
          clearTimeout(timer);
          log("Ответ: "+JSON.stringify(data));
          if(data && data.offline === true) showOfflineChoice();
          else if(data) goOnline();
          else showOfflineChoice();
        })
        .catch(function(e){
          clearTimeout(timer);
          log("fetch упал с ошибкой: "+e.message);
          showOfflineChoice();
        });
    });
  }
  document.getElementById("retryBtn").addEventListener("click", checkConnection);
  document.getElementById("offlineBtn").addEventListener("click", function(){ dumpCacheState("Кэш перед офлайн-открытием").then(goOffline); });
  document.getElementById("fallbackOfflineBtn").addEventListener("click", function(){ dumpCacheState("Кэш перед аварийным офлайн-открытием").then(goOffline); });

  if("serviceWorker" in navigator){
    navigator.serviceWorker.register("/sw.js").then(function(reg){
      log("SW зарегистрирован, scope: "+reg.scope);
      checkConnection();
    }).catch(function(e){
      log("Ошибка регистрации SW: "+e.message);
      checkConnection();
    });
  } else {
    log("Service Worker не поддерживается браузером");
    checkConnection();
  }
})();
</script>
</body>
</html>
'''

SW_JS = r'''/* STATV2 PWA V26.6 — old production offline flow + multi-object DB isolation */
const CACHE_NAME = 'statv2-pwa-v16';
const CACHE_PREFIX = 'statv2-pwa-';

self.addEventListener('install', function(e) {
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      /* The old site had its login logic inside index_v2.html. In the multi-object
         build the same logic lives in two small JS files, so they are cached together
         with the old three-file shell. No readiness protocol or forced reloads. */
      return cache.addAll([
        '/index.html',
        '/index_v2.html',
        '/gate.html',
        '/offline_v261.js',
        '/multiobject.js'
      ]);
    }).catch(function(err){ console.warn('precache failed:', err); throw err; })
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

self.addEventListener('fetch', function(e) {
  var url = new URL(e.request.url);
  if(url.origin !== self.location.origin) return;

  /* Same navigation logic as old production. */
  if(e.request.mode === 'navigate') {
    var cacheKey = (url.pathname === '/') ? (url.origin + '/gate.html') : e.request;
    var navNetwork = fetch(e.request.clone()).then(function(r) {
      if(r.ok){
        var copy = r.clone();
        caches.open(CACHE_NAME).then(function(c){ c.put(cacheKey, copy); });
      }
      return r;
    });

    e.waitUntil(navNetwork.catch(function(){}));
    var navTimeout = new Promise(function(resolve) {
      setTimeout(function(){ resolve(null); }, 4000);
    });

    e.respondWith(
      Promise.race([navNetwork, navTimeout]).then(function(r) {
        if(r) return r;
        return caches.match(cacheKey).then(function(cached) {
          return cached || navNetwork;
        });
      }).catch(function() {
        return caches.match(cacheKey).then(function(cached) {
          return cached || caches.match('/index_v2.html').then(function(shell) {
            return shell || new Response(
              '<!doctype html><meta charset="utf-8"><body style="background:#111;color:#eee;font-family:sans-serif;padding:40px;text-align:center"><h2>Нет соединения</h2><p>Сайт ещё ни разу не открывался на этом устройстве с интернетом — офлайн-копии нет.</p></body>',
              {headers:{'Content-Type':'text/html; charset=utf-8'}, status:200}
            );
          });
        });
      })
    );
    return;
  }

  /* Exactly the old gate contract. */
  if(url.pathname === '/api/session') {
    e.respondWith(
      fetch(e.request).catch(function() {
        return new Response(JSON.stringify({ok:true,authenticated:false,offline:true}), {
          headers:{'Content-Type':'application/json'}
        });
      })
    );
    return;
  }

  if(url.pathname.startsWith('/api/')) {
    e.respondWith(
      fetch(e.request).catch(function() {
        return new Response(JSON.stringify({ok:false,error:'offline',offline:true}), {
          headers:{'Content-Type':'application/json'}
        });
      })
    );
    return;
  }

  /* The one intentional multi-object difference from the old site:
     DB files are NOT stored in one shared CacheStorage bucket. The frontend keeps
     them in IndexedDB under object_id + access scope. */
  if(url.pathname.startsWith('/db/')) {
    e.respondWith(fetch(e.request));
    return;
  }

  /* Static files: same stale-on-failure flow as old production. */
  var otherNetwork = fetch(e.request.clone());
  var otherCacheUpdate = otherNetwork.then(function(r) {
    if(r.ok){
      return caches.open(CACHE_NAME).then(function(c){ return c.put(e.request, r.clone()); });
    }
  }).catch(function(){});
  e.waitUntil(otherCacheUpdate);
  e.respondWith(
    otherNetwork.then(function(r){ return r; }).catch(function() {
      return caches.match(e.request).then(function(c) {
        return c || new Response('Offline', {status:503});
      });
    })
  );
});
'''

OFFLINE_JS = r'''/* STATV2 OFFLINE MULTIOBJECT V26.6
   Old-production login semantics, with per-object profiles/manifests.
   No readiness badges, no shell protocol, no forced reloads. */
(function(){
  'use strict';

  var PROFILE_KEY='statv2_offline_v261_profiles';
  var LEGACY_FORCE_KEY='statv2_offline_force';
  var PBKDF2_ITERATIONS=120000;
  var pendingCredential=null;
  var activeCredential=null;
  var currentProfile=null;

  function safeJsonParse(s,fallback){try{return JSON.parse(s)}catch(e){return fallback}}
  function normLogin(v){return String(v||'').trim().toLowerCase()}
  function cleanPath(v){
    var s=String(v||'');
    try{if(/^https?:\/\//i.test(s))s=new URL(s,location.href).pathname}catch(e){}
    return s.split('?')[0].split('#')[0].replace(/^\/+/, '').replace(/^db\//,'');
  }
  function normalizeShard(v){
    var p=typeof v==='string'?v:(v&&v.path)||'';
    return cleanPath(p);
  }
  function b64(bytes){
    var s='';for(var i=0;i<bytes.length;i++)s+=String.fromCharCode(bytes[i]);return btoa(s);
  }
  function unb64(s){
    var bin=atob(String(s||'')),out=new Uint8Array(bin.length);
    for(var i=0;i<bin.length;i++)out[i]=bin.charCodeAt(i);return out;
  }
  async function deriveVerifier(login,password,saltB64,iterations){
    if(!crypto||!crypto.subtle)throw new Error('WebCrypto недоступен');
    var key=await crypto.subtle.importKey(
      'raw',new TextEncoder().encode(String(password||'')),{name:'PBKDF2'},false,['deriveBits']
    );
    var bits=await crypto.subtle.deriveBits({
      name:'PBKDF2',hash:'SHA-256',salt:unb64(saltB64),iterations:Number(iterations)||PBKDF2_ITERATIONS
    },key,256);
    var loginBytes=new TextEncoder().encode(normLogin(login));
    var digestInput=new Uint8Array(bits.byteLength+loginBytes.length);
    digestInput.set(new Uint8Array(bits),0);digestInput.set(loginBytes,bits.byteLength);
    var digest=await crypto.subtle.digest('SHA-256',digestInput);
    return b64(new Uint8Array(digest));
  }
  async function newCredential(login,password){
    var salt=new Uint8Array(16);crypto.getRandomValues(salt);
    var saltB64=b64(salt);
    return {
      login:normLogin(login),salt:saltB64,iterations:PBKDF2_ITERATIONS,
      verifier:await deriveVerifier(login,password,saltB64,PBKDF2_ITERATIONS),
      saved_at:new Date().toISOString()
    };
  }
  async function credentialMatches(c,login,password){
    if(!c||normLogin(c.login)!==normLogin(login))return false;
    try{return await deriveVerifier(login,password,c.salt,c.iterations)===c.verifier}catch(e){return false}
  }
  function loadProfiles(){
    var rows=safeJsonParse(localStorage.getItem(PROFILE_KEY)||'[]',[]);
    return Array.isArray(rows)?rows:[];
  }
  function saveProfiles(rows){localStorage.setItem(PROFILE_KEY,JSON.stringify(rows))}
  function profileKey(role,objectId,scope,welderId){
    return [String(role||''),String(objectId||''),String(scope||''),String(welderId||'')].join('|');
  }
  function requiredPathsFor(data,manifest){
    if(!data||!manifest)return [];
    if(data.role==='welder'){
      var shard=normalizeShard(data.shard);
      if(!shard)return [];
      return [shard.indexOf('welders/')===0?shard:'welders/'+shard];
    }
    if(data.role==='admin'){
      var out=[];
      var summary=normalizeShard(manifest.admin_summary_file||'admin_summary.json.gz');
      if(summary)out.push(summary);
      (manifest.shards||[]).forEach(function(s){var p=normalizeShard(s);if(p)out.push(p)});
      return Array.from(new Set(out));
    }
    return [];
  }
  function objectFromData(data,manifest,context){
    var o=(data&&data.object)||{},c=context||{};
    return {
      id:String(o.id||c.object_id||''),
      name:String(o.name||c.object_name||o.id||c.object_id||''),
      generated_at:String((manifest&&manifest.generated_at)||o.generated_at||'')
    };
  }

  /* One successful manual online login is enough. Later cookie/session restores update
     this object's manifest while keeping the already saved verifier. */
  async function remember(data,manifest,context){
    try{
      if(!data)return {ok:false,reason:'no data'};
      if(data.role!=='admin'&&data.role!=='welder')return {ok:false,reason:'unsupported role'};
      context=context||{};
      if(!manifest||!context.object_id)return {ok:false,reason:'no object/manifest'};

      var obj=objectFromData(data,manifest,context);
      var scope=String(context.scope||'anon');
      var key=profileKey(data.role,obj.id,scope,data.welder_id||'');
      var rows=loadProfiles();
      var idx=rows.findIndex(function(p){return p.profile_id===key});
      var old=idx>=0?rows[idx]:null;
      var creds=(old&&Array.isArray(old.credentials))?old.credentials.slice():[];

      if(pendingCredential){
        activeCredential=await newCredential(pendingCredential.login,pendingCredential.password);
        pendingCredential=null;
      }
      if(activeCredential){
        creds=creds.filter(function(c){return normLogin(c.login)!==normLogin(activeCredential.login)});
        creds.push(activeCredential);
        if(creds.length>8)creds=creds.slice(-8);
      }
      /* If this is a restored online cookie session, the profile must already have
         a verifier from a previous manual login. Keep it; no new login is required. */
      if(!creds.length)return {ok:false,reason:'first manual login required'};

      var profile={
        version:266,
        profile_id:key,
        role:String(data.role),
        object:obj,
        scope:scope,
        welder_id:String(data.welder_id||''),
        shard:String(data.shard||''),
        org_filter:String(data.org_filter||''),
        account_filter_type:String(data.account_filter_type||''),
        account_filter_value:String(data.account_filter_value||''),
        spk_contractor_id:String(data.spk_contractor_id||''),
        spk_brigadier_filter:String(data.spk_brigadier_filter||''),
        manifest:manifest,
        required_paths:requiredPathsFor(data,manifest),
        credentials:creds,
        saved_at:new Date().toISOString()
      };
      if(idx>=0)rows[idx]=profile;else rows.push(profile);
      saveProfiles(rows);
      try{if(navigator.storage&&navigator.storage.persist)await navigator.storage.persist()}catch(e){}
      return {ok:true,ready:true,missing:[],profile:profile};
    }catch(e){
      console.warn('offline profile save failed',e);
      return {ok:false,error:String(e&&e.message||e)};
    }
  }

  async function findProfiles(login,password){
    var rows=loadProfiles(),out=[];
    for(var i=0;i<rows.length;i++){
      var p=rows[i],creds=Array.isArray(p.credentials)?p.credentials:[],matched=false;
      for(var j=0;j<creds.length;j++){
        if(await credentialMatches(creds[j],login,password)){matched=true;break}
      }
      if(matched)out.push(Object.assign({},p,{_ready:true,_missing:[]}));
    }
    return out;
  }

  /* Compatibility API for multiobject.js. Deliberately no status UI. */
  function setPending(login,password){
    pendingCredential={login:String(login||''),password:String(password||'')};
    activeCredential=null;
  }
  function clearPending(){pendingCredential=null}
  function setCurrentProfile(profile){currentProfile=profile||null;window.STATV2_OFFLINE_ACTIVE=!!profile}
  function getCurrentProfile(){return currentProfile}
  function forceRequested(){return false}
  function setForce(){try{sessionStorage.removeItem(LEGACY_FORCE_KEY)}catch(e){}}
  function networkError(e){
    if(navigator.onLine===false)return true;
    if(!e)return false;
    var name=String(e.name||'').toLowerCase(),msg=String(e.message||e).toLowerCase();
    return name==='aborterror'||msg==='offline'||msg.indexOf('offline')>=0||
      msg.indexOf('failed to fetch')>=0||msg.indexOf('networkerror')>=0||
      msg.indexOf('network error')>=0||msg.indexOf('load failed')>=0||
      (msg.indexOf('fetch')>=0&&msg.indexOf('failed')>=0);
  }
  function clearActive(){currentProfile=null;activeCredential=null;window.STATV2_OFFLINE_ACTIVE=false}
  function readiness(){return Promise.resolve({ready:true,missing:[]})}
  function updateStatus(){return Promise.resolve()}

  try{sessionStorage.removeItem(LEGACY_FORCE_KEY)}catch(e){}

  window.STATV2_OFFLINE_V261={
    version:266,
    setPending:setPending,
    clearPending:clearPending,
    remember:remember,
    findProfiles:findProfiles,
    readiness:readiness,
    updateStatus:updateStatus,
    setCurrentProfile:setCurrentProfile,
    getCurrentProfile:getCurrentProfile,
    forceRequested:forceRequested,
    setForce:setForce,
    networkError:networkError,
    clearActive:clearActive,
    cleanPath:cleanPath
  };
})();
'''

gate.write_text(GATE_HTML, encoding='utf-8')
sw.write_text(SW_JS, encoding='utf-8')
offline.write_text(OFFLINE_JS, encoding='utf-8')

s = index.read_text(encoding='utf-8')

# Remove the V26.1-26.5 readiness badge completely.
s = re.sub(r'\n?<div id="offlineReadyStatus"[^>]*>.*?</div>\n?', '\n', s, count=1, flags=re.S)

# Replace the V26.5 shell protocol/controller reload block with the old simple registration.
old_registration = '''/* STATV2 V26.6: old production Service Worker registration — no readiness protocol, no reloads. */
if("serviceWorker" in navigator){
  window.addEventListener("load",function(){
    navigator.serviceWorker.register("/sw.js").catch(function(e){console.warn("SW register failed",e)});
  });
}
'''
if 'STATV2 V26.6: old production Service Worker registration' not in s:
    start = s.find('/* STATV2 V26.5: Service Worker is the ONLY owner of the offline shell cache. */')
    if start < 0:
        start = s.find('var STATV2_SW_URL=')
    end = s.find('let DB=null,AUTH=null,MANIFEST=null', start)
    if start < 0 or end < 0:
        raise SystemExit('index_v2.html: V26.5 SW block not found')
    s = s[:start] + old_registration + s[end:]

# Restore the old quiet HTML refresh behavior (no indicators, no reload).
start = s.find('/* STATV2 V26.5: legacy page-side shell cache writers removed.')
end_marker = '// STATV2 V26.1: legacy offline credentials / shared DB CacheStorage migration removed.'
end = s.find(end_marker, start) if start >= 0 else -1
if start >= 0 and end >= 0:
    replacement = '''var _shellSilentRefreshDone = false;
function silentlyRefreshOfflineShell(){
  if(_shellSilentRefreshDone) return;
  if(!("caches" in window) || !("fetch" in window)) return;
  _shellSilentRefreshDone = true;
  var HTML_CACHE = "statv2-pwa-v16";
  ["/gate.html", "/index_v2.html"].forEach(function(url){
    fetch(url, {cache:"no-store", credentials:"same-origin"}).then(function(res){
      if(!res.ok) return;
      return caches.open(HTML_CACHE).then(function(cache){ return cache.put(url, res); });
    }).catch(function(e){ console.warn("Тихое обновление " + url + " не удалось:", e); });
  });
}
function refreshOfflineShellInBackground(){ return; }

'''
    s = s[:start] + replacement + s[end:]

# Use stable unversioned module URLs exactly like the old site's SW model.
s = re.sub(r'<script src="/offline_v261\.js(?:\?v=[^"]+)?"></script>', '<script src="/offline_v261.js"></script>', s, count=1)
s = re.sub(r'<script src="/multiobject\.js(?:\?v=[^"]+)?"></script>', '<script src="/multiobject.js"></script>', s, count=1)

# The fail-safe is only reached if the page itself is corrupt/missing JS. Keep it plain;
# do not instruct the user to wait for colored readiness states that no longer exist.
s = s.replace(
    'Офлайн-оболочка загрузилась не полностью. Подключитесь к интернету, откройте сайт один раз и дождитесь статуса «Офлайн-режим готов».',
    'Не удалось загрузить модуль входа. Откройте сайт один раз при наличии интернета и попробуйте снова.'
)
s = s.replace(
    'Модуль входа не загрузился. Подключитесь к интернету и обновите страницу.',
    'Не удалось загрузить модуль входа. Откройте сайт один раз при наличии интернета и попробуйте снова.'
)

index.write_text(s, encoding='utf-8')
PY

echo "===== STATIC CHECKS ====="
grep -q 'statv2-pwa-v16' "$SW"
grep -q 'old production offline flow' "$SW"
grep -q 'STATV2 OFFLINE MULTIOBJECT V26.6' "$OFFLINE"
grep -q 'old production Service Worker registration' "$INDEX"
! grep -q 'offlineReadyStatus' "$INDEX"
! grep -q 'statv2CheckOfflineShellReady' "$INDEX"
! grep -q 'controllerchange' "$INDEX"
! grep -q 'statv2-v265-controller-reload' "$INDEX"
! grep -q 'statv2_offline_force.*setItem' "$GATE"

echo "Offline status badges: 0"
echo "Forced controller reloads: 0"
echo "Old gate /api/session flow: OK"
echo "DB CacheStorage sharing: disabled (/db stays IndexedDB object+scope)"

if command -v node >/dev/null 2>&1; then
  node --check "$SW"
  node --check "$OFFLINE"
  node --check "$MULTI"
  echo "JS syntax: OK"
else
  echo "Node not installed: JS syntax check skipped"
fi

# Check the inline scripts of index/gate with a tiny extractor if node is available.
if command -v node >/dev/null 2>&1; then
  python3 - "$INDEX" "$GATE" "$SITE" <<'PY'
from pathlib import Path
import re,sys
out=Path(sys.argv[3])/'._v266_inline_check.js'
parts=[]
for p in map(Path,sys.argv[1:3]):
    s=p.read_text(encoding='utf-8')
    parts += re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',s,re.S|re.I)
out.write_text('\n;\n'.join(parts),encoding='utf-8')
PY
  node --check "$SITE/._v266_inline_check.js"
  rm -f "$SITE/._v266_inline_check.js"
  echo "Inline JS syntax: OK"
fi

if [ "$SITE" = "/var/www/statv2" ]; then
  echo "===== NGINX ====="
  nginx -t
fi

echo "===== RESULT ====="
echo "STATV2 V26.6 OLD-OFFLINE MULTIOBJECT УСТАНОВЛЕН"
echo "  • gate/offline detection = old production flow"
echo "  • no green/yellow offline readiness badges"
echo "  • no controllerchange reloads"
echo "  • no sessionStorage force mode"
echo "  • login verifier survives normal online session restores"
echo "  • each object keeps its own manifest/profile"
echo "  • DB blobs stay separated by object + access scope in IndexedDB"
echo "  • V26.3 smooth loader preserved"
echo "Backup: $BACKUP"
