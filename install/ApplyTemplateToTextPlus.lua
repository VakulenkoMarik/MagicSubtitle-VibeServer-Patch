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

local function clipInterval(item)
    local startFrame, startError = call(item, "GetStart")
    local endFrame, endError = call(item, "GetEnd")
    local duration, durationError = call(item, "GetDuration")
    startFrame, endFrame, duration =
        tonumber(startFrame), tonumber(endFrame), tonumber(duration)
    if startError or endError or durationError or not startFrame or not endFrame
        or not duration or duration <= 0 or endFrame - startFrame ~= duration
    then
        return nil, nil, nil, "clip timing unavailable or inconsistent"
    end
    return startFrame, endFrame, duration
end

local function readTrack(timeline, trackIndex)
    local items, itemsError = call(timeline, "GetItemListInTrack", "video", trackIndex)
    if itemsError then return nil, itemsError end
    if items == nil then return {} end
    if type(items) ~= "table" then return nil, "video track item list is not a table" end
    return items
end

local function getTextTools(item)
    local comp, compError = call(item, "GetFusionCompByIndex", 1)
    if not comp then return nil, compError or "Fusion comp unavailable" end
    local tools, toolsError = call(comp, "GetToolList", false, "TextPlus")
    if toolsError then return nil, toolsError end
    if type(tools) ~= "table" then return nil, "TextPlus tool list unavailable" end

    local entries = {}
    for key, textTool in pairs(tools) do
        table.insert(entries, { key = key, tool = textTool })
    end
    table.sort(entries, function(left, right)
        if type(left.key) == "number" and type(right.key) == "number" then
            return left.key < right.key
        end
        return tostring(left.key) < tostring(right.key)
    end)
    local result = {}
    for _, entry in ipairs(entries) do
        table.insert(result, entry.tool)
    end
    return result
end

local function findTemplate(folder, templateName, matches, fusionTitleNames, visited)
    local folderIdentity = tostring(folder)
    if visited[folderIdentity] then return end
    visited[folderIdentity] = true

    local clips, clipsError = call(folder, "GetClipList")
    if clipsError then error("GetClipList failed: " .. clipsError) end
    for _, item in ipairs(clips or {}) do
        local clipType, typeError = call(item, "GetClipProperty", "Type")
        local name, nameError = call(item, "GetName")
        if typeError or nameError then
            error("Could not read a Media Pool item's name or Type")
        end
        if clipType == "Fusion Title" then
            table.insert(fusionTitleNames, tostring(name or ""))
            if name == templateName then table.insert(matches, item) end
        end
    end

    local folders, foldersError = call(folder, "GetSubFolderList")
    if foldersError then error("GetSubFolderList failed: " .. foldersError) end
    for _, subfolder in ipairs(folders or {}) do
        findTemplate(
            subfolder, templateName, matches, fusionTitleNames, visited
        )
    end
end

local function identity(item)
    return tostring(item)
end

local function snapshotTrack(timeline, trackIndex)
    local items, itemsError = readTrack(timeline, trackIndex)
    if not items then return nil, itemsError end
    local result = {}
    for _, item in ipairs(items) do
        local startFrame, endFrame, _, timingError = clipInterval(item)
        if timingError then return nil, timingError end
        table.insert(result, {
            item = item,
            identity = identity(item),
            startFrame = startFrame,
            endFrame = endFrame,
        })
    end
    return result
end

local function isOriginalEntry(item, entry)
    return item == entry.item or identity(item) == entry.identity
end

local function findAt(timeline, trackIndex, wantedStart, wantedEnd)
    local items, itemsError = readTrack(timeline, trackIndex)
    if not items then return nil, itemsError end
    local match
    for _, item in ipairs(items) do
        local startFrame, endFrame = clipInterval(item)
        if startFrame == wantedStart and endFrame == wantedEnd then
            if match then return nil, "multiple clips at requested timing" end
            match = item
        end
    end
    return match
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

local function exportComp(item, path)
    local result, exportError = call(item, "ExportFusionComp", path)
    if exportError or result == false then
        return false, exportError or "ExportFusionComp returned false"
    end
    local file = io.open(path, "rb")
    if not file then return false, "export file was not created" end
    local size = file:seek("end")
    file:close()
    if not size or size <= 0 then return false, "export file is empty" end
    return true
end

local function importComp(item, path)
    local result, importError = call(item, "ImportFusionComp", path)
    if importError or result == false then
        return false, importError or "ImportFusionComp returned false"
    end
    return true
