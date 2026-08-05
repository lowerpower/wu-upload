#!/bin/bash
# Read one temperature/humidity report from an Acurite 433 MHz sensor.
#
# Returns as soon as a matching packet is decoded, rather than burning the
# full wait window. rtl_433 23.11 has no -E quit, and command substitution
# blocks until every process in a pipeline exits -- so SIGPIPE from `head`
# is not enough. We run rtl_433 in the background, poll its output, and
# kill it explicitly once we have what we need.

set -u
set -o pipefail

WAIT_SECONDS="${ACURITE_WAIT_SECONDS:-90}"

# Sensor id to accept. Empty string means "any Acurite", which will pick up
# a neighbour's sensor if one ever comes into range. Note that Acurite ids
# usually change when the battery is replaced -- if readings stop, re-run
# with ACURITE_ID= to discover the new id.
ACURITE_ID="${ACURITE_ID:-460}"

# Explicit centre frequency: the R820T reports "PLL not locked" when left to
# pick its own, which can cost sensitivity.
RTL_FREQ="${RTL_FREQ:-433.92M}"

# Successful reads also refresh the four-line input consumed by MRTG.
LAKE_TEMP_FILE="${LAKE_TEMP_FILE:-/tmp/lake_temp.txt}"

if [ -x /usr/bin/rtl_433 ]; then
    DEFAULT_RTL_433_BIN=/usr/bin/rtl_433
else
    DEFAULT_RTL_433_BIN=$(command -v rtl_433 2>/dev/null || true)
fi
RTL_433_BIN="${RTL_433_BIN:-$DEFAULT_RTL_433_BIN}"

usage()
{
    echo "Usage: $0 [--json] [seconds]" >&2
    echo "  seconds defaults to ACURITE_WAIT_SECONDS or 90" >&2
}

OUTPUT_JSON=0
if [ "${1:-}" = "--json" ]; then
    OUTPUT_JSON=1
    shift
fi

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; }; then
    usage
    exit 2
fi
[ "$#" -eq 1 ] && WAIT_SECONDS="$1"

if [ -z "$RTL_433_BIN" ] || [ ! -x "$RTL_433_BIN" ]; then
    echo "Error: rtl_433 was not found. Set RTL_433_BIN to its path." >&2
    exit 1
fi
for tool in jq stdbuf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool is required." >&2
        exit 1
    fi
done

ERROR_FILE=$(mktemp /tmp/read_acurite.XXXXXX)
RAW=$(mktemp /tmp/read_acurite_raw.XXXXXX)
RTL_PID=""

cleanup()
{
    if [ -n "$RTL_PID" ]; then
        kill "$RTL_PID" 2>/dev/null
        wait "$RTL_PID" 2>/dev/null
    fi
    rm -f "$ERROR_FILE" "$RAW"
}
trap cleanup EXIT INT TERM

# Do not use a numeric -R protocol filter: its value varies among rtl_433
# releases. Decode packets normally and select an Acurite temperature/humidity
# report from the JSON stream.
stdbuf -oL "$RTL_433_BIN" -F json -f "$RTL_FREQ" >"$RAW" 2>"$ERROR_FILE" &
RTL_PID=$!

READING=""
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    kill -0 "$RTL_PID" 2>/dev/null || break     # rtl_433 exited early

    READING=$(
        jq -c --arg ID "$ACURITE_ID" '
            select(
                ((.model // "") | test("acurite"; "i")) and
                ($ID == "" or ((.id // "") | tostring) == $ID) and
                (.humidity != null) and
                (.temperature_C != null or .temperature_F != null)
            )' "$RAW" 2>/dev/null | head -n 1
    )
    [ -n "$READING" ] && break

    sleep 0.5
done

kill "$RTL_PID" 2>/dev/null
wait "$RTL_PID" 2>/dev/null
RTL_PID=""

if [ -z "$READING" ]; then
    if grep -qiE 'error while loading shared libraries|not found' "$ERROR_FILE"; then
        echo "Error: rtl_433 cannot start because a shared library is missing:" >&2
        sed -n '1,3p' "$ERROR_FILE" >&2
    elif grep -qiE 'usb_claim_interface|device.*busy|No supported devices' "$ERROR_FILE"; then
        echo "Error: SDR unavailable (in use by another process?)." >&2
        sed -n '1,5p' "$ERROR_FILE" >&2
    else
        echo "Error: no Acurite report (id=${ACURITE_ID:-any}) in ${WAIT_SECONDS}s." >&2
        [ -s "$ERROR_FILE" ] && sed -n '1,5p' "$ERROR_FILE" >&2
    fi
    exit 1
fi

# Write the MRTG input atomically so readers never see a partial update.
# Keep the previous good reading if parsing or writing this update fails.
MRTG_VALUES=$(
    echo "$READING" | jq -er '
        def fahrenheit:
            if .temperature_F != null then .temperature_F
            else ((.temperature_C * 9 / 5) + 32)
            end;
        [(fahrenheit | . * 10 | round / 10), .humidity] | @tsv
    '
) || {
    echo "Error: could not format Acurite reading for $LAKE_TEMP_FILE." >&2
    exit 1
}

IFS=$'\t' read -r TEMPERATURE_F HUMIDITY <<EOF
$MRTG_VALUES
EOF

LAKE_TEMP_DIR=$(dirname "$LAKE_TEMP_FILE")
LAKE_TEMP_TMP=$(mktemp "${LAKE_TEMP_DIR}/.lake_temp.XXXXXX") || {
    echo "Error: could not create temporary MRTG input in $LAKE_TEMP_DIR." >&2
    exit 1
}
if ! printf '%s\n%s\n%s\n%s\n' \
    "$TEMPERATURE_F" "$HUMIDITY" "$(uptime)" "${HOSTNAME:-$(hostname)}" \
    >"$LAKE_TEMP_TMP" ||
   ! chmod 644 "$LAKE_TEMP_TMP" ||
   ! mv -f "$LAKE_TEMP_TMP" "$LAKE_TEMP_FILE"; then
    rm -f "$LAKE_TEMP_TMP"
    echo "Error: could not update $LAKE_TEMP_FILE." >&2
    exit 1
fi

if [ "$OUTPUT_JSON" -eq 1 ]; then
    echo "$READING" | jq .
    exit 0
fi

echo "$READING" | jq -r '
    def fahrenheit:
        if .temperature_F != null then .temperature_F
        else ((.temperature_C * 9 / 5) + 32)
        end;
    "Model:       \(.model)",
    "Sensor ID:   \(.id // "unknown")",
    (if .channel != null then "Channel:     \(.channel)" else empty end),
    "Temperature: \(fahrenheit | . * 10 | round / 10) F (\(.temperature_C // ((.temperature_F - 32) * 5 / 9) | . * 10 | round / 10) C)",
    "Humidity:    \(.humidity)%",
    "Battery:     \(.battery_ok // .battery // "unknown")",
    (if .time != null then "Received:    \(.time)" else empty end)
'




