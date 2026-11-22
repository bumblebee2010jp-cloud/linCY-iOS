#!/usr/bin/env python3
"""校验未签名 ipa 的结构，供手机端签名前自检。

用法:
    python scripts/check_ipa.py linCY-0.1.0-1-Release-unsigned.ipa

检查项:
    - Payload/ 下恰好一个 .app
    - Info.plist 存在且可解析，CFBundleExecutable 与主二进制同名
    - 主二进制存在、Mach-O 魔数合法、arm64 架构
    - 是否残留 _CodeSignature / embedded.mobileprovision
    - Frameworks/ 下每个 framework 是否有可执行文件（手机端需全部重签）
    - Bundle ID / 版本 / 部署目标 / 权限说明摘要
"""

from __future__ import annotations

import plistlib
import sys
import zipfile
from pathlib import Path


def _setup_console() -> None:
    """让 Windows 控制台正确显示中文（默认 936 代码页会把 UTF-8 打成乱码）。"""
    if sys.platform != "win32":
        return
    try:
        import ctypes

        ctypes.windll.kernel32.SetConsoleOutputCP(65001)
    except Exception:
        pass
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass


_setup_console()

MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe": "Mach-O 64 小端 (arm64/x86_64)",
    b"\xca\xfe\xba\xbe": "Fat/Universal",
    b"\xce\xfa\xed\xfe": "Mach-O 32 小端",
    b"\xfe\xed\xfa\xcf": "Mach-O 64 大端",
}

CPU_ARM64 = 0x0100000C


def fail(msg: str) -> None:
    print(f"[FAIL] {msg}")


def warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def ok(msg: str) -> None:
    print(f"[ OK ] {msg}")


def read_macho_header(zf: zipfile.ZipFile, name: str) -> tuple[str, int | None]:
    with zf.open(name) as f:
        head = f.read(8)
    magic = head[:4]
    desc = MACHO_MAGIC.get(magic)
    if desc is None:
        return f"未知魔数 {magic.hex()}", None
    if magic == b"\xca\xfe\xba\xbe" and len(head) >= 8:
        nfat = int.from_bytes(head[4:8], "big")
        return f"{desc} ({nfat} 个 slice)", None
    cputype = int.from_bytes(head[4:8], "little")
    return desc, cputype


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    ipa = Path(sys.argv[1])
    if not ipa.is_file():
        fail(f"文件不存在: {ipa}")
        return 2

    print(f"文件: {ipa.name}  ({ipa.stat().st_size / 1024 / 1024:.2f} MiB)")
    problems = 0

    with zipfile.ZipFile(ipa) as zf:
        names = zf.namelist()

        apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and "/" in n[8:]})
        apps = [a for a in apps if a.endswith(".app")]
        if len(apps) != 1:
            fail(f"Payload 下的 .app 数量为 {len(apps)}，应为 1: {apps}")
            return 1
        app = apps[0]
        root = f"Payload/{app}"
        ok(f"App 包: {app}")

        info_path = f"{root}/Info.plist"
        if info_path not in names:
            fail("缺 Info.plist")
            return 1

        with zf.open(info_path) as f:
            info = plistlib.load(f)

        bundle_id = info.get("CFBundleIdentifier", "?")
        exec_name = info.get("CFBundleExecutable", "?")
        version = info.get("CFBundleShortVersionString", "?")
        build = info.get("CFBundleVersion", "?")
        deploy = info.get("MinimumOSVersion", "?")

        print()
        print("── Info.plist ──")
        print(f"  Bundle ID       : {bundle_id}")
        print(f"  Executable      : {exec_name}")
        print(f"  版本            : {version} ({build})")
        print(f"  显示名          : {info.get('CFBundleDisplayName') or info.get('CFBundleName')}")
        print(f"  最低 iOS        : {deploy}")
        print(f"  设备族          : {info.get('UIDeviceFamily')}")
        caps = [
            k for k, v in info.items()
            if k.startswith("NS") and k.endswith("UsageDescription")
        ]
        if caps:
            print("  权限说明        :")
            for k in sorted(caps):
                print(f"    - {k}")

        print()
        print("── 二进制 ──")
        bin_path = f"{root}/{exec_name}"
        if bin_path not in names:
            fail(f"缺主二进制 {exec_name}")
            problems += 1
        else:
            desc, cputype = read_macho_header(zf, bin_path)
            size = zf.getinfo(bin_path).file_size
            ok(f"{exec_name}: {desc}, {size / 1024:.0f} KiB")
            if cputype is not None and cputype != CPU_ARM64:
                problems += 1
                fail(f"主二进制不是 arm64（cputype=0x{cputype:08x}），真机装不上")

        print()
        print("── 签名状态 ──")
        signed = [n for n in names if "/_CodeSignature/" in n]
        provision = [n for n in names if n.endswith("embedded.mobileprovision")]
        if signed:
            warn(f"残留 {len(signed)} 个 _CodeSignature 条目，手机端工具通常需勾选「移除原有签名」")
        else:
            ok("无 _CodeSignature，确认是未签名包")
        if provision:
            warn("残留 embedded.mobileprovision，签名时会覆盖，一般无需手动删")

        print()
        print("── Frameworks（手机端需逐个重签）──")
        fws = sorted({n.split("/")[3] for n in names
                      if n.startswith(f"{root}/Frameworks/") and len(n.split("/")) > 4})
        if not fws:
            print("  无内嵌 Framework（纯系统框架，签名时无需处理）")
        else:
            for fw in fws:
                ok(fw)
            print(f"  共 {len(fws)} 个，签名工具里务必勾选「重签所有 Framework」")

        print()
        total = len(names)
        print(f"条目总数: {total}")
        print()
        if problems:
            print(f"结论: 发现 {problems} 个阻断问题，先修再装。")
            return 1
        print("结论: 结构正常，可以拿到手机上签名安装。")
        print()
        print("手机端签名时注意：")
        print("  1. 勾选「移除原有签名」与「重签所有 Framework」")
        print("  2. Bundle ID 与描述文件里的 App ID 保持一致")
        print(f"  3. 目标设备的 UDID 必须在描述文件的设备名单内（当前包未绑定任何 profile）")
        return 0


if __name__ == "__main__":
    sys.exit(main())
