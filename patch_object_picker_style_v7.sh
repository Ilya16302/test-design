#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="/var/www/statv2"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_object_picker_style_v7_${STAMP}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$SITE_DIR/multiobject.js" \
  "$SITE_DIR/index_v2.html" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. PATCH OBJECT PICKER STYLE ====="
python3 - <<'PY'
from pathlib import Path
import re

p = Path('/var/www/statv2/multiobject.js')
s = p.read_text(encoding='utf-8')
marker = '/* STATV2 OBJECT PICKER STYLE V7 */'
if marker in s:
    print('V7 style patch already present — skipping body patch')
else:
    # Replace multiEnsureChooser block
    start = s.find('function multiEnsureChooser(){')
    end = s.find('function multiHideChooser(){', start)
    if start < 0 or end < 0:
        raise SystemExit('Не найден блок multiEnsureChooser')
    new_ensure = r'''/* STATV2 OBJECT PICKER STYLE V7 */
function multiEnsureChooserStyle(){
  if(document.getElementById("multiObjectChooserStyle"))return;
  var st=document.createElement("style");
  st.id="multiObjectChooserStyle";
  st.textContent=`
    #multiObjectChooser .login-fields-inner{
      gap:0;
    }
    #multiObjectChooser .mo-chooser-head{
      margin:14px 0 12px;
    }
    #multiObjectChooser .mo-chooser-eyebrow{
      color:var(--muted2);
      font-size:11px;
      line-height:1;
      font-weight:800;
      letter-spacing:.10em;
      text-transform:uppercase;
      margin-bottom:6px;
    }
    #multiObjectChooser .mo-chooser-title{
      color:#fff;
      font-size:18px;
      line-height:1.15;
      font-weight:900;
      letter-spacing:-.02em;
      margin:0;
    }
    #multiObjectChooser .mo-chooser-list{
      display:grid;
      gap:12px;
      margin-top:2px;
    }
    #multiObjectChooser .mo-chooser-card{
      position:relative;
      width:100%;
      min-height:108px;
      display:block;
      text-align:left;
      padding:16px 18px;
      border-radius:18px;
      border:1px solid rgba(255,255,255,.10) !important;
      background:linear-gradient(145deg,rgba(255,255,255,.050),rgba(255,255,255,.028)) !important;
      color:var(--text) !important;
      box-shadow:inset 0 1px 0 rgba(255,255,255,.06),0 10px 24px rgba(0,0,0,.18) !important;
      cursor:pointer;
      transition:transform .16s ease,border-color .16s ease,box-shadow .16s ease,background .16s ease;
      outline:none;
      -webkit-tap-highlight-color: transparent;
    }
    #multiObjectChooser .mo-chooser-card::before{
      content:"";
      position:absolute;
      inset:0;
      border-radius:inherit;
      pointer-events:none;
      background:linear-gradient(180deg,rgba(255,255,255,.025),rgba(255,255,255,0));
    }
    #multiObjectChooser .mo-chooser-card:hover,
    #multiObjectChooser .mo-chooser-card:focus-visible{
      transform:translateY(-1px);
      border-color:rgba(106,179,255,.24) !important;
      background:linear-gradient(145deg,rgba(255,255,255,.066),rgba(255,255,255,.034)) !important;
      box-shadow:inset 0 1px 0 rgba(255,255,255,.08),0 14px 28px rgba(0,0,0,.22),0 0 0 1px rgba(106,179,255,.05) !important;
    }
    #multiObjectChooser .mo-chooser-card[disabled]{
      cursor:not-allowed;
      opacity:.58;
      transform:none;
      box-shadow:inset 0 1px 0 rgba(255,255,255,.04),0 8px 18px rgba(0,0,0,.14) !important;
    }
    #multiObjectChooser .mo-chooser-card .mo-name{
      display:block;
      color:#fff;
      font-size:16px;
      line-height:1.18;
      font-weight:900;
      letter-spacing:-.015em;
      margin:0;
    }
    #multiObjectChooser .mo-chooser-card .mo-date-label{
      display:block;
      margin-top:10px;
      color:var(--muted2);
      font-size:11px;
      line-height:1;
      font-weight:700;
    }
    #multiObjectChooser .mo-chooser-card .mo-date{
      display:block;
      margin-top:4px;
      color:var(--text);
      font-size:14px;
      line-height:1.15;
      font-weight:800;
    }
    #multiObjectChooser .mo-chooser-back{
      width:100%;
      margin-top:12px;
      box-shadow:inset 0 1px 0 rgba(255,255,255,.07),0 8px 20px rgba(0,0,0,.12) !important;
    }
    #multiObjectChooser .mo-chooser-msg{
      margin-top:10px;
      font-size:13px;
    }
  `;
  document.head.appendChild(st);
}
function multiEnsureChooser(){
  multiEnsureChooserStyle();
  var old=document.getElementById("multiObjectChooser");
  if(old)return old;
  var loginFields=$("loginFields");
  if(!loginFields)throw new Error("Не найден блок входа");
  var wrap=document.createElement("div");
  wrap.id="multiObjectChooser";
  wrap.className="login-fields collapsed";
  wrap.innerHTML=`
    <div class="login-fields-inner">
      <div class="mo-chooser-head">
        <div class="mo-chooser-eyebrow">Доступные объекты</div>
        <div class="mo-chooser-title">Выберите объект</div>
      </div>
      <div id="multiObjectChooserList" class="mo-chooser-list"></div>
      <button id="multiObjectChooserBack" class="ghost mo-chooser-back" type="button">← Вернуться ко входу</button>
      <div id="multiObjectChooserMsg" class="muted mo-chooser-msg"></div>
    </div>`;
  loginFields.insertAdjacentElement("afterend",wrap);
  $("multiObjectChooserBack")?.addEventListener("click",multiCancelChooser);
  return wrap;
}

'''
    s = s[:start] + new_ensure + s[end:]

    # Replace button rendering inside multiShowChooser
    old_fragment = '''  list.innerHTML=rows.map(function(o){
    var noDb=o.has_database===false;
    return `<button type="button" data-object-id="${multiEsc(o.id)}" ${noDb?"disabled":""}
      style="width:100%;text-align:left;padding:14px 16px;border-radius:16px;border:1px solid var(--line);background:rgba(255,255,255,.055);color:var(--text);cursor:${noDb?"not-allowed":"pointer"};opacity:${noDb?".55":"1"};">
      <div style="font-size:16px;font-weight:900;">${multiEsc(o.name||o.id)}</div>
      <div class="muted" style="font-size:11px;margin-top:7px;">Последняя база</div>
      <div style="font-size:13px;font-weight:800;margin-top:2px;">${multiEsc(multiDbDate(o.generated_at))}</div>
    </button>`;
  }).join("");'''
    new_fragment = '''  list.innerHTML=rows.map(function(o){
    var noDb=o.has_database===false;
    return `<button type="button" class="mo-chooser-card" data-object-id="${multiEsc(o.id)}" ${noDb?"disabled":""}>
      <span class="mo-name">${multiEsc(o.name||o.id)}</span>
      <span class="mo-date-label">Последняя база</span>
      <span class="mo-date">${multiEsc(multiDbDate(o.generated_at))}</span>
    </button>`;
  }).join("");'''
    if old_fragment not in s:
        raise SystemExit('Не найден шаблон карточек выбора объекта')
    s = s.replace(old_fragment, new_fragment, 1)

    p.write_text(s, encoding='utf-8')
    print('V7 style patch installed')
PY

echo "===== 3. BUMP FRONTEND VERSION ====="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
s=re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>', '<script src="/multiobject.js?v=20260821-7"></script>', s)
p.write_text(s,encoding='utf-8')
print('multiobject.js version -> 20260821-7')
PY

echo "===== 4. CHECK ====="
grep -q 'STATV2 OBJECT PICKER STYLE V7' "$SITE_DIR/multiobject.js"
grep -q 'mo-chooser-card' "$SITE_DIR/multiobject.js"
grep -q 'multiobject.js?v=20260821-7' "$SITE_DIR/index_v2.html"
echo "Marker check: OK"

echo "===== 5. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health
echo

echo

echo "=============================================="
echo "OBJECT PICKER STYLE V7 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Сделай Ctrl+F5 и проверь внешний вид выбора объекта."
echo "=============================================="
