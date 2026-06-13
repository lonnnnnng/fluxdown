# Protocol E2E Test Cases

This matrix is the reusable protocol test suite for FluxDown clients. Keep each
download payload below 10 MB unless the test explicitly documents a different
stress threshold.

## Scope

- Applies to Android, iOS, desktop GUI, and CLI.
- Uses the same case id across platforms so reports can be compared.
- Separates public internet fixtures from fixtures that should be hosted on a
  local lab network.
- A passing result requires a real file write plus size/content verification,
  not only protocol detection or task creation.

## Public Fixtures

| Case id | Protocol | Source | Size limit | Expected check | Notes |
| --- | --- | --- | --- | --- | --- |
| `http-example-page` | HTTP | `http://example.com/` | <= 1 MB | output size > 0 and <= 1 MB | Public example page; stable plain HTTP smoke fixture. |
| `https-cloudflare-trace` | HTTPS | `https://cloudflare.com/cdn-cgi/trace` | <= 1 MB | output text is non-empty and <= 1 MB | Public Cloudflare trace endpoint; small HTTPS smoke fixture. |
| `ftp-rebex-readme` | FTP | `ftp://demo:password@test.rebex.net/readme.txt` | 379 bytes | output text contains Rebex readme | Rebex public read-only test server. |
| `ftps-rebex-readme` | FTPS | `ftps://demo:password@test.rebex.net/readme.txt` | 379 bytes | output text contains Rebex readme | Public compatibility check. Rebex requires TLS session resumption for the data connection, so clients without that support should fail with a clear error. |
| `sftp-rebex-readme` | SFTP | `sftp://demo:password@test.rebex.net/readme.txt` | 379 bytes | output text contains Rebex readme | Rebex public read-only test server. |
| `webdav-example-page` | WebDAV transport | `webdav://example.com/` | <= 1 MB | output size > 0 and <= 1 MB | Mobile currently maps this scheme to HTTP transport; this is not full WebDAV method coverage. |
| `webdavs-cloudflare-trace` | WebDAVS transport | `webdavs://cloudflare.com/cdn-cgi/trace` | <= 1 MB | output text is non-empty and <= 1 MB | Mobile currently maps this scheme to HTTPS transport; this is not full WebDAV method coverage. |
| `ipfs-hello` | IPFS | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244` | 11 bytes | output text equals `Hello IPFS` | Public IPFS sample fetched through the app's gateway path. |

## Local Lab Fixtures

Public, stable, read-only fixtures are not realistic for every protocol. Use
these local fixtures for repeatable validation on any platform.

| Case id | Protocol | Source pattern | Size limit | Expected check | Lab setup |
| --- | --- | --- | --- | --- | --- |
| `https-local-small` | HTTPS | `https://<host>:9443/https.txt?allowBadCertificate=true` | <= 1 MB | output text/hash matches fixture | Use a local HTTPS server with an explicit lab-only self-signed certificate opt-in. |
| `ftp-local-small` | FTP | `ftp://<user>:<pass>@<host>:2021/readme.txt` | <= 1 MB | output text/hash matches fixture | Use a LAN FTP fixture with a fixed passive port range. |
| `webdav-local-small` | WebDAV | `webdav://<host>:<port>/fixtures/sample.bin` | <= 1 MB | output size/hash matches fixture | Start a local WebDAV server on the same LAN. Use this for full WebDAV behavior once the client implements WebDAV-specific methods. |
| `webdavs-local-small` | WebDAVS | `webdavs://<host>:9443/https.txt?allowBadCertificate=true` | <= 1 MB | output text/hash matches fixture | Same as WebDAV over HTTPS with an explicit lab-only self-signed certificate opt-in. |
| `ftps-local-small` | FTPS | `ftps://<user>:<pass>@<host>:2121/readme.txt?allowBadCertificate=true` | <= 1 MB | output size/hash matches fixture | Use an explicit FTPS server matching the client mode being tested; include a TLS-session-resumption fixture if possible. |
| `sftp-local-small` | SFTP | `sftp://<user>:<pass>@<host>:2222/upload/readme.txt` | <= 1 MB | output text/hash matches fixture | Use a LAN SFTP fixture with a password-auth test user. |
| `smb-local-small` | SMB | `smb://<user>:<pass>@<host>/<share>/sample.txt` | <= 1 MB | output text/hash matches fixture | Use a LAN SMB2/3 share; do not expose SMB to the internet. |
| `http-local-small` | HTTP | `http://<host>:<port>/seg1.ts` | <= 1 MB | output text/hash matches fixture | Useful for device networking and app write-path smoke tests. |
| `hls-local-small` | m3u8/HLS | `http://<host>:<port>/playlist.m3u8` | <= 1 MB | output `.ts` size/hash matches concatenated segments | Use a short VOD playlist with two tiny segments. |
| `torrent-local-small` | BitTorrent | `http://<host>:<port>/webtorrent-sample.torrent` or `file://...` | <= 10 MB total payload | torrent finishes and file content/hash matches fixture | Use a legal lab torrent with known small payload and seeded peer. |
| `magnet-local-small` | Magnet | `magnet:?xt=urn:btih:<infohash>&dn=<name>&tr=<tracker>` | <= 10 MB total payload | torrent finishes and file content/hash matches fixture | Use the same small legal torrent as `torrent-local-small`. |
| `ipfs-local-gateway-small` | IPFS | `ipfs://<cid>/readme.txt?gateway=http%3A%2F%2F<host>%3A8765` | <= 1 MB | output text/hash matches fixture | Use a local IPFS gateway-compatible HTTP path `/ipfs/<cid>/...`; custom gateway keeps tests device-network independent. |
| `ed2k-handoff` | ed2k | `ed2k://|file|sample.bin|<size>|<hash>|/` | <= 10 MB | FluxDown hands off to an installed ed2k client, or reports no handler clearly | FluxDown cannot verify external client completion. |

