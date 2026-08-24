#!/usr/bin/env bash
set -euo pipefail

ROOT="${V253_ROOT:-}"
SITE="${ROOT}/var/www/statv2"
BACKEND="${ROOT}/opt/statv2-uploader"
V25="$BACKEND/v25_access.py"
HTML="$SITE/index_v2.html"
MJS="$SITE/multiobject.js"
STAMP="$(date +%Y%m%d_%H%M%S)"

for F in "$V25" "$HTML" "$MJS"; do
  [ -f "$F" ] || { echo "ERROR: не найден $F"; exit 1; }
done

if grep -q 'CONTRACTOR BRIGADIER CONSISTENCY V25.3' "$V25"; then
  echo "V25.3 уже установлен. Повторно ничего не меняю."
  exit 0
fi

echo "===== 1. BACKUP ====="
if [ -z "$ROOT" ]; then
  BACKUP="/root/statv2_before_v25_3_${STAMP}.tar.gz"
else
  BACKUP="$ROOT/v25_3_backup_${STAMP}.tar.gz"
fi
tar -czf "$BACKUP" "$V25" "$HTML" "$MJS" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. BACKEND: CONTRACTOR JOINT SCOPE ====="
cat >> "$V25" <<'PYV253'

# === STATV2 CONTRACTOR BRIGADIER CONSISTENCY V25.3 ===
# Для учётки, связанной с подрядчиком СПК, принадлежность СТЫКА подрядчику
# определяется исключительно полем joint.brigadier и brigadier_filter подрядчика.
# Персональные строки сварщиков по-прежнему ограничиваются account_filter_*.

def _v253_linked_contractor():
    if str(session.get("role") or "") != "admin":
        return None
    try:
        item = core.statv2_find_spk_contractor_by_account(session.get("login", ""))
        return item if isinstance(item, dict) else None
    except Exception:
        return None


def _v253_brigadier_filter():
    item = _v253_linked_contractor()
    return str((item or {}).get("brigadier_filter") or "").strip()


def _v253_joint_matches_contractor(joint, brigadier_filter=None):
    needle = _norm(brigadier_filter if brigadier_filter is not None else _v253_brigadier_filter())
    if not needle:
        return False
    return needle in _norm((joint or {}).get("brigadier"))


# V25 фильтровал joints ограниченной учётки через сварщиков.
# Для связанного подрядчика V25.3 оставляет welders/events персонально ограниченными,
# а массив joints формирует по Бригадиру — именно он питает Историю и аналитику.
_V253_ORIG_FILTER_SHARD = _filter_shard


def _filter_shard(data, allowed_ids):
    brigadier_filter = _v253_brigadier_filter()
    if not brigadier_filter:
        return _V253_ORIG_FILTER_SHARD(data, allowed_ids)

    allowed_ids = set(allowed_ids or set())
    allowed_names = _allowed_welder_names(allowed_ids) or set()
    out = copy.deepcopy(data or {})
    out["auth"] = {}

    out["welders"] = [
        w for w in (out.get("welders") or [])
        if str((w or {}).get("id") or "") in allowed_ids
    ]

    events = {}
    for wid, rows in (out.get("welder_events") or {}).items():
        if str(wid) in allowed_ids:
            events[str(wid)] = [
                _clean_welder_refs(e, allowed_ids, allowed_names)
                for e in (rows or [])
            ]
    out["welder_events"] = events

    # В истории подрядчика показываем весь стык и все его этапы,
    # если Бригадир самого стыка соответствует brigadier_filter.
    joints = [
        copy.deepcopy(joint)
        for joint in (out.get("joints") or [])
        if _v253_joint_matches_contractor(joint, brigadier_filter)
    ]
    out["joints"] = joints

    meta = out.get("meta") if isinstance(out.get("meta"), dict) else {}
    counts = meta.get("counts") if isinstance(meta.get("counts"), dict) else {}
    if counts:
        counts["welders"] = len(out["welders"])
        counts["joints"] = len(joints)
        counts["events"] = sum(len(x) for x in events.values())
    return out


# В Excel «С материалами» агрегаты (# ИТОГО и лист «Материалы»)
# считаем не по сварщикам учётки, а по ВСЕМ actions стыков подрядчика,
# выбранных через joint.brigadier.
_V253_ORIG_CALC_STATS_FROM_JOINTS = core.calc_stats_from_joints
_V253_ORIG_CALC_MATERIAL_STATS_FROM_JOINTS = core.calc_material_stats_from_joints


def _v253_calc_stats_from_joints(joints, scope, start, end, allowed_welder_ids=None):
    brigadier_filter = _v253_brigadier_filter()
    if brigadier_filter:
        contractor_joints = [
            j for j in (joints or [])
            if _v253_joint_matches_contractor(j, brigadier_filter)
        ]
        return _V253_ORIG_CALC_STATS_FROM_JOINTS(
            contractor_joints, scope, start, end, None
        )
    return _V253_ORIG_CALC_STATS_FROM_JOINTS(
        joints, scope, start, end, allowed_welder_ids
    )


