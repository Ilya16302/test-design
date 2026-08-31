#!/usr/bin/env bash
set -euo pipefail

SITE="${STATV2_SITE_ROOT:-/var/www/statv2}"
INDEX="$SITE/index_v2.html"
MULTI="$SITE/multiobject.js"
OFFLINE="$SITE/offline_v261.js"
SW="$SITE/sw.js"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_v26_4_${STAMP}.tar.gz"

for f in "$INDEX" "$MULTI" "$OFFLINE" "$SW"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "===== V26.4 BACKUP ====="
if [ "$SITE" = "/var/www/statv2" ]; then
  tar -czf "$BACKUP" -C "$SITE" index_v2.html multiobject.js offline_v261.js sw.js gate.html index.html 2>/dev/null || \
  tar -czf "$BACKUP" -C "$SITE" index_v2.html multiobject.js offline_v261.js sw.js
  echo "Backup: $BACKUP"
else
  BACKUP="$SITE/.v26_4_test_backup_${STAMP}.tar.gz"
  tar -czf "$BACKUP" -C "$SITE" index_v2.html multiobject.js offline_v261.js sw.js
  echo "Test backup: $BACKUP"
fi

echo "===== PATCH ====="
python3 - "$INDEX" "$MULTI" "$OFFLINE" "$SW" <<'PY'
from pathlib import Path
import re, sys

index = Path(sys.argv[1])
multi = Path(sys.argv[2])
offline = Path(sys.argv[3])
sw = Path(sys.argv[4])

# ------------------------------------------------------------------
# 1) index_v2.html: remove obsolete single-object offline login body.
#    If multiobject.js ever fails to load, show a clear error instead of
#    crashing on removed _checkOfflineCredential/_saveOfflineCredential.
# ------------------------------------------------------------------
s = index.read_text(encoding='utf-8')
start = s.find('async function doLogin(){', s.find('async function doLoginGuarded'))
end_marker = '\n\n/* ADMIN WELDER HEADER BACK START */'
end = s.find(end_marker, start) if start >= 0 else -1
fallback = '''async function doLogin(){
  /* STATV2 V26.4: fail-safe only. The real multi-object doLogin is loaded
     later from /multiobject.js and replaces this function. */
  revealLoginFields();
  var msg=$("loginMsg");
  if(msg)msg.innerHTML='<span class="error">Модуль входа не загрузился. Подключитесь к интернету и обновите страницу.</span>';
}'''
if start >= 0 and end >= 0:
    block = s[start:end]
    if '_checkOfflineCredential' in block or '_saveOfflineCredential' in block or 'doLogin: trying apiJson' in block:
        s = s[:start] + fallback + s[end:]
elif 'STATV2 V26.4: fail-safe only' not in s:
    raise SystemExit('index_v2.html: legacy doLogin block not found')

# Force a fresh browser/SW script generation.
s = re.sub(r'<script src="/offline_v261\.js\?v=[^"]+"></script>',
           '<script src="/offline_v261.js?v=20260831-264"></script>', s, count=1)
s = re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>',
           '<script src="/multiobject.js?v=20260831-264"></script>', s, count=1)
index.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 2) offline_v261.js: once a password verifier has been created, allow
#    an authenticated ONLINE session restore to refresh manifest/paths
#    without asking for the password again.
# ------------------------------------------------------------------
s = offline.read_text(encoding='utf-8')
s = s.replace('/* STATV2 OFFLINE MULTIOBJECT V26.2', '/* STATV2 OFFLINE MULTIOBJECT V26.4', 1)

old_guard = "if(!data||!pendingCredential)return {ok:false,reason:'no credential'};"
new_guard = "if(!data)return {ok:false,reason:'no data'};"
if old_guard in s:
    s = s.replace(old_guard, new_guard, 1)
elif new_guard not in s:
    raise SystemExit('offline_v261.js: remember guard anchor not found')

old_cred = '''      var cred=await newCredential(pendingCredential.login,pendingCredential.password);
      profile.credentials=profile.credentials.filter(function(c){return normLogin(c.login)!==normLogin(cred.login)});
      profile.credentials.push(cred);
      if(profile.credentials.length>6)profile.credentials=profile.credentials.slice(-6);

      var r=await readiness(profile);'''
new_cred = '''      /* V26.4: a fresh manual login creates/updates the verifier. If the
         browser restored an already authenticated server session, keep the
         existing verifier and only refresh object manifest/cache metadata. */
      if(pendingCredential){
        var cred=await newCredential(pendingCredential.login,pendingCredential.password);
        profile.credentials=profile.credentials.filter(function(c){return normLogin(c.login)!==normLogin(cred.login)});
        profile.credentials.push(cred);
        if(profile.credentials.length>6)profile.credentials=profile.credentials.slice(-6);
      }else if(!profile.credentials.length){
        return {ok:false,reason:'no existing credential'};
      }

      var r=await readiness(profile);'''
if old_cred in s:
    s = s.replace(old_cred, new_cred, 1)
elif 'V26.4: a fresh manual login creates/updates the verifier' not in s:
    raise SystemExit('offline_v261.js: credential block anchor not found')

