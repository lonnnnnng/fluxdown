# Android Real Device Protocol Report

## Run Context

- Date: 2026-06-13 Asia/Shanghai.
- Device: Redmi Note 8 Pro, adb id `wsvwypiz7xwslvl7`.
- App package: `dev.fluxdown.mobile`.
- Test entrypoint: `apps/mobile/integration_test/protocol_e2e_test.dart`.
- Rule: payloads should stay below 10 MB when possible. All completed payloads
  in this pass were below 1 MB.

## Source Selection

Public resources were tried only when they are intended for testing or are
small public samples. The final Android baseline uses local lab fixtures so the
suite is repeatable across device networks and other platforms. Protocols that
are unsafe or unrealistic to expose on the public internet, such as SMB and
WebDAV lab shares, are specified in `docs/protocol-e2e-test-cases.md` as local
lab fixtures.

## Results Summary

- Passed on the Android real device: HTTP, HTTPS, FTP, FTPS, SFTP, WebDAV
  transport, WebDAVS transport, m3u8/HLS, SMB, BitTorrent `.torrent`, magnet,
  and IPFS gateway download.
- Tested boundary: ed2k. FluxDown delegates ed2k to an external Android app;
  this device has no installed ed2k handler, so the expected result is a clear
  no-handler failure.
- Important distinction: WebDAV/WebDAVS currently reuse the mobile HTTP/HTTPS
  transport path. These cases prove FluxDown's scheme mapping and file write
  path, not full WebDAV method coverage such as `PROPFIND`.

## Detailed Results

| Case id | Protocol | Resource | Limit | Android result | Evidence |
| --- | --- | --- | --- | --- | --- |
| `http-local-small` | HTTP | `http://127.0.0.1:8765/seg1.ts` through `adb reverse` | 12 B | Passed | `state=finished`, `downloadedBytes=12`, `outputBytes=12`, content matched `segment-one\n`. |
| `https-local-small` | HTTPS | `https://127.0.0.1:9443/https.txt?allowBadCertificate=true` through `adb reverse` | 13 B | Passed | `state=finished`, `downloadedBytes=13`, `outputBytes=13`, content matched `https-sample\n`. |
| `ftp-local-small` | FTP | `ftp://flux:fluxpass@192.168.1.7:2021/readme.txt` | 12 B | Passed | `state=finished`, `downloadedBytes=12`, `outputBytes=12`, content matched `ftps-sample\n`. |
| `ftps-local-small` | FTPS | `ftps://flux:fluxpass@192.168.1.7:2121/readme.txt?allowBadCertificate=true` | 12 B | Passed | `state=finished`, `downloadedBytes=12`, `totalBytes=12`, `outputBytes=12`, content matched `ftps-sample\n`. |
| `sftp-local-small` | SFTP | `sftp://flux:fluxpass@192.168.1.7:2222/upload/readme.txt` | 12 B | Passed | `state=finished`, `downloadedBytes=12`, `outputBytes=12`, content matched `sftp-sample\n`. |
| `webdav-local-small` | WebDAV | `webdav://127.0.0.1:8765/seg1.ts` through `adb reverse` | 12 B | Passed | `state=finished`, `downloadedBytes=12`, `outputBytes=12`; mobile transport mapped to HTTP. |
| `webdavs-local-small` | WebDAVS | `webdavs://127.0.0.1:9443/https.txt?allowBadCertificate=true` through `adb reverse` | 13 B | Passed | `state=finished`, `downloadedBytes=13`, `outputBytes=13`; mobile transport mapped to HTTPS. |
| `hls-local-small` | m3u8/HLS | `http://127.0.0.1:8765/playlist.m3u8` through `adb reverse` | 24 B output | Passed | `state=finished`, `downloadedBytes=24`, `outputBytes=24`, content matched concatenated segments. |
| `smb-local-small` | SMB | `smb://flux:fluxpass@192.168.1.7/flux/sample.txt` | 11 B | Passed | `state=finished`, `downloadedBytes=11`, `outputBytes=11`, content matched `smb-sample\n`. |
| `torrent-local-small` | BitTorrent | `http://127.0.0.1:8765/webtorrent-sample.torrent` through `adb reverse` | 15 B payload | Passed | `state=finished`, `downloadedBytes=15`, `totalBytes=15`, `outputBytes=15`, content matched `torrent-sample\n`. |
| `magnet-local-small` | Magnet | `magnet:?xt=urn:btih:fb443f977107cf6810a45c93288e63009291124d&dn=torrent-sample.txt&tr=http%3A%2F%2F192.168.1.7%3A8000%2Fannounce` | 15 B payload | Passed | `state=finished`, `downloadedBytes=15`, `totalBytes=15`, `outputBytes=15`, content matched `torrent-sample\n`. |
| `ipfs-local-gateway-small` | IPFS | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8765` | 10 B | Passed | `state=finished`, `downloadedBytes=10`, `outputBytes=10`, content matched `Hello IPFS`. |
| `ed2k-no-handler` | ed2k | `ed2k://|file|sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/` | 12 B link | Expected no-handler boundary | `state=failed`, error contained `No installed app can handle this ed2k link`. Android package manager also returned `No activities found`. |

