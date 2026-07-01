# RTSP Server Hub Study Notes

Last studied: 2026-07-01

## Repo Snapshot

- Branch: `develop`
- Latest commit studied: `8d11ca5 Persist RTSP stream channel mappings`
- Working tree at study time: clean
- Files:
  - `README.md`
  - `rtsp_server_auto_install.sh`
  - `nvs_rtsp_list_uris.sh`

## Purpose

This repo installs and manages an NVS RTSP server stack around MediaMTX.

The installed service scans a directory of `.mp4` files, generates a MediaMTX
config, maps each video to a stable RTSP path, and publishes each video in a loop
through `ffmpeg` to MediaMTX.

## Main Installer

File: `rtsp_server_auto_install.sh`

Run as root:

```bash
sudo ./rtsp_server_auto_install.sh \
  --mediamtx-src /home/duncan/rtsp_server/mediamtx \
  --mp4-dir /home/duncan/h264_gop2s \
  --username senao \
  --password admin123 \
  --rtsp-port 8559
```

Required arguments:

- `--mediamtx-src PATH`: executable `mediamtx` binary or directory containing it
- `--mp4-dir PATH`: directory containing `.mp4` files

Common optional arguments:

- `--username USER`: default `senao`
- `--password PASS`: default `admin123`
- `--rtsp-port PORT`: default `8559`
- `--path-prefix PREFIX`: default `Streaming/Channels`
- `--channel-base N`: default `1000`
- `--disable-wait-online`: skips enabling `systemd-networkd-wait-online.service`

## Installed Paths

The installer writes these runtime files:

- `/usr/local/bin/mediamtx`
- `/usr/local/bin/nvs_rtsp_publish.sh`
- `/usr/local/bin/nvs_rtsp_build_config.sh`
- `/usr/local/bin/nvs_rtsp_server_start.sh`
- `/etc/default/nvs_rtsp_server`
- `/etc/systemd/system/nvs_rtsp_server.service`
- `/usr/local/etc/nvs_rtsp_server/mediamtx.yml`
- `/usr/local/etc/nvs_rtsp_server/stream_map.tsv`
- `/usr/local/etc/nvs_rtsp_server/stream_map.tsv.max_channel`

The config root `/usr/local/etc/nvs_rtsp_server` is created with mode `700`.
Generated config and stream map files are chmod `600`.

## Service Flow

Systemd starts:

```text
/usr/local/bin/nvs_rtsp_server_start.sh
```

The start script:

1. Sources `/etc/default/nvs_rtsp_server`.
2. Validates `mediamtx`, config builder, publisher script, and `MP4_DIR`.
3. Runs `nvs_rtsp_build_config.sh` to rebuild `mediamtx.yml` and
   `stream_map.tsv`.
4. Execs `mediamtx` with the generated YAML.

MediaMTX paths use `runOnInit` to invoke:

```text
/usr/local/bin/nvs_rtsp_publish.sh
```

The publisher script:

1. Reads `MTX_PATH`, RTSP settings, and `stream_map.tsv`.
2. Finds the mp4 file mapped to the current MediaMTX path.
3. Runs `ffmpeg` with `-re -stream_loop -1 -c copy`.
4. Publishes to `rtsp://USER:PASS@127.0.0.1:PORT/PATH` over TCP.

## Stream Mapping Behavior

`stream_map.tsv` format:

```text
<channel>\t<path>\t<file>
```

Important behavior:

- Existing videos keep their assigned channel and RTSP path across restarts.
- Removed videos are skipped.
- Newly added videos receive the next channel number after the highest known
  channel.
- The high water mark is stored in `stream_map.tsv.max_channel`, so removed tail
  channels are not reused later.
- If `PATH_PREFIX` changes, existing mapped paths keep working. The new prefix is
  used only for newly assigned channels.
- Existing mapped paths are explicitly added to MediaMTX auth permissions, along
  with the current prefix regex.

Default path pattern:

```text
Streaming/Channels/<channel>
```

With defaults, channel `1000` becomes:

```text
rtsp://senao:admin123@<ip>:8559/Streaming/Channels/1000
```

## URI Listing Tool

File: `nvs_rtsp_list_uris.sh`

Purpose: print generated RTSP URIs from the stream map.

Default inputs:

- Env file: `/etc/default/nvs_rtsp_server`
- Stream map: `/usr/local/etc/nvs_rtsp_server/stream_map.tsv`
- Interface: `eth0`
- Defaults if env missing:
  - user `senao`
  - password `admin123`
  - port `8559`

Install helper manually:

```bash
sudo install -m 755 /path/to/nvs_rtsp_list_uris.sh /usr/local/bin/nvs_rtsp_list_uris.sh
```

Examples:

```bash
nvs_rtsp_list_uris.sh --interface eth0
nvs_rtsp_list_uris.sh --show-file
nvs_rtsp_list_uris.sh --show-channel
nvs_rtsp_list_uris.sh --show-channel --show-file
```

Output formats:

- Default: URI only
- `--show-channel`: `<channel>\t<uri>`
- `--show-file`: `<uri>\t<file>`
- Both: `<channel>\t<uri>\t<file>`

## Useful Runtime Checks

```bash
sudo systemctl status nvs_rtsp_server.service --no-pager
journalctl -u nvs_rtsp_server.service -f
cat /usr/local/etc/nvs_rtsp_server/stream_map.tsv
cat /usr/local/etc/nvs_rtsp_server/mediamtx.yml
```

## Notes For Future Changes

- The installer uses heredocs to write helper scripts. Changes to installed
  runtime behavior usually need edits inside `rtsp_server_auto_install.sh`, not
  separate installed files.
- Be careful with `/etc/default/nvs_rtsp_server`: values are sourced as shell by
  both start and list scripts.
- `nvs_rtsp_list_uris.sh` depends on `ip`, `awk`, `cut`, and the chosen network
  interface having a global IPv4 address.
- `nvs_rtsp_build_config.sh` sorts discovered mp4 files with `sort -zV`.
- MediaMTX auth currently allows localhost `any` for api/metrics/pprof and uses
  the configured RTSP user for publish/read permissions.
