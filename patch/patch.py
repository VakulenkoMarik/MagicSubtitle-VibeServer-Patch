from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent


HELPERS = r'''
-- -----------------------------------------------------------
-- Vibe Server v0.6.x helpers
-- -----------------------------------------------------------

local function getVibeServerExecutable()
    local candidates = {}

    if isWindows() then
        candidates = {
            os.getenv("LOCALAPPDATA") .. "\\Programs\\vibe\\vibe-server.exe",
            os.getenv("PROGRAMFILES") .. "\\vibe\\vibe-server.exe",
            "vibe-server.exe"
        }
    else
        candidates = {
            "/Applications/vibe.app/Contents/MacOS/vibe-server",
            os.getenv("HOME") .. "/Applications/vibe.app/Contents/MacOS/vibe-server",
            "/usr/local/bin/vibe-server",
            "/opt/homebrew/bin/vibe-server",
            os.getenv("HOME") .. "/.local/bin/vibe-server"
        }
    end

    for _, path in ipairs(candidates) do
        if path and fileExists(path) then
            return path
        end
    end

    return nil
end

local function parseVibeTimestamp(timestamp)
    local h, m, s, ms = timestamp:match("(%d+):(%d+):(%d+)%.(%d+)")

    if not h then
        return nil
    end

    return tonumber(h) * 3600
        + tonumber(m) * 60
        + tonumber(s)
        + tonumber(ms) / 1000
end

local function buildSrtFromVibeOutput(rawText, srtFile, maxWords)
    local words = {}

    for startTime, endTime, word in rawText:gmatch(
        "%[(%d+:%d+:%d+%.%d+)%s+%-%->%s+(%d+:%d+:%d+%.%d+)%]%s*([^\n]*)"
    ) do
        if word ~= "" then
            table.insert(words, {
                start = parseVibeTimestamp(startTime),
                finish = parseVibeTimestamp(endTime),
                text = word
            })
        end
    end

    if #words == 0 then
        return false, "No timestamped words found in Vibe output"
    end

    local function formatSrtTime(seconds)
        local totalMs = math.floor(seconds * 1000 + 0.5)
        local hours = math.floor(totalMs / 3600000)
        totalMs = totalMs % 3600000

        local minutes = math.floor(totalMs / 60000)
        totalMs = totalMs % 60000

        local secs = math.floor(totalMs / 1000)
        local millis = totalMs % 1000

        return string.format(
            "%02d:%02d:%02d,%03d",
            hours,
            minutes,
            secs,
            millis
        )
    end

    local entries = {}
    local current = {}
    local currentChars = 0

    local function flush()
        if #current == 0 then
            return
        end

        local startTime = current[1].start
        local endTime = current[#current].finish

        local parts = {}

        for _, item in ipairs(current) do
            table.insert(parts, item.text)
        end

        table.insert(entries,
            formatSrtTime(startTime)
            .. " --> "
            .. formatSrtTime(endTime)
            .. "\n"
            .. table.concat(parts, " ")
        )

        current = {}
        currentChars = 0
    end

    for i, item in ipairs(words) do
        local previous = words[i - 1]

        local pause = 0

        if previous then
            pause = item.start - previous.finish
        end

        local additionalChars = #item.text

        if #current > 0 then
            additionalChars = additionalChars + 1
        end

        local tooManyWords = #current >= (maxWords or 35)
        local tooLong = currentChars + additionalChars > 80
        local longPause = pause >= 0.55

        if tooManyWords or tooLong or longPause then
            flush()
        end

        table.insert(current, item)
        currentChars = currentChars + additionalChars
    end

    flush()

    local output = {}

    for i, entry in ipairs(entries) do
        table.insert(output, tostring(i))
        table.insert(output, entry)
        table.insert(output, "")
    end

    local ok = writeFile(srtFile, table.concat(output, "\n"))

    if not ok then
        return false, "Could not write SRT file"
    end

    return true, nil
end

local function transcribeWithVibeServer(
    vibeServerExe,
    audioFile,
    srtFile,
    modelPath,
    language,
    maxSentenceLen,
    prompt
)
    local rawFile = tempPath("MagicSubtitlesVibeRaw")

    local cmd =
        shellArg(vibeServerExe)
        .. " transcribe "
        .. shellArg(modelPath)
        .. " "
        .. shellArg(audioFile)
        .. " --word-timestamps"

    if language and language ~= "" and language ~= "auto" then
        cmd = cmd .. " --language " .. shellArg(language)
    end

    if maxSentenceLen then
        cmd = cmd
            .. " --max-segment-len "
            .. shellArg(tostring(maxSentenceLen))
    end

    if prompt and prompt ~= "" then
        cmd = cmd .. " --prompt " .. shellArg(prompt)
    end

    cmd = cmd .. " > " .. shellArg(rawFile) .. " 2>&1"

    local ok, exitCode = runCmd(cmd)

    if not ok then
        local output = readFile(rawFile) or ""
        os.remove(rawFile)
        return false, exitCode, output
    end

    local rawOutput = readFile(rawFile) or ""
    os.remove(rawFile)

    local srtOk, srtErr =
        buildSrtFromVibeOutput(
            rawOutput,
            srtFile,
            tonumber(maxSentenceLen) or 35
        )

    if not srtOk then
        return false, exitCode, srtErr
    end

    return true, exitCode, nil
end

'''


BRANCH = r'''-- -----------------------------------------------------------
-- Branch B: Vibe Server v0.6.x
-- -----------------------------------------------------------
elseif vibeMode == "legacy" then

    local vibeServerExe = getVibeServerExecutable()

    if not vibeServerExe then
        print("\n✗ Could not find vibe-server")
        return
    end

    print("✓ Vibe Server: " .. vibeServerExe)

    local t0 = os.time()

    local ok, exitCode, err =
        transcribeWithVibeServer(
            vibeServerExe,
            audioFile,
            srtFile,
            modelPath,
            selectedLanguage,
            maxSentenceLen,
            initPrompt
        )

    print(
        "   Elapsed: "
            .. (os.time() - t0)
            .. "s, exit "
            .. tostring(exitCode)
    )

    if not ok then
        print("\n✗ Vibe Server failed:")
        print(tostring(err))
        return
    end

    print("✓ Vibe Server transcription converted to SRT")
end

'''


def patch_file(original_path, output_path):
    original = Path(original_path).read_text(encoding="utf-8")

    if "Vibe Server v0.6.x helpers" in original:
        raise SystemExit("ERROR: Input Lua already contains the patch.")

    detect_marker = "local function detectVibeMode()"

    if detect_marker not in original:
        raise SystemExit("ERROR: Could not find detectVibeMode().")

    patched = original.replace(
        detect_marker,
        HELPERS + "\n" + detect_marker,
        1
    )

    branch_marker = "-- Branch B: old Vibe (legacy CLI)"

    if branch_marker not in patched:
        raise SystemExit("ERROR: Could not find legacy Vibe Branch B.")

    branch_start = patched.index(branch_marker)

    after_branch = "if not fileExists(srtFile) then"
    branch_end = patched.find(after_branch, branch_start)

    if branch_end == -1:
        raise SystemExit("ERROR: Could not find end of legacy Vibe Branch B.")

    patched = (
        patched[:branch_start]
        + BRANCH
        + patched[branch_end:]
    )

    Path(output_path).write_text(patched, encoding="utf-8")

    print("OK: Generated")
    print(output_path)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(
            "Usage: python3 patch.py /path/to/ItsMaVibe.lua"
        )

    input_path = Path(sys.argv[1])
    patch_file(input_path, input_path)


if __name__ == "__main__":
    main()
