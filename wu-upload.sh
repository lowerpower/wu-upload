#!/usr/bin/env bash
#
# wu-upload.sh — push Acurite temp/humidity to Weather Underground PWS
#
# Install:  /usr/local/bin/wu-upload.sh   (chmod 755)
# Secrets:  /etc/pws/secrets.env          (chmod 600)
# Reader:   read_acurite.sh, path set by $READER
#
# Cron (note the offset — everyone else fires on the :00/:05 mark):
#   PATH=/usr/local/bin:/usr/bin:/bin
#   2,7,12,17,22,27,32,37,42,47,52,57 * * * * /usr/local/bin/wu-upload.sh
#
# Every setting below can be overridden from the environment, so a second
# station needs no edit to this file — only a different STATION_ID and a
# matching WU_UPLOAD_KEY_<STATION_ID> in the secrets file.
#
set -euo pipefail

STATION_ID="${STATION_ID:-KCACLEAR4}"
SECRETS="${SECRETS:-/etc/pws/secrets.env}"
READER="${READER:-/usr/local/bin/read_acurite.sh}"
READ_WINDOW="${READ_WINDOW:-60}"
LOGFILE="${LOGFILE:-/var/log/pws/wu-upload.log}"
LOCKFILE="${LOCKFILE:-/run/lock/wu-upload.lock}"
MISSFILE="${MISSFILE:-/run/pws/consecutive-misses}"
SOFTWARE="${SOFTWARE:-mycal-pws/0.1}"
ENDPOINT="${ENDPOINT:-https://weatherstation.wunderground.com/weatherstation/updateweatherstation.php}"

# Plausibility bounds — reject obvious sensor faults rather than publishing
# them to a permanent public archive.
TEMP_F_MIN=-40
TEMP_F_MAX=140
HUM_MIN=0
HUM_MAX=100

mkdir -p /run/pws "$(dirname "$LOGFILE")" 2>/dev/null || true

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOGFILE"
}

die() {
    log "FATAL $*"
    exit 1
}

scrub() {
    sed -E 's/PASSWORD=[^&[:space:]]*/PASSWORD=***/g'
}

# ---------------------------------------------------------------- lock
# Two rtl_433 processes on one dongle will both fail. Bail rather than fight.
exec 9>"$LOCKFILE"
flock -n 9 || { log "SKIP previous run still active"; exit 0; }

# ------------------------------------------------------------- secrets
[[ -r "$SECRETS" ]] || die "cannot read $SECRETS"

perms=$(stat -c '%a' "$SECRETS")
[[ "$perms" == "600" || "$perms" == "400" ]] || die "$SECRETS is mode $perms, want 600"

set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

# The key is named after the station, so one secrets file can serve several.
KEY_VAR="WU_UPLOAD_KEY_${STATION_ID}"
UPLOAD_KEY="${!KEY_VAR:?$KEY_VAR not set in $SECRETS}"

# ---------------------------------------------------------------- read
# A missing reader is a configuration error, not a lossy-RF condition. Say so
# rather than letting it accumulate as misses and blame the sensor battery.
[[ -x "$READER" ]] || die "reader not executable: $READER (set \$READER)"

