#!/usr/bin/env bash
set -eo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo 'Bash 4+ required'; exit 1; }
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'test_status=$?; if ((test_status)); then tail -40 "$test_dir/output.log" >&2; fi; rm -rf "$test_dir"' EXIT
source <(sed -n '/^colorize() {/,/^install_jq() {/p' "$repo_dir/backhaul.sh" | sed '$d')
source <(sed -n '/^declare -A CONFIG/,/^SERVER_IP=/p' "$repo_dir/backhaul.sh" | sed '$d')
config_dir="$test_dir/configs"
service_dir="$test_dir/services"
CERT_DIR="$test_dir/certs"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
SERVER_IP=192.0.2.1
mkdir -p "$config_dir" "$service_dir" "$CERT_DIR" "$test_dir/source"
touch "$CERT_FILE" "$KEY_FILE"
colorize() { printf '%s\n' "$2"; }
sleep() { :; }
press_key() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_value() { [[ "$(edit_value "$1")" == "$2" ]] || fail "$1: expected $2, got $(edit_value "$1")"; }
systemctl() {
    echo "$*" >> "$test_dir/services.log"
    if [[ "$1" == enable && -f "$test_dir/fail-start" ]]; then rm "$test_dir/fail-start"; return 1; fi
    return 0
}
fixture() {
    local transport="$1" enc="${2:-tcp}" tun=false ipx=false
    CONFIG=(
        [bind_addr]=:8443 [remote_addr]=192.0.2.1:8443 [dial_timeout]=10 [retry_interval]=3
        [transport_type]="$transport" [nodelay]=true [keepalive_period]=40 [accept_udp]=false
        [proxy_protocol]=false [connection_pool]=8 [heartbeat_interval]=10 [heartbeat_timeout]=25
        [token]='shared "literal" # $(not_a_command)' [auto_tuning]=true [tuning_profile]=latency
        [workers]=2 [channel_size]=4096 [tcp_mss]=0 [so_rcvbuf]=0 [so_sndbuf]=0
        [buffer_profile]=low_cpu [read_timeout]=120 [log_level]=info [ports_mapping]='443,8443=443,5000-5010:5201'
        [tun_encapsulation]="$enc" [tun_name]=backhaul [tun_local_addr]=10.10.10.1/24
        [tun_remote_addr]=10.10.10.2/24 [tun_health_port]=1234 [tun_mtu]=1320 [forwarder]=backhaul
        [ipx_mode]=server [ipx_profile]=udp [ipx_listen_ip]=192.0.2.1 [ipx_dst_ip]=192.0.2.2
        [ipx_interface]=eth0 [enable_encryption]=true [algorithm]=aes-256-gcm
        [psk]=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= [kdf_iterations]=100000 [batch_size]=2048
        [mux_version]=2 [mux_framesize]=32768 [mux_recievebuffer]=4194304 [mux_streambuffer]=2097152 [mux_concurrency]=8
    )
    if [[ "$transport" == tun ]]; then
        tun=true
        if [[ "$enc" == ipx ]]; then ipx=true; unset 'CONFIG[nodelay]' 'CONFIG[keepalive_period]'; fi
    fi
    if [[ "$transport" =~ ^(wss|wssmux|anytls)$ ]]; then CONFIG[tls_cert]="$CERT_FILE"; CONFIG[tls_key]="$KEY_FILE"; fi
    [[ "$transport" == anytls ]] && CONFIG[tls_sni]=example.com
    generate_toml_config server "$test_dir/source/iran8443.toml" "$tun" "$ipx"
}

for transport in tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun; do
    fixture "$transport"
    link=$(peer_setup_link "$test_dir/source/iran8443.toml" <<< '192.0.2.1')
    load_setup_link "$link" > "$test_dir/output.log"
    assert_value transport.type "$transport"
    assert_value security.token 'shared "literal" # $(not_a_command)'
    assert_value dialer.remote_addr 192.0.2.1:8443
    [[ -z "${EDIT_VALUES[listener.bind_addr]+present}" && -z "${EDIT_VALUES[tls.tls_key]+present}" ]] || fail 'server-local settings were exported'
    if [[ "$transport" == tun ]]; then
        assert_value tun.local_addr 10.10.10.2/24
        assert_value tun.remote_addr 10.10.10.1/24
    fi
    edit_write_config "$test_dir/peer-$transport.toml"
