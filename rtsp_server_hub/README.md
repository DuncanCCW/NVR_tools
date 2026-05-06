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



```
sudo install -m 755 /path/to/nvs_rtsp_list_uris.sh /usr/local/bin/nvs_rtsp_list_uris.sh

nvs_rtsp_list_uris.sh --interface eth0
nvs_rtsp_list_uris.sh --show-file
nvs_rtsp_list_uris.sh --show-channel
nvs_rtsp_list_uris.sh --show-channel --show-file
```


