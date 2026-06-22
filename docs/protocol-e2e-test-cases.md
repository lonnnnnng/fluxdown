# 协议端到端测试用例

这份矩阵是 FluxDown 各端可复用的协议下载测试套件。除非用例明确标记为媒体级或压力回归，
下载资源应优先控制在 10 MB 以下。

## 适用范围

- 适用于 Android、iOS、桌面 GUI 和 CLI。
- 各平台使用相同 case id，便于横向对比报告。
- 区分公网只读资源和本地实验室资源。
- 通过标准必须是真实写入文件并完成大小或内容校验，不能只验证协议识别或任务创建。

## 公网资源

| Case id | 协议 | 下载源 | 体积限制 | 预期校验 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `http-example-page` | HTTP | `http://example.com/` | <= 1 MB | 输出大小 > 0 且 <= 1 MB | 稳定的小体积 HTTP smoke case。 |
| `https-cloudflare-trace` | HTTPS | `https://cloudflare.com/cdn-cgi/trace` | <= 1 MB | 输出文本非空且 <= 1 MB | 小体积 HTTPS smoke case。 |
| `ftp-rebex-readme` | FTP | `ftp://demo:password@test.rebex.net/readme.txt` | 379 bytes | 输出文本包含 Rebex readme | Rebex 公共只读测试服务。 |
| `ftps-rebex-readme` | FTPS | `ftps://demo:password@test.rebex.net/readme.txt` | 379 bytes | 输出文本包含 Rebex readme | Rebex 对 data connection TLS session resumption 有要求；不支持的客户端应给出清晰错误。 |
| `sftp-rebex-readme` | SFTP | `sftp://demo:password@test.rebex.net/readme.txt` | 379 bytes | 输出文本包含 Rebex readme | Rebex 公共只读测试服务。 |
| `webdav-example-page` | WebDAV transport | `webdav://example.com/` | <= 1 MB | 输出大小 > 0 且 <= 1 MB | 移动端当前映射到 HTTP transport，不代表完整 WebDAV 方法覆盖。 |
| `webdavs-cloudflare-trace` | WebDAVS transport | `webdavs://cloudflare.com/cdn-cgi/trace` | <= 1 MB | 输出文本非空且 <= 1 MB | 移动端当前映射到 HTTPS transport，不代表完整 WebDAV 方法覆盖。 |
| `ipfs-hello` | IPFS | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244` | 11 bytes | 输出文本等于 `Hello IPFS` | 通过 App 的 IPFS gateway 路径拉取公开样例。 |

## 本地实验室资源

并不是所有协议都适合依赖公网稳定资源。下列资源用于在任意平台上做可重复验证。

| Case id | 协议 | 下载源模式 | 体积限制 | 预期校验 | 实验室配置 |
| --- | --- | --- | --- | --- | --- |
| `https-local-small` | HTTPS | `https://<host>:9443/https.txt?allowBadCertificate=true` | <= 1 MB | 输出文本/hash 匹配 fixture | 本地 HTTPS 服务，显式使用仅限实验室的自签证书 opt-in。 |
| `ftp-local-small` | FTP | `ftp://<user>:<pass>@<host>:2021/readme.txt` | <= 1 MB | 输出文本/hash 匹配 fixture | LAN FTP fixture，固定 passive port range。 |
| `webdav-local-small` | WebDAV | `webdav://<host>:<port>/fixtures/sample.bin` | <= 1 MB | 输出大小/hash 匹配 fixture | 同 LAN WebDAV 服务；客户端实现 WebDAV 专用方法后用于完整覆盖。 |
| `webdavs-local-small` | WebDAVS | `webdavs://<host>:9443/https.txt?allowBadCertificate=true` | <= 1 MB | 输出文本/hash 匹配 fixture | 等价于 WebDAV over HTTPS，并带实验室自签证书 opt-in。 |
| `ftps-local-small` | FTPS | `ftps://<user>:<pass>@<host>:2121/readme.txt?allowBadCertificate=true` | <= 1 MB | 输出大小/hash 匹配 fixture | 使用和目标客户端模式匹配的 FTPS 服务，尽量包含 TLS session resumption fixture。 |
| `sftp-local-small` | SFTP | `sftp://<user>:<pass>@<host>:2222/upload/readme.txt` | <= 1 MB | 输出文本/hash 匹配 fixture | LAN SFTP fixture，使用密码认证测试用户。 |
| `smb-local-small` | SMB | `smb://<user>:<pass>@<host>/<share>/sample.txt` | <= 1 MB | 输出文本/hash 匹配 fixture | LAN SMB2/3 共享；不要把 SMB 暴露到公网。 |
| `http-local-small` | HTTP | `http://<host>:<port>/seg1.ts` | <= 1 MB | 输出文本/hash 匹配 fixture | 设备网络和 App 写入路径 smoke case。 |
| `hls-local-small` | m3u8/HLS | `http://<host>:<port>/playlist.m3u8` | <= 1 MB | 移动端输出 `.mp4` header 包含 `ftyp`；核心层 `.ts` 可比对 hash | 使用有效 MPEG-TS 分片验证移动端 remux。 |
| `torrent-local-small` | BitTorrent | `http://<host>:<port>/webtorrent-sample.torrent` 或 `file://...` | <= 10 MB 总 payload | torrent 完成且文件内容/hash 匹配 fixture | 使用合法小体积实验种子和正在做种的 peer。 |
| `magnet-local-small` | Magnet | `magnet:?xt=urn:btih:<infohash>&dn=<name>&tr=<tracker>` | <= 10 MB 总 payload | torrent 完成且文件内容/hash 匹配 fixture | 与 `torrent-local-small` 使用同一份合法小种子。 |
| `hls-local-media` | m3u8/HLS | `http://<host>:8766/hls/index.m3u8` | 媒体回归，可超过 10 MB | Android 输出最终 `.mp4`；任务完成且 duration 非零，无 remux crash | 用于验证真实视频 remux，不作为小体积 smoke case。 |
| `torrent-local-media-single` | BitTorrent | `http://<host>:8766/torrent/20260614.torrent` | 媒体回归，可超过 10 MB | metadata 将卡片名从 `.torrent` 改为真实文件名；所选文件完成且大小匹配 | 从实验室主机做种合法本地媒体。 |
| `magnet-local-media-single` | Magnet | `magnet:?xt=urn:btih:<media-infohash>&dn=<name>&tr=<tracker>` | 媒体回归，可超过 10 MB | metadata 将临时 magnet 名称改为真实文件名；下载完成且大小匹配 | 与 `torrent-local-media-single` 使用同一媒体 payload。 |
| `torrent-local-media-multi-selection` | BitTorrent | `http://<host>:8766/multi_torrent/20260614_bundle.torrent` | 媒体回归，可超过 10 MB | Android 显示 libtorrent 文件列表；桌面 CLI/Tauri command 传入文件编号；所选 indexes 持久化，进度只计算所选 payload | 包含一个大媒体文件和至少一个小 sidecar 文件。 |
| `magnet-local-media-multi-selection` | Magnet | `magnet:?xt=urn:btih:<bundle-infohash>&dn=<bundle>&tr=<tracker>` | 媒体回归，可超过 10 MB | Android 在 magnet metadata 到达后显示文件列表；桌面后续需要补齐 metadata 列表交互；所选 indexes 持久化，进度只计算所选 payload | 与 `torrent-local-media-multi-selection` 使用同一多文件 payload。 |
| `ipfs-local-gateway-small` | IPFS | `ipfs://<cid>/readme.txt?gateway=http%3A%2F%2F<host>%3A8765` | <= 1 MB | 输出文本/hash 匹配 fixture | 使用兼容 `/ipfs/<cid>/...` 的本地 HTTP gateway，避免设备网络影响。 |
| `ed2k-handoff` | ed2k | `ed2k://|file|sample.bin|<size>|<hash>|/` | <= 10 MB | FluxDown 移交给已安装 ed2k 客户端，或在无 handler 时清晰报错 | FluxDown 不能验证外部客户端最终下载完成。 |

