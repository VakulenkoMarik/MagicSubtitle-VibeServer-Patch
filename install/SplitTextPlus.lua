local INSPECTOR_PROPERTIES = {
    "Pan", "Tilt", "ZoomX", "ZoomY", "Opacity", "CompositeMode",
}

local function call(object, methodName, ...)
    if object == nil then return nil, "object is nil" end
    local arguments = { ... }
    local unpackValues = table.unpack or unpack
    local ok, result = pcall(function()
        local method = object[methodName]
        if type(method) ~= "function" then
            error(methodName .. " is unavailable")
        end
        return method(object, unpackValues(arguments))
    end)
    if not ok then return nil, tostring(result) end
    return result
end

local function findTemplate(folder, templateName, matches, visited)
    local identity = tostring(folder)
    if visited[identity] then return end
    visited[identity] = true

    local clips, clipsError = call(folder, "GetClipList")
    if clipsError then error(clipsError) end
    for _, item in ipairs(clips or {}) do
        local clipType, typeError = call(item, "GetClipProperty", "Type")
        local name, nameError = call(item, "GetName")
        if not typeError and not nameError
            and clipType == "Fusion Title" and name == templateName
        then
            table.insert(matches, item)
        end
    end

    local folders, foldersError = call(folder, "GetSubFolderList")
    if foldersError then error(foldersError) end
    for _, subfolder in ipairs(folders or {}) do
        findTemplate(subfolder, templateName, matches, visited)
    end
end

local function getTextTool(item)
    local comp, compError = call(item, "GetFusionCompByIndex", 1)
    if not comp then return nil, compError or "Fusion comp unavailable" end
    local tools, toolsError = call(comp, "GetToolList", false, "TextPlus")
    if toolsError then return nil, toolsError end
    if type(tools) ~= "table" then return nil, "TextPlus tool list unavailable" end
    for _, textTool in pairs(tools) do
        return textTool
    end
    return nil, "TextPlus tool not found"
end

local function timecodeToFrame(timecode, frameRate)
    if type(timecode) ~= "string" then return nil end
    local hours, minutes, seconds, separator, frames =
        timecode:match("^(%d+):(%d+):(%d+)([:;])(%d+)$")
    if not hours then return nil end

    local nominalRate = math.floor((tonumber(frameRate) or 0) + 0.5)
    if nominalRate <= 0 then return nil end
    hours, minutes, seconds, frames =
        tonumber(hours), tonumber(minutes), tonumber(seconds), tonumber(frames)
    if frames >= nominalRate or minutes > 59 or seconds > 59 then return nil end

    local totalMinutes = hours * 60 + minutes
    local frame = ((hours * 3600 + minutes * 60 + seconds) * nominalRate) + frames
    if separator == ";" then
        local droppedPerMinute = nominalRate == 60 and 4 or 2
        frame = frame - droppedPerMinute * (totalMinutes - math.floor(totalMinutes / 10))
    end
    return frame
end

local function interval(item)
    local startFrame, startError = call(item, "GetStart")
    local duration, durationError = call(item, "GetDuration")
    local endFrame, endError = call(item, "GetEnd")
    startFrame, duration = tonumber(startFrame), tonumber(duration)
    if startError or durationError or not startFrame or not duration or duration <= 0 then
        return nil, nil, nil, "clip timing unavailable"
    end
    if endError or endFrame == nil then endFrame = startFrame + duration end
    endFrame = tonumber(endFrame)
    if not endFrame or endFrame - startFrame ~= duration then
        return nil, nil, nil, "clip end does not match its duration"
    end
    return startFrame, endFrame, duration
end

local function readTrack(timeline, trackIndex)
    local items, itemsError = call(timeline, "GetItemListInTrack", "video", trackIndex)
    if itemsError then return nil, itemsError end
    if items == nil then return {} end
    if type(items) ~= "table" then return nil, "track item list unavailable" end
    return items
