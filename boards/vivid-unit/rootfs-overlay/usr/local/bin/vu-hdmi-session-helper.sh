#!/bin/bash
# This script detects HDMI connection, and perfroms two-step initialization to
# avoid affecting DSI display (wrong color or/and offsetted image).
# When screen orientation is changed by VSA, it rotates HDMI display as well.
set -u

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
LOG_FILE="$LOG_DIR/vu-hdmi-session-helper.log"
mkdir -p "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="$RUNTIME_DIR/vu-hdmi-session-helper.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

TARGET_DSI_MODE="720x1280"
DEFAULT_DSI_ANGLE="270"
POLL_INTERVAL=1
STARTUP_TIMEOUT=120

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

rotation_token_to_angle() {
    case "$1" in
        0|normal) echo 0 ;;
        90|left) echo 90 ;;
        180|inverted) echo 180 ;;
        270|right|"") echo 270 ;;
        *) return 1 ;;
    esac
}

rotation_angle_to_token() {
    case "$1" in
        0) echo normal ;;
        90) echo left ;;
        180) echo inverted ;;
        270|"") echo right ;;
        *) echo right ;;
    esac
}

normalize_angle() {
    local angle="${1:-0}"
    angle=$((angle % 360))
    if [ "$angle" -lt 0 ]; then
        angle=$((angle + 360))
    fi
    case "$angle" in
        0|90|180|270) echo "$angle" ;;
        *) echo "$DEFAULT_DSI_ANGLE" ;;
    esac
}

read_rotation_file_angle() {
    local raw
    raw="$(tr -d '\r' </etc/vu/rotation 2>/dev/null || true)"
    raw="$(trim "$raw")"
    if [ -z "$raw" ]; then
        return 1
    fi

    if rotation_token_to_angle "$raw" >/dev/null 2>&1; then
        rotation_token_to_angle "$raw"
        return 0
    fi

    return 1
}

get_output_rotation_token() {
    local output="$1"
    xrandr --query | awk -v out="$output" '
        $1 == out && $2 == "connected" {
            for (i = 1; i <= NF; i++) {
                if ($i == "normal" || $i == "left" || $i == "right" || $i == "inverted") {
                    print $i
                    exit
                }
            }
        }
    '
}

get_target_dsi_angle() {
    local dsi="${1:-}"
    local angle token

    if angle="$(read_rotation_file_angle 2>/dev/null)"; then
        echo "$(normalize_angle "$angle")"
        return 0
    fi

    if [ -n "$dsi" ]; then
        token="$(get_output_rotation_token "$dsi")"
        if [ -n "$token" ] && rotation_token_to_angle "$token" >/dev/null 2>&1; then
            rotation_token_to_angle "$token"
            return 0
        fi
    fi

    echo "$DEFAULT_DSI_ANGLE"
}

get_target_hdmi_angle() {
    local dsi_angle="$(normalize_angle "${1:-$DEFAULT_DSI_ANGLE}")"
    normalize_angle $((dsi_angle + 90))
}

get_dsi_logical_size() {
    local dsi_angle="$(normalize_angle "${1:-$DEFAULT_DSI_ANGLE}")"
    case "$dsi_angle" in
        0|180) echo "720x1280" ;;
        90|270) echo "1280x720" ;;
    esac
}

get_hdmi_target_physical_mode() {
    local dsi_angle="$(normalize_angle "${1:-$DEFAULT_DSI_ANGLE}")"
    local hdmi_angle="$(normalize_angle "${2:-0}")"
    local logical w h

    logical="$(get_dsi_logical_size "$dsi_angle")"
    w="${logical%x*}"
    h="${logical#*x}"

    case "$hdmi_angle" in
        0|180) echo "${w}x${h}" ;;
        90|270) echo "${h}x${w}" ;;
    esac
}

xrandr_ready() {
    xrandr --query >/dev/null 2>&1
}

find_connected_output() {
    local prefix="$1"
    xrandr --query | awk -v pfx="$prefix" '$1 ~ ("^" pfx) && $2 == "connected" { print $1; exit }'
}