done
fixture tun ipx
link=$(peer_setup_link "$test_dir/source/iran8443.toml")
load_setup_link "$link" > "$test_dir/output.log"
assert_value ipx.mode client
assert_value ipx.listen_ip 192.0.2.2
assert_value ipx.dst_ip 192.0.2.1
[[ -z "${EDIT_VALUES[ipx.interface]+present}" ]] || fail 'host-local interface should be requested on KHAREJ'
bad=$(decode_backhaul_link backhaul "$link" | jq -c '.settings["security.psk"] += "!"')
set +o pipefail
if load_setup_link "$(encode_backhaul_link backhaul "$bad")" > "$test_dir/output.log" 2>&1; then fail 'invalid PSK accepted without pipefail'; fi
set -o pipefail
load_setup_link "$link"
install_link_settings > "$test_dir/output.log" <<'EOF'
eth1
y
EOF
edit_load_config "$config_dir/kharej1234.toml"
assert_value ipx.interface eth1
rm "$config_dir/kharej1234.toml" "$service_dir/backhaul-kharej1234.service"
echo 'PASS: links pair every transport, swap TUN/IPX addresses, preserve literal credentials and request local interfaces'

fixture tcp
link=$(peer_setup_link "$test_dir/source/iran8443.toml" <<< '2001:db8::1')
load_setup_link "$link" > "$test_dir/output.log"
assert_value dialer.remote_addr '[2001:db8::1]:8443'
install_link_settings <<< y > "$test_dir/output.log"
[[ -f "$service_dir/backhaul-kharej8443.service" ]] || fail 'service not created'
cp "$config_dir/kharej8443.toml" "$test_dir/before.toml"
fixture wssmux
CONFIG[bind_addr]=:9443
generate_toml_config server "$test_dir/source/iran8443.toml" false false
link=$(peer_setup_link "$test_dir/source/iran8443.toml" <<< '192.0.2.1')
load_setup_link "$link" > "$test_dir/output.log"
install_link_settings <<< y > "$test_dir/output.log"
edit_load_config "$config_dir/kharej8443.toml"
assert_value transport.type wssmux
assert_value dialer.remote_addr 192.0.2.1:9443
cmp "$test_dir/before.toml" "$config_dir/kharej8443.toml.bak"
[[ ! -e "$config_dir/kharej9443.toml" ]] || fail 'duplicate tunnel was created instead of updating'
grep -q '^restart backhaul-kharej8443.service$' "$test_dir/services.log" || fail 'updated tunnel not restarted'
echo 'PASS: IPv6 setup works; reapplying a link updates/restarts one existing tunnel with a backup'

cp "$config_dir/kharej8443.toml" "$test_dir/before.toml"
load_setup_link "$link"
install_link_settings <<< n > "$test_dir/output.log"
cmp "$test_dir/before.toml" "$config_dir/kharej8443.toml"
bad=$(decode_backhaul_link backhaul "$link" | jq -c '.settings["transport.connection_pool"]="oops"')
if load_setup_link "$(encode_backhaul_link backhaul "$bad")" > "$test_dir/output.log" 2>&1; then fail 'wrong types accepted'; fi
bad=$(decode_backhaul_link backhaul "$link" | jq -c '.settings["listener.bind_addr"]="$(not_a_command)"')
if load_setup_link "$(encode_backhaul_link backhaul "$bad")" > "$test_dir/output.log" 2>&1; then fail 'unexpected fields accepted'; fi
if load_setup_link 'backpack://2.not-compatible' > "$test_dir/output.log" 2>&1; then fail 'wrong scheme accepted'; fi
if load_setup_link 'backhaul://1.bad!' > "$test_dir/output.log" 2>&1; then fail 'bad encoding accepted'; fi
cmp "$test_dir/before.toml" "$config_dir/kharej8443.toml"
echo 'PASS: cancellation, malformed links, unknown fields and wrong types leave files untouched'

