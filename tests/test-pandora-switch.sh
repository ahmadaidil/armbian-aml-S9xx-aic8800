#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlay/usr/local/sbin/aic8800-pandora-switch"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/sys/bus/usb/devices" "$TEST_ROOT/bin"
printf 'test\n' > "$TEST_ROOT/config"

run_switch() {
    AIC_SYSFS_ROOT="$TEST_ROOT/sys" \
    AIC_MODE_SWITCH_CONFIG="$TEST_ROOT/config" \
    AIC_USB_MODESWITCH="$TEST_ROOT/bin/usb_modeswitch" \
    AIC_LOCK_FILE="$TEST_ROOT/lock" \
    AIC_RETRIES="${AIC_RETRIES:-1}" \
    AIC_POLL_ATTEMPTS="${AIC_POLL_ATTEMPTS:-1}" \
    AIC_POLL_DELAY=0 \
    "$SCRIPT"
}

cat > "$TEST_ROOT/bin/usb_modeswitch" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_ROOT/bin/usb_modeswitch"

echo "Test: no Pandora adapter"
run_switch

echo "Test: successful switch"
mkdir -p "$TEST_ROOT/sys/bus/usb/devices/1-1"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct"
cat > "$TEST_ROOT/bin/usb_modeswitch" <<EOF
#!/bin/sh
printf 'a69c\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor'
printf '8d80\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct'
EOF
chmod +x "$TEST_ROOT/bin/usb_modeswitch"
run_switch

echo "Test: retry then successful fallback switch"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct"
printf '0\n' > "$TEST_ROOT/retry-count"
cat > "$TEST_ROOT/bin/usb_modeswitch" <<EOF
#!/bin/sh
count=\$(cat '$TEST_ROOT/retry-count')
count=\$((count + 1))
printf '%s\\n' "\$count" > '$TEST_ROOT/retry-count'
if [ "\$count" -eq 2 ]; then
    printf 'a69c\\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor'
    printf '8d80\\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct'
fi
EOF
chmod +x "$TEST_ROOT/bin/usb_modeswitch"
AIC_RETRIES=2 run_switch
[[ "$(cat "$TEST_ROOT/retry-count")" == 2 ]]

echo "Test: concurrent invocations are serialized"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct"
: > "$TEST_ROOT/calls"
cat > "$TEST_ROOT/bin/usb_modeswitch" <<EOF
#!/bin/sh
printf 'called\\n' >> '$TEST_ROOT/calls'
sleep 1
printf 'a69c\\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor'
printf '8d80\\n' > '$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct'
EOF
chmod +x "$TEST_ROOT/bin/usb_modeswitch"
run_switch &
first_pid=$!
run_switch &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(wc -l < "$TEST_ROOT/calls" | tr -d ' ')" == 1 ]]

echo "Test: terminal failure"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idVendor"
printf '1111\n' > "$TEST_ROOT/sys/bus/usb/devices/1-1/idProduct"
cat > "$TEST_ROOT/bin/usb_modeswitch" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TEST_ROOT/bin/usb_modeswitch"
if run_switch; then
    echo "Expected failure when Pandora remains in storage mode" >&2
    exit 1
fi

echo "Pandora fallback tests passed"
