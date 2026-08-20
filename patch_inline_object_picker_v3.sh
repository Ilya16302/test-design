#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/statv2-uploader"
SITE_DIR="/var/www/statv2"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_inline_picker_${STAMP}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$APP_DIR/multiobject.py" \
  "$SITE_DIR/multiobject.js" \
  "$SITE_DIR/index_v2.html" \
  "$SITE_DIR/sw.js" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. PATCH BACKEND ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/statv2-uploader/multiobject.py')
s=p.read_text(encoding='utf-8')
marker='# STATV2 AUTO SINGLE OBJECT V3'
if marker not in s:
    start=s.find('    # Глобальный admin: сначала выбор объекта.')
    end=s.find('    # Управляющая учётка конкретного объекта.', start)
    if start<0 or end<0:
        raise SystemExit('Не найден блок глобального admin')
    new='''    # Глобальный admin: при одном объекте заходим сразу, при нескольких даём выбор.\n    # STATV2 AUTO SINGLE OBJECT V3\n    if hmac.compare_digest(login, GLOBAL_ADMIN_LOGIN) and hmac.compare_digest(password, GLOBAL_ADMIN_PASS):\n        candidates = _all_candidates()\n        if not candidates:\n            return core.error("Объектов пока нет", 409)\n        if len(candidates) == 1:\n            object_id = str(candidates[0].get("id") or "")\n            obj = read_registry().get("objects", {}).get(object_id)\n            if not obj:\n                return core.error("Объект не найден", 404)\n            session.clear()\n            session["login"] = GLOBAL_ADMIN_LOGIN\n            session["role"] = "admin"\n            _set_object_session(object_id)\n            _clear_pending()\n            return jsonify({\n                "ok": True,\n                "role": "admin",\n                "object": _candidate(object_id, obj),\n                "meta": core.safe_public_meta(),\n            })\n\n        session.clear()\n        session["role"] = "admin_pending"\n        session["login"] = GLOBAL_ADMIN_LOGIN\n        session["pending_type"] = "global_admin"\n        session["pending_candidates"] = [c["id"] for c in candidates]\n        return jsonify({\n            "ok": True,\n            "role": "admin_pending",\n            "needs_object_selection": True,\n            "candidates": candidates,\n        })\n\n'''
    s=s[:start]+new+s[end:]

    start=s.find('    if with_stamp:')
    end=s.find('    # Без клейма:', start)
    if start<0 or end<0:
        raise SystemExit('Не найден блок сварщика с клеймом')
    new='''    if with_stamp:\n        stamp = str(with_stamp[2].get("stamp") or "").strip().upper()\n        registry = read_registry().get("objects", {})\n        candidates = []\n        for object_id, obj in registry.items():\n            auth_db = _load_auth_for_object(object_id)\n            if _find_welder_by_stamp(auth_db, stamp):\n                candidates.append(_candidate(object_id, obj))\n        candidates.sort(key=lambda x: (str(x.get("name") or "").casefold(), x["id"]))\n\n        if not candidates:\n            return core.error("Сварщик с этим клеймом не найден ни на одном объекте", 404)\n\n        # Если клеймо присутствует ровно на одном объекте — никакого выбора.\n        if len(candidates) == 1:\n            object_id = str(candidates[0].get("id") or "")\n            obj = registry.get(object_id)\n            w = _find_welder_by_stamp(_load_auth_for_object(object_id), stamp)\n            if not obj or not w:\n                return core.error("Сварщик на объекте не найден", 404)\n            session["role"] = "welder"\n            session["welder_id"] = str(w.get("id") or "")\n            _set_object_session(object_id)\n            _clear_pending()\n            return jsonify({\n                "ok": True,\n                "role": "welder",\n                "welder_id": str(w.get("id") or ""),\n                "shard": str(w.get("shard") or ""),\n                "name": str(w.get("name") or ""),\n                "object": _candidate(object_id, obj),\n                "meta": core.safe_public_meta(),\n            })\n\n        session["role"] = "welder_pending"\n        session["pending_type"] = "welder_stamp"\n        session["pending_stamp"] = stamp\n        session["pending_candidates"] = [c["id"] for c in candidates]\n        return jsonify({\n            "ok": True,\n            "role": "welder_pending",\n            "needs_object_selection": True,\n            "welder_stamp": stamp,\n            "candidates": candidates,\n        })\n\n'''
    s=s[:start]+new+s[end:]
    p.write_text(s,encoding='utf-8')
