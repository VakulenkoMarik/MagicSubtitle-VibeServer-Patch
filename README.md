# MagicSubtitle Vibe Server Patch

Patch for Magic Subtitles Lite that adds support for the `vibe-server` CLI from Vibe v0.6.x.

The patch allows Magic Subtitles Lite to use Vibe's Ukrainian speech recognition and convert word-level timestamps into an SRT subtitle file.

## What this patch does

The original Magic Subtitles Lite script expects the older Vibe CLI.

This patch:

- detects `vibe-server`
- uses `vibe-server transcribe`
- enables word timestamps
- supports language selection
- supports `--max-segment-len`
- converts Vibe's timestamped output into SRT
- imports the generated SRT into DaVinci Resolve

## Requirements

- macOS
- DaVinci Resolve
- Magic Subtitles Lite
- Vibe v0.6.x
- Python 3

The Vibe executable is expected at:

    /Applications/vibe.app/Contents/MacOS/vibe-server

## Repository structure

    .
    ├── README.md
    ├── install/
    │   └── install.py
    ├── patch/
    │   ├── ItsMaVibe-original.lua
    │   ├── ItsMaVibe-patched.lua
    │   ├── ItsMaVibe.lua
    │   └── patch.py
    └── docs/
        └── setup.md

## Installation

First make sure Magic Subtitles Lite is already installed in DaVinci Resolve.

Create a backup of the original `.drfx` file.

Then run:

    python3 install/install.py /path/to/MagicSubtitleLite.drfx

The installer will:

1. Create a backup.
2. Extract the `.drfx` archive.
3. Patch `ItsMaVibe.lua`.
4. Rebuild the `.drfx`.
5. Install the patched version.

## Example

    python3 install/install.py ~/Desktop/MagicSubtitleLite-original.drfx

After installation, restart DaVinci Resolve if it was running.

## Testing

To verify that the patched `.drfx` contains the Vibe Server integration:

    unzip -p /path/to/MagicSubtitleLite.drfx Edit/Scripts/ItsMaVibe.lua | grep -n "Vibe Server v0.6.x"

Expected output should contain:

    -- Vibe Server v0.6.x helpers
    -- Branch B: Vibe Server v0.6.x

## Safety

The installer creates a backup before modifying the `.drfx` file.

The patcher also refuses to patch a Lua file that already contains the Vibe Server patch.

## Notes

This project is a compatibility patch and is not affiliated with the developers of Magic Subtitles Lite or Vibe.

The patch was created specifically to bridge Magic Subtitles Lite with the Vibe v0.6.x `vibe-server` command-line interface.
