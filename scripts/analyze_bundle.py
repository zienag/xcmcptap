#!/usr/bin/env python3
"""
Bundle size analyzer for .app bundles.

Attributes every byte to a category, forensics each Mach-O (arch slices,
segments, symbol-by-module), inspects Assets.car, and ranks findings by
estimated bytes saved. Not a `du` wrapper — the point is to tell you *what
to do*.

Usage:
    scripts/analyze_bundle.py [BUNDLE]
    scripts/analyze_bundle.py --json > report.json
    scripts/analyze_bundle.py --baseline prev.json  # diff mode
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Iterable

DEFAULT_BUNDLE = Path.home() / "Applications" / "Xcode MCP Tap.app"
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
NATIVE_ARCH = "arm64"  # host arch for symbol analysis; fat binaries analyzed per-slice separately


# ---------- data model ----------

@dataclass
class FileEntry:
    path: str           # relative to bundle
    size: int
    kind: str           # macho | asset_catalog | icns | nib | plist | signature | resource | other

@dataclass
class Segment:
    name: str
    size: int
    sections: dict[str, int] = field(default_factory=dict)

@dataclass
class MachOReport:
    path: str
    file_size: int
    archs: list[str]
    arch_sizes: dict[str, int]
    segments: list[Segment]
    linked_dylibs: list[str]
    module_bytes: dict[str, int]     # Swift/C symbols bucketed by top-level module
    reflection_bytes: int             # strippable Swift reflection metadata

@dataclass
class AssetReport:
    path: str
    file_size: int
    total_asset_bytes: int
    by_type: dict[str, int]
    largest_assets: list[tuple[str, int]]
    has_1024_icon: bool
    has_dark_variants: bool

@dataclass
class Finding:
    impact_bytes: int
    title: str
    detail: str

@dataclass
class BundleReport:
    bundle: str
    total_bytes: int
    files: list[FileEntry]
    by_kind: dict[str, int]
    machos: list[MachOReport]
    assets: list[AssetReport]
    findings: list[Finding]
    redundant_icon: bool


# ---------- utilities ----------

def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout

def human(n: int) -> str:
    step = 1024.0
    for unit in ("B", "K", "M", "G"):
        if abs(n) < step:
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= step
    return f"{n:.1f}T"

def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            return f.read(4) in MACHO_MAGIC
    except OSError:
        return False

def classify(path: Path, bundle: Path) -> str:
    rel = path.relative_to(bundle)
    name = path.name
    parts = rel.parts
    if "_CodeSignature" in parts or name == "CodeResources":
        return "signature"
    if name.endswith(".car"):
        return "asset_catalog"
    if name.endswith(".icns"):
        return "icns"
    if name.endswith(".nib") or name.endswith(".storyboardc"):
        return "nib"
    if name.endswith(".plist") or name == "PkgInfo":
        return "plist"
    if is_macho(path):
        return "macho"
    if "Resources" in parts:
        return "resource"
    return "other"


# ---------- Mach-O analysis ----------

SEG_RE = re.compile(r"^Segment (\S+): (\d+)")
SEC_RE = re.compile(r"^\s+Section (\S+): (\d+)")
# Swift mangled module extraction: _$s<len><module>... — e.g. _$s18XcodeMCPTapService...
SWIFT_MANGLED = re.compile(r"^_\$s(\d+)([A-Za-z0-9_]+)")
REFLECTION_SECTIONS = {
    "__swift5_reflstr", "__swift5_fieldmd", "__swift5_assocty",
    "__swift5_capture", "__swift5_typeref", "__swift5_builtin", "__swift5_mpenum",
}

def parse_segments(size_output: str) -> list[Segment]:
    segments: list[Segment] = []
    for line in size_output.splitlines():
        if m := SEG_RE.match(line):
            name, sz = m.group(1), int(m.group(2))
            if name == "__PAGEZERO":
                continue
            segments.append(Segment(name=name, size=sz))
        elif m := SEC_RE.match(line):
            if segments:
                segments[-1].sections[m.group(1)] = int(m.group(2))
    return segments

def swift_module(mangled: str) -> str | None:
    if m := SWIFT_MANGLED.match(mangled):
        length, rest = int(m.group(1)), m.group(2)
        if len(rest) >= length:
            return rest[:length]
    return None

def bucket_symbols(binary: Path, arch: str, text_segment_size: int) -> dict[str, int]:
    """Compute symbol sizes by diffing sorted addresses, bucketed by module.

    nm on Mach-O never reports sizes directly — we derive them by sorting
    addresses and subtracting. Uses `nm -m` for real section info so diffs
    don't cross segment boundaries. Only __TEXT.__text symbols are attributed
    (that's where code lives). Bucket by module: Swift mangled symbols expose
    their module name; C/ObjC symbols go to 'C/ObjC'; unknown goes to
    '<unknown>'.
    """
    # `nm -m` format: "<addr> (<segment>,<section>) <type> <symbol>"
    out = run(["nm", "-m", "-arch", arch, "-n", "--defined-only", str(binary)])
    text_entries: list[tuple[int, str]] = []
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]+)\s+\(([^)]+)\)\s+\S+\s+(.+)$", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        section = m.group(2).strip()
        sym = m.group(3).strip()
        if section != "__TEXT,__text":
            continue
        text_entries.append((addr, sym))

    text_entries.sort()
    by_module: dict[str, int] = defaultdict(int)
    # Cap any individual diff at the __TEXT segment size — a bigger diff means
    # we hit a hole or the last symbol, not a real function size.
    for (addr, sym), (next_addr, _) in zip(text_entries, text_entries[1:]):
        size = next_addr - addr
        if size <= 0 or size > text_segment_size:
            continue
        mod = swift_module(sym)
        if mod is None:
            mod = "C/ObjC" if sym.startswith(("_", ".")) else "<unknown>"
        by_module[mod] += size
    return dict(by_module)

def analyze_macho(binary: Path, bundle: Path) -> MachOReport:
    lipo_out = run(["lipo", "-info", str(binary)])
    # "Non-fat file: X is architecture: arm64" or "Architectures in the fat file: X are: arm64 x86_64"
    if "Non-fat" in lipo_out:
        archs = [lipo_out.strip().split()[-1]]
    else:
        archs = lipo_out.strip().split(":")[-1].split()
    arch_sizes: dict[str, int] = {}
    if len(archs) > 1:
        detailed = run(["lipo", "-detailed_info", str(binary)])
        current = None
        for line in detailed.splitlines():
            line = line.strip()
            if line.startswith("architecture "):
                current = line.split()[-1]
            elif current and line.startswith("size "):
                arch_sizes[current] = int(line.split()[-1])
    else:
        arch_sizes[archs[0]] = binary.stat().st_size

    size_out = run(["size", "-m", str(binary)])
    segments = parse_segments(size_out)

    # For fat binaries, symbol analysis runs against NATIVE_ARCH slice only.
    arch_for_symbols = NATIVE_ARCH if NATIVE_ARCH in archs else archs[0]
    text_seg_size = next((s.size for s in segments if s.name == "__TEXT"), binary.stat().st_size)
    modules = bucket_symbols(binary, arch_for_symbols, text_seg_size)

    reflection_bytes = 0
    for seg in segments:
        for sec, sz in seg.sections.items():
            if sec in REFLECTION_SECTIONS:
                reflection_bytes += sz

    dylibs_raw = run(["otool", "-L", str(binary)]).splitlines()[1:]
    dylibs = [line.strip().split()[0] for line in dylibs_raw if line.strip()]

    return MachOReport(
        path=str(binary.relative_to(bundle)),
        file_size=binary.stat().st_size,
        archs=archs,
        arch_sizes=arch_sizes,
        segments=segments,
        linked_dylibs=dylibs,
        module_bytes=modules,
        reflection_bytes=reflection_bytes,
    )


# ---------- asset catalog ----------

def analyze_car(car: Path, bundle: Path) -> AssetReport:
    out = run(["assetutil", "--info", str(car)])
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        data = []
    by_type: dict[str, int] = defaultdict(int)
    named: list[tuple[str, int]] = []
    has_1024 = False
    has_dark = False
    for entry in data:
        if "AssetType" not in entry:
            continue
        sz = entry.get("SizeOnDisk") or 0
        by_type[entry["AssetType"]] += sz
        name = entry.get("Name", "?")
        named.append((name, sz))
        px = entry.get("PixelWidth") or 0
        if px >= 1024 or entry.get("Size") == "1024x1024":
            has_1024 = True
        if entry.get("Appearance") == "NSAppearanceNameDarkAqua":
            has_dark = True
    named.sort(key=lambda x: x[1], reverse=True)
    return AssetReport(
        path=str(car.relative_to(bundle)),
        file_size=car.stat().st_size,
        total_asset_bytes=sum(by_type.values()),
        by_type=dict(by_type),
        largest_assets=named[:10],
        has_1024_icon=has_1024,
        has_dark_variants=has_dark,
    )


# ---------- synthesis ----------

def synthesize(report: BundleReport) -> list[Finding]:
    findings: list[Finding] = []

    # 1. Fat binaries — drop non-native slices.
    for m in report.machos:
        if len(m.archs) > 1:
            non_native = sum(sz for a, sz in m.arch_sizes.items() if a != NATIVE_ARCH)
            findings.append(Finding(
                impact_bytes=non_native,
                title=f"Strip non-{NATIVE_ARCH} slices from {m.path}",
                detail=f"Binary is fat ({', '.join(m.archs)}). "
                       f"Run `lipo -thin {NATIVE_ARCH}` or set ONLY_ACTIVE_ARCH/VALID_ARCHS.",
            ))

    # 2. Redundant icon (icns + asset catalog icon).
    if report.redundant_icon:
        icns_bytes = sum(f.size for f in report.files if f.kind == "icns")
        findings.append(Finding(
            impact_bytes=icns_bytes,
            title="Redundant AppIcon.icns alongside Assets.car",
            detail="Bundle ships both a standalone .icns and an asset catalog icon. "
                   "Modern apps reference CFBundleIconName and only need the catalog. "
                   "Remove the .icns from project.yml or the Copy Files phase.",
        ))

    # 3. Swift reflection metadata (strippable).
    for m in report.machos:
        if m.reflection_bytes > 20_000:
            findings.append(Finding(
                impact_bytes=m.reflection_bytes,
                title=f"Swift reflection metadata in {m.path}",
                detail=f"{human(m.reflection_bytes)} across __swift5_* sections. "
                       f"Pass `-Xfrontend -disable-reflection-metadata` (or use "
                       f"SWIFT_REFLECTION_METADATA_LEVEL=none) if you don't use Mirror/dump.",
            ))

    # 4. Oversized __LINKEDIT (symbol/string table bloat).
    for m in report.machos:
        linkedit = next((s for s in m.segments if s.name == "__LINKEDIT"), None)
        text = next((s for s in m.segments if s.name == "__TEXT"), None)
        if linkedit and text and linkedit.size > text.size:
            findings.append(Finding(
                impact_bytes=linkedit.size - text.size,
                title=f"Oversized __LINKEDIT in {m.path}",
                detail=f"__LINKEDIT ({human(linkedit.size)}) > __TEXT ({human(text.size)}). "
                       f"Likely unstripped symbols. Ensure DEPLOYMENT_POSTPROCESSING=YES, "
                       f"COPY_PHASE_STRIP=YES, STRIP_INSTALLED_PRODUCT=YES in Release.",
            ))

    # 5. Big 1024 icon renditions.
    for a in report.assets:
        if a.has_1024_icon and a.file_size > 500_000:
            findings.append(Finding(
                impact_bytes=a.file_size // 4,  # rough guess: 1024 dominant
                title=f"Asset catalog {a.path} dominated by large renditions",
                detail=f"{human(a.file_size)}, contains 1024×1024 icon variants. "
                       f"Top 3: " + ", ".join(f"{n}={human(s)}" for n, s in a.largest_assets[:3]),
            ))

    # 6. Non-system dynamic links (should be rare for embedded tools).
    for m in report.machos:
        suspicious = [d for d in m.linked_dylibs
                      if not d.startswith(("/usr/lib/", "/System/", "@rpath/libswift"))
                      and not d.endswith(m.path.split("/")[-1])]
        if suspicious:
            findings.append(Finding(
                impact_bytes=0,
                title=f"Non-system dylibs linked into {m.path}",
                detail="Review: " + ", ".join(suspicious),
            ))

    findings.sort(key=lambda f: f.impact_bytes, reverse=True)
    return findings


# ---------- driver ----------

def walk_bundle(bundle: Path) -> list[FileEntry]:
    out = []
    for p in bundle.rglob("*"):
        if p.is_file() and not p.is_symlink():
            out.append(FileEntry(
                path=str(p.relative_to(bundle)),
                size=p.stat().st_size,
                kind=classify(p, bundle),
            ))
    return out

def build_report(bundle: Path) -> BundleReport:
    files = walk_bundle(bundle)
    by_kind: dict[str, int] = defaultdict(int)
    for f in files:
        by_kind[f.kind] += f.size
    machos = [analyze_macho(bundle / f.path, bundle) for f in files if f.kind == "macho"]
    assets = [analyze_car(bundle / f.path, bundle) for f in files if f.kind == "asset_catalog"]
    redundant_icon = any(f.kind == "icns" for f in files) and any(f.kind == "asset_catalog" for f in files)
    report = BundleReport(
        bundle=str(bundle),
        total_bytes=sum(f.size for f in files),
        files=files,
        by_kind=dict(by_kind),
        machos=machos,
        assets=assets,
        findings=[],
        redundant_icon=redundant_icon,
    )
    report.findings = synthesize(report)
    return report


# ---------- reporting ----------

def print_report(r: BundleReport, baseline: BundleReport | None) -> None:
    print(f"\n=== {r.bundle} ===")
    print(f"Total: {human(r.total_bytes)}")
    if baseline:
        delta = r.total_bytes - baseline.total_bytes
        sign = "+" if delta >= 0 else ""
        print(f"vs baseline: {sign}{human(delta)}")

    print("\n-- Byte attribution --")
    for kind, sz in sorted(r.by_kind.items(), key=lambda x: -x[1]):
        pct = 100 * sz / r.total_bytes if r.total_bytes else 0
        print(f"  {kind:16s} {human(sz):>8s}  {pct:5.1f}%")

    print("\n-- Largest files --")
    for f in sorted(r.files, key=lambda x: -x.size)[:10]:
        print(f"  {human(f.size):>8s}  {f.path}")

    for m in r.machos:
        print(f"\n-- Mach-O: {m.path} ({human(m.file_size)}, {'/'.join(m.archs)}) --")
        for seg in m.segments:
            print(f"  {seg.name:16s} {human(seg.size):>8s}")
        if m.reflection_bytes:
            print(f"  (reflection:   {human(m.reflection_bytes):>6s} — strippable)")
        print("  Top modules by code size:")
        top_mods = sorted(m.module_bytes.items(), key=lambda x: -x[1])[:8]
        for mod, sz in top_mods:
            print(f"    {mod:40s} {human(sz):>8s}")
        if baseline:
            prior = next((pm for pm in baseline.machos if pm.path == m.path), None)
            if prior:
                delta = m.file_size - prior.file_size
                if abs(delta) > 1024:
                    sign = "+" if delta >= 0 else ""
                    print(f"  Δ vs baseline: {sign}{human(delta)}")
                    for mod, sz in top_mods:
                        pd = sz - prior.module_bytes.get(mod, 0)
                        if abs(pd) > 4096:
                            ps = "+" if pd >= 0 else ""
                            print(f"    {mod:40s} {ps}{human(pd)}")

    for a in r.assets:
        print(f"\n-- Asset catalog: {a.path} ({human(a.file_size)}) --")
        for t, sz in sorted(a.by_type.items(), key=lambda x: -x[1]):
            print(f"  {t:16s} {human(sz):>8s}")
        print("  Largest entries:")
        for name, sz in a.largest_assets[:5]:
            print(f"    {human(sz):>8s}  {name}")

    print("\n-- Findings (ranked by estimated savings) --")
    if not r.findings:
        print("  (nothing flagged)")
    for f in r.findings:
        tag = f"[-{human(f.impact_bytes)}]" if f.impact_bytes else "[info]"
        print(f"  {tag:>10s}  {f.title}")
        for line in f.detail.split(". "):
            line = line.strip().rstrip(".")
            if line:
                print(f"              {line}.")


def load_baseline(path: Path) -> BundleReport:
    data = json.loads(path.read_text())
    # Best-effort rehydrate for diff purposes; only fields we actually read.
    machos = [MachOReport(**{**m, "segments": [Segment(**s) for s in m["segments"]]})
              for m in data["machos"]]
    assets = [AssetReport(**a) for a in data["assets"]]
    files = [FileEntry(**f) for f in data["files"]]
    findings = [Finding(**f) for f in data["findings"]]
    return BundleReport(
        bundle=data["bundle"], total_bytes=data["total_bytes"], files=files,
        by_kind=data["by_kind"], machos=machos, assets=assets,
        findings=findings, redundant_icon=data["redundant_icon"],
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle", nargs="?", default=str(DEFAULT_BUNDLE), help="path to .app bundle")
    ap.add_argument("--json", action="store_true", help="emit JSON to stdout")
    ap.add_argument("--baseline", type=Path, help="JSON baseline from a prior run; prints diff")
    args = ap.parse_args()

    for tool in ("lipo", "size", "nm", "otool", "assetutil"):
        if not shutil.which(tool):
            print(f"error: required tool `{tool}` not on PATH", file=sys.stderr)
            return 2

    bundle = Path(args.bundle)
    if not bundle.is_dir():
        print(f"error: {bundle} is not a directory", file=sys.stderr)
        return 2

    report = build_report(bundle)

    if args.json:
        json.dump(asdict(report), sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0

    baseline = load_baseline(args.baseline) if args.baseline else None
    print_report(report, baseline)
    return 0


if __name__ == "__main__":
    sys.exit(main())