else:
    print('Backend уже пропатчен — пропускаю')
PY

echo "===== 3. PATCH INLINE OBJECT PICKER ====="
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/statv2/multiobject.js')
s=p.read_text(encoding='utf-8')
marker='/* STATV2 INLINE OBJECT PICKER V3 */'
if marker in s:
    print('Frontend уже пропатчен — пропускаю')
    raise SystemExit(0)

start=s.find('function multiEnsureChooser(){')
end=s.find('async function multiEnterRole(data){', start)
if start<0 or end<0:
    raise SystemExit('Не найден старый multiObjectChooser')

chooser=r'''/* STATV2 INLINE OBJECT PICKER V3 */
function multiSetLoginLoadVisible(show){
  var box=document.querySelector("#loginView .load-box");
  if(box)box.style.display=show?"":"none";
}
function multiEnsureChooser(){
  var old=document.getElementById("multiObjectChooser");
  if(old)return old;
  var loginFields=$("loginFields");
  if(!loginFields)throw new Error("Не найден блок входа");
  var wrap=document.createElement("div");
  wrap.id="multiObjectChooser";
  wrap.className="login-fields collapsed";
  wrap.innerHTML=`
    <div class="login-fields-inner">
      <div style="margin:14px 0 10px;">
        <div class="muted" style="font-size:11px;font-weight:800;text-transform:uppercase;letter-spacing:.1em;">Доступные объекты</div>
        <div style="font-size:18px;font-weight:900;margin-top:4px;">Выберите объект</div>
      </div>
      <div id="multiObjectChooserList" style="display:grid;gap:10px;"></div>
      <button id="multiObjectChooserBack" class="ghost" type="button" style="width:100%;margin-top:12px;">← Вернуться ко входу</button>
      <div id="multiObjectChooserMsg" class="muted" style="margin-top:10px;font-size:13px;"></div>
    </div>`;
  loginFields.insertAdjacentElement("afterend",wrap);
  $("multiObjectChooserBack")?.addEventListener("click",multiCancelChooser);
  return wrap;
}
function multiHideChooser(){
  var el=document.getElementById("multiObjectChooser");
  if(el)el.classList.add("collapsed");
}
async function multiCancelChooser(){
  try{await fetch("/api/logout",{method:"POST",credentials:"same-origin"});}catch(e){}
  multiHideChooser();
  multiSetLoginLoadVisible(false);
  $("loginMsg").textContent="";
  revealLoginFields();
  setTimeout(()=>$(`loginInput`)?.focus(),80);
}
function multiShowChooser(data){
  var el=multiEnsureChooser();
  var list=document.getElementById("multiObjectChooserList");
  var rows=(data&&data.candidates)||[];
  collapseLoginFields();
  list.innerHTML=rows.map(function(o){
    var noDb=o.has_database===false;
    return `<button type="button" data-object-id="${multiEsc(o.id)}" ${noDb?"disabled":""}
      style="width:100%;text-align:left;padding:14px 16px;border-radius:16px;border:1px solid var(--line);background:rgba(255,255,255,.055);color:var(--text);cursor:${noDb?"not-allowed":"pointer"};opacity:${noDb?".55":"1"};">
      <div style="font-size:16px;font-weight:900;">${multiEsc(o.name||o.id)}</div>
      <div class="muted" style="font-size:11px;margin-top:7px;">Последняя база</div>
      <div style="font-size:13px;font-weight:800;margin-top:2px;">${multiEsc(multiDbDate(o.generated_at))}</div>
    </button>`;
  }).join("");
  var msg=document.getElementById("multiObjectChooserMsg");
  if(msg)msg.textContent=rows.length?"":"Доступных объектов пока нет.";
  list.querySelectorAll("[data-object-id]").forEach(function(btn){
    btn.addEventListener("click",function(){multiSelectObject(btn.dataset.objectId,btn);});
  });
  multiSetLoginLoadVisible(true);
  setLoad("Доступ найден",100,"Выберите объект для входа");
  $("loginMsg").textContent="";
  el.classList.remove("collapsed");
}
async function multiSelectObject(objectId,button){
  var el=multiEnsureChooser();
  var msg=document.getElementById("multiObjectChooserMsg");
  if(button)button.disabled=true;
  if(msg)msg.textContent="Открываю объект…";
  multiSetLoginLoadVisible(true);
  setLoad("Открываю объект…",3,"Подготавливаю базу выбранного объекта");
  try{
    var data=await apiJson("/api/multi/select_object",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({object_id:objectId})});
    el.classList.add("collapsed");
    await multiEnterRole(data);
  }catch(e){
    el.classList.remove("collapsed");
    if(msg)msg.textContent="Ошибка: "+(e.message||e);
    setLoad("Не удалось открыть объект",0,e.message||String(e));
    if(button)button.disabled=false;
  }
}

'''
s=s[:start]+chooser+s[end:]

