#!/usr/bin/env bash
set -Eeuo pipefail

INPUT=""
OUTPUT=""
FPS=""
GOP_SEC=""
VAAPI_DEVICE=""
VIDEO_BITRATE="12M"
MAXRATE="16M"
BUFSIZE="24M"
AUDIO_BITRATE="128k"

usage() {
    cat <<USAGE
Usage:
  $0 -i INPUT -o OUTPUT -f FPS -g GOP_SECONDS [options]

Required:
  -i INPUT          Input video file
  -o OUTPUT         Output mp4 file
  -f FPS            Output frame rate, example: 20
  -g GOP_SECONDS    GOP duration in seconds, example: 2

Optional:
  -d DEVICE         VAAPI render device, default: auto detect /dev/dri/renderD*
  -b BITRATE        Video bitrate, default: 12M
  -m MAXRATE        Video maxrate, default: 16M
  -u BUFSIZE        Video bufsize, default: 24M
  -a AUDIO_BITRATE  Audio bitrate, default: 128k
  -h                Show this help

Example:
  $0 -i Bears.webm -o Bears_h264_20fps_gop2s.mp4 -f 20 -g 2

USAGE
}

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

is_positive_number_or_ratio() {
    local value="$1"

    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v v="$value" 'BEGIN { exit !(v > 0) }'
        return
    fi

    if [[ "$value" =~ ^[0-9]+/[0-9]+$ ]]; then
        awk -v v="$value" '
            BEGIN {
                split(v, a, "/")
                exit !(a[1] > 0 && a[2] > 0)
            }
        '
        return
    fi

    return 1
}

is_positive_number() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v v="$value" 'BEGIN { exit !(v > 0) }'
}

fps_to_float() {
    local fps="$1"

    awk -v fps="$fps" '
        BEGIN {
            if (fps ~ /^[0-9]+\/[0-9]+$/) {
                split(fps, a, "/")
                printf "%.6f", a[1] / a[2]
            } else {
                printf "%.6f", fps
            }
        }
    '
}

calc_gop_frames() {
    local fps="$1"
    local gop_sec="$2"

    awk -v fps="$fps" -v gop_sec="$gop_sec" '
        BEGIN {
            if (fps ~ /^[0-9]+\/[0-9]+$/) {
                split(fps, a, "/")
                fps_value = a[1] / a[2]
            } else {
                fps_value = fps
            }

            gop_frames = fps_value * gop_sec

            # FFmpeg -g requires an integer.
            # Round to nearest integer.
            gop_frames = int(gop_frames + 0.5)

            if (gop_frames < 1) {
                gop_frames = 1
            }

            print gop_frames
        }
    '
}

detect_vaapi_device() {
    if [[ -n "$VAAPI_DEVICE" ]]; then
        [[ -e "$VAAPI_DEVICE" ]] || die "VAAPI device does not exist: $VAAPI_DEVICE"
        echo "$VAAPI_DEVICE"
        return
    fi

    if [[ -e /dev/dri/renderD128 ]]; then
        echo "/dev/dri/renderD128"
        return
    fi

    local dev
    for dev in /dev/dri/renderD*; do
        if [[ -e "$dev" ]]; then
            echo "$dev"
            return
        fi
    done

    die "No VAAPI render device found under /dev/dri/renderD*"
}

check_vaapi_permission() {
    local dev="$1"

    [[ -r "$dev" && -w "$dev" ]] || {
        ls -l "$dev" >&2 || true
        die "No read/write permission for $dev. Try: sudo usermod -aG render,video \$USER, then logout/login."
    }
}

check_ffmpeg_vaapi_support() {
    ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -qx "vaapi" \
        || die "This FFmpeg build does not list VAAPI in: ffmpeg -hwaccels"

    ffmpeg -hide_banner -encoders 2>/dev/null | grep  "h264_vaapi" \
        || die "This FFmpeg build does not support encoder: h264_vaapi"
}

check_vainfo_h264_encode() {
    local dev="$1"
    local tmp
    local h264_caps

    tmp="$(mktemp)"
    h264_caps="$(mktemp)"

    if ! vainfo --display drm --device "$dev" >"$tmp" 2>&1; then
        cat "$tmp" >&2
        rm -f "$tmp" "$h264_caps"
        die "vainfo failed. VAAPI driver/device is not working."
    fi

    # Keep only H.264 VAAPI capability lines, for example:
    #   VAProfileH264Main               : VAEntrypointVLD
    #   VAProfileH264Main               : VAEntrypointEncSlice
    #   VAProfileH264High               : VAEntrypointVLD
    #   VAProfileH264High               : VAEntrypointEncSlice
    grep -E "VAProfileH264[^:]*:[[:space:]]*VAEntrypoint" "$tmp" >"$h264_caps" || true

    if [[ ! -s "$h264_caps" ]]; then
        cat "$tmp" >&2
        rm -f "$tmp" "$h264_caps"
        die "No VAAPI H.264 capability lines found in vainfo output."
    fi

    log "Detected VAAPI H.264 capabilities:"
    sed 's/^/  /' "$h264_caps"

    # H.264 hardware encode requires at least one VAProfileH264* line with VAEntrypointEncSlice.
    # VLD means decode only; EncSlice means encode support.
    if ! grep -E "VAProfileH264[^:]*:[[:space:]]*VAEntrypointEncSlice" "$h264_caps" >/dev/null 2>&1; then
        rm -f "$tmp" "$h264_caps"
        die "VAAPI H.264 hardware encode is not supported. Missing VAProfileH264* : VAEntrypointEncSlice"
    fi

    # The FFmpeg command below uses '-profile:v high', so check High profile explicitly.
    # If only Main/Baseline encode exists, h264_vaapi might still encode after changing '-profile:v'.
    if ! grep -E "VAProfileH264High[[:space:]]*:[[:space:]]*VAEntrypointEncSlice" "$h264_caps" >/dev/null 2>&1; then
        warn "VAProfileH264High EncSlice was not found. The script uses '-profile:v high'; change the profile if FFmpeg fails."
    fi

    rm -f "$tmp" "$h264_caps"
}

