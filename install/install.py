from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
import time
import sys


ROOT = Path(__file__).resolve().parent.parent
PATCH_DIR = ROOT / "patch"
CONVERTER_SOURCE = ROOT / "install" / "ConvertSubtitlesToTextPlus.lua"

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


def PatchCreateSubtitlesSetting(setting_path):
    setting = setting_path.read_text(encoding="utf-8")
    instance_marker = "Input10 = InstanceInput {"
    tool_marker = "\t\t\t\tBackground1 = Background {"
    execute_path = (
        "@templates:MagicSubtitleLite.drfx/"
        "Edit/Scripts/ConvertSubtitlesToTextPlus.lua"
    )

    if (
        "ConvertTextPlus = InstanceInput {" in setting
        or "MaxWords = InstanceInput {" in setting
        or "SplitPunctuation = InstanceInput {" in setting
        or execute_path in setting
    ):
        raise SystemExit("ERROR: CreateSubtitles.setting already has the patched controls.")
    if setting.count(instance_marker) != 1:
        raise SystemExit("ERROR: Could not uniquely find the CreateSubtitles input insertion point.")
    if setting.count(tool_marker) != 1:
        raise SystemExit("ERROR: Could not uniquely find the CreateSubtitles tool insertion point.")

    instance_input = (
        '\t\t\t\tSplitPunctuation = InstanceInput {\n'
        '\t\t\t\t\tSourceOp = "BUTTONS",\n'
        '\t\t\t\t\tSource = "SplitPunctuation",\n'
        '\t\t\t\t\tWidth = 1,\n'
        '\t\t\t\t},\n\n'
        '\t\t\t\tMaxWords = InstanceInput {\n'
        '\t\t\t\t\tSourceOp = "BUTTONS",\n'
        '\t\t\t\t\tSource = "MaxWords",\n'
        '\t\t\t\t\tWidth = 1,\n'
        '\t\t\t\t},\n\n'
        '\t\t\t\tConvertTextPlus = InstanceInput {\n'
        '\t\t\t\t\tSourceOp = "BUTTONS",\n'
        '\t\t\t\t\tSource = "ConvertTextPlus",\n'
        '\t\t\t\t\tWidth = 1,\n'
        '\t\t\t\t},\n\n'
        '\t\t\t\t'
        + instance_marker
    )
    wireless_button = (
        '\t\t\t\tBUTTONS = Fuse.Wireless {\n'
        '\t\t\t\t\tUserControls = ordered() {\n'
        '\t\t\t\t\t\tConvertTextPlus = {\n'
        '\t\t\t\t\t\t\tICD_Width = 1,\n'
        '\t\t\t\t\t\t\tINP_Integer = false,\n'
        '\t\t\t\t\t\t\tINPID_InputControl = "ButtonControl",\n'
        '\t\t\t\t\t\t\tINP_Default = 0,\n'
        '\t\t\t\t\t\t\tLINKID_DataType = "Number",\n'
        '\t\t\t\t\t\t\tBTNCS_Execute = "' + execute_path + '",\n'
        '\t\t\t\t\t\t\tLINKS_Name = "Convert to Text+",\n'
        '\t\t\t\t\t\t\tICS_ControlPage = "Controls",\n'
        '\t\t\t\t\t\t},\n'
        '\t\t\t\t\t\tMaxWords = {\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Auto" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "1" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "2" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "3" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "4" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "5" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "6" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "8" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "10" },\n'
        '\t\t\t\t\t\t\tINP_Integer = false,\n'
        '\t\t\t\t\t\t\tINPID_InputControl = "ComboControl",\n'
        '\t\t\t\t\t\t\tINP_Default = 0,\n'
        '\t\t\t\t\t\t\tLINKID_DataType = "Number",\n'
        '\t\t\t\t\t\t\tCC_LabelPosition = "Horizontal",\n'
        '\t\t\t\t\t\t\tLINKS_Name = "Max words per subtitle",\n'
        '\t\t\t\t\t\t},\n'
        '\t\t\t\t\t\tSplitPunctuation = {\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Off" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Sentence ends only" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Sentence + commas (min half)" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Sentence + commas (min 2 words)" },\n'
        '\t\t\t\t\t\t\t{ CCS_AddString = "Every punctuation mark" },\n'
        '\t\t\t\t\t\t\tINP_Integer = false,\n'
        '\t\t\t\t\t\t\tINPID_InputControl = "ComboControl",\n'
        '\t\t\t\t\t\t\tINP_Default = 0,\n'
        '\t\t\t\t\t\t\tLINKID_DataType = "Number",\n'
        '\t\t\t\t\t\t\tCC_LabelPosition = "Horizontal",\n'
        '\t\t\t\t\t\t\tLINKS_Name = "Split at punctuation",\n'
        '\t\t\t\t\t\t},\n'
        '\t\t\t\t\t},\n'
        '\t\t\t\t},\n\n'
        + tool_marker
    )

    setting = setting.replace(instance_marker, instance_input, 1)
    setting = setting.replace(tool_marker, wireless_button, 1)
    setting_path.write_text(setting, encoding="utf-8")


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

        setting_path = (
            extract_dir
            / "Edit"
            / "Titles"
            / "MagicToolkit"
            / "MagicSubtitlesLite"
            / "CreateSubtitles.setting"
        )
        if not setting_path.exists():
            raise SystemExit(
                f"ERROR: CreateSubtitles.setting not found:\n{setting_path}"
            )

        print("Adding Max words per subtitle dropdown and Convert to Text+ button...")
        PatchCreateSubtitlesSetting(setting_path)

        if not CONVERTER_SOURCE.exists():
            raise SystemExit(
                f"ERROR: Text+ converter script not found:\n{CONVERTER_SOURCE}"
            )
        converter_path = extract_dir / "Edit" / "Scripts" / CONVERTER_SOURCE.name
        print("Packaging ConvertSubtitlesToTextPlus.lua...")
        shutil.copy2(CONVERTER_SOURCE, converter_path)

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