current_outputs_summary() {
    xrandr --query | awk '/ connected/ { print }'
}

pick_preferred_prep_mode() {
    local output="$1"
    local supported
    local mode
    # preferred mode should not be 16:9, or DSI display will get affected
    # adjust this list accordingly if your HDMI display doesn't like a certain mode
    local preferred_modes=(
        800x600
        1024x768
        1280x1024
        1152x864
        1280x960
        832x624
        640x480
    )

    supported="$(xrandr --verbose | awk -v out="$output" '
        $1 == out && $2 == "connected" { in_block = 1; next }
        in_block && $1 ~ /^[A-Za-z0-9._-]+$/ && ($2 == "connected" || $2 == "disconnected") { exit }
        in_block && $1 ~ /^[0-9]+x[0-9]+$/ { print $1 }
    ')" || supported=""

    for mode in "${preferred_modes[@]}"; do
        if grep -qx "$mode" <<<"$supported"; then
            printf '%s\n' "$mode"
            return 0
        fi
    done

    return 1
}

pick_final_hdmi_mode() {
    local output="$1"
    local target_mode="$2"
    xrandr --verbose | awk -v out="$output" -v target="$target_mode" '
        function abs(v) { return v < 0 ? -v : v }

        $1 == out && $2 == "connected" { in_block = 1; next }
        in_block && $1 ~ /^[A-Za-z0-9._-]+$/ && ($2 == "connected" || $2 == "disconnected") { in_block = 0 }

        in_block && $1 ~ /^[0-9]+x[0-9]+$/ {
            mode = $1
            if (first == "") first = mode
            if (index($0, "+preferred") && preferred == "")
                preferred = mode

            split(mode, dims, "x")
            w = dims[1] + 0
            h = dims[2] + 0
            split(target, want, "x")
            tw = want[1] + 0
            th = want[2] + 0

            if (mode == target) {
                exact = mode
                found_exact = 1
                exit
            }

            score = ((w - tw) * (w - tw)) + ((h - th) * (h - th))
            area_diff = abs((w * h) - (tw * th))
            area = w * h

            if (best == "" ||
                score < best_score ||
                (score == best_score && area_diff < best_area_diff) ||
                (score == best_score && area_diff == best_area_diff && area < best_area)) {
                best = mode
                best_score = score
                best_area_diff = area_diff
                best_area = area
            }
        }

        END {
            if (found_exact) print exact
            else if (best != "") print best
            else if (preferred != "") print preferred
            else if (first != "") print first
        }
    '
}

apply_cleanup_sequence() {
    local dsi="$1"
    local hdmi="$2"
    local prep_mode="$3"
    local final_mode="$4"
    local dsi_rotation="$5"
    local hdmi_rotation="$6"

    # using this two-step initialization to avoid affecting DSI display (wrong color or/and offsetted image)
    log "Applying cleanup sequence: HDMI-only(prep=$prep_mode, hdmi-rotate=$hdmi_rotation) -> overlay(final=$final_mode, dsi-rotate=$dsi_rotation, hdmi-rotate=$hdmi_rotation)"

    if ! xrandr \
        --output "$dsi" --off \
        --output "$hdmi" --mode "$prep_mode" --rotate normal --pos 0x0; then
        log "ERROR: HDMI-only preparation step failed"
        return 1
    fi

    if ! xrandr \
        --output "$dsi" --mode "$TARGET_DSI_MODE" --rotate "$dsi_rotation" --pos 0x0 \
        --output "$hdmi" --mode "$final_mode" --rotate "$hdmi_rotation" --pos 0x0; then
        log "ERROR: final overlay step failed"
        return 1
    fi

    log "Cleanup sequence finished"
    current_outputs_summary | sed 's/^/[state] /'
    return 0
}

