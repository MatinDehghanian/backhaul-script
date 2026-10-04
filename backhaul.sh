#!/bin/bash

# Define script version
SCRIPT_VERSION="v1.1.0"

if ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash 4 or newer."
    exit 1
fi

# Global Variables
service_dir="/etc/systemd/system"
config_dir="/root/backhaul-core"
CERT_DIR="/root/backhaul-core/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"

# Ensure cert_files directory exists
mkdir -p "$CERT_DIR"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   sleep 1
   exit 1
fi

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"

    local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
    local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
    local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"

    local color_code
    case $color in
        black) color_code=$black ;; red) color_code=$red ;;
        green) color_code=$green ;; yellow) color_code=$yellow ;;
        blue) color_code=$blue ;; magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;; white) color_code=$white ;;
        *) color_code=$reset ;;
    esac

    local style_code
    case $style in
        bold) style_code=$bold ;; underline) style_code=$underline ;;
        normal | *) style_code=$normal ;;
    esac

    echo -e "${style_code}${color_code}${text}${reset}"
}

press_key() {
    read -r -p "Press any key to continue..."
}

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input

    echo -ne "[-] $prompt (default: $default): "
    read -r input
    printf -v "$var_name" '%s' "${input:-$default}"
}

toml_string_setting() {
    printf '%s = %s\n' "$1" "$(jq -cn --arg value "$2" '$value')"
}

prompt_boolean() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    while true; do
        prompt_with_default "$prompt [true/false]" "$default" "$var_name"
        local value="${!var_name}"
        if [[ "$value" == "true" || "$value" == "false" ]]; then
            break
        fi
        colorize red "Invalid input. Please enter 'true' or 'false'."
    done
}

validate_cidr() {
    local cidr="$1" ip mask a b c d

    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi

    IFS='/' read -r ip mask <<< "$cidr"
    IFS='.' read -r a b c d <<< "$ip"

    # Parse decimal explicitly so input such as /08 cannot trigger octal errors.
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d)); mask=$((10#$mask))

    if (( a<0 || a>255 || b<0 || b>255 || c<0 || c>255 || d<0 || d>255 )); then
        return 1
    fi

    if (( mask < 1 || mask > 32 )); then
        return 1
    fi

    local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))

    local mask_int
    if (( mask == 32 )); then
        mask_int=0xFFFFFFFF
    else
        mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    fi

    local net_int=$(( ip_int & mask_int ))
    local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))

    # Reject if IP is network address
    if (( ip_int == net_int )); then
        return 1
    fi

    # Reject if IP is broadcast address
    if (( ip_int == broadcast_int )); then
        return 1
    fi

    return 0
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            colorize yellow "Installing jq..."
            sudo apt-get update && sudo apt-get install -y jq
        else
            colorize red "Error: Unsupported package manager. Please install jq manually."
            press_key
            exit 1
        fi
    fi
}

download_backhaul() {
    if [[ "$1" == "menu" ]]; then
        colorize cyan "Restart all services after updating to new core" bold
        sleep 2
    elif [[ -f "${config_dir}/backhaul_premium" ]]; then
        chmod +x "${config_dir}/backhaul_premium" || exit 1
        return 0
    fi

    local download_url="https://raw.githubusercontent.com/MatinDehghanian/backhaul-script/refs/heads/main/backhaul"
    local download_dir
    mkdir -p "$config_dir" || exit 1
    download_dir=$(mktemp -d "${config_dir}/.backhaul-download.XXXXXX") || exit 1
    echo "Downloading Backhaul..."

    if ! curl -fSL --retry 2 --max-time 30 -o "$download_dir/backhaul" "$download_url"; then
        colorize red "Download failed."
        rm -rf "$download_dir"
        exit 1
    fi

    if ! chmod +x "$download_dir/backhaul" || ! mv -f "$download_dir/backhaul" "${config_dir}/backhaul_premium"; then
        colorize red "Backhaul installation failed."
        rm -rf "$download_dir"
        exit 1
    fi
    rm -rf "$download_dir"
    colorize green "Backhaul installation completed."
}

install_jq
download_backhaul

# ============================================================================
# CONFIGURATION SECTIONS - MODULAR PROMPTING
# ============================================================================

# Declare config storage
declare -A CONFIG

# Reset config
reset_config() {
    CONFIG=()
}

# Section: Connection (Listener or Dialer)
prompt_connection_section() {
    local mode="$1"  # server or client

    colorize blue "━━━ Connection Configuration ━━━" bold

    if [[ "$mode" == "server" ]]; then
        # Server: listener section
        prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]

        # If no colon is included, prepend ":"
        if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
            CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
        fi

        #CONFIG[bind_addrs]="[]"
    else
        # Client: dialer section
        while true; do
            echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
            read -r CONFIG[remote_addr]

            # Check non-empty
            if [[ -z "${CONFIG[remote_addr]}" ]]; then
                colorize red "Server address cannot be empty."
                continue
            fi

            # Validate pattern: IP:Port or Domain:Port
            # IP: 1-3 digits per octet, 0-255 (basic check), Port: 1-65535
            # Domain: letters, digits, hyphens, dots
            if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
                  "${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
                break
            else
                colorize red "Invalid format. Use IP:Port or Domain:Port."
            fi
        done

      #Port Mapping Configuration  # Edge IP/Domain only for ws wss wsmux wssmux xwsmux
        if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
            echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
            read -r CONFIG[edge_ip]
        fi

        #CONFIG[remote_addrs]="[]"
        #CONFIG[local_addr]=""
        #CONFIG[local_addrs]="[]"
        CONFIG[dial_timeout]="10"
        CONFIG[retry_interval]="3"
    fi
    echo ""
}

# Section: Security
VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")

is_valid_algorithm() {
    local input="$1"
    for alg in "${VALID_ALGORITHMS[@]}"; do
        if [[ "$input" == "$alg" ]]; then
            return 0
        fi
    done
    return 1
}

prompt_security_section() {
    local is_ipx="$1"

    colorize blue "━━━ Security Configuration ━━━" bold

    if [[ "$is_ipx" == "true" ]]; then
        # IPX encapsulation - use encryption instead of token
        prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]

        if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
            echo
            while true; do
                colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
                prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]

                if is_valid_algorithm "${CONFIG[algorithm]}"; then
                    break
                else
                    colorize red "Invalid algorithm selected. Please choose one from the list."
                    echo
                fi
            done

            local generated_psk
            generated_psk=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
            prompt_with_default "PSK (base64-encoded 32 bytes)" "$generated_psk" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        # Non-IPX - use token
        prompt_with_default "Security Token" "$(random_secret)" CONFIG[token]
        CONFIG[enable_encryption]="false"
    fi
    echo ""
}

# Section: Transport
prompt_transport_section() {
    local mode="$1"
    local is_ipx="false"

    colorize blue "━━━ Transport Configuration ━━━" bold

    # Transport type selection
    local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
    echo "Available transports:"
    printf '  • %s\n' "${valid_transports[@]}"

    while true; do
        echo -ne "Select transport: "
        read -r CONFIG[transport_type]
        [[ " ${valid_transports[*]} " =~ " ${CONFIG[transport_type]} " ]] && break
        colorize red "Invalid transport."
    done

    # if tun selected, get encapsulation type
    if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
        echo
        local encapsulations=(tcp ipx)
        echo "Available encapsulations:"
        printf '  • %s\n' "${encapsulations[@]}"

          while true; do
              echo -ne "Select encapsulation: "
              read -r CONFIG[tun_encapsulation]
              [[ " ${encapsulations[*]} " =~ " ${CONFIG[tun_encapsulation]} " ]] && break
              colorize red "Invalid encapsulation."
          done
    fi

    echo

    if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
        is_ipx="true"
    fi

    # Nodelay - except ipx
    if [[ "$is_ipx" != "true" ]]; then
        prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
    fi

    # Mode-specific options
    if [[ "$mode" == "server" ]]; then
        # Accept UDP - only for tcp transport
        if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
            prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
        fi

        # Proxy Protocol - except tun, ipx, ws
        if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
            prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
        fi
    else
        # Connection pool - except tun
        if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
            prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
        fi
    fi

    # Heartbeat
    CONFIG[heartbeat_interval]="10"
    CONFIG[heartbeat_timeout]="25"

    # keepalive - except ipx
    if [[ "$is_ipx" != "true" ]]; then
        CONFIG[keepalive_period]="40"
    fi

    echo ""
}

# Section: Mux (for mux transports)
prompt_mux_section() {
    local transport="$1"

    if [[ ! "$transport" =~ mux$ ]]; then
        return
    fi

    colorize blue "━━━ Mux Configuration ━━━" bold
    prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
    prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
    CONFIG[mux_framesize]="32768"
    CONFIG[mux_recievebuffer]="4194304"
    CONFIG[mux_streambuffer]="2097152"
    echo ""
}

# Section: TUN (for tun transport)
prompt_tun_section() {
    local transport="$1"
    local mode="$2"
    local is_ipx="$3"

    [[ "$transport" != "tun" ]] && return

    colorize blue "━━━ TUN Configuration ━━━" bold

    prompt_with_default "TUN Device Name" "backhaul" CONFIG[tun_name]

    # Local and Remote addresses with CIDR validation
    # Server: local=10.10.10.3/24, remote=10.10.10.4/24
    # Client: local=10.10.10.4/24, remote=10.10.10.3/24
    local default_local default_remote
    if [[ "$mode" == "server" ]]; then
        default_local="10.10.10.1/24"
        default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"
        default_remote="10.10.10.1/24"
    fi

    while true; do
        prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
        if validate_cidr "${CONFIG[tun_local_addr]}"; then
            break
        fi
        local suggested=$(validate_cidr "${CONFIG[tun_local_addr]}" 2>&1)
        colorize red "Invalid CIDR. Network address should be: $suggested"
    done

    while true; do
        prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
        if validate_cidr "${CONFIG[tun_remote_addr]}"; then
            break
        fi
        colorize red "Invalid CIDR format."
    done

    prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]

    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
    else
        prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
    fi
    echo ""
}

# Section: TLS (for anytls, wss, wssmux)
prompt_tls_section() {
    local mode="$1"
    local transport="$2"

    if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
        return
    fi

    colorize blue "━━━ TLS Configuration ━━━" bold
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
    fi

    if [[ "$mode" == "client" ]]; then
        echo
        return
    fi

    # Generate cert/key if missing
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        colorize red "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out  "$CERT_FILE" -subj "/CN=backhaul.com"
        colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
        echo
    fi

    # Prompt for cert/key paths with defaults pointing to generated files
    prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
    prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
    echo ""
}

