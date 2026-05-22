#!/usr/bin/env bash
set -euo pipefail

# Install NVS RTSP server stack:
# - /usr/local/bin/mediamtx
# - /usr/local/bin/nvs_rtsp_build_config.sh
# - /usr/local/bin/nvs_rtsp_publish.sh
# - /usr/local/bin/nvs_rtsp_server_start.sh
# - /etc/default/nvs_rtsp_server
# - /etc/systemd/system/nvs_rtsp_server.service
#
# After installation, the service scans all *.mp4 files in MP4_DIR,
# rebuilds a MediaMTX config, and publishes every file as an RTSP path.
#
# Example:
#   sudo bash rtsp_server_auto_install.sh \
#       --mediamtx-src /home/duncan/rtsp_server/mediamtx \
#       --mp4-dir /home/duncan/h264_gop2s \
#       --username senao \
#       --password admin123 \
#       --rtsp-port 8559

SERVICE_NAME="nvs_rtsp_server"
INSTALL_MEDIAMTX_BIN="/usr/local/bin/mediamtx"
INSTALL_HELPER_DIR="/usr/local/bin"
CONFIG_ROOT="/usr/local/etc/${SERVICE_NAME}"
GENERATED_YAML="${CONFIG_ROOT}/mediamtx.yml"
STREAM_MAP_FILE="${CONFIG_ROOT}/stream_map.tsv"
ENV_FILE="/etc/default/${SERVICE_NAME}"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
PUBLISHER_SCRIPT="${INSTALL_HELPER_DIR}/nvs_rtsp_publish.sh"
CONFIG_BUILDER_SCRIPT="${INSTALL_HELPER_DIR}/nvs_rtsp_build_config.sh"
START_SCRIPT="${INSTALL_HELPER_DIR}/nvs_rtsp_server_start.sh"

MEDIAMTX_SRC=""
MP4_DIR=""
RTSP_USER="senao"
RTSP_PASS="admin123"
RTSP_PORT="8559"
PATH_PREFIX="Streaming/Channels"
CHANNEL_BASE="1000"
ENABLE_WAIT_ONLINE="yes"

usage() {
    cat <<USAGE
Usage:
  sudo bash $0 --mediamtx-src <path/to/mediamtx> --mp4-dir <path/to/mp4_dir> [options]

Required:
  --mediamtx-src PATH   Source mediamtx binary path, or a directory containing mediamtx
  --mp4-dir PATH        Directory to scan for *.mp4 files

Optional:
  --username USER       RTSP username (default: senao)
  --password PASS       RTSP password (default: admin123)
  --rtsp-port PORT      RTSP port (default: 8559)
  --path-prefix PREFIX  RTSP path prefix (default: Streaming/Channels)
  --channel-base N      First channel number (default: 1000)
  --disable-wait-online Do not enable systemd-networkd-wait-online.service
  -h, --help            Show this help

Notes:
  * Every service start will rescan MP4_DIR and rebuild the generated YAML.
  * Streams are assigned sequentially from CHANNEL_BASE according to filename sort order.
  * Path mapping is written to: ${STREAM_MAP_FILE}
USAGE
}

log() {
    echo "[INFO] $*"
}

err() {
    echo "[ERROR] $*" >&2
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        err "please run as root: sudo bash $0 ..."
        exit 1
    fi
}

resolve_mediamtx_src() {
    local input="$1"

    if [[ -d "$input" ]]; then
        if [[ -x "$input/mediamtx" ]]; then
            printf '%s\n' "$input/mediamtx"
            return 0
        fi
        err "directory does not contain executable mediamtx: $input"
        exit 1
    fi

    if [[ -x "$input" ]]; then
        printf '%s\n' "$input"
        return 0
    fi

    err "mediamtx source is not executable: $input"
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mediamtx-src)
                MEDIAMTX_SRC="${2:-}"
                shift 2
                ;;
            --mp4-dir)
                MP4_DIR="${2:-}"
                shift 2
                ;;
            --username)
                RTSP_USER="${2:-}"
                shift 2
                ;;
            --password)
                RTSP_PASS="${2:-}"
                shift 2
                ;;
            --rtsp-port)
                RTSP_PORT="${2:-}"
                shift 2
                ;;
            --path-prefix)
                PATH_PREFIX="${2:-}"
                shift 2
                ;;
            --channel-base)
                CHANNEL_BASE="${2:-}"
                shift 2
                ;;
            --disable-wait-online)
                ENABLE_WAIT_ONLINE="no"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$MEDIAMTX_SRC" || -z "$MP4_DIR" ]]; then
        err "--mediamtx-src and --mp4-dir are required"
        usage
        exit 1
    fi

    if [[ ! "$RTSP_PORT" =~ ^[0-9]+$ ]]; then
        err "invalid --rtsp-port: $RTSP_PORT"
        exit 1
    fi

    if [[ ! "$CHANNEL_BASE" =~ ^[0-9]+$ ]]; then
        err "invalid --channel-base: $CHANNEL_BASE"
        exit 1
    fi
}