end

local function identity(item)
    return tostring(item)
end

local function snapshotTrack(timeline, trackIndex)
    local items, itemsError = readTrack(timeline, trackIndex)
    if not items then return nil, itemsError end
    local snapshot = {}
    for _, item in ipairs(items) do
        local startFrame, endFrame, _, timingError = interval(item)
        if timingError then return nil, timingError end
        table.insert(snapshot, {
            item = item,
            identity = identity(item),
            startFrame = startFrame,
            endFrame = endFrame,
        })
    end
    return snapshot
end

local function sameSnapshot(timeline, trackIndex, expected)
    local current, currentError = snapshotTrack(timeline, trackIndex)
    if not current then return false, currentError end
    if #current ~= #expected then return false, "track item count changed" end
    for _, old in ipairs(expected) do
        local found = false
        for _, now in ipairs(current) do
            if now.identity == old.identity and now.startFrame == old.startFrame
                and now.endFrame == old.endFrame
            then
                found = true
                break
            end
        end
        if not found then return false, "an existing clip changed" end
    end
    return true
end

local function findAt(timeline, trackIndex, wantedStart, wantedEnd)
    local items, itemsError = readTrack(timeline, trackIndex)
    if not items then return nil, itemsError end
    local match
    for _, item in ipairs(items) do
        local startFrame, endFrame = interval(item)
        if startFrame == wantedStart and endFrame == wantedEnd then
            if match then return nil, "multiple clips at requested frames" end
            match = item
        end
    end
    return match
end

local function countNonSpaceCharacters(text)
    local count = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 128 or byte >= 192 then count = count + 1 end
    end
    return count
end

local function propertyValue(value, property)
    if type(value) == "table" and value[property] ~= nil then
        return value[property]
    end
    return value
end