# Section: Tuning
prompt_tuning_section() {
    local is_ipx="$1"
    local is_tun="$2"

    colorize blue "━━━ Tuning Configuration ━━━" bold
    prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
    echo
    colorize magenta "Profiles: balanced, fast, latency, resource" normal
    prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
    prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]

    if [[ "$is_tun" != "true" ]]; then
        prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
    fi

    if [[ "$is_tun" == "true" ]]; then
            CONFIG[channel_size]="10_000"
    fi

    # Batch size - for ipx
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    else
        prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
        prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    fi

    # Read timeout - except tun, ipx
    if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
        echo
        colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
        prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
        prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
    fi

    #CONFIG[max_connections]="0"
    echo ""
}

# Section: Logging
prompt_logging_section() {
    colorize blue "━━━ Logging Configuration ━━━" bold
    colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
    prompt_with_default "Log Level" "info" CONFIG[log_level]
    echo ""
}

# Section: Accept UDP (only if enabled)
prompt_accept_udp_section() {
    local accept_udp="$1"

    [[ "$accept_udp" != "true" ]] && return

    CONFIG[ring_size]="64"
    CONFIG[frame_size]="2048"
    CONFIG[peer_idle_timeout_s]="120"
    CONFIG[write_timeout_ms]="3"
}

# Section: Ports
prompt_ports_section() {
    local mode="$1"
    local is_tun="$2"

  [[ "$mode" != "server" ]] && return

    if [[ "$is_tun" != "true" ]]; then
        colorize blue "━━━ Port Mapping Configuration ━━━" bold
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo "  3. 443-600       - Listen on range 443-600"
        echo "  4. 443-600:5201  - Range forwarding to 5201"
        echo ""

        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""

    else
        colorize blue "━━━ Port Mapping Configuration (tun helper) ━━━" bold
        colorize magenta "Forwarder: use 'bbackhaul' for TCP support only, or 'iptables' for TCP + UDP support"
        prompt_with_default "Forwarder (backhaul/iptables)" "backhaul" CONFIG[forwarder]
        echo ""
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo ""

        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""

    fi
}


# Section: IPX (only for ipx encapsulation)
prompt_ipx_section() {
    local is_ipx="$1"
    local mode="$2"

    [[ "$is_ipx" != "true" ]] && return

    colorize blue "━━━ IPX Configuration ━━━" bold

    CONFIG[ipx_mode]="$mode"

    # Available profiles
    AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")

    # Show available protocols
    colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"

    while true; do
        # Prompt user with default
        prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]

        # Normalize to lowercase
        CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"

        # Validate selection
        for profile in "${AVAILABLE_PROFILES[@]}"; do
            if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
                break 2
            fi
        done

        colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
        echo
        colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
    done


    prompt_with_default "Listen IP" $SERVER_IP CONFIG[ipx_listen_ip]

    while :; do
        prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]

        if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
            break
        fi

        colorize red "Destination IP cannot be empty."
    done


    interface=$(ip route show default | awk '{print $5}')
    prompt_with_default "Network Interface" $interface CONFIG[ipx_interface]

    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
        prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
    fi
    echo ""
}

# ============================================================================
# TOML GENERATION
# ============================================================================

