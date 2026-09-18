#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${PROJECT_DIR}/overlay/common/usr/local/sbin/armbian-firstlogin-wifi-connect"
PATCHER="${PROJECT_DIR}/scripts/patch-armbian-firstlogin-wifi.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"

cat > "$TEST_ROOT/bin/iw" <<'EOF'
#!/bin/sh
if [ "$1 $3" = "dev info" ]; then
    exit 0
fi
if [ "$1 $3" = "dev link" ]; then
    count_file="$MOCK_STATE_DIR/iw-count"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -ge "${MOCK_IW_CONNECTED_AFTER:-1}" ]; then
        echo "Connected to aa:bb:cc:dd:ee:ff (on wlan0)"
    else
        echo "Not connected."
    fi
    exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/bin/netplan" <<'EOF'
#!/bin/sh
printf 'netplan %s\n' "$*" >> "$MOCK_STATE_DIR/commands"
[ "${MOCK_NETPLAN_FAIL:-}" != "$1" ]
EOF

for command_name in ip rfkill; do
    cat > "$TEST_ROOT/bin/$command_name" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$MOCK_STATE_DIR/commands"
exit 0
EOF
done

cat > "$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_ROOT/bin/"*

run_helper() {
    local netplan_dir="$1" password="$2"
    shift 2
    printf '%s' "$password" | env \
        PATH="$TEST_ROOT/bin:$PATH" \
        MOCK_STATE_DIR="$TEST_ROOT/state" \
        ARMBIAN_FIRSTLOGIN_NETPLAN_DIR="$netplan_dir" \
        ARMBIAN_FIRSTLOGIN_WIFI_WAIT_ATTEMPTS=4 \
        ARMBIAN_FIRSTLOGIN_WIFI_WAIT_DELAY=0 \
        "$@" \
        "$HELPER" wlan0 'Cafe "AIC": #5\GHz'
}

echo "Test: special SSID and passphrase characters produce valid Netplan"
success_dir="$TEST_ROOT/netplan-success"
mkdir -p "$success_dir"
export MOCK_IW_CONNECTED_AFTER=3
run_helper "$success_dir" 'pa"ss\word:# value'
python3 - "$success_dir/30-wifis-dhcp.yaml" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
wifi = document["network"]["wifis"]["wlan0"]
assert document["network"]["version"] == 2
assert wifi["access-points"]['Cafe "AIC": #5\\GHz']["password"] == 'pa"ss\\word:# value'
PY
grep -Fqx 'rfkill unblock wifi' "$TEST_ROOT/state/commands"
grep -Fqx 'ip link set dev wlan0 up' "$TEST_ROOT/state/commands"
grep -Fqx 'netplan generate' "$TEST_ROOT/state/commands"
grep -Fqx 'netplan apply --timeout 0' "$TEST_ROOT/state/commands"
[[ "$(stat -f '%Lp' "$success_dir/30-wifis-dhcp.yaml" 2>/dev/null || stat -c '%a' "$success_dir/30-wifis-dhcp.yaml")" == 600 ]]

echo "Test: no external internet probe is required"
! rg -q 'curl|ipinfo' "$HELPER"

echo "Test: failed association restores an existing wizard Netplan file"
rm -f "$TEST_ROOT/state/iw-count" "$TEST_ROOT/state/commands"
failure_dir="$TEST_ROOT/netplan-failure"
mkdir -p "$failure_dir"
printf '%s\n' '{"previous": true}' > "$failure_dir/30-wifis-dhcp.yaml"
cp "$failure_dir/30-wifis-dhcp.yaml" "$TEST_ROOT/previous.yaml"
export MOCK_IW_CONNECTED_AFTER=99
if run_helper "$failure_dir" 'correct-password'; then
    echo "Expected association failure" >&2
    exit 1
fi
cmp "$TEST_ROOT/previous.yaml" "$failure_dir/30-wifis-dhcp.yaml"

echo "Test: invalid Netplan rolls back a newly created file"
rm -f "$TEST_ROOT/state/iw-count" "$TEST_ROOT/state/commands"
invalid_dir="$TEST_ROOT/netplan-invalid"
mkdir -p "$invalid_dir"
export MOCK_IW_CONNECTED_AFTER=1
if run_helper "$invalid_dir" 'correct-password' env MOCK_NETPLAN_FAIL=generate; then
    echo "Expected Netplan validation failure" >&2
    exit 1
fi
[[ ! -e "$invalid_dir/30-wifis-dhcp.yaml" ]]

echo "Test: firstlogin patch is exact, checked, and idempotent"
fixture="$TEST_ROOT/armbian-firstlogin"
cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
set_timezone_and_locales() {
	if true; then
		if true; then
			if true; then
				# bring up wifi device (not done by networkd, only by NetworkManager)
				ip link set ${WIFI_DEVICE} up
				if true; then
					while true; do
						while true; do
							SSID=$(echo ${ARRAY[$input-1]} | cut -d"," -f2-)
							break
						done
						# generate config
						echo old-fragile-implementation
						done

				fi # detected or not detected wireless network
			fi
		fi
	fi
}
EOF
python3 "$PATCHER" "$fixture"
python3 "$PATCHER" --check "$fixture"
bash -n "$fixture"
cp "$fixture" "$TEST_ROOT/patched-once"
python3 "$PATCHER" "$fixture"
cmp "$TEST_ROOT/patched-once" "$fixture"
grep -Fq 'robust first-login Wi-Fi' "$fixture"
grep -Fq 'rfkill unblock wifi' "$fixture"
! grep -Fq 'old-fragile-implementation' "$fixture"

echo "Test: changed upstream anchors fail closed"
printf '%s\n' '#!/usr/bin/env bash' > "$TEST_ROOT/unexpected-firstlogin"
if python3 "$PATCHER" "$TEST_ROOT/unexpected-firstlogin" >/dev/null 2>&1; then
    echo "Expected an unknown upstream firstlogin layout to fail" >&2
    exit 1
fi

echo "First-login Wi-Fi tests passed"
