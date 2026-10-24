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

    audio_file_marker = 'local audioFile  = outputBase .. ".mov"'
    if audio_file_marker not in patched:
        raise SystemExit("ERROR: Could not find audio output file path.")
    patched = patched.replace(
        audio_file_marker,
        'local audioFile  = outputBase .. ".wav"',
        1
    )

    render_block = (
        'print("\\nExporting audio (H.264 Master)...")\n'
        'local renderResult\n'
        'local exportOk = pcall(function()\n'
        '    renderResult = project:RenderWithQuickExport("H.264 Master", {\n'
        '        ["TargetDir"] = outputDir, ["CustomName"] = baseName, ["SelectAllFrames"] = true,\n'
        '    })\n'
        'end)\n\n'
        '-- Restore tracks immediately'
    )
    if render_block not in patched:
        raise SystemExit("ERROR: Could not find the Quick Export render block.")

    patched = patched.replace(
        render_block,
        'print("\\nExporting audio (WAV)...")\n'
        'local renderStartedAt = os.clock()\n'
        'local renderWallStartedAt = os.time()\n'
        'print("Starting audio export...")\n'
        'local function printRenderValue(label, ok, value)\n'
        '    if not ok then\n'
        '        print(label .. " error: " .. tostring(value))\n'
        '        return false\n'
        '    end\n'
        '    if type(value) == "table" then value = "table" end\n'
        '    print(label .. ": " .. tostring(value))\n'
        '    return value\n'
        'end\n'
        'local timelineOk, timelineResult = pcall(function()\n'
        '    return project:SetCurrentTimeline(timeline)\n'
        'end)\n'
        'printRenderValue("SetCurrentTimeline", timelineOk, timelineResult)\n'
        'local renderJobId\n'
        'local exportOk = timelineOk and timelineResult ~= false\n'
        'local renderResult = false\n'
        'local formatOk, formatResult = pcall(function()\n'
        '    return project:SetCurrentRenderFormatAndCodec("wav", "Linear PCM")\n'
        'end)\n'
        'printRenderValue("SetCurrentRenderFormatAndCodec(wav, Linear PCM)", formatOk, formatResult)\n'
        'local settingsOk, settingsResult = pcall(function()\n'
        '    return project:SetRenderSettings({\n'
        '        ["ExportVideo"] = false,\n'
        '        ["ExportAudio"] = true,\n'
        '        ["TargetDir"] = outputDir,\n'
        '        ["CustomName"] = baseName,\n'
        '        ["SelectAllFrames"] = true,\n'
        '    })\n'
        'end)\n'
        'printRenderValue("SetRenderSettings", settingsOk, settingsResult)\n'
        'local manualSettingsOk = formatOk and formatResult ~= false and settingsOk and settingsResult ~= false\n'
        'if not manualSettingsOk then\n'
        '    print("Manual audio settings failed; trying Audio Only render preset.")\n'
        '    local presetOk, presetResult = pcall(function()\n'
        '        return project:LoadRenderPreset("Audio Only")\n'
        '    end)\n'
        '    printRenderValue("LoadRenderPreset(Audio Only)", presetOk, presetResult)\n'
        '    if presetOk and presetResult ~= false then\n'
        '        local outputSettingsOk, outputSettingsResult = pcall(function()\n'
        '            return project:SetRenderSettings({\n'
        '                ["TargetDir"] = outputDir,\n'
        '                ["CustomName"] = baseName,\n'
        '                ["SelectAllFrames"] = true,\n'
        '            })\n'
        '        end)\n'
        '        printRenderValue("SetRenderSettings(output path)", outputSettingsOk, outputSettingsResult)\n'
        '        manualSettingsOk = outputSettingsOk and outputSettingsResult ~= false\n'
        '    else\n'
        '        manualSettingsOk = false\n'
        '    end\n'
        'end\n'
        'exportOk = exportOk and manualSettingsOk\n'
        'if exportOk then\n'
        '    local addOk, addResult = pcall(function() return project:AddRenderJob() end)\n'
        '    renderJobId = addOk and addResult or nil\n'
        '    printRenderValue("AddRenderJob", addOk, addOk and (addResult or "EMPTY") or addResult)\n'
        '    if not addOk or not renderJobId then\n'
        '        if addOk then print("AddRenderJob returned EMPTY") end\n'
        '        exportOk = false\n'
        '    end\n'
        'end\n'
        'if exportOk then\n'
        '    local startOk, startResult = pcall(function()\n'
        '        return project:StartRendering(renderJobId)\n'
        '    end)\n'
        '    printRenderValue("StartRendering", startOk, startResult)\n'
        '    exportOk = startOk and startResult ~= false\n'
        'end\n'
        'if renderJobId and exportOk then\n'
        '    local renderWaitStartedAt = os.time()\n'
        '    local renderTimedOut = false\n'
        '    while exportOk do\n'
        '        local renderingOk, rendering = pcall(function()\n'
        '            return project:IsRenderingInProgress()\n'
        '        end)\n'
        '        if not renderingOk then\n'
        '            print("IsRenderingInProgress error: " .. tostring(rendering))\n'
        '            exportOk = false\n'
        '        elseif not rendering then\n'
        '            break\n'
        '        elseif os.time() - renderWaitStartedAt >= 900 then\n'
        '            print("ERROR: Audio render timed out after 900 seconds.")\n'
        '            renderTimedOut = true\n'
        '            exportOk = false\n'
        '        else\n'
        '            sleep(0.5)\n'
        '        end\n'
        '    end\n'
        '    local renderWaitSeconds = os.time() - renderWaitStartedAt\n'
        '    print(string.format("Audio render wait: %d seconds", renderWaitSeconds))\n'
        '    local statusOk, statusResult = pcall(function()\n'
        '        return project:GetRenderJobStatus(renderJobId)\n'
        '    end)\n'
        '    local jobStatus = statusOk and type(statusResult) == "table"\n'
        '        and statusResult.JobStatus or nil\n'
        '    if statusOk then\n'
        '        print("Render job status: " .. tostring(jobStatus or "unavailable"))\n'
        '    else\n'
        '        print("GetRenderJobStatus error: " .. tostring(statusResult))\n'
        '    end\n'
        '    if not statusOk then\n'
        '        exportOk = false\n'
        '    elseif renderTimedOut or jobStatus ~= "Complete" then\n'
        '        print("ERROR: Audio render did not complete. JobStatus: "\n'
        '            .. tostring(jobStatus or "unavailable"))\n'
        '        exportOk = false\n'
        '    end\n'
        '    renderResult = exportOk and jobStatus == "Complete"\n'
        'end\n'
        'if renderJobId then\n'
        '    local deleteOk, deleteResult = pcall(function()\n'
        '        return project:DeleteRenderJob(renderJobId)\n'
        '    end)\n'
        '    printRenderValue("DeleteRenderJob", deleteOk, deleteResult)\n'
        '    if not deleteOk then exportOk = false; renderResult = false end\n'
        'end\n'
        'if renderResult then\n'
        '    local audioHandle, fileError = io.open(audioFile, "rb")\n'
        '    if not audioHandle then\n'
        '        print("ERROR: Could not read rendered WAV file size: " .. tostring(fileError))\n'
        '        exportOk = false\n'
        '        renderResult = false\n'
        '    else\n'
        '        local audioFileSize = audioHandle:seek("end")\n'
        '        audioHandle:close()\n'
        '        if audioFileSize then\n'
        '            print(string.format("Rendered WAV size: %d bytes", audioFileSize))\n'
        '        else\n'
        '            print("ERROR: Could not determine rendered WAV file size.")\n'
        '            exportOk = false\n'
        '            renderResult = false\n'
        '        end\n'
        '    end\n'
        'end\n\n'
        'print(string.format("Audio export finished in %.2f seconds '
        '(wall clock: %d seconds)", os.clock() - renderStartedAt, '
        'os.time() - renderWallStartedAt))\n'
        'restoreProjectRenderSettings()\n\n'
        '-- Restore tracks immediately',
        1
    )

    audio_state_marker = (
        '-- Solo selected audio track, disable all video for export\n'
        'local originalAudioStates = rememberAudioState(timeline)\n'
    )
    if audio_state_marker not in patched:
        raise SystemExit("ERROR: Could not find audio track state setup.")
    patched = patched.replace(
        audio_state_marker,
        '-- Solo selected audio track\n'
        'local originalAudioStates = rememberAudioState(timeline)\n'
        'local originalRenderFormat, originalRenderCodec\n'
        'local renderFormatSnapshotOk, renderFormatSnapshotError = pcall(function()\n'
        '    originalRenderFormat, originalRenderCodec = project:GetCurrentRenderFormatAndCodec()\n'
        'end)\n'
        'if renderFormatSnapshotOk then\n'
        '    print("Saved render format/codec: " .. tostring(originalRenderFormat)\n'
        '        .. " / " .. tostring(originalRenderCodec))\n'
        'else\n'
        '    print("Could not save render format/codec: " .. tostring(renderFormatSnapshotError))\n'
        'end\n'
        'local renderSettingsSnapshotOk, originalRenderSettings = pcall(function()\n'
        '    return project:GetRenderSettings()\n'
        'end)\n'
        'if renderSettingsSnapshotOk then\n'
        '    print("Saved render settings: " .. (type(originalRenderSettings) == "table" and "available" or "unavailable"))\n'
        'else\n'
        '    print("Could not save render settings: " .. tostring(originalRenderSettings))\n'
        'end\n'
        'local renderSettingsRestored = false\n'
        'local function restoreProjectRenderSettings()\n'
        '    if renderSettingsRestored then return end\n'
        '    renderSettingsRestored = true\n'
        '    if renderFormatSnapshotOk and originalRenderFormat and originalRenderCodec then\n'
        '        local restoreFormatOk, restoreFormatResult = pcall(function()\n'
        '            return project:SetCurrentRenderFormatAndCodec(originalRenderFormat, originalRenderCodec)\n'
        '        end)\n'
        '        if restoreFormatOk then\n'
        '            print("Restored render format/codec: " .. tostring(restoreFormatResult))\n'
        '        else\n'
        '            print("ERROR: Could not restore render format/codec: " .. tostring(restoreFormatResult))\n'
        '        end\n'
        '    end\n'
        '    if renderSettingsSnapshotOk and type(originalRenderSettings) == "table" then\n'
        '        local restoreSettingsOk, restoreSettingsResult = pcall(function()\n'
        '            return project:SetRenderSettings(originalRenderSettings)\n'
        '        end)\n'
        '        if restoreSettingsOk then\n'
        '            print("Restored render settings: " .. tostring(restoreSettingsResult))\n'
        '        else\n'
        '            print("ERROR: Could not restore render settings: " .. tostring(restoreSettingsResult))\n'
        '        end\n'
        '    end\n'
        'end\n'
        'local runOk, runError = pcall(function()\n',
        1
    )

    video_disable_block = (
        'local videoTrackCount = timeline:GetTrackCount("video") or 0\n'
        'local originalVideoStates = {}\n'
        'for i = 1, videoTrackCount do\n'
        '    local ok, state = pcall(function() return timeline:GetIsTrackEnabled("video", i) end)\n'
        '    originalVideoStates[i] = (ok and (state == true)) or false\n'
        '    pcall(function() timeline:SetTrackEnable("video", i, false) end)\n'
        'end\n'
    )
    video_restore_block = (
        '-- Restore tracks immediately\n'
        'for i = 1, videoTrackCount do\n'
        '    pcall(function() timeline:SetTrackEnable("video", i, originalVideoStates[i]) end)\n'
        'end\n'
        'restoreAudioState(timeline, originalAudioStates)\n'
    )
    if video_disable_block not in patched or video_restore_block not in patched:
        raise SystemExit("ERROR: Could not find video track disable/restore blocks.")
    patched = patched.replace(video_disable_block, "", 1)
    patched = patched.replace(video_restore_block, "", 1)

    patched += (
        '\nend)\n'
        'if not runOk then\n'
        '    print("ERROR: Script failed: " .. tostring(runError))\n'
        'end\n'
        'restoreProjectRenderSettings()\n'
        'restoreAudioState(timeline, originalAudioStates)\n'
    )

    append_marker = 'local appendedItems = mediaPool:AppendToTimeline({srtClip})'
    if append_marker not in patched:
        raise SystemExit("ERROR: Could not find subtitle timeline insertion call.")
    patched = patched.replace(
        append_marker,
        'local function printTimelineBounds(label)\n'
        '    local ok, startFrame, endFrame, startTimecode = pcall(function()\n'
        '        return timeline:GetStartFrame(), timeline:GetEndFrame(), timeline:GetStartTimecode()\n'
        '    end)\n'
        '    if ok then\n'
        '        print(label .. " timeline bounds: startFrame=" .. tostring(startFrame)\n'
        '            .. ", endFrame=" .. tostring(endFrame)\n'
        '            .. ", startTimecode=" .. tostring(startTimecode))\n'
        '    else\n'
        '        print(label .. " timeline bounds error: " .. tostring(startFrame))\n'
        '    end\n'
        'end\n'
        'printTimelineBounds("Before subtitle insertion")\n'
        'local startFrame = timeline:GetStartFrame()\n'
        'print("SRT insertion: AppendToTimeline at recordFrame " .. tostring(startFrame))\n'
        'local appendedItems = mediaPool:AppendToTimeline({{mediaPoolItem = srtClip, recordFrame = startFrame}})\n'
        'printTimelineBounds("After subtitle insertion")\n'
        'if appendedItems and #appendedItems > 0 and appendedItems[1] then\n'
        '    local clipStartOk, clipStartFrame = pcall(function() return appendedItems[1]:GetStart() end)\n'
        '    if clipStartOk then\n'
        '        print("Subtitle clip start frame after insertion: " .. tostring(clipStartFrame))\n'
        '    else\n'
        '        print("Subtitle clip start frame error: " .. tostring(clipStartFrame))\n'
        '    end\n'
        'end',
        1
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