# Полностью заменяем doLogin — выбор теперь встроен в форму, а индикатор загрузки показывается сразу.
start=s.find('async function doLogin(){')
end=s.find('async function tryRestoreSession(){', start)
if start<0 or end<0:
    raise SystemExit('Не найден doLogin()')
new_login=r'''async function doLogin(){
  var login=$("loginInput").value.trim(),pass=$("passwordInput").value;
  if(!login||!pass){$("loginMsg").innerHTML='<span class="error">Введите логин и пароль.</span>';return;}
  multiObjectId="";multiObjectName="";SPK_OBJECT_ID="";SPK_OBJECT_NAME="";multiIsObjectAdmin=false;multiResetClientDb();
  multiHideChooser();
  collapseLoginFields();
  multiSetLoginLoadVisible(true);
  setLoad("Проверяю доступ…",4,"Проверяю логин, пароль и доступные объекты");
  $("loginMsg").textContent="";
  try{
    var data=await apiJson("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({login:login,password:pass}),timeoutMs:10000});
    if(data.needs_object_selection||data.role==="admin_pending"||data.role==="welder_pending"){
      multiShowChooser(data);
      return;
    }
    await multiEnterRole(data);
  }catch(e){
    multiHideChooser();
    multiSetLoginLoadVisible(false);
    revealLoginFields();
    $("loginMsg").innerHTML='<span class="error">'+multiEsc(e.message||e)+'</span>';
  }
}

'''
s=s[:start]+new_login+s[end:]

# Полностью заменяем восстановление сессии, чтобы pending после F5 тоже был встроенным.
start=s.find('async function tryRestoreSession(){')
end=s.find('/* ---------- Управление объектами ---------- */', start)
if start<0 or end<0:
    raise SystemExit('Не найден tryRestoreSession()')
new_restore=r'''async function tryRestoreSession(){
  if(restoreAttempted)return;
  restoreAttempted=true;
  try{
    var s=await apiJson("/api/session",{timeoutMs:10000});
    if(!s.authenticated){multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();return;}
    if(s.role==="admin_pending"||s.role==="welder_pending"){
      var p=await apiJson("/api/multi/pending");
      collapseLoginFields();
      multiShowChooser(p);
      return;
    }
    if(s.object)multiApplyObject(s.object);
    if(s.role==="stat_admin"){
      multiSetLoginLoadVisible(false);
      currentRole="stat_admin";multiIsObjectAdmin=!!s.object_admin;enterStatAdmin();return;
    }
    if(s.role==="updater"){
      multiSetLoginLoadVisible(false);
      currentRole="updater";enterUpdater();return;
    }
    if(s.role==="admin"){
      multiSetLoginLoadVisible(true);
      adminOrgFilter=s.org_filter||"";adminAccountFilterType=s.account_filter_type||"";adminAccountFilterValue=s.account_filter_value||"";currentSpkContractorId=s.spk_contractor_id||"";
      currentRole="admin";await loadDb();await ensureAdminDbLoaded();enterAdmin();return;
    }
    if(s.role==="welder"){
      multiSetLoginLoadVisible(true);
      currentRole="welder";await loadDb();
      var w=await ensureWelderShardLoaded({id:s.welder_id,shard:s.shard});currentWelder=w;openWelder(w,false);return;
    }
    multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();
  }catch(e){console.warn("restore",e);multiHideChooser();multiSetLoginLoadVisible(false);revealLoginFields();}
}

'''
s=s[:start]+new_restore+s[end:]

