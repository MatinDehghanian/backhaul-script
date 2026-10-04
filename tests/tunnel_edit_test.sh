#!/usr/bin/env bash
# Run with Bash 4+ and jq; Python 3.11+ independently verifies emitted TOML.
set -eo pipefail
if ((BASH_VERSINFO[0] < 4)); then
    echo 'These tests require Bash 4 or newer.' >&2
    exit 1
fi
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'test_status=$?; if ((test_status)); then tail -50 "$test_dir/menu-output.log" >&2; fi; rm -rf "$test_dir"' EXIT
PYTHON=${PYTHON:-python3}

# Load only definitions, avoiding package installation, downloads and the menu loop.
source <(sed -n '/^colorize() {/,/^install_jq() {/p' "$repo_dir/backhaul.sh" | sed '$d')
source <(sed -n '/^declare -A CONFIG/,/^SERVER_IP=/p' "$repo_dir/backhaul.sh" | sed '$d')
config_dir="$test_dir"
CERT_DIR="$test_dir/certs"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
SERVER_IP=192.0.2.1
mkdir -p "$CERT_DIR"
touch "$CERT_FILE" "$KEY_FILE"
colorize() { printf '%s\n' "$2"; }
sleep() { :; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_value() {
    [[ "$(edit_value "$1")" == "$2" ]] || fail "$1 should be $2, got $(edit_value "$1")"
}
assert_absent() { [[ -z "${EDIT_VALUES[$1]+present}" ]] || fail "$1 should be removed"; }
systemctl() {
    echo "$*" >> "$test_dir/systemctl.log"
    if [[ "$1" == restart && -f "$test_dir/fail-next-restart" ]]; then
        rm "$test_dir/fail-next-restart"
        return 1
    fi
    if [[ "$1" == is-active && -f "$test_dir/fail-next-active" ]]; then
        rm "$test_dir/fail-next-active"
        return 1
    fi
    return 0
}

fixture() {
    reset_config
    CONFIG=(
        [bind_addr]=:8443 [remote_addr]=192.0.2.1:8443 [dial_timeout]=10 [retry_interval]=3
        [transport_type]=tcp [nodelay]=true [keepalive_period]=40 [accept_udp]=false
        [proxy_protocol]=false [connection_pool]=8 [heartbeat_interval]=10 [heartbeat_timeout]=25
        [token]='keep # token' [auto_tuning]=true [tuning_profile]=latency [workers]=4
        [channel_size]=4096 [tcp_mss]=0 [so_rcvbuf]=0 [so_sndbuf]=0
        [buffer_profile]=low_cpu [read_timeout]=120 [log_level]=info
        [ports_mapping]='443,8443=443,5000-5010:5201'
    )
    generate_toml_config "$1" "$2" false false
}

# Load and rewrite real generated files; compare with an independent TOML parser.
for edit_mode in server client; do
    fixture "$edit_mode" "$test_dir/original.toml"
    cat >> "$test_dir/original.toml" <<'EOF'

[custom]
extra = "quoted \" text \\ path # still text" # outside comment
EOF
    edit_load_config "$test_dir/original.toml"
    edit_write_config "$test_dir/roundtrip.toml"
    "$PYTHON" - "$test_dir/original.toml" "$test_dir/roundtrip.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as a, open(sys.argv[2], 'rb') as b:
    assert tomllib.load(a) == tomllib.load(b)
PY
done
echo 'PASS: server/client roundtrip preserves values, arrays, escapes and custom sections'

# Supply answers through the actual field editor while recording dependency prompts.
eval "$(declare -f edit_prompt_field | sed '1s/edit_prompt_field/real_edit_prompt_field/')"
edit_prompt_field() {
    echo "$1" >> "$test_dir/prompts.log"
    local answer=""
    case "$1" in
        ipx.dst_ip) answer=192.0.2.2 ;;
        ipx.interface) answer=eth0 ;;
        security.psk) answer=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ;;
        security.token) answer='new shared token' ;;
        dialer.remote_addr) answer=192.0.2.1:8443 ;;
        tun.encapsulation) answer="${test_encapsulation:-tcp}" ;;
        ports.mapping) answer='443,8443=443' ;;
    esac
    real_edit_prompt_field "$@" <<< "$answer"
}