end

local function setAndVerifyText(textTool, text)
    local result, setError = call(textTool, "SetInput", "StyledText", text)
    if setError or result == false then
        return false, setError or "StyledText could not be set"
    end
    local readback, readError = call(textTool, "GetInput", "StyledText")
    if readError or readback ~= text then return false, "StyledText verification failed" end
    return true
end

local function appendTemplate(mediaPool, template, trackIndex, startFrame, duration)
    local result, appendError = call(mediaPool, "AppendToTimeline", {
        {
            mediaPoolItem = template,
            startFrame = 0,
            endFrame = duration,
            recordFrame = startFrame,
            trackIndex = trackIndex,
        },
    })
    return result, appendError
end

local function collectTimelineItems(value, result, visited)
    if value == nil then return end
    local ok, method = pcall(function() return value.GetStart end)
    if ok and type(method) == "function" then
        table.insert(result, value)
        return
    end
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    for _, nested in pairs(value) do
        collectTimelineItems(nested, result, visited)
    end
end

local function findPostDeleteItems(timeline, state)
    local items = readTrack(timeline, state.trackIndex) or {}
    local created = {}
    for _, item in ipairs(items) do
        for _, createdIdentity in ipairs(state.createdIdentities) do
            if identity(item) == createdIdentity then
                table.insert(created, item)
                break
            end
        end
    end
    if #created > 0 then return created end
    if state.disableFallbackCleanup then return created end

    for _, item in ipairs(items) do
        local wasPresent = false
        for _, survivor in ipairs(state.survivors) do
            if isOriginalEntry(item, survivor) then
                wasPresent = true
                break
            end
        end
        if not wasPresent and state.allowCleanup then
            table.insert(created, item)
        elseif not wasPresent then
            local itemStart, itemEnd = clipInterval(item)
            if itemStart == state.startFrame and itemEnd == state.endFrame then
                table.insert(created, item)
            end
        end
    end
    return created
end

