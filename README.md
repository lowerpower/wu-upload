# wu-upload — Acurite 433 MHz → Weather Underground

Reads a temperature/humidity packet from an [Acurite](https://www.acurite.com/)
433 MHz sensor with an RTL-SDR dongle, validates it, and uploads it to a
Weather Underground personal weather station.

Also writes a small plain-text file that a local grapher (MRTG, Munin, a cron
script — anything that can `cat` a file) can consume, so one RF read serves both
the public upload and local graphing without a second process fighting for the
SDR.

```text
Acurite sensor
    -> RTL-SDR / rtl_433
    -> read_acurite.sh
       -> /tmp/lake_temp.txt   (local graphing)
       -> JSON -> wu-upload.sh -> Weather Underground
```

`read_acurite.sh` is the only script here that starts `rtl_433`. Keep it that
way: two processes on one dongle will both fail.

## Requirements

- An RTL-SDR dongle
- [`rtl_433`](https://github.com/merbanan/rtl_433) (tested against 23.11)
- `jq`, `stdbuf` (coreutils), `curl`, `flock` (util-linux), `awk`
- A Weather Underground PWS station ID and upload key

## Files

| File | Purpose |
| --- | --- |
| `read_acurite.sh` | Reads one Acurite RF packet; prints it and refreshes the local data file. |
| `wu-upload.sh` | Validates a reading and uploads it to Weather Underground. |
| `process_data.sh` | No-op compatibility shim for an older cron entry. See below. |
| `secrets.env.example` | Template for the upload key file. |
| `crontab.example` | Suggested schedule. |

## Setup

1. Install the scripts:

   ```bash
   sudo install -m 755 read_acurite.sh /usr/local/bin/read_acurite.sh
   sudo install -m 755 wu-upload.sh    /usr/local/bin/wu-upload.sh
   ```

2. Create the secrets file, named after your station ID:

   ```bash
   sudo mkdir -p /etc/pws
   sudo cp secrets.env.example /etc/pws/secrets.env
   sudo chmod 600 /etc/pws/secrets.env
   sudo editor /etc/pws/secrets.env
   ```

   `wu-upload.sh` refuses to run unless this file is mode `600` or `400`.

3. Point `wu-upload.sh` at your reader and station. Every setting has an
   environment override, so no edit to the script is needed:

   ```bash
   STATION_ID=KXXYYYY7 READER=/usr/local/bin/read_acurite.sh /usr/local/bin/wu-upload.sh
   ```

   Defaults are the author's own (`STATION_ID=KCACLEAR4`, reader under
   `/home/mike/operations/`); override them or edit the defaults at the top of
   the script.

4. Install a schedule — see `crontab.example`.

## read_acurite.sh

Listens on 433.92 MHz and returns as soon as a matching temperature/humidity
packet arrives, rather than burning the whole wait window. Defaults to a
90-second window and Acurite sensor ID `460`.

```bash
# Human-readable
./read_acurite.sh

# JSON, 30-second window
./read_acurite.sh --json 30
```

Overrides:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ACURITE_ID` | `460` | Sensor ID to accept. Empty accepts any Acurite sensor. |
| `ACURITE_WAIT_SECONDS` | `90` | Read window, also settable as the positional argument. |
| `RTL_FREQ` | `433.92M` | Centre frequency. Set explicitly — the R820T reports "PLL not locked" when left to choose. |
| `LAKE_TEMP_FILE` | `/tmp/lake_temp.txt` | Local data file to refresh. |
| `RTL_433_BIN` | autodetected | Path to `rtl_433`. |

Acurite sensor IDs usually **change when the battery is replaced**. If readings
stop, re-run with `ACURITE_ID=` to discover the new one:

```bash
ACURITE_ID= ./read_acurite.sh --json 60
```

Note that an empty ID will also pick up a neighbour's sensor if one is in range.

### The local data file

Every successful read atomically replaces `$LAKE_TEMP_FILE` (default
`/tmp/lake_temp.txt`). A failed read leaves the last good file in place. The
file is mode `644` and holds four lines:

```text
temperature in Fahrenheit
relative humidity percentage
system uptime
hostname
```

For example:

```text
76.3
49
 10:37:12 up 2 days, 12:14, 2 users, load average: 0.22, 0.17, 0.12
lakeserver
```

That four-line shape is what MRTG expects from an external script (value 1,
value 2, uptime, hostname), so it can be consumed directly by a target such as:

```text
Target[lake]: `cat /tmp/lake_temp.txt`
Options[lake]: nopercent,gauge
```

Any tool that reads the first two lines will do just as well.

## wu-upload.sh

- Takes a non-blocking lock so overlapping runs do not fight over the SDR.
- Calls `read_acurite.sh --json` with a 60-second window.
- Rejects temperatures outside -40..140 °F and humidity outside 0..100%, rather
  than publishing obvious sensor faults to a permanent public archive.
- Computes dew point (Magnus-Tetens) and heat index (NWS Rothfusz regression).
- Uploads to Weather Underground.
- Counts consecutive RF misses and escalates from `WARN` to `ERROR` after six.
  A single miss is normal — RF is lossy. Sustained silence is not.
- Logs to `$LOGFILE`, scrubbing the upload key from any curl output.

Weather Underground returns HTTP 200 for every outcome, so the script checks the
response body: `success`, or `INVALIDPASSWORDID` meaning the key was rejected.

Environment overrides: `STATION_ID`, `SECRETS`, `READER`, `READ_WINDOW`,
`LOGFILE`, `LOCKFILE`, `MISSFILE`, `SOFTWARE`, `ENDPOINT`.

The upload key is read from `$SECRETS` and is looked up by station, so one
secrets file can serve several stations:

```bash
WU_UPLOAD_KEY_KCACLEAR4=...
WU_UPLOAD_KEY_KCAOTHER9=...
```

## process_data.sh

A deliberate no-op. An older setup ran a lake-temperature reader from
`/etc/crontab` every five minutes, which launched its own `rtl_433` and could
compete with the upload job for the SDR. The scheduled upload now obtains the
packet and `read_acurite.sh` refreshes both consumers from that single reading.

The shim exists so a stale `/etc/crontab` entry does nothing instead of failing.
If you have no such entry, you do not need this file.

## Troubleshooting

Check the latest values and when they were written:

```bash
cat /tmp/lake_temp.txt
stat /tmp/lake_temp.txt
```

Check uploader status and the current miss streak:

```bash
sudo tail -n 50 /var/log/pws/wu-upload.log
cat /run/pws/consecutive-misses
```

| Symptom | Cause |
| --- | --- |
| `SDR unavailable` | Another process claimed the USB device. Confirm no legacy reader is scheduled or running. |
| No matching Acurite report | Check the battery, widen the read window, or use `ACURITE_ID=` to find a changed sensor ID. |
| `cannot read /etc/pws/secrets.env` | Missing file, or not readable by the user cron runs as. |
| `is mode NNN, want 600` | `sudo chmod 600 /etc/pws/secrets.env` |
| `credentials rejected` | Wrong upload key for that station ID. |
| `rtl_433 was not found` | Install it, or set `RTL_433_BIN`. |

## License

MIT — see `LICENSE`.