# A single miss is normal — RF is lossy. Sustained silence is not.
if ! reading=$("$READER" --json "$READ_WINDOW" 2>>"$LOGFILE"); then
    n=$(( $(cat "$MISSFILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$MISSFILE"
    if (( n >= 6 )); then
        log "ERROR $n consecutive misses — check sensor battery / SDR"
    else
        log "WARN no read (miss $n)"
    fi
    exit 0
fi
echo 0 > "$MISSFILE"

read -r TEMP_F HUMIDITY BATT SENSOR_ID < <(
    jq -r '
        def fahrenheit:
            if .temperature_F != null then .temperature_F
            else ((.temperature_C * 9 / 5) + 32) end;
        "\(fahrenheit | .*10 | round/10) \(.humidity) \(.battery_ok // 1) \(.id // "?")"
    ' <<<"$reading"
)

# -------------------------------------------------------------- verify
is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

is_num "${TEMP_F:-}"   || die "temp not numeric: '${TEMP_F:-}'"
is_num "${HUMIDITY:-}" || die "humidity not numeric: '${HUMIDITY:-}'"

in_range() {  # value min max
    awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'
}

in_range "$TEMP_F" "$TEMP_F_MIN" "$TEMP_F_MAX" \
    || die "temp ${TEMP_F}F outside [$TEMP_F_MIN,$TEMP_F_MAX]"
in_range "$HUMIDITY" "$HUM_MIN" "$HUM_MAX" \
    || die "humidity ${HUMIDITY}% outside [$HUM_MIN,$HUM_MAX]"

# ------------------------------------------------------------- derived
# WU computes both of these itself, but sending them explicitly keeps our
# local record and theirs in agreement rather than depending on their
# formula matching ours.

# Dewpoint — Magnus-Tetens, ±0.4C over normal ranges.
DEWPT_F=$(awk -v tf="$TEMP_F" -v rh="$HUMIDITY" 'BEGIN {
    if (rh <= 0) exit 1
    t = (tf - 32) / 1.8
    g = log(rh/100) + (17.62 * t) / (243.12 + t)
    printf "%.1f", ((243.12 * g) / (17.62 - g)) * 1.8 + 32
}') || DEWPT_F=""

# Heat index — NWS Rothfusz regression with the standard low/high-RH
# adjustments. Undefined below 80F, where it simply equals air temperature.
HEATIDX_F=$(awk -v t="$TEMP_F" -v r="$HUMIDITY" 'BEGIN {
    if (t < 80) { printf "%.1f", t; exit }
    hi = -42.379 + 2.04901523*t + 10.14333127*r \
       - 0.22475541*t*r - 0.00683783*t*t - 0.05481717*r*r \
       + 0.00122874*t*t*r + 0.00085282*t*r*r - 0.00000199*t*t*r*r
    d = (t - 95 < 0) ? 95 - t : t - 95
    if (r < 13 && t >= 80 && t <= 112)
        hi -= ((13 - r) / 4) * sqrt((17 - d) / 17)
    else if (r > 85 && t >= 80 && t <= 87)
        hi += ((r - 85) / 10) * ((87 - t) / 5)
    printf "%.1f", hi
}') || HEATIDX_F=""

# -------------------------------------------------------------- upload
DATEUTC=$(date -u '+%Y-%m-%d %H:%M:%S')

args=(
    -sS --max-time 20 -G "$ENDPOINT"
    --data-urlencode "action=updateraw"
    --data-urlencode "ID=$STATION_ID"
    --data-urlencode "PASSWORD=$UPLOAD_KEY"
    --data-urlencode "dateutc=$DATEUTC"
    --data-urlencode "tempf=$TEMP_F"
    --data-urlencode "humidity=$HUMIDITY"
    --data-urlencode "softwaretype=$SOFTWARE"
)
[[ -n "$DEWPT_F"   ]] && args+=(--data-urlencode "dewptf=$DEWPT_F")
[[ -n "$HEATIDX_F" ]] && args+=(--data-urlencode "heatindexf=$HEATIDX_F")
[[ "$BATT" == "0"  ]] && args+=(--data-urlencode "lowbatt=1")

# curl can echo the request URL on failure; scrub before it reaches the log.
if ! response=$(curl "${args[@]}" 2>&1); then
    log "ERROR curl failed: $(scrub <<<"$response")"
    exit 1
fi

response=$(tr -d '\r\n' <<<"$response" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

# Every outcome returns HTTP 200 — the body is the real status.
case "${response,,}" in
    success)
        log "OK id=$SENSOR_ID tempf=$TEMP_F humidity=$HUMIDITY dewptf=${DEWPT_F:-none} heatindexf=${HEATIDX_F:-none} batt=$BATT"
        ;;
    *invalidpasswordid*)
        die "credentials rejected — check Upload Key for $STATION_ID"
        ;;
    *)
        log "ERROR unexpected response: $(scrub <<<"$response")"
        exit 1
        ;;
esac



