#!/bin/bash

# Define script version
SCRIPT_VERSION="v1.0.0"

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
    eval "$var_name=\"${input:-$default}\""
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
    local cidr="$1"

    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi

    IFS='/' read -r ip mask <<< "$cidr"
    IFS='.' read -r a b c d <<< "$ip"

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

            prompt_with_default "PSK (32-char base64)" "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        # Non-IPX - use token
        prompt_with_default "Security Token" "your_token" CONFIG[token]
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
            echo "bind_addr = \"${CONFIG[bind_addr]}\""
            #echo "bind_addrs = ${CONFIG[bind_addrs]}"
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            echo "remote_addr = \"${CONFIG[remote_addr]}\""
            #echo "remote_addrs = ${CONFIG[remote_addrs]}"
            #[[ -n "${CONFIG[local_addr]}" ]] && echo "local_addr = \"${CONFIG[local_addr]}\""
            #echo "local_addrs = ${CONFIG[local_addrs]}"
            [[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi


        # Transport section
        echo "[transport]"
        echo "type = \"${CONFIG[transport_type]}\""
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
            echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
            echo "name = \"${CONFIG[tun_name]}\""
            echo "local_addr = \"${CONFIG[tun_local_addr]}\""
            echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            echo ""
        fi

        # IPX section (if ipx encapsulation)
        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            echo "mode = \"${CONFIG[ipx_mode]}\""
            echo "profile = \"${CONFIG[ipx_profile]}\""
            echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
            echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
            echo "interface = \"${CONFIG[ipx_interface]}\""
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
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            }
        else
            echo "token = \"${CONFIG[token]}\""
        fi

        echo ""

        # TLS section (if needed)
        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
            echo "[tls]"

            [[ -n "${CONFIG[tls_sni]}" ]]  && echo "sni = \"${CONFIG[tls_sni]}\""
            [[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
            [[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = \"${CONFIG[tls_key]}\""

            echo ""
        fi

        # Tuning section
        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]]  && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
        [[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]]  && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
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
        echo "log_level = \"${CONFIG[log_level]}\""
        echo ""

        # Ports section (if not client)
        if [[ "$mode" == "server" ]] ; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]]  && echo "forwarder = \"${CONFIG[forwarder]}\""
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
    if [[ "$mode" == "server" ]]; then
        tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
    else
        tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
    fi
    if [[ -z "$tunnel_port" ]]; then
        tunnel_port=$(echo "${CONFIG[tun_health_port]}")
    fi

    # Generate config file
    local config_file
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"
    fi

    generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"

    # Create systemd service
    local service_type
    [[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file"

    echo ""
    colorize green "✔ Configuration completed successfully!" bold
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

    systemctl daemon-reload
    systemctl enable --now "backhaul-${type}${port}.service" >/dev/null 2>&1

    colorize green "✔ Service backhaul-${type}${port} created and started" bold
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
    echo
    read -r -p "Enter your choice (0 to return): " choice

    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        5) edit_tunnel "$selected_config" ;;
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
    return
    DEST_DIR="/usr/bin/"
    BACKHAUL_SCRIPT="backhaul"
    SCRIPT_URL="http://194.9.6.93/backhaul.sh"

    [ -f "$DEST_DIR/$BACKHAUL_SCRIPT" ] && rm "$DEST_DIR/$BACKHAUL_SCRIPT"

    if curl -s -L -o "$DEST_DIR/$BACKHAUL_SCRIPT" "$SCRIPT_URL"; then
        chmod +x "$DEST_DIR/$BACKHAUL_SCRIPT"
        colorize yellow "Type 'backhaul' to run the script." bold
        exit 0
    else
        colorize red "Download failed."
    fi
    press_key
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
    echo ""
    read -r -p "Enter your choice: " configure_choice

    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
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