for edit_mode in server client; do
    for transport in tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun; do
        fixture "$edit_mode" "$test_dir/original.toml"
        edit_load_config "$test_dir/original.toml"
        EDIT_VALUES[transport.type]="\"$transport\""
        edit_complete_transport > "$test_dir/menu-output.log"
        assert_value transport.type "$transport"
        assert_value security.token 'keep # token'
        assert_value tuning.tuning_profile latency
        if [[ "$transport" == *mux ]]; then assert_value mux.mux_version 2; else assert_absent mux.mux_version; fi
        if [[ "$transport" == tun ]]; then assert_value tun.encapsulation tcp; else assert_absent tun.encapsulation; fi
        edit_write_config "$test_dir/result-$edit_mode-$transport.toml"
        # Move back to TCP and check transport-specific fields really disappear.
        EDIT_VALUES[transport.type]='"tcp"'
        edit_complete_transport > "$test_dir/menu-output.log"
        assert_absent tun.encapsulation
        assert_absent mux.mux_version
        assert_absent tls.tls_cert
        assert_absent tls.sni
        assert_absent ports.forwarder
    done
done
grep -q '^mux.mux_version$' "$test_dir/prompts.log" || fail 'mux settings were not requested'
grep -q '^tls.tls_cert$' "$test_dir/prompts.log" || fail 'TLS settings were not requested'
echo 'PASS: all ten transports, both roles, preserve shared settings and remove obsolete fields'

# UDP settings must vanish when leaving TCP, including the entire section.
edit_mode=server
fixture server "$test_dir/original.toml"
edit_load_config "$test_dir/original.toml"
EDIT_VALUES[transport.accept_udp]=true
edit_complete_transport > "$test_dir/menu-output.log"
assert_value accept_udp.ring_size 64
EDIT_VALUES[transport.type]='"ws"'
edit_complete_transport > "$test_dir/menu-output.log"
assert_absent transport.accept_udp
assert_absent accept_udp.ring_size
echo 'PASS: TCP UDP options are removed for other transports'

# IPX requires new addressing/security; switching out restores token/address prompts.
for edit_mode in server client; do
    fixture "$edit_mode" "$test_dir/original.toml"
    edit_load_config "$test_dir/original.toml"
    EDIT_VALUES[transport.type]='"tun"'
    test_encapsulation=ipx
    edit_complete_transport > "$test_dir/menu-output.log"
    assert_value ipx.mode "$edit_mode"
    assert_value ipx.dst_ip 192.0.2.2
    assert_value security.enable_encryption true
    assert_absent security.token
    assert_absent listener.bind_addr
    assert_absent dialer.remote_addr
    assert_absent transport.nodelay
    edit_write_config "$test_dir/result-$edit_mode-ipx.toml"
    EDIT_VALUES[security.enable_encryption]=false
    edit_complete_transport > "$test_dir/menu-output.log"
    assert_absent security.psk
    EDIT_VALUES[transport.type]='"anytls"'
    edit_complete_transport > "$test_dir/menu-output.log"
    assert_absent ipx.mode
    assert_value security.token 'new shared token'
    assert_value tls.sni www.digikala.com
    edit_write_config "$test_dir/result-$edit_mode-from-ipx.toml"
done
unset test_encapsulation
echo 'PASS: IPX addressing/encryption and transitions back to TLS transports'

# Restore the real interactive editor for end-to-end menu and input tests.
eval "$(declare -f real_edit_prompt_field | sed '1s/real_edit_prompt_field/edit_prompt_field/')"
edit_mode=server
fixture server "$test_dir/iran8443.toml"
cp "$test_dir/iran8443.toml" "$test_dir/before.toml"
edit_tunnel "$test_dir/iran8443.toml" > "$test_dir/menu-output.log" <<'EOF'
1
1
:9443
0
6
1
443=5443
0
s

EOF
edit_load_config "$test_dir/iran8443.toml"
assert_value listener.bind_addr :9443
assert_value ports.mapping 443=5443
cmp "$test_dir/before.toml" "$test_dir/iran8443.toml.bak"
grep -q '^restart backhaul-iran8443.service$' "$test_dir/systemctl.log" || fail 'edited service was not restarted'
grep -q 'keep # token' "$test_dir/menu-output.log" || fail 'menu did not show current settings'
echo 'PASS: easy menu edits address/mappings, saves, backs up and restarts the same service'

cp "$test_dir/iran8443.toml" "$test_dir/before.toml"
cp "$test_dir/systemctl.log" "$test_dir/before-services.log"
edit_tunnel "$test_dir/iran8443.toml" > "$test_dir/menu-output.log" <<'EOF'
3
1
cancelled-token
0
0
EOF
cmp "$test_dir/before.toml" "$test_dir/iran8443.toml"
cmp "$test_dir/before-services.log" "$test_dir/systemctl.log"
echo 'PASS: cancel leaves file and services unchanged'