## 本地资源搭建

### HTTP 与 m3u8/HLS

```sh
mkdir -p /tmp/fluxdown-e2e-hls
printf 'segment-one\n' > /tmp/fluxdown-e2e-hls/seg1.ts
printf 'segment-two\n' > /tmp/fluxdown-e2e-hls/seg2.ts
cat > /tmp/fluxdown-e2e-hls/playlist.m3u8 <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:1
#EXTINF:1.0,
seg1.ts
#EXTINF:1.0,
seg2.ts
#EXT-X-ENDLIST
EOF
python3 scripts/range-http-server.py \
  --bind 0.0.0.0 \
  --port 8765 \
  --directory /tmp/fluxdown-e2e-hls
```

Android 设备通过 USB 连接时：

```sh
adb -s <device-id> reverse tcp:8765 tcp:8765
```

然后使用：

- `http://127.0.0.1:8765/seg1.ts`
- `http://127.0.0.1:8765/playlist.m3u8`

### HTTPS 与 WebDAVS

```sh
mkdir -p /tmp/fluxdown-e2e-ftps
printf 'https-sample\n' > /tmp/fluxdown-e2e-hls/https.txt
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=127.0.0.1' \
  -keyout /tmp/fluxdown-e2e-ftps/key.pem \
  -out /tmp/fluxdown-e2e-ftps/cert.pem
python3 -m http.server 9443 --bind 0.0.0.0 \
  -d /tmp/fluxdown-e2e-hls \
  --tls-cert /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-key /tmp/fluxdown-e2e-ftps/key.pem
adb -s <device-id> reverse tcp:9443 tcp:9443
```

