#!/usr/bin/env python3
"""Copy a release package into the Cydia source without replacing published versions."""
import io
import shutil
import tarfile
from pathlib import Path
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cydia_index", ROOT / "scripts/cydia-index.py")
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


def fields(text):
    return dict(line.split(": ", 1) for line in text.splitlines() if ": " in line and not line.startswith(" "))


def validate(package, expected):
    control = fields(index.deb_control(package))
    for key in ("Package", "Version", "Architecture"):
        if control.get(key) != expected[key]:
            raise ValueError(f"{package}: {key} does not match control")
    members = dict(index.ar_members(package.read_bytes()))
    if members.get("debian-binary") != b"2.0\n" or "control.tar.gz" not in members or "data.tar.gz" not in members:
        raise ValueError(f"{package}: publish gzip archives for iOS 6")
    with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz") as archive:
        for path, marker in (
            ("Library/MobileSubstrate/DynamicLibraries/NewsstandRSS.dylib", b"com.aurelio.newsstandrss/test"),
            ("Library/NewsstandRSS/Reader.app/Reader", b"com.aurelio.newsstandrss/reader-test"),
        ):
            member = next(item for item in archive.getmembers() if item.name.lstrip("./") == path)
            if marker in archive.extractfile(member).read():
                raise ValueError(f"{package}: diagnostic code in {path}")


def main():
    control = fields((ROOT / "control").read_text())
    package = ROOT / "packages" / f"{control['Package']}_{control['Version']}_{control['Architecture']}.deb"
    validate(package, control)
    destination = ROOT / "repo/debs" / package.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        validate(destination, control)
        print(f"Keeping published {destination.name}; bump Version in control to publish another build.")
    else:
        shutil.copyfile(package, destination)
        print(f"Published {destination.name}")


if __name__ == "__main__":
    main()