check_input_video() {
    local input="$1"

    [[ -f "$input" ]] || die "Input file does not exist: $input"

    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=codec_name,width,height,avg_frame_rate \
        -of default=nw=1 "$input" >/dev/null \
        || die "ffprobe failed or no video stream found: $input"
}

check_output_path() {
    local output="$1"
    local outdir

    outdir="$(dirname "$output")"

    if [[ ! -d "$outdir" ]]; then
        mkdir -p "$outdir" || die "Failed to create output directory: $outdir"
    fi

    [[ -w "$outdir" ]] || die "Output directory is not writable: $outdir"
}

while getopts ":i:o:f:g:d:b:m:u:a:h" opt; do
    case "$opt" in
        i) INPUT="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        f) FPS="$OPTARG" ;;
        g) GOP_SEC="$OPTARG" ;;
        d) VAAPI_DEVICE="$OPTARG" ;;
        b) VIDEO_BITRATE="$OPTARG" ;;
        m) MAXRATE="$OPTARG" ;;
        u) BUFSIZE="$OPTARG" ;;
        a) AUDIO_BITRATE="$OPTARG" ;;
        h)
            usage
            exit 0
            ;;
        :)
            die "Option -$OPTARG requires an argument"
            ;;
        \?)
            die "Unknown option: -$OPTARG"
            ;;
    esac
done

[[ -n "$INPUT" ]] || die "Missing required option: -i INPUT"
[[ -n "$OUTPUT" ]] || die "Missing required option: -o OUTPUT"
[[ -n "$FPS" ]] || die "Missing required option: -f FPS"
[[ -n "$GOP_SEC" ]] || die "Missing required option: -g GOP_SECONDS"

is_positive_number_or_ratio "$FPS" || die "Invalid FPS: $FPS"
is_positive_number "$GOP_SEC" || die "Invalid GOP seconds: $GOP_SEC"

need_cmd ffmpeg
need_cmd ffprobe
need_cmd vainfo

DEVICE="$(detect_vaapi_device)"
GOP_FRAMES="$(calc_gop_frames "$FPS" "$GOP_SEC")"
FPS_FLOAT="$(fps_to_float "$FPS")"

log "Checking input file..."
check_input_video "$INPUT"

log "Checking output path..."
check_output_path "$OUTPUT"

log "Checking VAAPI device..."
log "VAAPI device: $DEVICE"
check_vaapi_permission "$DEVICE"

log "Checking FFmpeg VAAPI support..."
check_ffmpeg_vaapi_support

log "Checking VAAPI H.264 hardware encode support..."
check_vainfo_h264_encode "$DEVICE"

log "Input:"
ffprobe -hide_banner \
    -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate,pix_fmt \
    -of default=nw=1 "$INPUT"

log "Output settings:"
echo "  FPS          : $FPS"
echo "  FPS float    : $FPS_FLOAT"
echo "  GOP seconds  : $GOP_SEC"
echo "  GOP frames   : $GOP_FRAMES"
echo "  Video codec  : h264_vaapi"
echo "  Bitrate      : $VIDEO_BITRATE"
echo "  Maxrate      : $MAXRATE"
echo "  Bufsize      : $BUFSIZE"
echo "  Audio codec  : AAC"
echo "  Output       : $OUTPUT"

log "Starting FFmpeg..."

ffmpeg -hide_banner -y \
    -vaapi_device "$DEVICE" \
    -i "$INPUT" \
    -map 0:v:0 -map 0:a? \
    -vf "fps=${FPS},format=nv12,hwupload" \
    -c:v h264_vaapi \
    -profile:v high \
    -g "$GOP_FRAMES" \
    -force_key_frames "expr:gte(t,n_forced*${GOP_SEC})" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$MAXRATE" \
    -bufsize "$BUFSIZE" \
    -c:a aac \
    -b:a "$AUDIO_BITRATE" \
    -movflags +faststart \
    "$OUTPUT"

log "Transcode completed."

log "Verifying output video stream..."
ffprobe -hide_banner \
    -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt \
    -of default=nw=1 "$OUTPUT"

log "First keyframes:"
ffprobe -v error \
    -select_streams v:0 \
    -skip_frame nokey \
    -show_entries frame=best_effort_timestamp_time,pict_type \
    -of csv=p=0 "$OUTPUT" | head -20