write_publisher_script() {
    cat > "$PUBLISHER_SCRIPT" <<'EOF_PUBLISHER'
#!/usr/bin/env bash
set -euo pipefail

MTX_PATH="${MTX_PATH:-}"
RTSP_PORT="${RTSP_PORT:-}"
RTSP_USER="${RTSP_USER:-senao}"
RTSP_PASS="${RTSP_PASS:-admin123}"
STREAM_MAP_FILE="${NVS_STREAM_MAP:-/usr/local/etc/nvs_rtsp_server/stream_map.tsv}"

if [[ -z "$MTX_PATH" || -z "$RTSP_PORT" ]]; then
    echo "MTX_PATH or RTSP_PORT is missing" >&2
    exit 1
fi

if [[ ! -f "$STREAM_MAP_FILE" ]]; then
    echo "stream map file not found: $STREAM_MAP_FILE" >&2
    exit 1
fi

INPUT_FILE=""
while IFS=$'\t' read -r channel path file; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == "$MTX_PATH" ]]; then
        INPUT_FILE="$file"
        break
    fi
done < "$STREAM_MAP_FILE"

if [[ -z "$INPUT_FILE" ]]; then
    echo "no input file mapped for MTX_PATH=$MTX_PATH" >&2
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "input file not found: $INPUT_FILE" >&2
    exit 1
fi

exec ffmpeg -nostdin -hide_banner -loglevel warning \
    -re -stream_loop -1 \
    -i "$INPUT_FILE" \
    -map 0:v:0 -map 0:a? \
    -c copy \
    -f rtsp -rtsp_transport tcp \
    "rtsp://${RTSP_USER}:${RTSP_PASS}@127.0.0.1:${RTSP_PORT}/${MTX_PATH}"
EOF_PUBLISHER

    chmod 755 "$PUBLISHER_SCRIPT"
}

write_config_builder_script() {
    cat > "$CONFIG_BUILDER_SCRIPT" <<'EOF_BUILDER'
#!/usr/bin/env bash
set -euo pipefail

MP4_DIR=""
OUTPUT_YAML=""
STREAM_MAP_FILE=""
RTSP_USER=""
RTSP_PASS=""
RTSP_PORT=""
PATH_PREFIX=""
CHANNEL_BASE=""
PUBLISHER_SCRIPT="/usr/local/bin/nvs_rtsp_publish.sh"

usage() {
    cat <<USAGE
Usage:
  nvs_rtsp_build_config.sh \
    --mp4-dir DIR \
    --output FILE \
    --stream-map FILE \
    --username USER \
    --password PASS \
    --rtsp-port PORT \
    --path-prefix PREFIX \
    --channel-base N \
    [--publisher-script PATH]
USAGE
}

yaml_quote() {
    local s="$1"
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mp4-dir)
                MP4_DIR="${2:-}"
                shift 2
                ;;
            --output)
                OUTPUT_YAML="${2:-}"
                shift 2
                ;;
            --stream-map)
                STREAM_MAP_FILE="${2:-}"
                shift 2
                ;;
            --username)
                RTSP_USER="${2:-}"
                shift 2
                ;;
            --password)
                RTSP_PASS="${2:-}"
                shift 2
                ;;
            --rtsp-port)
                RTSP_PORT="${2:-}"
                shift 2
                ;;
            --path-prefix)
                PATH_PREFIX="${2:-}"
                shift 2
                ;;
            --channel-base)
                CHANNEL_BASE="${2:-}"
                shift 2
                ;;
            --publisher-script)
                PUBLISHER_SCRIPT="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$MP4_DIR" || -z "$OUTPUT_YAML" || -z "$STREAM_MAP_FILE" || -z "$RTSP_USER" || -z "$RTSP_PASS" || -z "$RTSP_PORT" || -z "$PATH_PREFIX" || -z "$CHANNEL_BASE" ]]; then
        echo "missing required arguments" >&2
        usage >&2
        exit 1
    fi
}