使用：

- `https://127.0.0.1:9443/https.txt?allowBadCertificate=true`
- `webdavs://127.0.0.1:9443/https.txt?allowBadCertificate=true`

`allowBadCertificate=true` 只允许用于本地实验室自签证书资源。

### FTP 与 FTPS

```sh
python3 -m venv /tmp/fluxdown-ftps-venv
/tmp/fluxdown-ftps-venv/bin/python -m pip install pyftpdlib pyopenssl
mkdir -p /tmp/fluxdown-e2e-ftps
printf 'ftps-sample\n' > /tmp/fluxdown-e2e-ftps/readme.txt
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=<lan-ip>' \
  -keyout /tmp/fluxdown-e2e-ftps/key.pem \
  -out /tmp/fluxdown-e2e-ftps/cert.pem

/tmp/fluxdown-ftps-venv/bin/python -m pyftpdlib \
  -i 0.0.0.0 \
  -p 2021 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux \
  -P fluxpass \
  -n <lan-ip> \
  -r 30100-30110

/tmp/fluxdown-ftps-venv/bin/python -m pyftpdlib \
  -i 0.0.0.0 \
  -p 2121 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux \
  -P fluxpass \
  --tls \
  --keyfile /tmp/fluxdown-e2e-ftps/key.pem \
  --certfile /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-control-required \
  --tls-data-required \
  -n <lan-ip> \
  -r 30000-30010
```

使用：

- `ftp://flux:fluxpass@<lan-ip>:2021/readme.txt`
- `ftps://flux:fluxpass@<lan-ip>:2121/readme.txt?allowBadCertificate=true`

### SFTP

```sh
mkdir -p /tmp/fluxdown-e2e-sftp/upload
printf 'sftp-sample\n' > /tmp/fluxdown-e2e-sftp/upload/readme.txt
docker run -d --name fluxdown-sftp -p 2222:22 \
  -v /tmp/fluxdown-e2e-sftp/upload:/home/flux/upload:ro \
  atmoz/sftp flux:fluxpass:::upload
```

使用：

```text
sftp://flux:fluxpass@<lan-ip>:2222/upload/readme.txt
```

### SMB

```sh
mkdir -p /tmp/fluxdown-e2e-smb
printf 'smb-sample\n' > /tmp/fluxdown-e2e-smb/sample.txt
docker run -d --name fluxdown-samba -p 445:445 \
  -v /tmp/fluxdown-e2e-smb:/share:ro \
  dperson/samba \
  -u 'flux;fluxpass' \
  -s 'flux;/share;yes;no;no;flux'
```

使用：

```text
smb://flux:fluxpass@<lan-ip>/flux/sample.txt
```

### BitTorrent 与 Magnet

Android 真机基线使用过一个 15-byte 的合法本地 payload：

```sh
mkdir -p /tmp/fluxdown-bt-seed
printf 'torrent-sample\n' > /tmp/fluxdown-bt-seed/torrent-sample.txt

mkdir -p /tmp/fluxdown-bt-tools
cd /tmp/fluxdown-bt-tools
npm init -y
npm install bittorrent-tracker webtorrent-cli

./node_modules/.bin/bittorrent-tracker --http --udp --port 8000
./node_modules/.bin/webtorrent create /tmp/fluxdown-bt-seed/torrent-sample.txt \
  --announce http://<lan-ip>:8000/announce \
  > /tmp/fluxdown-bt-seed/webtorrent-sample.torrent
cp /tmp/fluxdown-bt-seed/webtorrent-sample.torrent /tmp/fluxdown-e2e-hls/
./node_modules/.bin/webtorrent seed /tmp/fluxdown-bt-seed/torrent-sample.txt \
  --announce http://<lan-ip>:8000/announce \
  --torrent-port 51413 \
  --keep-seeding \
  --quiet
```

`.torrent` 通过本地 HTTP fixture server 分发；magnet 使用生成出的同一份 info hash。
2026-06-13 Android 验证中可用的 magnet info hash 为：

```text
fb443f977107cf6810a45c93288e63009291124d
```

媒体级 HLS/torrent/magnet 回归使用合法本地视频，并让所有服务保持在同一局域网：