wait_for_xrandr() {
    local waited=0
    until xrandr_ready; do
        if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
            log "ERROR: xrandr never became ready"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

run_if_ready() {
    local dsi="$1"
    local hdmi="$2"
    local prep_mode final_mode
    local dsi_angle hdmi_angle dsi_rotation hdmi_rotation hdmi_target_mode

    dsi_angle="$(get_target_dsi_angle "$dsi")"
    hdmi_angle="$(get_target_hdmi_angle "$dsi_angle")"
    dsi_rotation="$(rotation_angle_to_token "$dsi_angle")"
    hdmi_rotation="$(rotation_angle_to_token "$hdmi_angle")"
    hdmi_target_mode="$(get_hdmi_target_physical_mode "$dsi_angle" "$hdmi_angle")"

    prep_mode="$(pick_preferred_prep_mode "$hdmi")"
    final_mode="$(pick_final_hdmi_mode "$hdmi" "$hdmi_target_mode")"

    if [ -z "$prep_mode" ]; then
        log "HDMI connected but none of the preferred preparation modes is available yet on $hdmi"
        return 1
    fi

    if [ -z "$final_mode" ]; then
        log "HDMI connected but no final mode is available yet on $hdmi (target=$hdmi_target_mode)"
        return 1
    fi

    log "Target rotations: dsi_angle=$dsi_angle($dsi_rotation) hdmi_angle=$hdmi_angle($hdmi_rotation)"
    log "Selected HDMI preparation mode=$prep_mode final mode=$final_mode (target physical mode=$hdmi_target_mode)"
    apply_cleanup_sequence "$dsi" "$hdmi" "$prep_mode" "$final_mode" "$dsi_rotation" "$hdmi_rotation"
}

main() {
    log "Starting session helper DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY"

    wait_for_xrandr || exit 0

    local prev_hdmi=""
    local startup_pending_hdmi=""
    local last_cleaned_signature=""
    local dsi hdmi rotation_sig current_sig

    prev_hdmi="$(find_connected_output 'HDMI-')"
    if [ -n "$prev_hdmi" ]; then
        startup_pending_hdmi="$prev_hdmi"
        log "HDMI already connected at session start ($prev_hdmi); startup cleanup armed"
    fi

    while true; do
        dsi="$(find_connected_output 'DSI-')"
        hdmi="$(find_connected_output 'HDMI-')"
        rotation_sig="$(get_target_dsi_angle "$dsi")"
        current_sig=""
        if [ -n "$hdmi" ]; then
            current_sig="${hdmi}|${rotation_sig}"
        fi

        if [ -n "$startup_pending_hdmi" ]; then
            if [ -z "$hdmi" ]; then
                log "Startup-pending HDMI disconnected before cleanup could run"
                startup_pending_hdmi=""
                last_cleaned_signature=""
            elif [ -z "$dsi" ]; then
                log "Waiting for DSI to be connected before startup cleanup"
            elif [ "$last_cleaned_signature" != "$current_sig" ]; then
                if run_if_ready "$dsi" "$hdmi"; then
                    last_cleaned_signature="$current_sig"
                    startup_pending_hdmi=""
                fi
            else
                startup_pending_hdmi=""
            fi
        elif [ -n "$dsi" ] && [ -z "$prev_hdmi" ] && [ -n "$hdmi" ]; then
            log "Detected new HDMI hotplug on $hdmi while $dsi is active"
            if run_if_ready "$dsi" "$hdmi"; then
                last_cleaned_signature="$current_sig"
            fi
        elif [ -n "$dsi" ] && [ -n "$hdmi" ] && [ "$last_cleaned_signature" != "$current_sig" ]; then
            log "HDMI is connected on $hdmi and desired rotation state changed or has not been cleaned yet; applying cleanup"
            if run_if_ready "$dsi" "$hdmi"; then
                last_cleaned_signature="$current_sig"
                startup_pending_hdmi=""
            fi
        elif [ -z "$hdmi" ] && [ -n "$last_cleaned_signature" ]; then
            log "HDMI disconnected; re-arming cleanup for next hotplug"
            last_cleaned_signature=""
        fi

        prev_hdmi="$hdmi"
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