# Stored profile/API version marker; keep key/API name for backward compatibility.
s = s.replace('version:262,\n        profile_id:key,', 'version:264,\n        profile_id:key,', 1)
s = s.replace('version:262,\n    setPending:setPending,', 'version:264,\n    setPending:setPending,', 1)
offline.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 3) multiobject.js: after cookie/session restoration and a successful DB
#    load, refresh an existing offline profile. This is what removes the
#    need to logout/login every time the DB manifest changes.
# ------------------------------------------------------------------
s = multi.read_text(encoding='utf-8')

old_admin = '''      currentRole="admin";await loadDb();await ensureAdminDbLoaded();enterAdmin();return;'''
new_admin = '''      currentRole="admin";await loadDb();await ensureAdminDbLoaded();
      await multiRememberOfflineProfile(s);
      enterAdmin();return;'''
if old_admin in s:
    s = s.replace(old_admin, new_admin, 1)
elif 'await multiRememberOfflineProfile(s);\n      enterAdmin();return;' not in s:
    raise SystemExit('multiobject.js: restored admin anchor not found')

old_welder = '''      var w=await ensureWelderShardLoaded({id:s.welder_id,shard:s.shard});currentWelder=w;openWelder(w,false);return;'''
new_welder = '''      var w=await ensureWelderShardLoaded({id:s.welder_id,shard:s.shard});currentWelder=w;
      await multiRememberOfflineProfile(s);
      openWelder(w,false);return;'''
if old_welder in s:
    s = s.replace(old_welder, new_welder, 1)
elif 'await multiRememberOfflineProfile(s);\n      openWelder(w,false);return;' not in s:
    raise SystemExit('multiobject.js: restored welder anchor not found')

# Preserve brigadier context on restored contractor sessions too.
old_filters = 'adminAccountFilterValue=s.account_filter_value||"";currentSpkContractorId=s.spk_contractor_id||"";'
new_filters = 'adminAccountFilterValue=s.account_filter_value||"";currentSpkContractorId=s.spk_contractor_id||"";currentSpkBrigadierFilter=s.spk_brigadier_filter||"";'
if old_filters in s:
    s = s.replace(old_filters, new_filters, 1)

# Update diagnostic text only; behavior lives in offline module.
s = s.replace('V26.1 offline copy incomplete', 'V26.4 offline copy incomplete')
s = s.replace('V26.1 offline remember', 'V26.4 offline remember')
multi.write_text(s, encoding='utf-8')

# ------------------------------------------------------------------
# 4) Service Worker: new cache generation + atomic critical shell precache.
#    Previously a missing multiobject.js was silently ignored, allowing an
#    "offline-ready" page to open with only the obsolete inline login code.
# ------------------------------------------------------------------
s = sw.read_text(encoding='utf-8')
s = s.replace('/* STATV2 PWA V26.2', '/* STATV2 PWA V26.4', 1)
s = re.sub(r"const CACHE_NAME = 'statv2-pwa-v\d+';", "const CACHE_NAME = 'statv2-pwa-v14';", s, count=1)

old_precache = '''const PRECACHE = [
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
});'''
new_precache = '''const CRITICAL_PRECACHE = [
  '/gate.html',
  '/index_v2.html',
  '/offline_v261.js',
  '/multiobject.js'
];
const OPTIONAL_PRECACHE = [
  '/index.html',
  '/object_media_v12.js',
  '/admin_v13.js',
  '/admin_v14.js'
];

self.addEventListener('install', function(e) {
  e.waitUntil(
    caches.open(CACHE_NAME).then(async function(cache) {
      /* V26.4: critical offline shell is all-or-nothing. Never activate a
         Service Worker that cached index_v2 but lost multiobject.js. */
      await cache.addAll(CRITICAL_PRECACHE.map(function(url){
        return new Request(url,{cache:'reload'});
      }));
      await Promise.all(OPTIONAL_PRECACHE.map(function(url) {
        return cache.add(new Request(url,{cache:'reload'})).catch(function(err) {
          console.warn('optional precache failed:',url,err);
          return null;
        });
      }));
    })
  );
  self.skipWaiting();
});'''
if old_precache in s:
    s = s.replace(old_precache, new_precache, 1)
elif 'const CRITICAL_PRECACHE' not in s:
    raise SystemExit('sw.js: precache block anchor not found')
sw.write_text(s, encoding='utf-8')
PY

echo "===== STATIC CHECKS ====="
grep -n 'STATV2 V26.4: fail-safe only' "$INDEX"
if grep -nE '_checkOfflineCredential|_saveOfflineCredential' "$INDEX"; then
  echo "ERROR: obsolete offline credential references still exist in index_v2.html"
  exit 1
else
  echo "Legacy undefined credential refs: 0"
fi
grep -n 'V26.4: a fresh manual login' "$OFFLINE"
grep -n 'multiRememberOfflineProfile(s)' "$MULTI"
grep -n "statv2-pwa-v14" "$SW"
grep -n 'CRITICAL_PRECACHE' "$SW"

# Browser JS parse checks when node is available (not required on server).
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
echo "STATV2 V26.4 OFFLINE PERSISTENCE + IOS SHELL FIX УСТАНОВЛЕН"
echo "  • повторный logout/login перед офлайном больше не требуется после первой подготовки"
echo "  • online session restore обновляет manifest офлайн-профиля без знания пароля"
echo "  • старые _checkOfflineCredential/_saveOfflineCredential удалены из index_v2"
echo "  • critical PWA shell кэшируется атомарно"
echo "  • PWA cache: statv2-pwa-v14"
echo "Backup: $BACKUP"