generate_toml_config() {
    local mode="$1"
    local output_file="$2"
    local is_tun="$3"
    local is_ipx="$4"

    {
        # Connection section
        if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
            echo "[listener]"
            toml_string_setting "bind_addr" "${CONFIG[bind_addr]}"
            #echo "bind_addrs = ${CONFIG[bind_addrs]}"
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            toml_string_setting "remote_addr" "${CONFIG[remote_addr]}"
            #echo "remote_addrs = ${CONFIG[remote_addrs]}"
            #[[ -n "${CONFIG[local_addr]}" ]] && toml_string_setting "local_addr" "${CONFIG[local_addr]}"
            #echo "local_addrs = ${CONFIG[local_addrs]}"
            [[ -n "${CONFIG[edge_ip]}" ]] && toml_string_setting "edge_ip" "${CONFIG[edge_ip]}"
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi


        # Transport section
        echo "[transport]"
        toml_string_setting "type" "${CONFIG[transport_type]}"
        [[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
        [[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"

        if [[ "$mode" == "server" ]]; then
            [[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
            [[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
        else
            [[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] && \
                echo "connection_pool = ${CONFIG[connection_pool]}"
        fi

        [[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
        [[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
        echo ""


        # TUN section (if tun transport)
        if [[ "$is_tun" == "true" ]]; then
            echo "[tun]"
            toml_string_setting "encapsulation" "${CONFIG[tun_encapsulation]}"
            toml_string_setting "name" "${CONFIG[tun_name]}"
            toml_string_setting "local_addr" "${CONFIG[tun_local_addr]}"
            toml_string_setting "remote_addr" "${CONFIG[tun_remote_addr]}"
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            echo ""
        fi

        # IPX section (if ipx encapsulation)
        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            toml_string_setting "mode" "${CONFIG[ipx_mode]}"
            toml_string_setting "profile" "${CONFIG[ipx_profile]}"
            toml_string_setting "listen_ip" "${CONFIG[ipx_listen_ip]}"
            toml_string_setting "dst_ip" "${CONFIG[ipx_dst_ip]}"
            toml_string_setting "interface" "${CONFIG[ipx_interface]}"
            [[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
            [[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
            echo ""
        fi

        # Mux section (if mux transport)
        if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
            echo "[mux]"
            echo "mux_version = ${CONFIG[mux_version]}"
            echo "mux_framesize = ${CONFIG[mux_framesize]}"
            echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
            echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
            [[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
            echo ""
        fi

        # Security section
        echo "[security]"
        if [[ "$is_ipx" == "true" ]]; then
            echo "enable_encryption = ${CONFIG[enable_encryption]}"
            [[ "${CONFIG[enable_encryption]}" == "true" ]] && {
                toml_string_setting "algorithm" "${CONFIG[algorithm]}"
                toml_string_setting "psk" "${CONFIG[psk]}"
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            }
        else
            toml_string_setting "token" "${CONFIG[token]}"
        fi

        echo ""

        # TLS section (if needed)
        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
            echo "[tls]"

            [[ -n "${CONFIG[tls_sni]}" ]]  && toml_string_setting "sni" "${CONFIG[tls_sni]}"
            [[ -n "${CONFIG[tls_cert]}" ]] && toml_string_setting "tls_cert" "${CONFIG[tls_cert]}"
            [[ -n "${CONFIG[tls_key]}" ]]  && toml_string_setting "tls_key" "${CONFIG[tls_key]}"

            echo ""
        fi

        # Tuning section
        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]]  && toml_string_setting "tuning_profile" "${CONFIG[tuning_profile]}"
        [[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]]  && toml_string_setting "buffer_profile" "${CONFIG[buffer_profile]}"
        [[ -n "${CONFIG[batch_size]}" ]]      && echo "batch_size = ${CONFIG[batch_size]}"
        [[ -n "${CONFIG[read_timeout]}" ]]    && echo "read_timeout = ${CONFIG[read_timeout]}"
        #[[ -n "${CONFIG[max_connections]}" ]] && echo "max_connections = ${CONFIG[max_connections]}"

        echo ""

        # Accept UDP section (if enabled)
        if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
            echo "[accept_udp]"
            echo "ring_size = ${CONFIG[ring_size]}"
            echo "frame_size = ${CONFIG[frame_size]}"
            echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
            echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
            echo ""
        fi

        # Logging section
        echo "[logging]"
        toml_string_setting "log_level" "${CONFIG[log_level]}"
        echo ""

        # Ports section (if not client)
        if [[ "$mode" == "server" ]] ; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]]  && toml_string_setting "forwarder" "${CONFIG[forwarder]}"
            echo "mapping = ["
            IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
            for port in "${ports[@]}"; do
                [[ -n "$port" ]] && echo "    \"${port// /}\","
            done
            echo "]"
        fi

    } > "$output_file"
}

# ============================================================================
# UNIFIED CONFIGURATION FUNCTION
# ============================================================================

configure_server() {
    local mode="$1"  # server or client
    local mode_name

    if [[ "$mode" == "server" ]]; then
        mode_name="IRAN (Server)"
    else
        mode_name="KHAREJ (Client)"
    fi

    clear
    colorize cyan "Configuring $mode_name" bold
    echo ""

    # Reset configuration
    reset_config

    # Prompt all sections

    # Determine if IPX encapsulation (we'll know after transport selection)
    # For now, assume non-IPX, will update if tun+ipx is selected

    prompt_transport_section "$mode"

    # Check if TUN transport
    local is_tun="false"
    local is_ipx="false"
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"

    prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
    prompt_ipx_section "$is_ipx" "$mode"

    if [[ "$is_ipx" != "true" ]]; then
        prompt_connection_section "$mode"
    fi

    prompt_security_section "$is_ipx"

    prompt_accept_udp_section "${CONFIG[accept_udp]}"
    prompt_mux_section "${CONFIG[transport_type]}"
    prompt_tls_section "$mode" "${CONFIG[transport_type]}"
    prompt_tuning_section "$is_ipx" "$is_tun"
    prompt_logging_section
    prompt_ports_section "$mode" "$is_tun"

    # Determine tunnel port
    local tunnel_port
    if [[ "$is_ipx" == true ]]; then
        tunnel_port="${CONFIG[tun_health_port]}"
    elif [[ "$mode" == "server" ]]; then
        tunnel_port="${CONFIG[bind_addr]##*:}"
    else
        tunnel_port="${CONFIG[remote_addr]##*:}"
    fi
    if [[ ! "$tunnel_port" =~ ^[0-9]{1,5}$ ]] || ((10#$tunnel_port < 1 || 10#$tunnel_port > 65535)); then
        colorize red 'Tunnel port must be 1-65535.'; press_key; return 1
    fi

    # Generate config file
    local config_file
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"
    fi

    # Create systemd service
    local service_type
    [[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
    if [[ -e "$config_file" || -e "$service_dir/backhaul-${service_type}${tunnel_port}.service" ]]; then
        colorize red 'A tunnel already uses this name/port. Use Tunnel management → Edit instead.'
        press_key; return 1
    fi
    local temporary
    temporary=$(mktemp "$config_dir/.setup.XXXXXX") || return 1
    if ! generate_toml_config "$mode" "$temporary" "$is_tun" "$is_ipx" ||
       ! edit_load_config "$temporary" || ! chmod 600 "$temporary" || ! ln "$temporary" "$config_file"; then
        rm -f "$temporary"
        colorize red 'Invalid settings or configuration could not be saved.'; press_key; return 1
    fi
    rm -f "$temporary"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file" || { press_key; return 1; }

    echo ""
    colorize green "✔ Configuration completed successfully!" bold
    if [[ "$mode" == server ]]; then
        echo 'KHAREJ setup link (contains credentials; keep private):'
        peer_setup_link "$config_file"
    fi
    echo ""
    press_key
}

# ============================================================================
# SYSTEMD SERVICE MANAGEMENT
# ============================================================================

# Easy editor. Values stay serialized as TOML/JSON scalars; never source a config.
declare -A EDIT_VALUES
declare -a EDIT_SECTIONS

edit_trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

edit_strip_comment() {
    local line="$1" result="" char quoted=false escaped=false i
    for ((i=0; i<${#line}; i++)); do
        char="${line:i:1}"
        if [[ "$escaped" == true ]]; then
            escaped=false
        elif [[ "$quoted" == true && "$char" == \\ ]]; then
            escaped=true
        elif [[ "$char" == '"' ]]; then
            [[ "$quoted" == true ]] && quoted=false || quoted=true
        elif [[ "$quoted" == false && "$char" == '#' ]]; then
            break
        fi
        result+="$char"
    done
    edit_trim "$result"
}

edit_load_config() {
    local file="$1" line section="" key value normalized pending="" number=0
    local section_pattern='^\[([a-zA-Z_][a-zA-Z0-9_]*)\]$'
    local field_pattern='^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
    EDIT_VALUES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((number+=1))
        line=$(edit_strip_comment "$line")
        [[ -z "$line" ]] && continue
        if [[ -n "$pending" ]]; then
            value+="$line"
        elif [[ "$line" =~ $section_pattern ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        elif [[ -n "$section" && "$line" =~ $field_pattern ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ -n "${EDIT_VALUES[$section.$key]+present}" ]]; then
                colorize red "Duplicate setting at line $number. File unchanged."
                return 1
            fi
        else
            colorize red "Cannot edit this TOML format at line $number. File unchanged."
            return 1
        fi
        if [[ "$value" == \[* && "$value" != *\] ]]; then
            pending=true
            continue
        fi
        pending=""
        # Script-generated TOML uses JSON-compatible strings/arrays and integers.
        # Remove TOML integer separators and the trailing comma in mapping arrays.
        if [[ "$value" =~ ^[0-9][0-9_]*$ ]]; then value="${value//_/}"; fi
        normalized=$(printf '%s' "$value" | sed 's/,[[:space:]]*]$/]/' | jq -c '
            if type == "string" or type == "boolean" or
                (type == "number" and . >= 0 and floor == .) or
                (type == "array" and all(.[]; type == "string")) then .
            else error("Unsupported TOML value") end') || {
            colorize red "Unsupported value at line $number. The editor supports script-generated TOML. File unchanged."
            return 1
        }
        [[ -n "$normalized" && "$normalized" != *$'\n'* ]] || {
            colorize red "Missing or invalid value at line $number. File unchanged."
            return 1
        }
        EDIT_VALUES[$section.$key]="$normalized"
    done < "$file"
    if [[ -n "$pending" || -z "${EDIT_VALUES[transport.type]}" ]]; then
        colorize red "Incomplete configuration. File unchanged."
        return 1
    fi
}

edit_value() {
    local value="${EDIT_VALUES[$1]:-$2}"
    [[ -n "$value" ]] && printf '%s' "$value" | jq -r 'if type == "array" then join(", ") else . end'
    return 0
}

# Fields are listed in menu order with defaults for settings absent from a file.
edit_fields() {
    case "$1" in
        listener) echo 'bind_addr|":8443"' ;;
        dialer) cat <<'EOF'
remote_addr|""
dial_timeout|10
retry_interval|3
EOF
            [[ "$(edit_value transport.type)" =~ ^(ws|wss|wsmux|wssmux|xwsmux)$ ]] && echo 'edge_ip|""'
            ;;
        transport) cat <<'EOF'
type|"tcp"
heartbeat_interval|10
heartbeat_timeout|25
EOF
            if [[ "$(edit_value tun.encapsulation)" != ipx ]]; then
                echo 'nodelay|true'
                echo 'keepalive_period|40'
            fi
            if [[ "$edit_mode" == server ]]; then
                [[ "$(edit_value transport.type)" == tcp ]] && echo 'accept_udp|false'
                [[ ! "$(edit_value transport.type)" =~ ^(tun|ws)$ ]] && echo 'proxy_protocol|false'
            elif [[ "$(edit_value transport.type)" != tun ]]; then
                echo 'connection_pool|8'
            fi
            ;;
        tun)
            echo 'encapsulation|"tcp"'
            echo 'name|"backhaul"'
            if [[ "$edit_mode" == server ]]; then
                echo 'local_addr|"10.10.10.1/24"'; echo 'remote_addr|"10.10.10.2/24"'
            else
                echo 'local_addr|"10.10.10.2/24"'; echo 'remote_addr|"10.10.10.1/24"'
            fi
            echo 'health_port|1234'
            [[ "$(edit_value tun.encapsulation)" == ipx ]] && echo 'mtu|1320' || echo 'mtu|1500'
            ;;
        ipx)
            local default_interface
            default_interface=$(ip route show default 2>/dev/null | awk '{print $5; exit}') || default_interface=""
            echo "listen_ip|$(jq -Rn --arg value "$SERVER_IP" '$value')"
            cat <<'EOF'
profile|"tcp"
dst_ip|""
EOF
            echo "interface|$(jq -Rn --arg value "$default_interface" '$value')"
            if [[ "$(edit_value ipx.profile)" == icmp ]]; then
                echo 'icmp_type|0'; echo 'icmp_code|0'
            fi
            ;;
        mux) cat <<'EOF'
mux_version|2
mux_concurrency|8
mux_framesize|32768
mux_recievebuffer|4194304
mux_streambuffer|2097152
EOF
            ;;
        security)
            if [[ "$(edit_value tun.encapsulation)" == ipx ]]; then
                echo 'enable_encryption|true'
                if [[ "$(edit_value security.enable_encryption true)" == true ]]; then
                    echo 'algorithm|"aes-256-gcm"'; echo 'psk|""'; echo 'kdf_iterations|100000'
                fi
            else
                echo 'token|""'
            fi
            ;;
        tls)
            [[ "$(edit_value transport.type)" == anytls ]] && echo 'sni|"www.digikala.com"'
            if [[ "$edit_mode" == server ]]; then
                echo "tls_cert|$(jq -Rn --arg value "$CERT_FILE" '$value')"
                echo "tls_key|$(jq -Rn --arg value "$KEY_FILE" '$value')"
            fi
            ;;
        tuning)
            cat <<'EOF'
auto_tuning|true
tuning_profile|"balanced"
workers|0
channel_size|4096
so_sndbuf|0
EOF
            if [[ "$(edit_value tun.encapsulation)" == ipx ]]; then
                echo 'batch_size|2048'
            else
                echo 'tcp_mss|0'; echo 'so_rcvbuf|0'
            fi
            if [[ "$(edit_value transport.type)" != tun ]]; then
                echo 'buffer_profile|"balanced"'; echo 'read_timeout|120'
            fi
            ;;
        accept_udp) cat <<'EOF'
ring_size|64
frame_size|2048
peer_idle_timeout_s|120
write_timeout_ms|3
EOF
            ;;
        logging) echo 'log_level|"info"' ;;
        ports)
            echo 'mapping|[]'
            [[ "$(edit_value transport.type)" == tun ]] && echo 'forwarder|"backhaul"'
            ;;
    esac
    return 0
}

edit_sections() {
    local transport="$(edit_value transport.type)"
    EDIT_SECTIONS=()
    if [[ "$transport" != tun || "$(edit_value tun.encapsulation)" != ipx ]]; then
        [[ "$edit_mode" == server ]] && EDIT_SECTIONS+=(listener) || EDIT_SECTIONS+=(dialer)
    fi
    EDIT_SECTIONS+=(transport)
    if [[ "$transport" == tun ]]; then
        EDIT_SECTIONS+=(tun)
        [[ "$(edit_value tun.encapsulation)" == ipx ]] && EDIT_SECTIONS+=(ipx)
    fi
    [[ "$transport" == *mux ]] && EDIT_SECTIONS+=(mux)
    EDIT_SECTIONS+=(security)
    if [[ "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
        [[ "$edit_mode" == server || "$transport" == anytls || " ${!EDIT_VALUES[*]} " == *' tls.'* ]] && EDIT_SECTIONS+=(tls)
    fi
    EDIT_SECTIONS+=(tuning logging)
    [[ "$edit_mode" == server && "$transport" == tcp && "$(edit_value transport.accept_udp)" == true ]] && EDIT_SECTIONS+=(accept_udp)
    [[ "$edit_mode" == server ]] && EDIT_SECTIONS+=(ports)
    return 0
}

edit_label() {
    case "$1" in
        listener|dialer) echo 'Connection address' ;;
        transport) echo 'Transport and connection options' ;;
        tun) echo 'TUN addresses and device' ;;
        ipx) echo 'IPX encapsulation' ;;
        mux) echo 'Multiplexing' ;;
        security) echo 'Security' ;;
        tls) echo 'TLS certificates / SNI' ;;
        tuning) echo 'Performance' ;;
        logging) echo 'Logging' ;;
        accept_udp) echo 'UDP forwarding' ;;
        ports) echo 'Port mappings' ;;
        *) local label="${1//_/ }"; printf '%s\n' "${label^}" ;;
    esac
}

edit_choices() {
    case "$1" in
        transport.type) echo 'tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun' ;;
        tun.encapsulation) echo 'tcp ipx' ;;
        ipx.profile) echo 'icmp ipip udp tcp gre bip' ;;
        security.algorithm) echo 'aes-256-gcm chacha20-poly1305 aes-128-gcm' ;;
        tuning.tuning_profile) echo 'balanced fast latency resource' ;;
        tuning.buffer_profile) echo 'extreme_low_cpu ultra_low_cpu low_cpu balanced low_memory' ;;
        logging.log_level) echo 'panic fatal error warn info debug trace' ;;
        ports.forwarder) echo 'backhaul iptables' ;;
        mux.mux_version) echo '1 2' ;;
    esac
}