# Вход в роль должен явно включать индикатор, когда начинается загрузка объектной базы.
needle='async function multiEnterRole(data){\n  data=data||{};'
repl='async function multiEnterRole(data){\n  data=data||{};\n  if(data.role==="admin"||data.role==="welder")multiSetLoginLoadVisible(true);\n  else multiSetLoginLoadVisible(false);'
if needle not in s:
    raise SystemExit('Не найден заголовок multiEnterRole()')
s=s.replace(needle,repl,1)

# При logout встроенный выбор не должен оставаться раскрытым.
boot='async function multiBootstrap(){'
pos=s.find(boot)
if pos<0:
    raise SystemExit('Не найден multiBootstrap()')
logout_patch=r'''var _multiOriginalLogout=logout;
logout=async function(){
  multiHideChooser();
  multiSetLoginLoadVisible(false);
  return await _multiOriginalLogout.apply(this,arguments);
};

'''
s=s[:pos]+logout_patch+s[pos:]

# Bootstrap: на чистом экране входа индикатор скрыт до нажатия «Войти».
s=s.replace('  var lb=document.querySelector("#loginView .load-box");if(lb)lb.style.display="none";','  multiSetLoginLoadVisible(false);',1)

p.write_text(s,encoding='utf-8')
PY

echo "===== 4. BUMP FRONTEND VERSION ====="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
s=re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>', '<script src="/multiobject.js?v=20260820-3"></script>', s)
p.write_text(s,encoding='utf-8')

sw=Path('/var/www/statv2/sw.js')
if sw.exists():
    t=sw.read_text(encoding='utf-8')
    t=re.sub(r"const CACHE_NAME = 'statv2-pwa-v\d+';", "const CACHE_NAME = 'statv2-pwa-v10';", t)
    sw.write_text(t,encoding='utf-8')
PY

echo "===== 5. PYTHON CHECK ====="
"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/app.py" "$APP_DIR/multiobject.py" "$APP_DIR/upload_async.py" "$APP_DIR/upload_worker.py"
echo "Python: OK"

echo "===== 6. FRONTEND CHECK ====="
grep -q 'STATV2 INLINE OBJECT PICKER V3' "$SITE_DIR/multiobject.js"
grep -q 'AUTO SINGLE OBJECT V3' "$APP_DIR/multiobject.py"
grep -q 'multiobject.js?v=20260820-3' "$SITE_DIR/index_v2.html"

# Проверяем синтаксис JS через node, если он установлен на сервере. Если нет — не устанавливаем его ради одной проверки.
if command -v node >/dev/null 2>&1; then
  node --check "$SITE_DIR/multiobject.js"
  echo "JavaScript: OK"
else
  echo "JavaScript marker check: OK (node не установлен)"
fi

echo "===== 7. RESTART ====="
systemctl restart statv2-uploader
sleep 2
if ! systemctl is-active --quiet statv2-uploader; then
  systemctl --no-pager --full status statv2-uploader || true
  journalctl -u statv2-uploader -n 100 --no-pager || true
  exit 1
fi

echo "===== 8. STATUS ====="
systemctl --no-pager --full status statv2-uploader | head -25

echo "===== 9. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health
echo

echo "===== 10. SINGLE-OBJECT LOGIC CHECK ====="
grep -n 'len(candidates) == 1' "$APP_DIR/multiobject.py" | head -5

echo
echo "=============================================="
echo "INLINE OBJECT PICKER V3 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Обнови страницу Ctrl+F5 и проверь вход сварщика."
echo "=============================================="
