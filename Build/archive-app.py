#!/usr/bin/env python3
"""Archive the already-built development app and CLI, preserving signatures."""
import hashlib
import pathlib
import shutil
import subprocess
import tempfile
from version import version

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
NAME = "Spice4Mac-" + version() + "-arm64"

def main():
    app, cli = DIST / "Spice4Mac.app", DIST / "spice4mac"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(cli)], check=True)
    archive = DIST / (NAME + ".zip")
    with tempfile.TemporaryDirectory(prefix="spice4mac-archive-") as temporary:
        stage = pathlib.Path(temporary) / NAME
        stage.mkdir()
        subprocess.run(["ditto", str(app), str(stage / app.name)], check=True)
        shutil.copy2(cli, stage / cli.name)
        for path in [ROOT / "README.md", ROOT / "LICENSE"]:
            shutil.copy2(path, stage / path.name)
        (stage / "docs").mkdir()
        for name in ["CLI.md", "BUILDING.md", "THIRD_PARTY.md"]:
            shutil.copy2(ROOT / "docs" / name, stage / "docs" / name)
        if archive.exists():
            archive.unlink()
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(archive)], check=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = DIST / (NAME + ".sha256")
    checksum.write_text(f"{digest}  {archive.name}\n")
    print(f"Created {archive} ({archive.stat().st_size:,} bytes)")
    print(checksum.read_text(), end="")

if __name__ == "__main__":
    main()