edit_valid_mappings() {
    local input="$1" mapping part first last
    local -a mappings parts
    input="${input// /}"
    [[ -z "$input" ]] && return 0
    IFS=',' read -r -a mappings <<< "$input"
    for mapping in "${mappings[@]}"; do
        if [[ "$(edit_value transport.type)" == tun ]]; then
            [[ "$mapping" =~ ^[0-9]{1,5}(=[0-9]{1,5})?$ ]] || return 1
        else
            [[ "$mapping" =~ ^[0-9]{1,5}(-[0-9]{1,5}(:[0-9]{1,5})?|=[0-9]{1,5})?$ ]] || return 1
        fi
        # Ranges must be ascending, and every port must be in 1-65535.
        IFS='=:' read -r first last <<< "$mapping"
        if [[ "$first" == *-* ]]; then
            IFS='-' read -r first part <<< "$first"
            ((10#$first <= 10#$part)) || return 1
        fi
        IFS='-=:' read -r -a parts <<< "$mapping"
        for part in "${parts[@]}"; do
            ((10#$part >= 1 && 10#$part <= 65535)) || return 1
        done
    done
}

edit_prompt_field() {
    local id="$1" default="$2" current type input encoded choices i
    local -a options
    current=$(edit_value "$id" "$default")
    type=$(printf '%s' "${EDIT_VALUES[$id]:-$default}" | jq -r type)
    choices=$(edit_choices "$id")
    echo
    colorize cyan "$(edit_label "${id#*.}"): $current" bold
    echo 'Press Enter to keep the displayed value.'
    if [[ "$type" == boolean ]]; then
        options=(true false)
    elif [[ -n "$choices" ]]; then
        read -r -a options <<< "$choices"
    fi
    if ((${#options[@]})); then
        for i in "${!options[@]}"; do echo " $((i+1))) ${options[$i]}"; done
    elif [[ "$type" == array ]]; then
        if [[ "$(edit_value transport.type)" == tun ]]; then
            echo 'TUN mappings: comma-separated ports or pairs, e.g. 443,8443=443.'
        else
            echo 'Enter comma-separated mappings, e.g. 443,8443=443,5000-5010.'
        fi
        echo 'Use - to clear all mappings.'
    elif [[ "$id" == dialer.edge_ip ]]; then
        echo 'Use - to clear the optional edge address.'
    fi
    while true; do
        read -r -p 'New value: ' input || return 1
        if [[ -z "$input" ]]; then input="$current"; fi
        if ((${#options[@]})); then
            if [[ "$input" =~ ^[0-9]+$ ]] && ((10#$input >= 1 && 10#$input <= ${#options[@]})); then
                input="${options[$((10#$input-1))]}"
            fi
            if [[ " ${options[*]} " != *" $input "* ]]; then
                colorize red 'Choose one of the listed options.'; continue
            fi
        fi
        case "$id" in
            listener.bind_addr)
                [[ "$input" != *:* ]] && input=":$input"
                if [[ ! "$input" =~ ^[^[:space:]]*:([0-9]{1,5})$ ]] || ((10#${BASH_REMATCH[1]:-0} < 1 || 10#${BASH_REMATCH[1]:-0} > 65535)); then
                    colorize red 'Use an address ending in :port (1-65535).'; continue
                fi ;;
            dialer.remote_addr)
                if [[ ! "$input" =~ ^[^[:space:]]+:([0-9]{1,5})$ ]] || ((10#${BASH_REMATCH[1]:-0} < 1 || 10#${BASH_REMATCH[1]:-0} > 65535)); then
                    colorize red 'Enter the IRAN server IP or domain with :port (1-65535).'; continue
                fi ;;
            tun.local_addr|tun.remote_addr)
                validate_cidr "$input" || { colorize red 'Enter a host address with CIDR, e.g. 10.10.10.1/24.'; continue; } ;;
            security.token|security.psk|ipx.dst_ip|ipx.interface|tls.tls_cert|tls.tls_key)
                [[ -n "$input" ]] || { colorize red 'This setting cannot be empty.'; continue; } ;;
            dialer.edge_ip) [[ "$input" == - ]] && input="" ;;
        esac
        case "$type" in
            boolean) encoded="$input" ;;
            number)
                input="${input//_/}"
                [[ "$input" =~ ^[0-9]{1,10}$ ]] || { colorize red 'Enter a non-negative whole number.'; continue; }
                encoded="$((10#$input))"
                if [[ "$id" == tun.health_port ]] && ((encoded < 1 || encoded > 65535)); then
                    colorize red 'Port must be 1-65535.'; continue
                fi ;;
            array)
                [[ "$input" == - ]] && input=""
                input="${input// /}"
                if [[ "$id" == ports.mapping ]] && ! edit_valid_mappings "$input"; then
                    colorize red 'Use valid ports (1-65535), mappings, or ascending ranges.'; continue
                fi
                encoded=$(jq -cn --arg value "$input" '$value | split(",") | map(select(length > 0))')
                ;;
            string) encoded=$(jq -cn --arg value "$input" '$value') ;;
            *) colorize red 'Unsupported setting type.'; return 1 ;;
        esac
        EDIT_VALUES[$id]="$encoded"
        return 0
    done
}

# Remove settings belonging to the old transport, preserving shared/custom fields.
edit_normalize() {
    local id section transport="$(edit_value transport.type)"
    edit_sections
    for id in "${!EDIT_VALUES[@]}"; do
        section="${id%%.*}"
        case "$section" in
            listener|dialer|tun|ipx|mux|security|tls|accept_udp|ports)
                [[ " ${EDIT_SECTIONS[*]} " == *" $section "* ]] || unset 'EDIT_VALUES[$id]' ;;
        esac
    done
    [[ "$transport" == tcp && "$edit_mode" == server ]] || unset 'EDIT_VALUES[transport.accept_udp]'
    [[ "$transport" =~ ^(tun|ws)$ || "$edit_mode" == client ]] && unset 'EDIT_VALUES[transport.proxy_protocol]'
    [[ "$transport" == tun || "$edit_mode" == server ]] && unset 'EDIT_VALUES[transport.connection_pool]'
    [[ "$transport" == tun ]] || unset 'EDIT_VALUES[ports.forwarder]'
    [[ "$transport" =~ ^(ws|wss|wsmux|wssmux|xwsmux)$ ]] || unset 'EDIT_VALUES[dialer.edge_ip]'
    [[ "$transport" == anytls ]] || unset 'EDIT_VALUES[tls.sni]'
    if [[ "$(edit_value tun.encapsulation)" == ipx ]]; then
        unset 'EDIT_VALUES[transport.nodelay]' 'EDIT_VALUES[transport.keepalive_period]'
        unset 'EDIT_VALUES[security.token]' 'EDIT_VALUES[tuning.tcp_mss]' 'EDIT_VALUES[tuning.so_rcvbuf]'
        EDIT_VALUES[ipx.mode]="\"$edit_mode\""
    else
        unset 'EDIT_VALUES[security.enable_encryption]' 'EDIT_VALUES[security.algorithm]'
        unset 'EDIT_VALUES[security.psk]' 'EDIT_VALUES[security.kdf_iterations]' 'EDIT_VALUES[tuning.batch_size]'
    fi
    if [[ "$transport" == tun ]]; then
        unset 'EDIT_VALUES[tuning.buffer_profile]' 'EDIT_VALUES[tuning.read_timeout]'
    fi
    if [[ "$(edit_value security.enable_encryption)" == false ]]; then
        unset 'EDIT_VALUES[security.algorithm]' 'EDIT_VALUES[security.psk]' 'EDIT_VALUES[security.kdf_iterations]'
    fi
    [[ "$(edit_value ipx.profile)" == icmp ]] || unset 'EDIT_VALUES[ipx.icmp_type]' 'EDIT_VALUES[ipx.icmp_code]'
    edit_sections
}

edit_complete_transport() {
    local section key default
    edit_normalize
    colorize yellow 'Complete any settings required by this transport. Existing values are kept.'
    # TUN encapsulation and encryption change which fields are required.
    if [[ "$(edit_value transport.type)" == tun && -z "${EDIT_VALUES[tun.encapsulation]}" ]]; then
        edit_prompt_field tun.encapsulation '"tcp"' || return 1
        edit_normalize
    fi
    for section in "${EDIT_SECTIONS[@]}"; do
        if [[ "$section" == security && "$(edit_value tun.encapsulation)" == ipx && -z "${EDIT_VALUES[security.enable_encryption]}" ]]; then
            edit_prompt_field security.enable_encryption true || return 1
        fi
        if [[ "$section" == ipx && -z "${EDIT_VALUES[ipx.profile]}" ]]; then
            edit_prompt_field ipx.profile '"tcp"' || return 1
        fi
        # Keep the field catalog on a separate descriptor so prompts read the user.
        while IFS='|' read -r -u 3 key default; do
            if [[ "$section.$key" == ports.mapping ]] && ! edit_valid_mappings "$(edit_value ports.mapping)"; then
                colorize yellow 'The current port mappings need adjustment for this transport.'
                edit_prompt_field ports.mapping "$default" || return 1
            fi
            [[ -n "${EDIT_VALUES[$section.$key]+present}" ]] && continue
            case "$section.$key" in
                transport.*|dialer.edge_ip|dialer.dial_timeout|dialer.retry_interval|accept_udp.*|tuning.*|logging.*)
                    EDIT_VALUES[$section.$key]="$default" ;;
                *) edit_prompt_field "$section.$key" "$default" || return 1 ;;
            esac
        done 3< <(edit_fields "$section")
    done
    edit_normalize
}

edit_section_menu() {
    local section="$1" key default choice i id
    local -a keys defaults
    while true; do
        keys=(); defaults=()
        echo
        colorize cyan "$(edit_label "$section")" bold
        while IFS='|' read -r key default; do
            keys+=("$key"); defaults+=("$default")
        done < <(edit_fields "$section")
        # Include additional scalar fields already present in this section.
        while IFS= read -r id; do
            [[ "$id" == "$section."* ]] || continue
            key="${id#*.}"
            [[ " ${keys[*]} " == *" $key "* ]] && continue
            keys+=("$key"); defaults+=("${EDIT_VALUES[$id]}")
        done < <(printf '%s\n' "${!EDIT_VALUES[@]}" | sort)
        for i in "${!keys[@]}"; do
            printf ' %s) %s: %s\n' "$((i+1))" "$(edit_label "${keys[$i]}")" "$(edit_value "$section.${keys[$i]}" "${defaults[$i]}")"
        done
        echo ' 0) Back'
        read -r -p 'Select a setting to change: ' choice || return 1
        [[ "$choice" == 0 ]] && return 0
        if [[ ! "$choice" =~ ^[0-9]{1,3}$ ]] || ((10#$choice < 1 || 10#$choice > ${#keys[@]})); then
            colorize red 'Invalid option.'; continue
        fi
        i=$((10#$choice-1))
        edit_prompt_field "$section.${keys[$i]}" "${defaults[$i]}" || return 1
        case "$section.${keys[$i]}" in
            transport.type|tun.encapsulation|security.enable_encryption|ipx.profile|transport.accept_udp)
                edit_complete_transport || return 1 ;;
        esac
        edit_normalize
        [[ " ${EDIT_SECTIONS[*]} " == *" $section "* ]] || return 0
    done
}

edit_write_config() {
    local output="$1" id section
    # Preserve additional sections/fields instead of regenerating a subset.
    {
        while IFS= read -r section; do
            echo "[$section]"
            while IFS= read -r id; do
                [[ "$id" == "$section."* ]] && printf '%s = %s\n' "${id#*.}" "${EDIT_VALUES[$id]}"
            done < <(printf '%s\n' "${!EDIT_VALUES[@]}" | sort)
            echo
        done < <(printf '%s\n' "${!EDIT_VALUES[@]}" | cut -d. -f1 | sort -u)
    } > "$output"
}

edit_save_config() {
    local file="$1" service="$2" temporary cert key
    cert=$(edit_value tls.tls_cert); key=$(edit_value tls.tls_key)
    if [[ "$edit_mode" == server && " ${EDIT_SECTIONS[*]} " == *' tls '* ]]; then
        if [[ "$cert" == "$CERT_FILE" && "$key" == "$KEY_FILE" && ( ! -f "$cert" || ! -f "$key" ) ]]; then
            colorize yellow 'Generating the default TLS certificate and key...'
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 \
                -keyout "$key" -out "$cert" -subj '/CN=backhaul.com' || return 1
        fi
        if [[ ! -f "$cert" || ! -f "$key" ]]; then
            colorize red 'TLS certificate/key not found. Set valid paths before saving.'
            return 1
        fi
    fi
    temporary=$(mktemp "${file}.edit.XXXXXX") || return 1
    if ! edit_write_config "$temporary" || ! chmod 600 "$temporary" || ! cp -p "$file" "${file}.bak" || ! mv -f "$temporary" "$file"; then
        rm -f "$temporary"
        colorize red 'Could not save the configuration.'
        return 1
    fi
    if systemctl restart "$service" && sleep 1 && systemctl is-active --quiet "$service"; then
        colorize green "✔ Saved and restarted $service. Backup: ${file}.bak" bold
        return 0
    fi
    colorize red 'The edited tunnel failed to restart. Restoring its previous configuration.'
    if cp -p "${file}.bak" "$file" && systemctl restart "$service" && sleep 1 && systemctl is-active --quiet "$service"; then
        colorize yellow 'Previous configuration restored and restarted. Your edits are still in the menu.'
    else
        colorize red "Recovery failed. Check systemctl status $service. Backup: ${file}.bak"
    fi
    return 1
}

edit_tunnel() {
    local file="$1" config_name="$(basename "${1%.toml}")" edit_mode choice i section id
    local service="backhaul-${config_name}.service"
    [[ "$config_name" == iran* ]] && edit_mode=server || edit_mode=client
    edit_load_config "$file" || { press_key; return 1; }
    while true; do
        edit_sections
        echo
        colorize cyan "Edit $config_name — $(edit_value transport.type)" bold
        echo 'Choose a group, then a setting. Changes apply only when you save.'
        for i in "${!EDIT_SECTIONS[@]}"; do
            section="${EDIT_SECTIONS[$i]}"
            printf ' %s) %s\n' "$((i+1))" "$(edit_label "$section")"
            while IFS= read -r id; do
                [[ "$id" == "$section."* ]] && printf '    %s: %s\n' "$(edit_label "${id#*.}")" "$(edit_value "$id")"
            done < <(printf '%s\n' "${!EDIT_VALUES[@]}" | sort)
        done
        echo ' s) Save changes and restart tunnel'
        echo ' 0) Cancel (discard edits)'
        read -r -p 'Select an option: ' choice || return 1
        case "$choice" in
            0) return 0 ;;
            s|S)
                # Complete dependencies even if input was interrupted earlier.
                edit_complete_transport || return 1
                colorize yellow 'Transport/security settings must also match on the other server.'
                if edit_save_config "$file" "$service"; then press_key; return 0; fi
                press_key ;;
            *)
                if [[ "$choice" =~ ^[0-9]{1,3}$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#EDIT_SECTIONS[@]})); then
                    edit_section_menu "${EDIT_SECTIONS[$((10#$choice-1))]}" || return 1
                else
                    colorize red 'Invalid option.'
                fi ;;
        esac
    done
}

create_systemd_service() {
    local type="$1"
    local port="$2"
    local config_file="$3"

    local service_file="${service_dir}/backhaul-${type}${port}.service"
    local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"

    cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_type Port $port
After=network.target

[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload || ! systemctl enable --now "backhaul-${type}${port}.service" ||
       ! sleep 1 || ! systemctl is-active --quiet "backhaul-${type}${port}.service"; then
        colorize red "Service backhaul-${type}${port} failed to start. Check its service logs."
        return 1
    fi

    colorize green "✔ Service backhaul-${type}${port} created and started" bold
}

# ============================================================================
# SETUP LINKS AND SINGLE-TUNNEL DIAGNOSTICS
# ============================================================================

random_secret() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

settings_json() {
    local id separator=""
    {
        printf '{'
        while IFS= read -r id; do
            printf '%s"%s":%s' "$separator" "$id" "${EDIT_VALUES[$id]}"
            separator=,
        done < <(printf '%s\n' "${!EDIT_VALUES[@]}" | sort)
        printf '}'
    } | jq -cS .
}

encode_backhaul_link() {
    local scheme="$1" body="$2"
    printf '%s://1.' "$scheme"
    printf '%s' "$body" | base64 | tr -d '\n=' | tr '+/' '-_'
    echo
}

decode_backhaul_link() {
    local scheme="$1" raw="$2" payload decoded
    # No fetching URLs or evaluating shell text; a link holds data only.
    raw=$(edit_trim "$raw")
    raw="${raw#\'}"; raw="${raw%\'}"; raw="${raw#\"}"; raw="${raw%\"}"
    if [[ ${#raw} -gt 32768 || "$raw" != "$scheme://1."* ]]; then
        colorize red "Expected a $scheme://1. link (maximum 32 KiB)." >&2
        return 1
    fi
    payload="${raw#*://1.}"
    [[ "$payload" =~ ^[A-Za-z0-9_-]+$ ]] || { colorize red 'Invalid link characters.' >&2; return 1; }
    payload=$(printf '%s' "$payload" | tr '_-' '/+')
    case $((${#payload}%4)) in
        2) payload+='==' ;; 3) payload+='=' ;; 1) colorize red 'Link is cut short.' >&2; return 1 ;;
    esac
    decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) || { colorize red 'Invalid link encoding.' >&2; return 1; }
    printf '%s' "$decoded" | jq -ce 'select(type == "object" and .v == 1)' || {
        colorize red 'Invalid or unsupported link version.' >&2; return 1;
    }
}

valid_endpoint() {
    local address="$1" port
    [[ "$address" =~ ^([a-zA-Z0-9._-]+|\[[a-fA-F0-9:]+\]):([0-9]{1,5})$ ]] || return 1
    port="${BASH_REMATCH[2]}"
    ((10#$port >= 1 && 10#$port <= 65535))
}

peer_setup_link() {
    local file="$1" edit_mode=client host port endpoint id section key default old_local old_listen
    local -A allowed
    [[ "$(basename "$file")" == iran*.toml ]] || { colorize red 'Export the setup link on the IRAN server.'; return 1; }
    edit_load_config "$file" || return 1
    if [[ "$(edit_value tun.encapsulation)" != ipx ]]; then
        endpoint=$(edit_value listener.bind_addr)
        port="${endpoint##*:}"
        host="${endpoint%:*}"
        [[ -z "$host" || "$host" == 0.0.0.0 || "$host" == '[::]' || "$host" == :: ]] && host="$SERVER_IP"
        echo 'Enter the IRAN address the KHAREJ server can reach.' >&2
        read -r -p "IRAN IP/domain [$host]: " endpoint || return 1
        host="${endpoint:-$host}"
        [[ "$host" == *:* && "$host" != \[*\] ]] && host="[$host]"
        endpoint="$host:$port"
        valid_endpoint "$endpoint" || { colorize red 'Invalid IRAN address or port.'; return 1; }
        EDIT_VALUES[dialer.remote_addr]=$(jq -cn --arg value "$endpoint" '$value')
        EDIT_VALUES[dialer.dial_timeout]=10
        EDIT_VALUES[dialer.retry_interval]=3
        EDIT_VALUES[transport.connection_pool]=8
    else
        old_listen="${EDIT_VALUES[ipx.listen_ip]}"
        EDIT_VALUES[ipx.listen_ip]="${EDIT_VALUES[ipx.dst_ip]}"
        EDIT_VALUES[ipx.dst_ip]="$old_listen"
        EDIT_VALUES[ipx.mode]='"client"'
        unset 'EDIT_VALUES[ipx.interface]'
    fi
    if [[ "$(edit_value transport.type)" == tun ]]; then
        old_local="${EDIT_VALUES[tun.local_addr]}"
        EDIT_VALUES[tun.local_addr]="${EDIT_VALUES[tun.remote_addr]}"
        EDIT_VALUES[tun.remote_addr]="$old_local"
    fi
    unset 'EDIT_VALUES[tls.tls_cert]' 'EDIT_VALUES[tls.tls_key]'
    edit_normalize
    # Transfer only settings supported by this script, excluding host-local extras.
    for section in "${EDIT_SECTIONS[@]}"; do
        while IFS='|' read -r key default; do allowed[$section.$key]=true; done < <(edit_fields "$section")
    done
    allowed[ipx.mode]=true
    for id in "${!EDIT_VALUES[@]}"; do
        [[ -n "${allowed[$id]}" ]] || unset 'EDIT_VALUES[$id]'
    done
    encode_backhaul_link backhaul "$(settings_json | jq -c '{v:1,kind:"setup",role:"client",settings:.}')"
}

validate_setup_settings() {
    local edit_mode=client id section key default type value choices psk_hex
    local -A allowed
    case "$(edit_value transport.type)" in tcp|tcpmux|xtcpmux|ws|wss|wsmux|wssmux|xwsmux|anytls|tun) ;; *) colorize red 'Unsupported transport in link.'; return 1 ;; esac
    if [[ "$(edit_value transport.type)" == tun ]]; then
        case "$(edit_value tun.encapsulation)" in tcp|ipx) ;; *) colorize red 'Invalid TUN encapsulation.'; return 1 ;; esac
    fi
    edit_sections
    for section in "${EDIT_SECTIONS[@]}"; do
        while IFS='|' read -r key default; do
            allowed[$section.$key]=$(printf '%s' "$default" | jq -r type)
        done < <(edit_fields "$section")
    done
    [[ "$(edit_value tun.encapsulation)" == ipx ]] && allowed[ipx.mode]=string
    for id in "${!EDIT_VALUES[@]}"; do
        type=$(printf '%s' "${EDIT_VALUES[$id]}" | jq -r type)
        if [[ -z "${allowed[$id]}" || "$type" != "${allowed[$id]}" ]]; then
            colorize red "Unsupported setting or wrong type: $id"; return 1
        fi
        value=$(edit_value "$id")
        [[ ${#value} -le 2048 ]] || { colorize red "Setting too long: $id"; return 1; }
        if [[ "$type" == number ]]; then
            printf '%s' "${EDIT_VALUES[$id]}" | jq -e '. >= 0 and . <= 2147483647 and floor == .' >/dev/null || return 1
        fi
        choices=$(edit_choices "$id")
        [[ -z "$choices" || " $choices " == *" $value "* ]] || { colorize red "Invalid choice: $id"; return 1; }
    done
    if [[ "$(edit_value tun.encapsulation)" != ipx ]]; then
        valid_endpoint "$(edit_value dialer.remote_addr)" || { colorize red 'Missing/invalid remote address.'; return 1; }
        [[ -n "$(edit_value security.token)" ]] || { colorize red 'Missing security token.'; return 1; }
    else
        [[ "$(edit_value ipx.mode)" == client && -n "$(edit_value ipx.listen_ip)" && -n "$(edit_value ipx.dst_ip)" ]] || return 1
        [[ -n "${EDIT_VALUES[security.enable_encryption]}" ]] || return 1
        if [[ "$(edit_value security.enable_encryption)" == true ]]; then
            psk_hex=$(set -o pipefail; printf '%s' "$(edit_value security.psk)" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n') || {
                colorize red 'Invalid base64 encoding for the IPX PSK.'; return 1;
            }
            [[ ${#psk_hex} -eq 64 ]] || {
                colorize red 'IPX encryption requires a base64-encoded 32-byte PSK.'; return 1;
            }
        fi
    fi
    if [[ "$(edit_value transport.type)" == tun ]]; then
        validate_cidr "$(edit_value tun.local_addr)" && validate_cidr "$(edit_value tun.remote_addr)" || return 1
        value=$(edit_value tun.health_port)
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) || return 1
    fi
    return 0
}

load_setup_link() {
    local raw="$1" json id value
    json=$(decode_backhaul_link backhaul "$raw") || return 1
    printf '%s' "$json" | jq -e '
        .kind == "setup" and .role == "client" and (.settings | type == "object") and
        (.settings | length > 0 and length <= 100) and
        all(.settings | to_entries[]; (.key | test("^[a-z_]+\\.[a-z_]+$")) and
            (.value | type == "string" or type == "boolean" or type == "number"))' >/dev/null || {
        colorize red 'Invalid setup link. No files changed.'; return 1;
    }
    EDIT_VALUES=()
    while IFS=$'\t' read -r id value; do EDIT_VALUES[$id]="$value"; done < <(
        printf '%s' "$json" | jq -r '.settings | to_entries[] | .key + "\t" + (.value | tojson)')
    validate_setup_settings
}

same_setup_identity() {
    local expected="$1" current
    current="${EDIT_VALUES[security.token]:-${EDIT_VALUES[security.psk]:-}}"
    [[ -n "$expected" && "$current" == "$expected" ]]
}

install_link_settings() {
    local edit_mode=client port file candidate identity temporary service matches=0 existing="" id
    local -A incoming
    identity="${EDIT_VALUES[security.token]:-${EDIT_VALUES[security.psk]:-}}"
    for id in "${!EDIT_VALUES[@]}"; do incoming[$id]="${EDIT_VALUES[$id]}"; done
    for candidate in "$config_dir"/kharej*.toml; do
        [[ -f "$candidate" ]] || continue
        if edit_load_config "$candidate" && same_setup_identity "$identity"; then
            existing="$candidate"; ((matches+=1))
        fi
    done
    EDIT_VALUES=()
    for id in "${!incoming[@]}"; do EDIT_VALUES[$id]="${incoming[$id]}"; done
    ((matches <= 1)) || { colorize red 'Multiple tunnels share this credential. Edit the intended tunnel manually.'; return 1; }
    edit_complete_transport || return 1
    incoming=()
    for id in "${!EDIT_VALUES[@]}"; do incoming[$id]="${EDIT_VALUES[$id]}"; done
    port="$(edit_value dialer.remote_addr)"; port="${port##*:}"
    [[ "$(edit_value tun.encapsulation)" == ipx ]] && port=$(edit_value tun.health_port)
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    file="${existing:-$config_dir/kharej$port.toml}"
    service="backhaul-$(basename "${file%.toml}").service"
    if [[ -z "$existing" && ( -e "$file" || -e "$service_dir/$service" ) ]]; then
        colorize red "A different tunnel already uses $file. Edit or remove it first."; return 1
    fi
    if [[ "$(edit_value transport.type)" == tun ]]; then
        local name="${EDIT_VALUES[tun.name]}"
        for candidate in "$config_dir"/{iran,kharej}*.toml; do
            [[ -f "$candidate" && "$candidate" != "$existing" ]] || continue
            if edit_load_config "$candidate" && [[ "${EDIT_VALUES[tun.name]}" == "$name" ]]; then
                colorize red 'Another tunnel uses this TUN device. Edit/remove it before importing.'; return 1
            fi
        done
        EDIT_VALUES=()
        for id in "${!incoming[@]}"; do EDIT_VALUES[$id]="${incoming[$id]}"; done
        edit_sections
    fi
    colorize cyan "Setup preview: ${existing:+update }$service" bold
    echo "Transport: $(edit_value transport.type)"
    echo "IRAN address: $(edit_value dialer.remote_addr "${EDIT_VALUES[ipx.dst_ip]}")"
    [[ "$(edit_value transport.type)" == tun ]] && echo "TUN: $(edit_value tun.local_addr) → $(edit_value tun.remote_addr)"
    echo "Config: $file"
    local confirm
    read -r -p 'Apply these settings and start this tunnel? [y/N]: ' confirm || return 1
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    if [[ -n "$existing" ]]; then
        edit_save_config "$file" "$service"
        return $?
    fi
    temporary=$(mktemp "$config_dir/.link.XXXXXX") || return 1
    if ! edit_write_config "$temporary" || ! chmod 600 "$temporary" || ! ln "$temporary" "$file"; then
        rm -f "$temporary"; return 1
    fi
    rm -f "$temporary"
    if ! create_systemd_service kharej "$port" "$file"; then
        systemctl disable --now "$service" >/dev/null 2>&1
        rm -f "$file" "$service_dir/$service"
        systemctl daemon-reload
        colorize red 'Setup failed. The new config and service were removed.'
        return 1
    fi
}

setup_from_link() {
    local raw
    echo 'Paste the backhaul://1. link generated on your IRAN server.'
    read -r -p 'Setup link (blank to cancel): ' raw || return 1
    [[ -n "$raw" ]] || return 0
    load_setup_link "$raw" && install_link_settings
    press_key
}

show_setup_link() {
    echo 'Copy this link to KHAREJ → Configure a new tunnel → Setup from link.'
    echo 'The link contains your tunnel credentials. Keep it private.'
    peer_setup_link "$1"
    press_key
}

# Python is needed only for diagnostics, keeping socket timeouts and exact
# byte comparisons portable. It starts no Backhaul processes or systemd units.
connection_tool() {
    command -v python3 >/dev/null || {
        colorize red 'Diagnostics require python3. Install it with: apt-get install -y python3' >&2
        return 1
    }
    # Pass credentials through a private descriptor, not public process arguments.
    python3 - 3< <(printf '%s\0' "$config_dir/.connection-test.lock" "$@") <<'PY'
import fcntl, hashlib, os, socket, statistics, struct, sys, time

def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError('connection closed during transfer')
        data.extend(chunk)
    return bytes(data)

def connect(host, port):
    return socket.create_connection((host, int(port)), timeout=3)

def route(host, port):
    times = []
    for n in range(10):
        start = time.monotonic()
        try:
            with connect(host, port):
                times.append((time.monotonic() - start) * 1000)
                print(f'Probe {n+1}/10: {times[-1]:.1f} ms', flush=True)
        except OSError as exc:
            print(f'Probe {n+1}/10 failed: {exc}', flush=True)
        time.sleep(.25)
    print(f'TCP connection success: {len(times)}/10 ({len(times)*10}%).')
    if times:
        jitter = statistics.pstdev(times)
        print(f'Connect latency: min {min(times):.1f}, avg {statistics.mean(times):.1f}, '
              f'max {max(times):.1f} ms; standard deviation {jitter:.1f} ms.')
    print('This measures TCP reachability, not authentication, packet loss or tunnel throughput.')
    return 0 if times else 1

def responder(host, port, secret):
    family = socket.AF_INET6 if ':' in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as listener:
        # Reuse TIME_WAIT sockets after a test, never another active listener.
        # No SO_REUSEPORT: an occupied backend must be refused, never taken over.
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, int(port)))
        listener.listen(1)
        listener.settimeout(1)
        deadline = time.monotonic() + 600
        print(f'Ready on {host}:{port}. Run the IRAN test now. Ctrl+C cancels; expires in 10 minutes.', flush=True)
        while time.monotonic() < deadline:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            with client:
                client.settimeout(5)
                try:
                    expected = b'BACKHAUL-TEST-1 ' + secret.encode() + b'\n'
                    prefix = recv_exact(client, 12)
                    if prefix == b'\r\n\r\n\0\r\nQUIT\n':  # PROXY protocol v2
                        header = recv_exact(client, 4)
                        size = struct.unpack('!H', header[2:])[0]
                        if header[0] >> 4 != 2 or size > 512:
                            raise ValueError('invalid PROXY v2 header')
                        recv_exact(client, size)
                        prefix = b''
                    elif prefix.startswith(b'PROXY '):  # PROXY protocol v1
                        while not prefix.endswith(b'\r\n') and len(prefix) <= 108:
                            prefix += recv_exact(client, 1)
                        if not prefix.endswith(b'\r\n'):
                            raise ValueError('invalid PROXY v1 header')
                        prefix = b''
                    if prefix + recv_exact(client, len(expected) - len(prefix)) != expected:
                        continue
                    client.sendall(expected)
                    while time.monotonic() < deadline:
                        size = struct.unpack('!I', recv_exact(client, 4))[0]
                        if size == 0:
                            print('Test finished. Temporary responder closed.', flush=True)
                            return 0
                        if size > 1024 * 1024:
                            raise ValueError('oversized test frame')
                        client.sendall(recv_exact(client, size))
                except (OSError, ValueError) as exc:
                    print(f'Test connection ended: {exc}', flush=True)
        print('Responder expired and closed.')
        return 1

def traffic(host, port, secret):
    times = []
    try:
        with connect(host, port) as sock:
            sock.settimeout(5)
            hello = b'BACKHAUL-TEST-1 ' + secret.encode() + b'\n'
            sock.sendall(hello)
            if recv_exact(sock, len(hello)) != hello:
                raise ValueError('wrong responder; check selected mapping and test link')
            for n in range(60):
                data = os.urandom(64)
                start = time.monotonic()
                sock.sendall(struct.pack('!I', len(data)) + data)
                if recv_exact(sock, len(data)) != data:
                    raise ValueError('echo bytes did not match')
                elapsed = time.monotonic() - start
                times.append(elapsed * 1000)
                print(f'Echo {n+1}/60: {times[-1]:.1f} ms', flush=True)
                time.sleep(max(0, 1 - elapsed))
            data = os.urandom(1024 * 1024)
            start = time.monotonic()
            sock.sendall(struct.pack('!I', len(data)) + data)
            if recv_exact(sock, len(data)) != data:
                raise ValueError('bulk echo bytes did not match')
            elapsed = max(time.monotonic() - start, .000001)
            sock.sendall(struct.pack('!I', 0))
        print(f'PASS: 60/60 exact echoes and 1 MiB bulk echo through the selected tunnel.')
        print(f'Round trip: min {min(times):.1f}, avg {statistics.mean(times):.1f}, max {max(times):.1f} ms; '
              f'jitter (standard deviation) {statistics.pstdev(times):.1f} ms.')
        print(f'Combined upload+download echo rate: {2*len(data)*8/elapsed/1e6:.2f} Mbit/s '
              '(not separate one-way speeds).')
        return 0
    except (OSError, ValueError) as exc:
        print(f'FAIL after {len(times)}/60 verified echoes: {exc}')
        print('Check both tunnel services, matching credentials/transport, port mapping and the KHAREJ responder.')
        return 1

try:
    tool_args = os.fdopen(3, 'rb').read().split(b'\0')[:-1]
    lock_path, action, *args = [arg.decode() for arg in tool_args]
    if action == 'fingerprint':
        print(hashlib.sha256(args[0].encode()).hexdigest())
        result = 0
    else:
        with open(lock_path, 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('Another connection test is running here. Finish/cancel it first.')
                sys.exit(1)
            result = {'route': route, 'responder': responder, 'traffic': traffic}[action](*args)
    sys.exit(result)
except KeyboardInterrupt:
    print('\nTest cancelled. Test sockets closed; tunnel settings unchanged.')
    sys.exit(130)
except (OSError, ValueError) as exc:
    print(f'Test could not start: {exc}', file=sys.stderr)
    sys.exit(1)
PY
}

pair_fingerprint() {
    local id separator="" body
    body=$({
        printf '{'
        for id in transport.type tun.encapsulation mux.mux_version security.token security.enable_encryption security.algorithm security.psk security.kdf_iterations; do
            [[ -n "${EDIT_VALUES[$id]}" ]] || continue
            printf '%s"%s":%s' "$separator" "$id" "${EDIT_VALUES[$id]}"; separator=,
        done
        printf '}'
    } | jq -cS .)
    connection_tool fingerprint "$body"
}

quick_connection_test() {
    local file="$1" endpoint host port
    edit_load_config "$file" || return 1
    if [[ "$(edit_value tun.encapsulation)" == ipx ]]; then
        colorize yellow 'IPX does not have a TCP tunnel listener. Use the real traffic test for this tunnel.'
        return 0
    fi
    if [[ "$(basename "$file")" == kharej* ]]; then
        endpoint=$(edit_value dialer.remote_addr)
        [[ -n "$(edit_value dialer.edge_ip)" ]] && colorize yellow 'This probe uses the IRAN address; the WebSocket edge may follow a different route.'
    else
        endpoint=$(edit_value listener.bind_addr)
        colorize yellow 'Local listener check only. Run this on KHAREJ to measure the inter-server route.'
    fi
    port="${endpoint##*:}"; host="${endpoint%:*}"
    [[ -z "$host" || "$host" == 0.0.0.0 ]] && host=127.0.0.1
    [[ "$host" == '[::]' || "$host" == :: ]] && host=::1
    host="${host#\[}"; host="${host%\]}"
    valid_endpoint "$endpoint" || [[ "$endpoint" =~ ^:[0-9]{1,5}$ ]] || return 1
    connection_tool route "$host" "$port"
}

prepare_traffic_test() {
    local file="$1" mapping choice forwarded backend host nonce fingerprint link input first last
    local -a mappings
    [[ "$(basename "$file")" == iran*.toml ]] || { colorize red 'Start this test on IRAN; run the responder on KHAREJ.'; return 1; }
    edit_load_config "$file" || return 1
    mapfile -t mappings < <(printf '%s' "${EDIT_VALUES[ports.mapping]:-[]}" | jq -r '.[]')
    ((${#mappings[@]})) || { colorize red 'This tunnel has no forwarded ports to test.'; return 1; }
    echo 'Choose ONE mapping whose KHAREJ backend port is unused. Existing applications will not be stopped.'
    for choice in "${!mappings[@]}"; do echo "$((choice+1))) ${mappings[$choice]}"; done
    read -r -p 'Mapping (0 cancels): ' choice || return 1
    [[ "$choice" == 0 ]] && return 0
    [[ "$choice" =~ ^[0-9]{1,3}$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#mappings[@]})) || return 1
    mapping="${mappings[$((10#$choice-1))]}"
    mapping="${mapping// /}"
    local edit_mode=server
    edit_valid_mappings "$mapping" || { colorize red 'Unsupported mapping format for this test.'; return 1; }
    first="${mapping%%[=:]*}"
    if [[ "$first" == *-* ]]; then
        last="${first##*-}"; first="${first%%-*}"
        read -r -p "Port within $first-$last [$first]: " forwarded || return 1
        forwarded="${forwarded:-$first}"
        [[ "$forwarded" =~ ^[0-9]{1,5}$ ]] && ((10#$forwarded >= 10#$first && 10#$forwarded <= 10#$last)) || return 1
    else
        forwarded="$first"
    fi
    backend="$forwarded"
    [[ "$mapping" == *=* ]] && backend="${mapping##*=}"
    [[ "$mapping" == *:* ]] && backend="${mapping##*:}"
    host=127.0.0.1
    [[ "$(edit_value transport.type)" == tun ]] && host="$(edit_value tun.remote_addr)" && host="${host%/*}"
    nonce=$(random_secret)
    fingerprint=$(pair_fingerprint) || return 1
    link=$(encode_backhaul_link backhaul-test "$(jq -cn --arg host "$host" --argjson port "$((10#$backend))" \
        --arg secret "$nonce" --arg pair "$fingerprint" '{v:1,kind:"traffic-test",host:$host,port:$port,secret:$secret,pair:$pair}')")
    echo 'On KHAREJ: select the matching tunnel → Test connection → Start responder → paste this link:'
    echo "$link"
    echo 'Keep the test link private. The responder exits after the test or Ctrl+C.'
    read -r -p 'When KHAREJ says Ready, press Enter here (q cancels): ' input || return 1
    [[ "$input" == q || "$input" == Q ]] && return 0
    local target="$(edit_value listener.bind_addr)"
    target="${target%:*}"
    [[ -z "$target" || "$target" == 0.0.0.0 || "$(edit_value tun.encapsulation)" == ipx ]] && target=127.0.0.1
    [[ "$target" == '[::]' || "$target" == :: ]] && target=::1
    target="${target#\[}"; target="${target%\]}"
    connection_tool traffic "$target" "$forwarded" "$nonce"
}

start_traffic_responder() {
    local file="$1" raw json host port secret pair expected_host
    [[ "$(basename "$file")" == kharej*.toml ]] || { colorize red 'Run the responder on KHAREJ.'; return 1; }
    read -r -p 'Paste the backhaul-test://1. link from IRAN: ' raw || return 1
    json=$(decode_backhaul_link backhaul-test "$raw") || return 1
    printf '%s' "$json" | jq -e '.kind == "traffic-test" and (.host | type == "string") and
        (.port | type == "number" and . >= 1 and . <= 65535 and floor == .) and
        (.secret | type == "string" and test("^[a-f0-9]{64}$")) and
        (.pair | type == "string" and test("^[a-f0-9]{64}$"))' >/dev/null || return 1
    edit_load_config "$file" || return 1
    pair=$(pair_fingerprint) || return 1
    [[ "$pair" == "$(printf '%s' "$json" | jq -r .pair)" ]] || { colorize red 'This test link belongs to different tunnel settings. Select the matching tunnel.'; return 1; }
    expected_host=127.0.0.1
    [[ "$(edit_value transport.type)" == tun ]] && expected_host="$(edit_value tun.local_addr)" && expected_host="${expected_host%/*}"
    host=$(printf '%s' "$json" | jq -r .host)
    [[ "$host" == "$expected_host" ]] || { colorize red 'The responder address does not match this tunnel.'; return 1; }
    port=$(printf '%s' "$json" | jq -r .port); secret=$(printf '%s' "$json" | jq -r .secret)
    echo "One temporary responder on $host:$port. An occupied port will be refused."
    connection_tool responder "$host" "$port" "$secret"
}

test_connection_menu() {
    local file="$1" choice
    while true; do
        colorize cyan "Test connection: $(basename "${file%.toml}")" bold
        echo '1) Quick TCP reachability (10 sequential probes)'
        echo '2) Real traffic test — start on IRAN (one selected mapping)'
        echo '3) Start responder — KHAREJ (paste IRAN test link)'
        echo '0) Back'
        read -r -p 'Choose one test: ' choice || return 1
        case "$choice" in
            1) quick_connection_test "$file"; press_key ;;
            2) prepare_traffic_test "$file"; press_key ;;
            3) start_traffic_responder "$file"; press_key ;;
            0) return 0 ;;
            *) colorize red 'Invalid option.' ;;
        esac
    done
}

tunnel_health_check() {
    local file="$1" name="$(basename "${1%.toml}")" cert token
    local service="backhaul-$name.service"
    edit_load_config "$file" || return 1
    colorize cyan "Health check: $name" bold
    [[ -x "$config_dir/backhaul_premium" ]] && echo 'OK: Core is executable.' || echo "FIX: Download the core or chmod +x $config_dir/backhaul_premium"
    systemctl is-active --quiet "$service" && echo 'OK: Service is active.' || echo "FIX: Restart this tunnel and inspect its logs ($service)."
    echo "Config: $file"
    echo "Service: $service_dir/$service"
    [[ -f "$file.bak" ]] && echo "Previous configuration: $file.bak"
    if [[ "$(edit_value transport.type)" == tun ]]; then
        [[ -e /dev/net/tun ]] || echo 'FIX: Enable /dev/net/tun for this TUN tunnel.'
    fi
    if [[ "$(edit_value tun.encapsulation)" == ipx ]]; then
        echo 'IPX: verify the profile, peer IP and encryption settings on both ends; TCP port probes do not apply.'
    else
        token=$(edit_value security.token)
        [[ ${#token} -ge 32 && "$token" != your_token ]] || echo 'FIX: Use a strong shared token on both ends (new setups generate one automatically).'
    fi
    cert=$(edit_value tls.tls_cert)
    if [[ -n "$cert" ]]; then
        if command -v openssl >/dev/null && openssl x509 -in "$cert" -checkend 604800 -noout >/dev/null 2>&1; then
            echo 'OK: TLS certificate is valid for more than 7 days.'
        else
            echo "FIX: Check/renew the TLS certificate at $cert."
        fi
    fi
    echo 'Recent selected-tunnel logs:'
    journalctl -u "$service" -n 12 --no-pager -o cat
    echo 'For actual connectivity, use Test connection. Service status alone does not prove a working peer.'
    press_key
}

toggle_tunnel_service() {
    local service="$1"
    if systemctl is-active --quiet "$service"; then
        systemctl stop "$service" && colorize yellow 'Tunnel stopped. It can still start at boot if enabled.'
    else
        if systemctl start "$service" && sleep 1 && systemctl is-active --quiet "$service"; then
            colorize green 'Tunnel started.'
        else
            colorize red 'Tunnel could not start. View its service logs for details.'
        fi
    fi
    press_key
}

restore_tunnel_backup() {
    local file="$1" edit_mode confirm
    [[ -f "$file.bak" ]] || { colorize red 'No previous configuration backup found.'; press_key; return 1; }
    [[ "$(basename "$file")" == iran* ]] && edit_mode=server || edit_mode=client
    edit_load_config "$file.bak" || return 1
    edit_sections
    echo "Restore $(edit_value transport.type) from $file.bak and restart this tunnel?"
    read -r -p 'Restore? [y/N]: ' confirm || return 1
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    edit_save_config "$file" "backhaul-$(basename "${file%.toml}").service"
    press_key
}

# ============================================================================
# SERVER INFO & DISPLAY FUNCTIONS
# ============================================================================

SERVER_IP=$(hostname -I | awk '{print $1}')
SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country')
SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp')

display_logo() {
    echo -e "\033[36m"
    cat << "EOF"
▗▄▄▖  ▗▄▖  ▗▄▄▖▗▖ ▗▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖
▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
▐▛▀▚▖▐▛▀▜▌▐▌   ▐▛▚▖ ▐▛▀▜▌▐▛▀▜▌▐▌ ▐▌▐▌
▐▙▄▞▘▐▌ ▐▌▝▚▄▄▖▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▝▚▄▞▘▐▙▄▄▖

Lightning-fast reverse tunneling solution
EOF
    echo -e "\033[0m\033[32m"
    echo -e "Script Version: \033[33m${SCRIPT_VERSION}\033[32m"
    [[ -f "${config_dir}/backhaul_premium" ]] && \
        echo -e "Core Version: \033[33m$($config_dir/backhaul_premium -v)\033[32m"
}

display_server_info() {
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
    echo -e "\033[36mIP Address:\033[0m $SERVER_IP"
    echo -e "\033[36mLocation:\033[0m $SERVER_COUNTRY"
    echo -e "\033[36mDatacenter:\033[0m $SERVER_ISP"
}

display_backhaul_core_status() {
    if [[ -f "${config_dir}/backhaul_premium" ]]; then
        echo -e "\033[36mBackhaul Core:\033[0m \033[32mInstalled\033[0m"
    else
        echo -e "\033[36mBackhaul Core:\033[0m \033[31mNot installed\033[0m"
    fi
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
}

check_config_backup() {
    missing_services=()

    for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
        [ -e "$config" ] || continue

        fname=$(basename "$config")
        if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            location="${BASH_REMATCH[1]}"
            tunnel_port="${BASH_REMATCH[2]}"
            service_file="${service_dir}/backhaul-${location}${tunnel_port}.service"

            if [[ ! -f "$service_file" ]]; then
                missing_services+=("$service_file:$location:$tunnel_port")
            fi
        fi
    done

    [[ ${#missing_services[@]} -eq 0 ]] && return 0

    echo
    colorize red "Missing service files:" bold
    for entry in "${missing_services[@]}"; do
        service_file="${entry%%:*}"
        location="${entry#*:}"; location="${location%%:*}"
        tunnel_port="${entry##*:}"
        echo "- $service_file (type: $location, port: $tunnel_port)"
    done

    echo
    read -r -p "Do you want to create missing service files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for entry in "${missing_services[@]}"; do
            service_file="${entry%%:*}"
            location="${entry#*:}"; location="${location%%:*}"
            tunnel_port="${entry##*:}"

            config_file="${config_dir}/${location}${tunnel_port}.toml"
            desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"

            cat > "$service_file" <<EOF
[Unit]
Description=Backhaul $desc_loc Port $tunnel_port
After=network.target

[Service]
Type=simple
User=root
ExecStart=${config_dir}/backhaul_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now "$(basename "$service_file")"
            echo "Created and started $(basename "$service_file")"
        done
    fi
    sleep 2
}

check_config_backup

# ============================================================================
# TUNNEL MANAGEMENT FUNCTIONS
# ============================================================================

check_tunnel_status() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi

    clear
    colorize yellow "Checking all services status..." bold
    sleep 1
    echo

    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue

        config_name=$(basename "$config_path")
        config_name="${config_name%.toml}"
        service_name="backhaul-${config_name}.service"

        if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Iran service (port $port) is running"
            else
                colorize red "Iran service (port $port) is not running"
            fi
        elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Kharej service (port $port) is running"
            else
                colorize red "Kharej service (port $port) is not running"
            fi
        fi
    done

    echo
    press_key
}

tunnel_management() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi

    clear
    colorize cyan "Existing services:" bold
    echo

    local index=1
    declare -a configs

    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue

        config_name=$(basename "$config_path")

        if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mKharej\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        fi
    done

    echo
    echo -ne "Enter your choice (0 to return): "
    read -r choice

    [[ "$choice" == "0" ]] && return

    while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
        colorize red "Invalid choice."
        echo -ne "Enter your choice (0 to return): "
        read -r choice
        [[ "$choice" == "0" ]] && return
    done

    selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    service_name="backhaul-${config_name}.service"

    clear
    colorize cyan "Manage $config_name:" bold
    echo
    colorize red "1) Remove this tunnel"
    colorize yellow "2) Restart this tunnel"
    echo "3) View service logs"
    echo "4) View service status"
    colorize cyan "5) Edit this tunnel (easy menu)"
    echo "6) Test connection (one tunnel at a time)"
    echo "7) Show setup link for KHAREJ"
    echo "8) Health check and file locations"
    echo "9) Start / stop this tunnel"
    echo "10) Restore previous configuration"
    echo
    read -r -p "Enter your choice (0 to return): " choice

    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        5) edit_tunnel "$selected_config" ;;
        6) test_connection_menu "$selected_config" ;;
        7) show_setup_link "$selected_config" ;;
        8) tunnel_health_check "$selected_config" ;;
        9) toggle_tunnel_service "$service_name" ;;
        10) restore_tunnel_backup "$selected_config" ;;
        0) return ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

destroy_tunnel() {
    config_path="$1"
    config_name=$(basename "${config_path%.toml}")
    service_name="backhaul-${config_name}.service"
    service_path="$service_dir/$service_name"

    [ -f "$config_path" ] && rm -f "$config_path"

    if [[ -f "$service_path" ]]; then
        systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
        rm -f "$service_path"
    fi

    systemctl daemon-reload
    echo
    colorize green "Tunnel destroyed successfully!" bold
    echo
    press_key
}

restart_service() {
    echo
    colorize yellow "Restarting $1" bold

    if systemctl list-units --type=service | grep -q "$1"; then
        systemctl restart "$1"
        colorize green "Service restarted successfully" bold
        echo
    else
        colorize red "Service not found"
    fi
    press_key
}

view_service_logs() {
    clear
    journalctl -eu "$1" -f -o cat
}

view_service_status() {
    clear
    systemctl status "$1"
    press_key
}

remove_core() {
    if find "$config_dir" -type f -name "*.toml" | grep -q .; then
        colorize red "Delete all services first."
        sleep 3
        return 1
    fi

    colorize yellow "Remove Backhaul-Core? (y/n)"
    read -r confirm

    if [[ $confirm == [yY] ]]; then
        [[ -d "$config_dir" ]] && rm -rf "$config_dir"
        colorize green "Backhaul-Core removed." bold
    fi
    press_key
}

update_script() {
    local dest_dir="/usr/bin"
    local script_url="https://raw.githubusercontent.com/MatinDehghanian/backhaul-script/refs/heads/main/backhaul.sh"
    local temporary

    if ! temporary=$(mktemp "$dest_dir/.backhaul-script.XXXXXX"); then
        colorize red "Could not prepare the script update."
        press_key
        return 1
    fi

    if ! curl -fLsS --ipv4 --retry 2 --max-time 30 -o "$temporary" "$script_url" ||
        [[ ! -s "$temporary" ]] ||
        [[ "$(head -n 1 "$temporary")" != '#!/bin/bash' ]] ||
        ! bash -n "$temporary" ||
        ! chmod 755 "$temporary" ||
        ! mv -fT -- "$temporary" "$dest_dir/backhaul"; then
        rm -f "$temporary"
        colorize red "Script update failed. The installed script was kept."
        press_key
        return 1
    fi

    colorize green "Script updated from GitHub." bold
    colorize yellow "Type 'backhaul' to run the updated script." bold
    exit 0
}

configure_tunnel() {
    [[ ! -d "$config_dir" ]] && {
        colorize red "Install Backhaul-Core first."
        press_key
        return 1
    }

    clear
    echo ""
    colorize green "1) Configure IRAN (Server)" bold
    colorize magenta "2) Configure KHAREJ (Client)" bold
    colorize cyan "3) Setup KHAREJ from an IRAN setup link" bold
    echo ""
    read -r -p "Enter your choice: " configure_choice

    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
        3) setup_from_link ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

# ============================================================================
# MENU SYSTEM
# ============================================================================

display_menu() {
    clear
    display_logo
    display_server_info
    display_backhaul_core_status

    echo
    colorize green " 1. Configure a new tunnel" bold
    colorize red " 2. Tunnel management" bold
    colorize cyan " 3. Check tunnel status" bold
    echo " 4. Update Backhaul Core"
    echo " 5. Update script"
    echo " 6. Remove Backhaul Core"
    echo " 0. Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

read_option() {
    read -r -p "Enter your choice [0-6]: " choice
    case $choice in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) download_backhaul "menu" ;;
        5) update_script ;;
        6) remove_core ;;
        0) exit 0 ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}

# Main loop
while true; do
    display_menu
    read_option
done