def _v253_calc_material_stats_from_joints(joints, scope, start, end, range_config, allowed_welder_ids=None):
    brigadier_filter = _v253_brigadier_filter()
    if brigadier_filter:
        contractor_joints = [
            j for j in (joints or [])
            if _v253_joint_matches_contractor(j, brigadier_filter)
        ]
        return _V253_ORIG_CALC_MATERIAL_STATS_FROM_JOINTS(
            contractor_joints, scope, start, end, range_config, None
        )
    return _V253_ORIG_CALC_MATERIAL_STATS_FROM_JOINTS(
        joints, scope, start, end, range_config, allowed_welder_ids
    )


core.calc_stats_from_joints = _v253_calc_stats_from_joints
core.calc_material_stats_from_joints = _v253_calc_material_stats_from_joints
core.v253_contractor_brigadier_filter = _v253_brigadier_filter


@APP.after_request
def v253_add_contractor_context(response):
    # Передаём frontend точный brigadier_filter связанного подрядчика,
    # чтобы История/Аналитика использовали тот же критерий, что СПК и Excel.
    if request.path not in ("/api/login", "/api/session"):
        return response
    if str(session.get("role") or "") != "admin":
        return response
    try:
        contractor = _v253_linked_contractor()
        brigadier_filter = str((contractor or {}).get("brigadier_filter") or "").strip()
        contractor_id = str((contractor or {}).get("id") or "")
        session["spk_brigadier_filter"] = brigadier_filter
        if contractor_id:
            session["spk_contractor_id"] = contractor_id

        if response.is_json:
            data = response.get_json(silent=True)
            if isinstance(data, dict):
                data["spk_brigadier_filter"] = brigadier_filter
                if contractor_id:
                    data["spk_contractor_id"] = contractor_id
                response.set_data(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
                response.headers["Content-Type"] = "application/json; charset=utf-8"
    except Exception:
        pass
    return response
PYV253

echo "===== 3. FRONTEND: HISTORY + ANALYTICS ====="
python3 - "$HTML" "$MJS" <<'PY'
from pathlib import Path
import re, sys

html = Path(sys.argv[1])
mjs = Path(sys.argv[2])
s = html.read_text(encoding="utf-8")

old = 'let adminAccountFilterType="",adminAccountFilterValue="",currentSpkContractorId="";'
new = 'let adminAccountFilterType="",adminAccountFilterValue="",currentSpkContractorId="",currentSpkBrigadierFilter="";'
if old not in s:
    raise SystemExit("ERROR: globals marker not found")
s = s.replace(old, new, 1)

old = 'currentSpkContractorId=s.spk_contractor_id||"";'
new = 'currentSpkContractorId=s.spk_contractor_id||"";currentSpkBrigadierFilter=s.spk_brigadier_filter||"";'
if old not in s:
    raise SystemExit("ERROR: restore-session marker not found")
s = s.replace(old, new, 1)

old = 'currentSpkContractorId=data.spk_contractor_id||"";'
new = 'currentSpkContractorId=data.spk_contractor_id||"";currentSpkBrigadierFilter=data.spk_brigadier_filter||"";'
if old not in s:
    raise SystemExit("ERROR: login marker not found")
s = s.replace(old, new, 1)

old = 'currentSpkContractorId="";spkContractors=[];'
new = 'currentSpkContractorId="";currentSpkBrigadierFilter="";spkContractors=[];'
if old not in s:
    raise SystemExit("ERROR: logout marker not found")
s = s.replace(old, new, 1)

old = '''function adminBrigadierAllowed(item){
  if(!adminOrgFilter)return true;

  const filterValue=norm(adminOrgFilter);
  if(!filterValue)return true;

  return norm(item?.brigadier||"").includes(filterValue);
}
function adminAllowedWelderNames(){
  return adminVisibleWelders().map(w=>norm(w.name||"")).filter(Boolean);
}
function jointAllowedByOrg(j){
  if(!adminOrgFilter)return true;
  const names=adminAllowedWelderNames();
  if(!names.length)return false;
  const actions=j.actions||[];
  return actions.some(a=>{
    const ww=norm(a.welder||a.welders||"");
    return names.some(n=>ww.includes(n)||n.includes(ww));
  });
}
'''
new = '''function activeContractorBrigadierFilter(){
  if(!currentSpkContractorId)return "";
  return norm(currentSpkBrigadierFilter||"");
}
function adminBrigadierAllowed(item){
  const contractorFilter=activeContractorBrigadierFilter();
  if(contractorFilter){
    return norm(item?.brigadier||"").includes(contractorFilter);
  }
  if(!adminOrgFilter)return true;
  const filterValue=norm(adminOrgFilter);
  if(!filterValue)return true;
  return norm(item?.brigadier||"").includes(filterValue);
}
function adminAllowedWelderNames(){
  return adminVisibleWelders().map(w=>norm(w.name||"")).filter(Boolean);
}
function jointAllowedByOrg(j){
  // V25.3: для связанного подрядчика история стыков — строго по Бригадиру.
  const contractorFilter=activeContractorBrigadierFilter();
  if(contractorFilter){
    return norm(j?.brigadier||"").includes(contractorFilter);
  }
  if(!adminOrgFilter)return true;
  const names=adminAllowedWelderNames();
  if(!names.length)return false;
  const actions=j.actions||[];
  return actions.some(a=>{
    const ww=norm(a.welder||a.welders||"");
    return names.some(n=>ww.includes(n)||n.includes(ww));
  });
}
'''
if old not in s:
    raise SystemExit("ERROR: brigadier/history helper block not found")
s = s.replace(old, new, 1)

old = 'currentSpkContractorId=data.contractor_id||currentSpkContractorId||"";'
new = '''currentSpkContractorId=data.contractor_id||currentSpkContractorId||"";
    const linkedContractor=(spkContractors||[]).find(item=>String(item.id||"")===String(currentSpkContractorId||""));
    if(linkedContractor)currentSpkBrigadierFilter=linkedContractor.brigadier_filter||currentSpkBrigadierFilter||"";'''
if old not in s:
    raise SystemExit("ERROR: SPK contractor load marker not found")
s = s.replace(old, new, 1)

# Bust active multiobject.js URL so browser definitely receives the new access-scope logic.
s = re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>', '<script src="/multiobject.js?v=20260824-253"></script>', s, count=1)
html.write_text(s, encoding="utf-8")

s = mjs.read_text(encoding="utf-8")
old = '''function multiSetAccessScope(data){
  data=data||{};
  var role=String(data.role||"");
  if(role==="welder") multiAccessCacheScope="welder:"+String(data.welder_id||"");
  else if(role==="admin"){
    var ft=String(data.account_filter_type||"");
    var fv=String(data.account_filter_value||data.org_filter||"");
    multiAccessCacheScope=fv?("admin:"+ft+":"+fv):"admin:full";
  }else multiAccessCacheScope=role||"anon";
}
'''
new = '''function multiSetAccessScope(data){
  data=data||{};
  var role=String(data.role||"");
  if(role==="welder") multiAccessCacheScope="welder:"+String(data.welder_id||"");
  else if(role==="admin"){
    var ft=String(data.account_filter_type||"");
    var fv=String(data.account_filter_value||data.org_filter||"");
    var cid=String(data.spk_contractor_id||"");
    var cb=String(data.spk_brigadier_filter||"");
    var base=fv?("admin:"+ft+":"+fv):"admin:full";
    multiAccessCacheScope="v253::"+base+(cid?("::spk:"+cid+":"+cb):"");
  }else multiAccessCacheScope=role||"anon";
}
'''
if old not in s:
    raise SystemExit("ERROR: multiSetAccessScope V25 block not found")
s = s.replace(old, new, 1)
mjs.write_text(s, encoding="utf-8")
PY

echo "===== 4. STATIC CHECKS ====="
python3 -m py_compile "$BACKEND/app.py" "$BACKEND/v25_access.py" "$BACKEND/multiobject.py"

grep -q 'CONTRACTOR BRIGADIER CONSISTENCY V25.3' "$V25"
grep -q 'activeContractorBrigadierFilter' "$HTML"
grep -q 'v253::' "$MJS"

if command -v node >/dev/null 2>&1; then
  node --check "$MJS"
  TMP="$(mktemp -d)"
  python3 - "$HTML" "$TMP" <<'PYJS'
from pathlib import Path
import re,sys
h=Path(sys.argv[1]).read_text(encoding='utf-8')
o=Path(sys.argv[2])
for i,b in enumerate(re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',h,re.S|re.I)):
    (o/f'i{i}.js').write_text(b,encoding='utf-8')
PYJS
  for F in "$TMP"/*.js; do node --check "$F"; done
  rm -rf "$TMP"
fi

echo "Static checks: OK"

if [ -z "$ROOT" ]; then
  echo "===== 5. RESTART ====="
  systemctl restart statv2-uploader
  sleep 2
  systemctl is-active --quiet statv2-uploader

  echo "===== 6. HEALTH ====="
  curl -fsS http://127.0.0.1:5088/health
  echo
fi

echo "====================================================="
echo "STATV2 V25.3 УСТАНОВЛЕН"
echo "  • подрядчик определяется по brigadier_filter"
echo "  • # ИТОГО в Excel с материалами считается по Бригадиру"
echo "  • лист Материалы в этом Excel считает тот же набор стыков"
echo "  • История всех стыков подрядчика показывает стыки по Бригадиру"
echo "  • Аналитика подрядчика использует тот же brigadier_filter"
echo "  • строки конкретных сварщиков остаются по фильтру учётки"
echo "  • cache scope обновлён, старые ограниченные shards не подмешаются"
echo "Backup: $BACKUP"
echo "====================================================="