local function restoreOriginal(state)
    local created = findPostDeleteItems(state.timeline, state)
    if #created > 0 then
        local result, deleteError = call(state.timeline, "DeleteClips", created, false)
        if deleteError or result == false then
            print("Rollback cleanup failed: " .. tostring(deleteError or result))
        end
    end

    local result, appendError = appendTemplate(
        state.mediaPool, state.rollbackTemplate, state.trackIndex,
        state.startFrame, state.duration
    )
    if appendError or result == false then
        print("Rollback failed: could not append the original clip.")
        return false
    end
    local restored, lookupError =
        findAt(state.timeline, state.trackIndex, state.startFrame, state.endFrame)
    if not restored then
        print("Rollback failed: original clip not found (" .. tostring(lookupError) .. ").")
        return false
    end

    local importOk, importError = importComp(restored, state.exportPath)
    local textTools, toolsError = getTextTools(restored)
    local textOk, textError = false, toolsError
    if textTools and #textTools > 0 then
        textOk, textError = setAndVerifyText(textTools[1], state.originalText)
    else
        textError = toolsError or "restored clip has no TextPlus tool"
    end
    local startFrame, endFrame = clipInterval(restored)
    local timingOk = startFrame == state.startFrame and endFrame == state.endFrame
    local expectedRestored = {}
    for _, survivor in ipairs(state.survivors) do
        table.insert(expectedRestored, survivor)
    end
    table.insert(expectedRestored, {
        item = restored, identity = identity(restored),
        startFrame = state.startFrame, endFrame = state.endFrame,
    })
    local survivorsOk = sameSnapshot(state.timeline, state.trackIndex, expectedRestored)
    if importOk and textOk and timingOk and survivorsOk then
        print("Rollback restored original clip.")
        return true
    end
    print("Rollback incomplete: import=" .. tostring(importError or "ok")
        .. ", text=" .. tostring(textError or "ok")
        .. ", timing=" .. tostring(timingOk)
        .. ", track=" .. tostring(survivorsOk))
    return false
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
        print("Apply template: Resolve connection unavailable.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local projectManager = call(resolve, "GetProjectManager")
    local project = call(projectManager, "GetCurrentProject")
    local timeline = call(project, "GetCurrentTimeline")
    if not project or not timeline then
        print("Apply template: open a project and timeline first.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local timecode = call(timeline, "GetCurrentTimecode")
    local frameRate = call(project, "GetSetting", "timelineFrameRate")
    local playhead = timecodeToFrame(timecode, frameRate)
    local trackCount, trackCountError = call(timeline, "GetTrackCount", "video")
    if not playhead or trackCountError or not tonumber(trackCount) then
        print("Apply template: could not read the playhead.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local original, originalTrack, originalText
    for trackIndex = tonumber(trackCount), 1, -1 do
        local items = readTrack(timeline, trackIndex)
        if not items then
            print("Apply template: could not read video track " .. tostring(trackIndex) .. ".")
            print("Summary: stopped; no clips changed.")
            return
        end
        for _, item in ipairs(items) do
            local startFrame, endFrame = clipInterval(item)
            if startFrame and startFrame <= playhead and playhead < endFrame then
                local textTools = getTextTools(item)
                if textTools and #textTools > 0 then
                    local text, textError = call(textTools[1], "GetInput", "StyledText")
                    if textError or type(text) ~= "string" then
                        print("Apply template: could not read the Text+ text.")
                        print("Summary: stopped; no clips changed.")
                        return
                    end
                    original, originalTrack, originalText = item, trackIndex, text
                    break
                end
            end
        end
        if original then break end
    end
    if not original then
        print("Apply template: no Text+ clip at the playhead.")
        print("Summary: stopped; no clips changed.")
        return
    end

    local startFrame, endFrame, duration = clipInterval(original)
    local templateName = tostring(
        tool and tool.StyleTemplateName and tool.StyleTemplateName[0] or ""
    )
    local mediaPool = call(project, "GetMediaPool")
    local root = call(mediaPool, "GetRootFolder")
    local matches, fusionTitleNames = {}, {}
    local searchError
    if root then
        local searchOk, searchResult = pcall(
            findTemplate, root, templateName, matches, fusionTitleNames, {}
        )
        if not searchOk then searchError = tostring(searchResult) end
    else
        searchError = "Media Pool root unavailable"
    end
    if searchError then
        local names = {}
        for index = 1, math.min(5, #fusionTitleNames) do
            table.insert(names, fusionTitleNames[index])
        end
        print(string.format('Apply template: search for "%s" failed; Fusion Titles: %s (%s)',
            templateName,
            #names > 0 and table.concat(names, ", ") or "none",
            searchError))
        print("Summary: stopped; no clips changed.")
        return
    end
    if templateName == "" or #matches == 0 then
        local names = {}
        for index = 1, math.min(5, #fusionTitleNames) do
            table.insert(names, fusionTitleNames[index])
        end
        print(string.format('Apply template: "%s" not found; Fusion Titles: %s',
            templateName,
            #names > 0 and table.concat(names, ", ") or "none"))
        print("Summary: stopped; no clips changed.")
        return
    end
    print("Template: " .. templateName)

    local before, snapshotError = snapshotTrack(timeline, originalTrack)
    if not before then
        print("Apply template: could not verify target track (" .. tostring(snapshotError) .. ").")
        print("Summary: stopped; no clips changed.")
        return
    end
    local survivors = {}
    for _, entry in ipairs(before) do
        if not isOriginalEntry(original, entry) then table.insert(survivors, entry) end
    end
    if #survivors ~= #before - 1 then
        print("Apply template: could not uniquely identify the original clip.")
        print("Summary: stopped; no clips changed.")
        return
    end
    for _, survivor in ipairs(survivors) do
        if survivor.startFrame == startFrame and survivor.endFrame == endFrame then
            print("Apply template: another clip has identical timing; stopping safely.")
            print("Summary: stopped; no clips changed.")
            return
        end
    end

    local exportPath = os.tmpname() .. ".setting"
    temporaryPath = exportPath
    local exported, exportError = exportComp(original, exportPath)
    if not exported then
        print("Apply template: export failed (" .. tostring(exportError) .. ").")
        print("Summary: stopped; no clips changed.")
        return
    end
    print("Old text: " .. string.format("%q", originalText))
    print("New text: " .. string.format("%q", originalText))

    rollbackState = {
        timeline = timeline, mediaPool = mediaPool, rollbackTemplate = matches[1],
        trackIndex = originalTrack, startFrame = startFrame, endFrame = endFrame,
        duration = duration, originalText = originalText,
        exportPath = exportPath, survivors = survivors,
        original = original, createdIdentities = {}, allowCleanup = false,
    }

    local deleteResult, deleteError = call(timeline, "DeleteClips", { original }, false)
    local afterDelete = snapshotTrack(timeline, originalTrack)
    local deletionVerified = afterDelete ~= nil and #afterDelete == #survivors
    if deletionVerified then
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
            if not found then deletionVerified = false; break end
        end
    end
    if not deletionVerified then
        local originalStillThere = false
        local current = readTrack(timeline, originalTrack) or {}
        for _, item in ipairs(current) do
            if item == original or identity(item) == identity(original) then
                originalStillThere = true
                break
            end
        end
        if originalStillThere then
            rollbackState = nil
            print("Apply template: original clip could not be safely deleted.")
            print("Exact start/end: original remains unchanged.")
            print("Summary: original clip remains.")
            return
        end
        print("Apply template: delete verification failed; restoring original.")
        print("Exact start/end: verification failed.")
        rollbackState.disableFallbackCleanup = true
        restoreOriginal(rollbackState)
        rollbackState = nil
        print("Summary: operation failed; rollback attempted.")
        return
    end
    rollbackState.survivors = afterDelete
    rollbackState.allowCleanup = true
    if deleteError or deleteResult == false then
        print("Apply template: delete reported failure; restoring original.")
        print("Exact start/end: verification failed.")
        restoreOriginal(rollbackState)
        rollbackState = nil
        print("Summary: operation failed; rollback attempted.")
        return
    end

    local appendResult, appendError =
        appendTemplate(mediaPool, matches[1], originalTrack, startFrame, duration)
    local returnedItems = {}
    collectTimelineItems(appendResult, returnedItems, {})
    for _, item in ipairs(returnedItems) do
        table.insert(rollbackState.createdIdentities, identity(item))
    end
    local newItem, lookupError = findAt(
        timeline, originalTrack, startFrame, endFrame
    )
    if appendError or appendResult == false or not newItem then
        print("Apply template: append failed (" .. tostring(appendError or lookupError) .. ").")
        print("Exact start/end: verification failed.")
        restoreOriginal(rollbackState)
        rollbackState = nil
        print("Summary: operation failed; rollback attempted.")
        return
    end

    local newTools, toolsError = getTextTools(newItem)
    if not newTools or #newTools == 0 then
        print("Apply template: selected template has no TextPlus tool.")
        print("Exact start/end: verification failed.")
        restoreOriginal(rollbackState)
        rollbackState = nil
        print("Summary: operation failed; rollback attempted.")
        return
    end
    if #newTools > 1 then
        print("Apply template: warning, template has multiple TextPlus tools; using the first.")
    end
    local textOk, textError = setAndVerifyText(newTools[1], originalText)
    local newStart, newEnd = clipInterval(newItem)
    local timingOk = newStart == startFrame and newEnd == endFrame
    local expectedNew = {}
    for _, survivor in ipairs(survivors) do table.insert(expectedNew, survivor) end
    table.insert(expectedNew, {
        item = newItem, identity = identity(newItem),
        startFrame = startFrame, endFrame = endFrame,
    })
    local trackOk = sameSnapshot(timeline, originalTrack, expectedNew)

    if timingOk and trackOk then
        print(string.format("Exact start/end: %d..%d verified.", newStart, newEnd))
    else
        print("Exact start/end: verification failed.")
    end
    if textOk and timingOk and trackOk then
        rollbackState = nil
        print("Summary: template applied.")
    else
        print("Apply template: " .. tostring(textError or "track verification failed") .. ".")
        restoreOriginal(rollbackState)
        rollbackState = nil
        print("Summary: operation failed; rollback attempted.")
    end
end

local ok, err = pcall(main)
if not ok then
    print("Apply template: unexpected error (" .. tostring(err) .. ").")
    if rollbackState then
        local current = readTrack(rollbackState.timeline, rollbackState.trackIndex) or {}
        local originalStillThere = false
        for _, item in ipairs(current) do
            if item == rollbackState.original
                or identity(item) == identity(rollbackState.original)
            then
                originalStillThere = true
                break
            end
        end
        if originalStillThere then
            print("Rollback skipped: original clip remains.")
            print("Exact start/end: original remains unchanged.")
        else
            print("Exact start/end: verification failed.")
            local rollbackOk, rollbackError = pcall(restoreOriginal, rollbackState)
            if not rollbackOk then
                print("Rollback failed unexpectedly (" .. tostring(rollbackError) .. ").")
            end
        end
        print("Summary: operation failed; rollback attempted.")
    else
        print("Summary: stopped; no clips changed.")
    end
end
if temporaryPath then os.remove(temporaryPath) end