# Change transport with actual numbered choices and default dependency answers.
fixture server "$test_dir/iran8443.toml"
edit_tunnel "$test_dir/iran8443.toml" > "$test_dir/menu-output.log" <<'EOF'
2
1
7







0
s

EOF
edit_load_config "$test_dir/iran8443.toml"
assert_value transport.type wssmux
assert_value mux.mux_version 2
assert_value tls.tls_cert "$CERT_FILE"
assert_value security.token 'keep # token'
cp "$test_dir/iran8443.toml" "$test_dir/before.toml"
echo 'PASS: numbered transport change prompts for mux/TLS details and saves successfully'

edit_load_config "$test_dir/iran8443.toml"
edit_sections
EDIT_VALUES[security.token]='"unsaved token"'
for failure in fail-next-restart fail-next-active; do
    touch "$test_dir/$failure"
    if edit_save_config "$test_dir/iran8443.toml" backhaul-iran8443.service > "$test_dir/menu-output.log"; then
        fail 'save should report failure'
    fi
    cmp "$test_dir/before.toml" "$test_dir/iran8443.toml"
    assert_value security.token 'unsaved token'
done
echo 'PASS: failed restart and inactive service restore the original file and keep edits available'

# Actual client menu input for a TUN/IPX transport, including newly required data.
fixture client "$test_dir/kharej8443.toml"
{
    printf '2\n1\n10\n2\n'
    printf '\n%.0s' {1..7}
    printf '192.0.2.2\neth0\n\n\n'
    printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    printf '\n0\ns\n\n'
} > "$test_dir/ipx-input.txt"
edit_tunnel "$test_dir/kharej8443.toml" < "$test_dir/ipx-input.txt" > "$test_dir/menu-output.log"
edit_load_config "$test_dir/kharej8443.toml"
assert_value transport.type tun
assert_value tun.encapsulation ipx
assert_value ipx.mode client
assert_value ipx.dst_ip 192.0.2.2
assert_value ipx.interface eth0
assert_value security.psk AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
assert_absent dialer.remote_addr
grep -q '^restart backhaul-kharej8443.service$' "$test_dir/systemctl.log" || fail 'client was not restarted'
echo 'PASS: client transport menu collects IPX addresses and encryption details'

# TLS clients can have additional settings; retain them while transport stays TLS.
edit_mode=client
fixture client "$test_dir/custom-client.toml"
edit_load_config "$test_dir/custom-client.toml"
EDIT_VALUES[transport.type]='"wss"'
EDIT_VALUES[tls.custom_option]=false
edit_complete_transport > "$test_dir/menu-output.log"
assert_value tls.custom_option false
echo 'PASS: custom TLS client settings are preserved'

edit_prompt_field listener.bind_addr '":8443"' > "$test_dir/menu-output.log" <<'EOF'
:99999
:1234
EOF
assert_value listener.bind_addr :1234
edit_prompt_field ports.mapping '[]' > "$test_dir/menu-output.log" <<'EOF'
9000-8000
0
443,8000-8010:9000
EOF
assert_value ports.mapping '443, 8000-8010:9000'
edit_prompt_field security.token '""' > "$test_dir/menu-output.log" <<'EOF'
literal "token" # $(touch /tmp/should-not-execute) \ path
EOF
assert_value security.token 'literal "token" # $(touch /tmp/should-not-execute) \ path'
edit_write_config "$test_dir/result-special-token.toml"
echo 'PASS: invalid ports/ranges are rejected and tokens remain literal data'

printf '[transport]\ntype = "tcp"\n[unknown.nested]\nvalue = 1\n' > "$test_dir/unsupported.toml"
if edit_load_config "$test_dir/unsupported.toml" > "$test_dir/menu-output.log"; then fail 'unsupported TOML should fail safely'; fi
echo 'PASS: unsupported TOML is rejected without saving'

"$PYTHON" - "$test_dir" <<'PY'
import pathlib, sys, tomllib
files = list(pathlib.Path(sys.argv[1]).glob('result-*.toml'))
assert len(files) == 25, len(files)
for path in files:
    with path.open('rb') as f:
        config = tomllib.load(f)
    assert 'transport' in config and 'security' in config
print(f'PASS: independent TOML validation of {len(files)} edited configurations')
PY