local function readInspectorProperties(item)
    local values, readable = {}, {}
    for _, property in ipairs(INSPECTOR_PROPERTIES) do
        local value, propertyError = call(item, "GetProperty", property)
        if not propertyError and value ~= nil then
            values[property] = propertyValue(value, property)
            table.insert(readable, property)
        end
    end
    print("Inspector read: " .. (#readable > 0 and table.concat(readable, ", ") or "none"))
    return values, readable
end

local function applyInspectorProperties(item, values, readable)
    local applied = {}
    for _, property in ipairs(readable) do
        local result, propertyError = call(item, "SetProperty", property, values[property])
        if not propertyError and result ~= false then
            local readback, readbackError = call(item, "GetProperty", property)
            if not readbackError and readback ~= nil
                and propertyValue(readback, property) == values[property]
            then
                table.insert(applied, property)
            end
        end
    end
    print("Inspector applied: " .. (#applied > 0 and table.concat(applied, ", ") or "none"))
    return applied
end

local function setAndVerifyText(item, text)
    local textTool, toolError = getTextTool(item)
    if not textTool then return false, toolError end
    local result, setError = call(textTool, "SetInput", "StyledText", text)
    if setError or result == false then
        return false, setError or "StyledText could not be set"
    end
    local readback, readError = call(textTool, "GetInput", "StyledText")
    if readError or readback ~= text then return false, "StyledText verification failed" end
    return true
end

local function appendClip(mediaPool, template, trackIndex, startFrame, endFrame)
    return call(mediaPool, "AppendToTimeline", {
        {
            mediaPoolItem = template,
            startFrame = 0,
            endFrame = endFrame - startFrame,
            recordFrame = startFrame,
            trackIndex = trackIndex,
        },
    })
end

local function importComp(item, path)
    local result, importError = call(item, "ImportFusionComp", path)
    if importError or result == false then
        return false, importError or "ImportFusionComp returned false"
    end
    return true
end

local function exportComp(item, path)
    local result, exportError = call(item, "ExportFusionComp", path)
    if exportError or result == false then
        return false, exportError or "ExportFusionComp returned false"
    end
    local file = io.open(path, "rb")
    if not file then return false, "Fusion comp export file was not created" end
    local size = file:seek("end")
    file:close()
    if not size or size <= 0 then return false, "Fusion comp export file is empty" end
    return true
end

local function restoreOriginal(
    timeline, mediaPool, template, trackIndex, startFrame, endFrame,
    text, exportPath, properties, readable, survivors
)
    local current = readTrack(timeline, trackIndex) or {}
    local created = {}
    for _, item in ipairs(current) do
        local isSurvivor = false
        for _, survivor in ipairs(survivors) do
            if item == survivor.item or identity(item) == survivor.identity then
                isSurvivor = true
                break
            end
        end
        if not isSurvivor then table.insert(created, item) end
    end
    if #created > 0 then
        local deleteResult, deleteError = call(timeline, "DeleteClips", created, false)
        if deleteError or deleteResult == false then
            print("Rollback cleanup failed: " .. tostring(deleteError or deleteResult))
        end
    end

    local appendResult, appendError =
        appendClip(mediaPool, template, trackIndex, startFrame, endFrame)
    if appendError or appendResult == false then
        print("Rollback failed: original clip could not be appended.")
        return false
    end
    local restored, lookupError = findAt(timeline, trackIndex, startFrame, endFrame)
    if not restored then
        print("Rollback failed: original clip not found (" .. tostring(lookupError) .. ").")
        return false
    end
    local importOk, importError = importComp(restored, exportPath)
    local textOk, textError = setAndVerifyText(restored, text)
    applyInspectorProperties(restored, properties, readable)
    if not importOk or not textOk then
        print("Rollback incomplete: import=" .. tostring(importError or "ok")
            .. ", text=" .. tostring(textError or "ok"))
        return false
    end
    print("Rollback restored original clip.")
    return true
end

local rollbackState
local temporaryPath

local function main()
    local resolve
    if type(_G.Resolve) == "function" then
        local ok, result = pcall(_G.Resolve)
        if ok then resolve = result end
    end
    resolve = resolve or _G.resolve
    if not resolve then
        print("Split Text+: Resolve connection unavailable.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local projectManager = call(resolve, "GetProjectManager")
    local project = call(projectManager, "GetCurrentProject")
    local timeline = call(project, "GetCurrentTimeline")
    if not project or not timeline then
        print("Split Text+: open a project and timeline first.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local timecode, timecodeError = call(timeline, "GetCurrentTimecode")
    local frameRate = call(project, "GetSetting", "timelineFrameRate")
    local playhead = timecodeToFrame(timecode, frameRate)
    local trackCount, trackCountError = call(timeline, "GetTrackCount", "video")
    if not playhead or trackCountError or not tonumber(trackCount) then
        print("Split Text+: could not read the playhead.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local original, originalTrack, originalTool
    for trackIndex = tonumber(trackCount), 1, -1 do
        local items = readTrack(timeline, trackIndex)
        if items then
            for _, item in ipairs(items) do
                local startFrame, endFrame = interval(item)
                if startFrame and startFrame <= playhead and playhead < endFrame then
                    local textTool = getTextTool(item)
                    if textTool then
                        original, originalTrack, originalTool = item, trackIndex, textTool
                        break
                    end
                end
            end
        end
        if original then break end
    end
    if not original then
        print("Split Text+: no Text+ clip at the playhead.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local startFrame, endFrame, duration = interval(original)
    local originalText, textError = call(originalTool, "GetInput", "StyledText")
    if textError or type(originalText) ~= "string" then
        print("Split Text+: could not read the clip text.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local splitAfter = tonumber(tool and tool.SplitAfterWord and tool.SplitAfterWord[0])
    if not splitAfter or splitAfter < 1 then
        print("Split Text+: enter a word number of at least 1.")
        print("Summary: stopped; no clips changed.")
        return
    end
    splitAfter = math.floor(splitAfter)

    local words = {}
    for word in originalText:gmatch("%S+") do
        table.insert(words, word)
    end
    if splitAfter >= #words then
        print("Split Text+: word number must be less than the word count.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local leftText, rightText = {}, {}
    for index, word in ipairs(words) do
        table.insert(index <= splitAfter and leftText or rightText, word)
    end
    local left = table.concat(leftText, " ")
    local right = table.concat(rightText, " ")
    local leftChars = countNonSpaceCharacters(left)
    local rightChars = countNonSpaceCharacters(right)
    local splitFrame = startFrame
        + math.floor(duration * leftChars / (leftChars + rightChars) + 0.5)
    if splitFrame <= startFrame or splitFrame >= endFrame then
        print("Split Text+: proportional split would create a zero-frame part.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local templateName = tostring(
        tool and tool.TemplateName and tool.TemplateName[0] or "Text+"
    )
    local mediaPool = call(project, "GetMediaPool")
    local root = call(mediaPool, "GetRootFolder")
    local templates = {}
    if root then
        local searchOk, searchError = pcall(findTemplate, root, templateName, templates, {})
        if not searchOk then
            print("Split Text+: Media Pool search failed.")
            print("Summary: stopped; no clips changed.")
            return
        end
    end
    if #templates == 0 then
        print("Split Text+: template \"" .. templateName .. "\" was not found.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local before, snapshotError = snapshotTrack(timeline, originalTrack)
    if not before then
        print("Split Text+: could not verify the track (" .. tostring(snapshotError) .. ").")
        print("Summary: stopped; no clips changed.")
        return
    end
    local survivors = {}
    for _, clip in ipairs(before) do
        if clip.item ~= original and clip.identity ~= identity(original) then
            table.insert(survivors, clip)
        end
    end
    if #survivors ~= #before - 1 then
        print("Split Text+: could not uniquely identify the original clip.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local exportPath = os.tmpname() .. ".setting"
    temporaryPath = exportPath
    local exported, exportError = exportComp(original, exportPath)
    if not exported then
        os.remove(exportPath)
        print("Split Text+: export failed (" .. tostring(exportError) .. ").")
        print("Summary: stopped; no clips changed.")
        return
    end
    local properties, readable = readInspectorProperties(original)
    print("Left text: " .. string.format("%q", left))
    print("Right text: " .. string.format("%q", right))
    print("Split frame: " .. tostring(splitFrame))

    rollbackState = {
        timeline = timeline, mediaPool = mediaPool, template = templates[1],
        trackIndex = originalTrack, startFrame = startFrame, endFrame = endFrame,
        text = originalText, exportPath = exportPath, properties = properties,
        readable = readable, survivors = survivors, original = original,
    }
    local deleteResult, deleteError = call(timeline, "DeleteClips", { original }, false)
    local afterDelete = snapshotTrack(timeline, originalTrack)
    local deleted = afterDelete ~= nil and #afterDelete == #survivors
    if deleted then
        for _, survivor in ipairs(survivors) do
            local found = false
            for _, current in ipairs(afterDelete) do
                if current.identity == survivor.identity
                    and current.startFrame == survivor.startFrame
                    and current.endFrame == survivor.endFrame
                then
                    found = true
                    break
                end
            end
            if not found then deleted = false; break end
        end
    end
    if not deleted then
        local stillThere = findAt(timeline, originalTrack, startFrame, endFrame)
        if stillThere then
            rollbackState = nil
            os.remove(exportPath)
            print("Split Text+: original clip could not be deleted.")
            print("Summary: stopped; original clip remains.")
            return
        end
        print("Split Text+: delete verification failed; restoring original.")
    elseif deleteError or deleteResult == false then
        print("Split Text+: delete returned an error; restoring original.")
    end

    local complete = false
    local timingVerified = false
    local failure = "clip replacement failed"
    if deleted and not deleteError and deleteResult ~= false then
        local firstResult, firstError =
            appendClip(mediaPool, templates[1], originalTrack, startFrame, splitFrame)
        local secondResult, secondError
        if not firstError and firstResult ~= false then
            secondResult, secondError =
                appendClip(mediaPool, templates[1], originalTrack, splitFrame, endFrame)
        end
        if firstError or firstResult == false or secondError or secondResult == false then
            failure = "append failed"
        else
            local first = findAt(timeline, originalTrack, startFrame, splitFrame)
            local second = findAt(timeline, originalTrack, splitFrame, endFrame)
            local expected = {}
            for _, survivor in ipairs(survivors) do table.insert(expected, survivor) end
            if first then
                table.insert(expected, {
                    item = first, identity = identity(first),
                    startFrame = startFrame, endFrame = splitFrame,
                })
            end
            if second then
                table.insert(expected, {
                    item = second, identity = identity(second),
                    startFrame = splitFrame, endFrame = endFrame,
                })
            end
            local trackExact = first ~= nil and second ~= nil
                and sameSnapshot(timeline, originalTrack, expected)
            if not trackExact then
                failure = "exact timing or track verification failed"
            else
                timingVerified = true
                print(string.format("Exact timing: %d..%d and %d..%d verified.",
                    startFrame, splitFrame, splitFrame, endFrame))
                local firstImported, firstImportError = importComp(first, exportPath)
                local secondImported, secondImportError = importComp(second, exportPath)
                local firstTextOk, firstTextError = setAndVerifyText(first, left)
                local secondTextOk, secondTextError = setAndVerifyText(second, right)
                applyInspectorProperties(first, properties, readable)
                applyInspectorProperties(second, properties, readable)
                if firstImported and secondImported and firstTextOk and secondTextOk then
                    local verifiedFirst = findAt(timeline, originalTrack, startFrame, splitFrame)
                    local verifiedSecond = findAt(timeline, originalTrack, splitFrame, endFrame)
                    complete = verifiedFirst ~= nil and verifiedSecond ~= nil
                        and sameSnapshot(timeline, originalTrack, expected)
                else
                    failure = "import or text verification failed"
                    if firstImportError or secondImportError then
                        failure = failure .. " (Fusion comp import)"
                    elseif firstTextError or secondTextError then
                        failure = failure .. " (StyledText)"
                    end
                end
            end
        end
    end

    if complete then
        print("Summary: split succeeded.")
        rollbackState = nil
    else
        if not timingVerified then print("Exact timing: verification failed.") end
        print("Split Text+: " .. failure .. ".")
        restoreOriginal(
            timeline, mediaPool, templates[1], originalTrack,
            startFrame, endFrame, originalText, exportPath,
            properties, readable, survivors
        )
        rollbackState = nil
        print("Summary: split failed; rollback attempted.")
    end
    os.remove(exportPath)
end

local ok, err = pcall(main)
if not ok then
    print("Split Text+: unexpected error (" .. tostring(err) .. ").")
    if rollbackState then
        local state = rollbackState
        local items = readTrack(state.timeline, state.trackIndex) or {}
        local originalStillThere = false
        for _, item in ipairs(items) do
            if item == state.original or identity(item) == identity(state.original) then
                originalStillThere = true
                break
            end
        end
        if originalStillThere then
            print("Rollback skipped: original clip remains.")
        else
            local rollbackOk, rollbackResult = pcall(restoreOriginal,
                state.timeline, state.mediaPool, state.template, state.trackIndex,
                state.startFrame, state.endFrame, state.text, state.exportPath,
                state.properties, state.readable, state.survivors
            )
            if not rollbackOk then
                print("Rollback failed unexpectedly (" .. tostring(rollbackResult) .. ").")
            end
        end
        print("Summary: operation failed; rollback attempted.")
    else
        print("Summary: stopped; no clips changed.")
    end
end
if temporaryPath then os.remove(temporaryPath) end