## Local Fixture Recipes

### HTTP and m3u8/HLS

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
python3 -m http.server 8765 --bind 0.0.0.0
```

For Android devices attached by USB:

```sh
adb -s <device-id> reverse tcp:8765 tcp:8765
```

Then use:

- `http://127.0.0.1:8765/seg1.ts`
- `http://127.0.0.1:8765/playlist.m3u8`

### HTTPS and WebDAVS

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

Use:

- `https://127.0.0.1:9443/https.txt?allowBadCertificate=true`
- `webdavs://127.0.0.1:9443/https.txt?allowBadCertificate=true`

`allowBadCertificate=true` is only for local lab fixtures with self-signed
certificates.

### FTP and FTPS

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

Use:

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

Use:

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

Use:

```text
smb://flux:fluxpass@<lan-ip>/flux/sample.txt
```

### BitTorrent and Magnet

The Android real-device pass used a 15-byte legal local payload:

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

Use the generated `.torrent` via the local HTTP fixture server and use the
matching generated info hash for the magnet case. In the 2026-06-13 Android
run, the working magnet info hash was:

```text
fb443f977107cf6810a45c93288e63009291124d
```

### FTPS

Keep both FTPS cases:

- Public compatibility case: Rebex should currently expose clients that cannot
  satisfy data-connection TLS session resumption.
- Local pass case: a controlled FTPS fixture should be added when the target
  platform client supports the chosen FTPS mode.

### IPFS

The content id is intentionally tiny, but public gateway reachability varies by
device/network. Use the `gateway=` query parameter to point the app at a local
gateway-compatible fixture:

```text
ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8765
```

### ed2k

The mobile app currently delegates `ed2k://` links to the Android system. The
case passes only when:

- An external ed2k client is installed and receives the intent.
- FluxDown reports a clear no-handler error when no external client exists.

## Android / iOS Mobile Automation

The mobile integration test accepts JSON test cases through
`FLUXDOWN_E2E_CASES_JSON`.

Example:

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

Each completed case prints one line beginning with `FLUXDOWN_E2E_RESULT`. The
full run prints `FLUXDOWN_E2E_SUMMARY`.

For boundary cases such as ed2k on a device without an installed handler, pass
`expectedState` and `expectedErrorContains`:

```json
{
  "id": "ed2k-no-handler",
  "source": "ed2k://|file|sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/",
  "expectedState": "failed",
  "expectedErrorContains": "No installed app"
}
```
