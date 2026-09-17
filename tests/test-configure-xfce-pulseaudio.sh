#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURE_SCRIPT="${PROJECT_DIR}/scripts/configure-xfce-pulseaudio.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
LAYOUT="${TEST_ROOT}/xfce4-panel.xml"

cat > "$LAYOUT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="15"/>
        <value type="int" value="4"/>
        <value type="int" value="6"/>
        <value type="int" value="2"/>
        <value type="int" value="5"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-15" type="string" value="separator"/>
    <property name="plugin-4" type="string" value="pager"/>
    <property name="plugin-6" type="string" value="systray"/>
    <property name="plugin-2" type="string" value="actions"/>
    <property name="plugin-5" type="string" value="clock"/>
  </property>
</channel>
EOF

echo "Test: add PulseAudio plugin and enable multimedia keys"
python3 "$CONFIGURE_SCRIPT" "$LAYOUT"
python3 "$CONFIGURE_SCRIPT" --check "$LAYOUT"
grep -q '<value type="int" value="16"' "$LAYOUT"
grep -q '<property name="plugin-16" type="string" value="pulseaudio"' "$LAYOUT"
grep -q '<property name="enable-keyboard-shortcuts" type="bool" value="true"' "$LAYOUT"
grep -q '<property name="enable-multimedia-keys" type="bool" value="true"' "$LAYOUT"
grep -q '<property name="enable-mpris" type="bool" value="true"' "$LAYOUT"
grep -q '<property name="appearance" type="uint" value="1"' "$LAYOUT"
grep -q '<property name="button-title" type="uint" value="0"' "$LAYOUT"

echo "Test: repeated configuration remains idempotent"
python3 "$CONFIGURE_SCRIPT" "$LAYOUT"
[[ "$(grep -c 'value="pulseaudio"' "$LAYOUT")" == 1 ]]
python3 "$CONFIGURE_SCRIPT" --check "$LAYOUT"

echo "XFCE PulseAudio panel tests passed"
