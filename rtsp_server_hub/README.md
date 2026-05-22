# RTSP Server Hub

```
chmod +x rtsp_server_auto_install.sh

sudo ./rtsp_server_auto_install.sh \
  --mediamtx-src /home/duncan/rtsp_server/mediamtx \
  --mp4-dir /home/duncan/h264_gop2s \
  --username senao \
  --password admin123 \
  --rtsp-port 8559
```


```
sudo systemctl status nvs_rtsp_server.service --no-pager
journalctl -u nvs_rtsp_server.service -f
cat /usr/local/etc/nvs_rtsp_server/stream_map.tsv
cat /usr/local/etc/nvs_rtsp_server/mediamtx.yml
```

`stream_map.tsv` is persistent across service restarts. Existing videos keep
their assigned RTSP path. Removed videos are skipped, and newly added videos use
the next channel number after the highest channel already assigned. The high
water mark is stored in `stream_map.tsv.max_channel` so removed tail entries are
not reused later. If `PATH_PREFIX` is changed, existing mapped paths keep working
and the new prefix is used only for newly assigned channels.

```
sudo install -m 755 /path/to/nvs_rtsp_list_uris.sh /usr/local/bin/nvs_rtsp_list_uris.sh

nvs_rtsp_list_uris.sh --interface eth0
nvs_rtsp_list_uris.sh --show-file
nvs_rtsp_list_uris.sh --show-channel
nvs_rtsp_list_uris.sh --show-channel --show-file
```
