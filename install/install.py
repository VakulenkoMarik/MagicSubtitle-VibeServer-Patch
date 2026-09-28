from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
import time
import sys


ROOT = Path(__file__).resolve().parent.parent
PATCH_DIR = ROOT / "patch"

DEFAULT_DRFX = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Blackmagic Design"
    / "DaVinci Resolve"
    / "Fusion"
    / "Templates"
    / "MagicSubtitleLite.drfx"
)


def RunPatch(lua_path):
    patcher = PATCH_DIR / "patch.py"

    subprocess.run(
        ["python3", str(patcher), str(lua_path)],
        check=True
    )


def Install(drfx_path):
    drfx_path = Path(drfx_path)

    if not drfx_path.exists():
        raise SystemExit(
            f"ERROR: .drfx file not found:\n{drfx_path}"
        )

    print("Magic Subtitles:")
    print(drfx_path)
    print()

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    backup = drfx_path.with_name(
        f"{drfx_path.stem}.backup-{timestamp}.drfx"
    )

    print("Creating backup...")
    shutil.copy2(drfx_path, backup)
    print(f"Backup: {backup}")
    print()

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        extract_dir = temp_path / "extracted"
        extract_dir.mkdir()

        print("Extracting .drfx...")

        with zipfile.ZipFile(drfx_path, "r") as archive:
            archive.extractall(extract_dir)

        lua_path = extract_dir / "Edit" / "Scripts" / "ItsMaVibe.lua"

        if not lua_path.exists():
            raise SystemExit(
                f"ERROR: ItsMaVibe.lua not found:\n{lua_path}"
            )

        print("Patching ItsMaVibe.lua...")

        RunPatch(lua_path)

        print("Building patched .drfx...")

        new_drfx = temp_path / drfx_path.name

        with zipfile.ZipFile(
            new_drfx,
            "w",
            zipfile.ZIP_DEFLATED
        ) as archive:

            for file in extract_dir.rglob("*"):
                if file.is_file():
                    archive.write(
                        file,
                        file.relative_to(extract_dir)
                    )

        print("Installing patched .drfx...")

        shutil.copy2(new_drfx, drfx_path)

    print()
    print("SUCCESS")
    print(f"Installed: {drfx_path}")
    print(f"Backup:    {backup}")


def main():
    if len(sys.argv) > 1:
        drfx_path = Path(sys.argv[1])
    else:
        drfx_path = DEFAULT_DRFX

    Install(drfx_path)


if __name__ == "__main__":
    main()
