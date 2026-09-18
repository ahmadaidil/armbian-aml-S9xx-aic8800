#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TEST_ROOT/bin/df" <<'EOF'
#!/bin/sh
cat <<'OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
test       120000000   1    119999999 1%       /test
OUTPUT
EOF
chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/df"

run_check() {
    PATH="$TEST_ROOT/bin:$PATH" "$PROJECT_DIR/build.sh" --check "$@"
}

echo "Test: default profile remains Ubuntu XFCE with audio"
default_output="$(run_check)"
grep -Fqx 'Variant: xfce' <<<"$default_output"
grep -Fqx 'Bluetooth audio: true' <<<"$default_output"
grep -Fq '/Resolute_current_xfce' <<<"$default_output"
grep -Fqx 'Expected distribution: ubuntu 26.04' <<<"$default_output"

echo "Test: minimal profile uses Debian Trixie without audio"
minimal_output="$(run_check --variant minimal)"
grep -Fqx 'Variant: minimal' <<<"$minimal_output"
grep -Fqx 'Bluetooth audio: false' <<<"$minimal_output"
grep -Fq '/Trixie_current_minimal' <<<"$minimal_output"
grep -Fqx 'Expected distribution: debian 13' <<<"$minimal_output"

echo "Test: Bluetooth audio can be enabled for minimal"
minimal_audio_output="$(run_check --variant minimal --bluetooth-audio)"
grep -Fqx 'Bluetooth audio: true' <<<"$minimal_audio_output"

echo "Test: the XFCE audio flag is accepted as redundant"
xfce_audio_output="$(run_check --variant xfce --bluetooth-audio)"
grep -Fqx 'Notice: --bluetooth-audio is already enabled by the XFCE profile.' <<<"$xfce_audio_output"
grep -Fqx 'Bluetooth audio: true' <<<"$xfce_audio_output"

echo "Test: invalid and incomplete options are rejected"
if run_check --variant server >/dev/null 2>&1; then
    echo "Expected an invalid variant to fail" >&2
    exit 1
fi
if run_check --variant >/dev/null 2>&1; then
    echo "Expected a missing variant value to fail" >&2
    exit 1
fi
if run_check --output-dir >/dev/null 2>&1; then
    echo "Expected a missing output directory to fail" >&2
    exit 1
fi

echo "Build profile CLI tests passed"
