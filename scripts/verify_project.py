#!/usr/bin/env python3
"""在 Windows 上静态检查 .xcodeproj 的完整性。

用途：本地没有 Xcode 时，提前发现「文件没提交全 / 引用断裂 / 资源没进 build phase /
Info.plist 被误当资源打包」这类会让 CI 第一次就失败的问题。

用法:
    python scripts/verify_project.py linCY.xcodeproj
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ID_RE = re.compile(r"[0-9A-Fa-f]{24}")
OBJ_RE = re.compile(r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{(.*)\};\s*$")
PATH_RE = re.compile(r'\bpath\s*=\s*"?([^";]+)"?\s*;')
NAME_RE = re.compile(r'\bname\s*=\s*"?([^";]+)"?\s*;')
ISA_RE = re.compile(r"\bisa\s*=\s*([A-Za-z]+)\s*;")


def setup_console() -> None:
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


def main() -> int:
    setup_console()

    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    proj = Path(sys.argv[1])
    if proj.is_dir():
        if proj.suffix != ".xcodeproj":
            print(f"[FAIL] 不是 .xcodeproj: {proj}")
            return 2
        pbx = proj / "project.pbxproj"
    else:
        pbx = proj
        proj = pbx.parent

    if not pbx.is_file():
        print(f"[FAIL] 找不到 {pbx}")
        return 2

    root = proj.parent  # SRCROOT
    text = pbx.read_text(encoding="utf-8", errors="replace")

    objects: dict[str, str] = {}
    for line in text.splitlines():
        m = OBJ_RE.match(line)
        if m:
            objects[m.group(1)] = m.group(2)

    if not objects:
        print("[FAIL] 解析不到任何对象，确认 project.pbxproj 没被改坏")
        return 1

    problems: list[str] = []
    warnings: list[str] = []

    def isa(body: str) -> str:
        m = ISA_RE.search(body)
        return m.group(1) if m else "?"

    # 1. 所有 24 位 ID 引用都应能在 objects 中找到
    defined = set(objects)
    referenced: set[str] = set()
    for oid, body in objects.items():
        for ref in ID_RE.findall(body):
            if ref != oid:
                referenced.add(ref)
    dangling = referenced - defined
    if dangling:
        for d in sorted(dangling):
            problems.append(f"引用了不存在的对象 {d}")
    else:
        print(f"[ OK ] 对象引用完整（{len(defined)} 个对象，无悬空引用）")

    # 2. 每个 fileRef 指向的磁盘文件是否存在
    file_refs: dict[str, tuple[str, str]] = {}
    for oid, body in objects.items():
        if isa(body) == "PBXFileReference":
            m = PATH_RE.search(body)
            if m:
                file_refs[oid] = (m.group(1), body)

    # 用 mainGroup 递归还原路径
    main_group = re.search(r"mainGroup\s*=\s*([0-9A-Fa-f]{24})", text)
    group_paths: dict[str, str] = {}
    if main_group:
        def walk(gid: str, prefix: str) -> None:
            body = objects.get(gid, "")
            if isa(body) != "PBXGroup":
                return
            m = PATH_RE.search(body)
            if m:
                cur = f"{prefix}/{m.group(1)}" if prefix else m.group(1)
            else:
                cur = prefix
            group_paths[gid] = cur
            cm = re.search(r"children\s*=\s*\(([^)]*)\)", body)
            if cm:
                for child in ID_RE.findall(cm.group(1)):
                    walk(child, cur)

        walk(main_group.group(1), "")

    locator: dict[str, str] = {}
    for gid, base in group_paths.items():
        body = objects.get(gid, "")
        cm = re.search(r"children\s*=\s*\(([^)]*)\)", body)
        if not cm:
            continue
        for child in ID_RE.findall(cm.group(1)):
            if child in file_refs:
                locator[child] = base

    missing = []
    for oid, (rel, body) in file_refs.items():
        if "BUILT_PRODUCTS_DIR" in body:
            continue
        base = locator.get(oid, "")
        candidate = (root / base / rel).resolve()
        if not candidate.exists():
            missing.append(f"{base}/{rel}".lstrip("/"))
    if missing:
        for m in missing:
            problems.append(f"文件不存在: {m}")
    else:
        print(f"[ OK ] 磁盘文件齐全（{len(file_refs)} 个 file reference）")

    # 3. build phase 完整性
    sources = [b for b in objects.values() if isa(b) == "PBXSourcesBuildPhase"]
    resources = [b for b in objects.values() if isa(b) == "PBXResourcesBuildPhase"]

    def phase_files(bodies: list[str]) -> list[str]:
        out = []
        for b in bodies:
            m = re.search(r"files\s*=\s*\(([^)]*)\)", b)
            if m:
                out.extend(ID_RE.findall(m.group(1)))
        return out

    src_ids = phase_files(sources)
    res_ids = phase_files(resources)

    # 每个 .swift 文件都应在 Sources phase 里
    swift_refs = {oid for oid, (rel, _) in file_refs.items() if rel.endswith(".swift")}
    src_refs = set()
    for bid in src_ids:
        m = re.search(r"fileRef\s*=\s*([0-9A-Fa-f]{24})", objects.get(bid, ""))
        if m:
            src_refs.add(m.group(1))
    unbuilt = swift_refs - src_refs
    if unbuilt:
        for u in sorted(unbuilt):
            problems.append(f"Swift 文件未加入 Sources build phase: {file_refs[u][0]}")
    else:
        print(f"[ OK ] 所有 .swift 都参与编译（{len(swift_refs)} 个）")

    # Info.plist 不应出现在 Resources phase（否则会被重复打包）
    res_refs = set()
    for bid in res_ids:
        m = re.search(r"fileRef\s*=\s*([0-9A-Fa-f]{24})", objects.get(bid, ""))
        if m:
            res_refs.add(m.group(1))
    if any(file_refs.get(r, ("", ""))[0].endswith("Info.plist") for r in res_refs):
        problems.append("Info.plist 被加入了 Resources build phase，会造成重复打包")
    else:
        print("[ OK ] Info.plist 未被误加入 Resources")

    # asset catalog 应在 Resources phase
    asset_refs = {oid for oid, (rel, _) in file_refs.items() if rel.endswith(".xcassets")}
    if asset_refs and not (asset_refs & res_refs):
        problems.append("Assets.xcassets 未加入 Resources build phase，图标不会被打包")
    elif asset_refs:
        print("[ OK ] Assets.xcassets 已加入 Resources")

    # 4. 关键 build settings
    print()
    print("── 关键 build settings ──")
    for key in (
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PRODUCT_NAME",
        "INFOPLIST_FILE",
        "IPHONEOS_DEPLOYMENT_TARGET",
        "SWIFT_VERSION",
        "TARGETED_DEVICE_FAMILY",
        "ASSETCATALOG_COMPILER_APPICON_NAME",
        "SDKROOT",
    ):
        vals = sorted(set(re.findall(rf"\b{key}\s*=\s*\"?([^\";]+)\"?\s*;", text)))
        if vals:
            print(f"  {key:38s} = {', '.join(vals)}")
        else:
            print(f"  {key:38s} = (未设置)")
            if key in ("PRODUCT_BUNDLE_IDENTIFIER", "INFOPLIST_FILE"):
                problems.append(f"{key} 未设置，构建会失败")

    # 5. Info.plist 本身可解析
    print()
    print("── Info.plist ──")
    inf = None
    for oid, (rel, body) in file_refs.items():
        if rel.endswith("Info.plist"):
            inf = (root / locator.get(oid, "") / rel).resolve()
            break
    if inf and inf.is_file():
        try:
            with inf.open("rb") as f:
                data = plistlib.load(f)
            print(f"  [ OK ] 可解析，{len(data)} 个键")
            for k in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                      "CFBundleVersion", "UILaunchScreen", "LSRequiresIPhoneOS"):
                print(f"    {k:34s} = {data.get(k, '(缺失)')}")
        except Exception as exc:  # noqa: BLE001
            problems.append(f"Info.plist 解析失败: {exc}")
    else:
        problems.append("找不到可通过 file reference 定位的 Info.plist")

    # 6. 文档残留检查
    print()
    print("── 其他 ──")
    xcuserdata = list(root.rglob("xcuserdata"))
    if xcuserdata:
        warnings.append("存在 xcuserdata，建议加进 .gitignore（已提供）")
    else:
        print("  [ OK ] 无 xcuserdata")
    ds = list(proj.rglob("*.xcscheme"))
    print(f"  [ OK ] scheme 文件 {len(ds)} 个: {', '.join(p.name for p in ds)}")

    print()
    for w in warnings:
        print(f"[WARN] {w}")
    if problems:
        print()
        for p in problems:
            print(f"[FAIL] {p}")
        print(f"\n结论: {len(problems)} 个阻断问题。")
        return 1

    print("结论: 工程结构完整，CI 上编译的前置条件都满足。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