## Commands Used

```sh
adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765

cd apps/mobile
flutter test integration_test/protocol_e2e_test.dart \
  -d wsvwypiz7xwslvl7 \
  --dart-define=FLUXDOWN_E2E_CASES_JSON='<json cases>'
```

The release APK was also installed and launched after the integration test run.
The device must be awake for screenshot/window verification:

```sh
adb -s wsvwypiz7xwslvl7 shell input keyevent KEYCODE_WAKEUP
adb -s wsvwypiz7xwslvl7 shell wm dismiss-keyguard
cd apps/mobile
flutter build apk --release
adb -s wsvwypiz7xwslvl7 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s wsvwypiz7xwslvl7 shell am start -n dev.fluxdown.mobile/.MainActivity
```

Foreground verification showed `dev.fluxdown.mobile/.MainActivity`,
`state=RESUMED`, `reportedDrawn=true`, and a visible Chinese default UI with
the source field, protocol chips, and queue controls.

## Local Lab Services Used

The following local services were used so the tests remain legal, small, and
repeatable on other platforms:

```sh
# HTTP/HLS/.torrent fixture server
python3 -m http.server 8765 --bind 0.0.0.0

# HTTPS/WebDAVS fixture server
python3 -m http.server 9443 --bind 0.0.0.0 \
  --tls-cert /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-key /tmp/fluxdown-e2e-ftps/key.pem

# Android access to local HTTP/HTTPS fixture servers
adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765
adb -s wsvwypiz7xwslvl7 reverse tcp:9443 tcp:9443

# FTP fixture
python -m pyftpdlib -i 0.0.0.0 -p 2021 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux -P fluxpass \
  -n 192.168.1.7 \
  -r 30100-30110

# FTPS fixture
python -m pyftpdlib -i 0.0.0.0 -p 2121 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux -P fluxpass \
  --tls \
  --keyfile /tmp/fluxdown-e2e-ftps/key.pem \
  --certfile /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-control-required \
  --tls-data-required \
  -n 192.168.1.7 \
  -r 30000-30010

# SFTP fixture
docker run -d --name fluxdown-sftp -p 2222:22 \
  -v /tmp/fluxdown-e2e-sftp/upload:/home/flux/upload:ro \
  atmoz/sftp flux:fluxpass:::upload

# SMB fixture
docker run -d --name fluxdown-samba -p 445:445 \
  -v /tmp/fluxdown-e2e-smb:/share:ro \
  dperson/samba \
  -u 'flux;fluxpass' \
  -s 'flux;/share;yes;no;no;flux'

# BitTorrent tracker and seed, from /tmp/fluxdown-bt-tools
./node_modules/.bin/bittorrent-tracker --http --udp --port 8000
./node_modules/.bin/webtorrent seed /tmp/fluxdown-bt-seed/torrent-sample.txt \
  --announce http://192.168.1.7:8000/announce \
  --torrent-port 51413 \
  --keep-seeding \
  --quiet
```

## Current Gaps

- ed2k needs an installed Android ed2k client. FluxDown currently delegates
  `ed2k://` links to another app and cannot verify that external download.
- WebDAV/WebDAVS are still transport-level checks on mobile because the current
  mobile backend maps them to HTTP/HTTPS GET. Full WebDAV method coverage needs
  a WebDAV-specific client implementation and fixture.
- Public internet smoke cases remain useful but are not stable enough for the
  required Android baseline on this device/network. In the final full-suite run,
  public Cloudflare/Rebex/example.com checks timed out, while equivalent local
  protocol fixtures passed.

## Notes

- Initial candidates `http://ipv4.download.thinkbroadband.com/5MB.zip`,
  `http://cachefly.cachefly.net/1mb.test`, and
  `https://speed.cloudflare.com/__down?bytes=1048576` were not kept as Android
  baseline cases because this device/network timed out or returned connection
  errors for those targets.
- The Android system `curl` on this device does not include FTP support, so FTP
  was verified through the FluxDown mobile FTP implementation itself.
- `flutter test` temporarily uninstalls/reinstalls the test app. A release APK
  was installed afterward to confirm launchability and visible UI on the real
  device.
- The final full local suite completed in one integration-test run with
  `00:08 +1: All tests passed!`.