restore_tunnel_backup "$config_dir/kharej8443.toml" <<< y > "$test_dir/output.log"
edit_load_config "$config_dir/kharej8443.toml"
assert_value transport.type tcp
assert_value dialer.remote_addr '[2001:db8::1]:8443'
cp "$config_dir/kharej8443.toml" "$test_dir/before.toml"
toggle_tunnel_service backhaul-kharej8443.service > "$test_dir/output.log"
grep -q '^stop backhaul-kharej8443.service$' "$test_dir/services.log" || fail 'selected tunnel not stopped'
echo 'PASS: restore and stop actions affect only the selected tunnel'

fixture tcp
CONFIG[token]=unique-new-token
generate_toml_config server "$test_dir/source/iran8443.toml" false false
link=$(peer_setup_link "$test_dir/source/iran8443.toml" <<< '192.0.2.1')
load_setup_link "$link"
if install_link_settings <<< y > "$test_dir/output.log"; then fail 'same-filename different tunnel should be refused'; fi
CONFIG[bind_addr]=:9555
generate_toml_config server "$test_dir/source/iran8443.toml" false false
link=$(peer_setup_link "$test_dir/source/iran8443.toml" <<< '192.0.2.1')
load_setup_link "$link"
touch "$test_dir/fail-start"
if install_link_settings <<< y > "$test_dir/output.log"; then fail 'failed service start was reported as success'; fi
[[ ! -f "$config_dir/kharej9555.toml" && ! -f "$service_dir/backhaul-kharej9555.service" ]] || fail 'failed import not cleaned up'
cmp "$test_dir/before.toml" "$config_dir/kharej8443.toml"
echo 'PASS: name collisions and failed starts do not overwrite or disturb other tunnels'

# Networking calls are recorded here; socket/data-path integration lives in Python.
connection_tool() {
    if [[ "$1" == fingerprint ]]; then
        printf '%s' "$2" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    else
        printf '%s\n' "$*" >> "$test_dir/probes.log"
    fi
}
fixture tcp
cp "$test_dir/source/iran8443.toml" "$config_dir/iran8443.toml"
cp "$config_dir/iran8443.toml" "$test_dir/untouched.toml"
cp "$test_dir/services.log" "$test_dir/untouched-services.log"
prepare_traffic_test "$config_dir/iran8443.toml" > "$test_dir/output.log" <<'EOF'
3
5003

EOF
test_link=$(sed -n '/^backhaul-test:\/\//p' "$test_dir/output.log")
json=$(decode_backhaul_link backhaul-test "$test_link")
[[ "$(printf '%s' "$json" | jq -r .port)" == 5201 ]] || fail 'range backend mapping incorrect'
grep -q '^traffic 127.0.0.1 5003 ' "$test_dir/probes.log" || fail 'wrong mapping was tested'
[[ "$(wc -l < "$test_dir/probes.log" | tr -d ' ')" == 1 ]] || fail 'more than one test ran'
cmp "$test_dir/untouched.toml" "$config_dir/iran8443.toml"
cmp "$test_dir/untouched-services.log" "$test_dir/services.log"
fixture tun ipx
cp "$test_dir/source/iran8443.toml" "$config_dir/iran8443.toml"
quick_connection_test "$config_dir/iran8443.toml" > "$test_dir/output.log"
[[ "$(wc -l < "$test_dir/probes.log" | tr -d ' ')" == 1 ]] || fail 'IPX incorrectly probed with TCP'
echo 'PASS: exactly one selected mapping is tested; no config/service changes and no TCP false negatives for IPX'

"${PYTHON:-python3}" - "$test_dir" <<'PY'
import pathlib, sys, tomllib
files = list(pathlib.Path(sys.argv[1]).glob('peer-*.toml'))
assert len(files) == 10
for path in files:
    with path.open('rb') as f:
        config = tomllib.load(f)
    assert 'dialer' in config and 'listener' not in config and 'ports' not in config
print('PASS: independent TOML validation of ten peer configurations')
PY
