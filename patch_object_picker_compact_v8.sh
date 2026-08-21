#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="/var/www/statv2"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/root/statv2_before_object_picker_compact_v8_${STAMP}.tar.gz"

echo "===== 1. BACKUP ====="
tar -czf "$BACKUP" \
  "$SITE_DIR/multiobject.js" \
  "$SITE_DIR/index_v2.html" 2>/dev/null || true
echo "Backup: $BACKUP"

echo "===== 2. COMPACT OBJECT PICKER ====="
python3 - <<'PY'
from pathlib import Path
import re

p = Path('/var/www/statv2/multiobject.js')
s = p.read_text(encoding='utf-8')

# We expect V7 styles to exist. Apply compact overrides by replacing the key size values.
replacements = [
    ('gap:12px;', 'gap:10px;'),
    ('min-height:108px;', 'min-height:56px;'),
    ('padding:16px 18px;', 'padding:11px 14px;'),
    ('font-size:16px;', 'font-size:15px;'),
    ('margin-top:10px;', 'margin-top:6px;'),
    ('font-size:11px;', 'font-size:10px;'),
    ('margin-top:4px;', 'margin-top:2px;'),
    ('font-size:14px;', 'font-size:12px;'),
    ('margin-top:12px;', 'margin-top:10px;'),
]

# Only mutate the chooser style block to avoid touching unrelated UI.
start = s.find('/* STATV2 OBJECT PICKER STYLE V7 */')
if start < 0:
    raise SystemExit('Не найден блок стилей V7 в multiobject.js')
end = s.find('function multiHideChooser(){', start)
if end < 0:
    raise SystemExit('Не найдена граница блока стилей выбора объекта')
block = s[start:end]
orig = block
for a,b in replacements:
    block = block.replace(a,b)

# Additional explicit tightening for card content spacing.
block = block.replace(
    '#multiObjectChooser .mo-chooser-card .mo-name{',
    '#multiObjectChooser .mo-chooser-card .mo-name{\n      margin-bottom:0;'
)
block = block.replace(
    '#multiObjectChooser .mo-chooser-card .mo-date-label{',
    '#multiObjectChooser .mo-chooser-card .mo-date-label{\n      opacity:.9;'
)
block = block.replace(
    '#multiObjectChooser .mo-chooser-card .mo-date{',
    '#multiObjectChooser .mo-chooser-card .mo-date{\n      letter-spacing:-.01em;'
)

if block == orig:
    print('Compact style values already applied or nothing changed')
else:
    s = s[:start] + block + s[end:]
    p.write_text(s, encoding='utf-8')
    print('Compact style patch installed')
PY

echo "===== 3. BUMP FRONTEND VERSION ====="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/var/www/statv2/index_v2.html')
s=p.read_text(encoding='utf-8')
s=re.sub(r'<script src="/multiobject\.js\?v=[^"]+"></script>', '<script src="/multiobject.js?v=20260821-8"></script>', s)
p.write_text(s,encoding='utf-8')
print('multiobject.js version -> 20260821-8')
PY

echo "===== 4. CHECK ====="
grep -q 'STATV2 OBJECT PICKER STYLE V7' "$SITE_DIR/multiobject.js"
grep -q 'min-height:56px' "$SITE_DIR/multiobject.js"
grep -q 'multiobject.js?v=20260821-8' "$SITE_DIR/index_v2.html"
echo "Marker check: OK"

echo "===== 5. HEALTH ====="
curl -fsS http://127.0.0.1:5088/health
echo

echo

echo "=============================================="
echo "OBJECT PICKER COMPACT V8 УСТАНОВЛЕН"
echo "Backup: $BACKUP"
echo "Сделай Ctrl+F5 и проверь высоту карточек выбора объекта."
echo "=============================================="
