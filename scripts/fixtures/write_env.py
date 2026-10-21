#!/usr/bin/env python3
"""把真机环境信息写成 env.json，供协议报告做环境门禁。

作者: long
用法：write_env.py <输出路径> <包名> <版本名> <版本号> <APK SHA-256> <设备型号> <序列号>
"""
from __future__ import annotations

import json
import sys


def main() -> None:
    if len(sys.argv) < 8:
        raise SystemExit(__doc__)
    path, package, version_name, version_code, apk_sha, model, serial = sys.argv[1:8]
    payload = {
        "package": package.strip(),
        "versionName": version_name.strip(),
        "versionCode": version_code.strip(),
        "apkSha256": apk_sha.strip(),
        "deviceModel": model.strip(),
        "serial": serial.strip(),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    print(path)


if __name__ == "__main__":
    main()