main() {
    parse_args "$@"

    if [[ ! -d "$MP4_DIR" ]]; then
        echo "mp4 directory not found: $MP4_DIR" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$OUTPUT_YAML")"
    mkdir -p "$(dirname "$STREAM_MAP_FILE")"

    mapfile -d '' files < <(find "$MP4_DIR" -maxdepth 1 -type f -iname '*.mp4' -print0 | sort -zV)

    if (( ${#files[@]} == 0 )); then
        echo "no .mp4 files found in: $MP4_DIR" >&2
        exit 1
    fi

    declare -A existing_channel_by_file=()
    declare -A existing_path_by_file=()
    declare -A authorized_path_seen=()
    declare -a authorized_paths=()
    local max_channel max_channel_file persisted_max
    max_channel=$((CHANNEL_BASE - 1))
    max_channel_file="${STREAM_MAP_FILE}.max_channel"
    authorized_paths+=("~^${PATH_PREFIX}/.*$")
    authorized_path_seen["~^${PATH_PREFIX}/.*$"]=1

    if [[ -f "$STREAM_MAP_FILE" ]]; then
        local old_channel old_path old_file
        while IFS=$'\t' read -r old_channel old_path old_file; do
            [[ -n "${old_channel:-}" && -n "${old_path:-}" && -n "${old_file:-}" ]] || continue
            [[ "$old_channel" =~ ^[0-9]+$ ]] || continue

            existing_channel_by_file["$old_file"]="$old_channel"
            existing_path_by_file["$old_file"]="$old_path"

            if (( old_channel > max_channel )); then
                max_channel="$old_channel"
            fi
        done < "$STREAM_MAP_FILE"
    fi

    if [[ -f "$max_channel_file" ]]; then
        read -r persisted_max < "$max_channel_file" || persisted_max=""
        if [[ "$persisted_max" =~ ^[0-9]+$ ]] && (( persisted_max > max_channel )); then
            max_channel="$persisted_max"
        fi
    fi

    local file existing_path
    for file in "${files[@]}"; do
        existing_path="${existing_path_by_file[$file]:-}"
        if [[ -n "$existing_path" && -z "${authorized_path_seen[$existing_path]:-}" ]]; then
            authorized_paths+=("$existing_path")
            authorized_path_seen["$existing_path"]=1
        fi
    done

    : > "$STREAM_MAP_FILE"

    {
        echo "logLevel: info"
        echo "logDestinations: [stdout]"
        echo
        echo "authMethod: internal"
        echo "authInternalUsers:"
        echo "  - user: any"
        echo "    pass:"
        echo "    ips: ['127.0.0.1', '::1']"
        echo "    permissions:"
        echo "      - action: api"
        echo "      - action: metrics"
        echo "      - action: pprof"
        echo "  - user: $(yaml_quote "$RTSP_USER")"
        echo "    pass: $(yaml_quote "$RTSP_PASS")"
        echo "    permissions:"
        local auth_path
        for auth_path in "${authorized_paths[@]}"; do
            echo "      - action: publish"
            echo "        path: $(yaml_quote "$auth_path")"
            echo "      - action: read"
            echo "        path: $(yaml_quote "$auth_path")"
        done
        echo
        echo "rtsp: true"
        echo "rtspAddress: :${RTSP_PORT}"
        echo "rtspTransports: [tcp]"
        echo
        echo "pathDefaults:"
        echo "  source: publisher"
        echo "  overridePublisher: true"
        echo
        echo "paths:"

        local channel path name
        for file in "${files[@]}"; do
            name="$(basename "$file")"

            if [[ -n "${existing_channel_by_file[$file]:-}" ]]; then
                channel="${existing_channel_by_file[$file]}"
                path="${existing_path_by_file[$file]}"
            else
                max_channel=$((max_channel + 1))
                channel="$max_channel"
                path="${PATH_PREFIX}/${channel}"
            fi

            printf '%s\t%s\t%s\n' "$channel" "$path" "$file" >> "$STREAM_MAP_FILE"

            echo "  # ${name}"
            echo "  $(yaml_quote "$path"):"
            echo "    runOnInit: $(yaml_quote "$PUBLISHER_SCRIPT")"
            echo "    runOnInitRestart: yes"
            echo
        done
    } > "$OUTPUT_YAML"

    chmod 600 "$OUTPUT_YAML" "$STREAM_MAP_FILE"
    printf '%s\n' "$max_channel" > "$max_channel_file"
    chmod 600 "$max_channel_file"
}

main "$@"
EOF_BUILDER

    chmod 755 "$CONFIG_BUILDER_SCRIPT"
}

write_start_script() {
    cat > "$START_SCRIPT" <<'EOF_START'
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="nvs_rtsp_server"
ENV_FILE="/etc/default/${SERVICE_NAME}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

: "${MEDIAMTX_BIN:=/usr/local/bin/mediamtx}"
: "${MP4_DIR:=}"
: "${GENERATED_YAML:=/usr/local/etc/nvs_rtsp_server/mediamtx.yml}"
: "${NVS_STREAM_MAP:=/usr/local/etc/nvs_rtsp_server/stream_map.tsv}"
: "${RTSP_USER:=senao}"
: "${RTSP_PASS:=admin123}"
: "${RTSP_PORT:=8559}"
: "${PATH_PREFIX:=Streaming/Channels}"
: "${CHANNEL_BASE:=1000}"
: "${CONFIG_BUILDER_SCRIPT:=/usr/local/bin/nvs_rtsp_build_config.sh}"
: "${PUBLISHER_SCRIPT:=/usr/local/bin/nvs_rtsp_publish.sh}"

if [[ ! -x "$MEDIAMTX_BIN" ]]; then
    echo "mediamtx binary not found or not executable: $MEDIAMTX_BIN" >&2
    exit 1
fi

if [[ ! -x "$CONFIG_BUILDER_SCRIPT" ]]; then
    echo "config builder script not found or not executable: $CONFIG_BUILDER_SCRIPT" >&2
    exit 1
fi

if [[ ! -x "$PUBLISHER_SCRIPT" ]]; then
    echo "publisher script not found or not executable: $PUBLISHER_SCRIPT" >&2
    exit 1
fi

if [[ -z "$MP4_DIR" ]]; then
    echo "MP4_DIR is empty" >&2
    exit 1
fi

"$CONFIG_BUILDER_SCRIPT" \
    --mp4-dir "$MP4_DIR" \
    --output "$GENERATED_YAML" \
    --stream-map "$NVS_STREAM_MAP" \
    --username "$RTSP_USER" \
    --password "$RTSP_PASS" \
    --rtsp-port "$RTSP_PORT" \
    --path-prefix "$PATH_PREFIX" \
    --channel-base "$CHANNEL_BASE" \
    --publisher-script "$PUBLISHER_SCRIPT"

exec "$MEDIAMTX_BIN" "$GENERATED_YAML"
EOF_START

    chmod 755 "$START_SCRIPT"
}

write_env_file() {
    cat > "$ENV_FILE" <<EOF_ENV
MEDIAMTX_BIN=${INSTALL_MEDIAMTX_BIN}
MP4_DIR=${MP4_DIR}
GENERATED_YAML=${GENERATED_YAML}
NVS_STREAM_MAP=${STREAM_MAP_FILE}
RTSP_USER=${RTSP_USER}
RTSP_PASS=${RTSP_PASS}
RTSP_PORT=${RTSP_PORT}
PATH_PREFIX=${PATH_PREFIX}
CHANNEL_BASE=${CHANNEL_BASE}
CONFIG_BUILDER_SCRIPT=${CONFIG_BUILDER_SCRIPT}
PUBLISHER_SCRIPT=${PUBLISHER_SCRIPT}
EOF_ENV

    chmod 600 "$ENV_FILE"
}

write_systemd_unit() {
    cat > "$SYSTEMD_UNIT" <<EOF_UNIT
[Unit]
Description=NVS RTSP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
ExecStart=${START_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 "$SYSTEMD_UNIT"
}

main() {
    require_root
    parse_args "$@"

    MEDIAMTX_SRC="$(resolve_mediamtx_src "$MEDIAMTX_SRC")"

    if [[ ! -d "$MP4_DIR" ]]; then
        err "mp4 directory not found: $MP4_DIR"
        exit 1
    fi

    mkdir -p "$INSTALL_HELPER_DIR" "$CONFIG_ROOT"
    chmod 700 "$CONFIG_ROOT"

    install -m 755 "$MEDIAMTX_SRC" "$INSTALL_MEDIAMTX_BIN"
    write_publisher_script
    write_config_builder_script
    write_start_script
    write_env_file
    write_systemd_unit

    if [[ "$ENABLE_WAIT_ONLINE" == "yes" ]] && systemctl list-unit-files | grep -q '^systemd-networkd-wait-online\.service'; then
        systemctl enable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"

    log "installation completed"
    log "service: ${SERVICE_NAME}.service"
    log "env file: ${ENV_FILE}"
    log "generated yaml: ${GENERATED_YAML}"
    log "stream map: ${STREAM_MAP_FILE}"
    log "check service status with: systemctl status ${SERVICE_NAME}.service --no-pager"
    log "follow logs with: journalctl -u ${SERVICE_NAME}.service -f"
}

main "$@"