```sh
mkdir -p local_protocol_resources/{hls,torrent,multi_torrent,source}
cp /path/to/legal-video.mp4 local_protocol_resources/source/20260614.mp4

ffmpeg -y -i local_protocol_resources/source/20260614.mp4 \
  -c copy \
  -f hls \
  -hls_time 4 \
  -hls_playlist_type vod \
  local_protocol_resources/hls/index.m3u8

transmission-create \
  -o local_protocol_resources/torrent/20260614.torrent \
  -t http://<lan-ip>:6969/announce \
  local_protocol_resources/source/20260614.mp4

mkdir -p local_protocol_resources/source/20260614_bundle
cp local_protocol_resources/source/20260614.mp4 \
  local_protocol_resources/source/20260614_bundle/20260614.mp4
printf 'FluxDown multi-file torrent sidecar\n' \
  > local_protocol_resources/source/20260614_bundle/readme.txt
transmission-create \
  -o local_protocol_resources/multi_torrent/20260614_bundle.torrent \
  -t http://<lan-ip>:6969/announce \
  local_protocol_resources/source/20260614_bundle

python3 local_protocol_resources/local_bt_tracker.py --host 0.0.0.0 --port 6969
python3 scripts/range-http-server.py \
  --bind 0.0.0.0 \
  --port 8766 \
  --directory local_protocol_resources
transmission-daemon --foreground \
  -g local_protocol_resources/transmission-config \
  -w local_protocol_resources/source \
  -T -r 127.0.0.1 -p 9092 -P 51413 -M -O -Y
```

Android 设备在同一 Wi-Fi 下应使用 `http://<lan-ip>:8766/...` 和包含 `<lan-ip>`
的 tracker URL，不能使用 `127.0.0.1`。

吞吐测试要使用上面的 Range-capable HTTP server。系统自带 `python3 -m http.server`
可能对 Range 请求返回 `200 OK`，导致移动端无法启用多线程 HTTP 下载。

### FTPS

保留两类 FTPS 用例：

- 公网兼容性用例：Rebex 能暴露客户端是否缺少 data connection TLS session resumption 支持。
- 本地通过用例：当目标平台客户端支持选定 FTPS 模式时，补充一个可控 FTPS fixture。

### IPFS

公共 CID 体积极小，但公共 gateway 在不同设备和网络下可能不稳定。可使用 `gateway=`
query 参数把 App 指向本地兼容 gateway 的 fixture：

```text
ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8765
```

### ed2k

移动端当前把 `ed2k://` 链接移交给 Android 系统。只有以下情况才算通过：

- 已安装外部 ed2k 客户端，并且能收到 intent。
- 未安装外部客户端时，FluxDown 给出清晰的 no-handler 错误。

## Android / iOS 移动端自动化

移动端 integration test 通过 `FLUXDOWN_E2E_CASES_JSON` 接收 JSON 测试用例。

iOS 可先使用仓库脚本跑本地 HTTP/HLS smoke。该脚本默认只选择已经连接或已经手动启动的
iOS 目标，不会自动打开 Simulator：

```sh
npm run verify:ios:integration
```

如果当前没有 iOS 目标，且允许脚本在后台 boot 一个可用 iPhone simulator，可以显式开启：

```sh
FLUXDOWN_IOS_BOOT_SIMULATOR=1 npm run verify:ios:integration
```

连接真机时，如果 iPhone 不能通过 `127.0.0.1` 访问 Mac 上的本地 fixture，需要显式指定
Mac 的局域网地址：

```sh
FLUXDOWN_IOS_DEVICE_ID=<device-id-or-name> \
FLUXDOWN_E2E_HOST=<mac-lan-ip> \
npm run verify:ios:integration
```

示例：

```sh
cd apps/mobile
flutter test integration_test/protocol_e2e_test.dart \
  -d <device-id> \
  --dart-define=FLUXDOWN_E2E_CASES_JSON='[
    {
      "id": "ipfs-hello",
      "source": "ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244",
      "fileName": "ipfs-hello.txt",
      "expectedBytes": 11,
      "expectedText": "Hello IPFS"
    }
  ]'
```

每个完成用例会打印一行 `FLUXDOWN_E2E_RESULT`；整轮结束会打印
`FLUXDOWN_E2E_SUMMARY`。

对未安装 handler 的 ed2k 这类边界用例，传入 `expectedState` 和
`expectedErrorContains`：

```json
{
  "id": "ed2k-no-handler",
  "source": "ed2k://|file|sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/",
  "expectedState": "failed",
  "expectedErrorContains": "No installed app"
}
```
