local function safeCall(object, methodName, ...)
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

local function describe(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, entry in pairs(value) do
        table.insert(parts, tostring(key) .. "=" .. tostring(entry))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function getTextTool(item)
    local comp, compError = safeCall(item, "GetFusionCompByIndex", 1)
    if not comp then return nil, compError or "Fusion comp unavailable" end
    local tools, toolsError = safeCall(comp, "GetToolList", false, "TextPlus")
    if toolsError then return nil, toolsError end
    if type(tools) ~= "table" then
        return nil, "GetToolList returned " .. type(tools)
    end
    for _, tool in pairs(tools) do
        return tool, nil, comp
    end
    return nil, "Fusion comp has no TextPlus tool", comp
end

local function findTemplate(folder, matches, visited)
    local identity = tostring(folder)
    if visited[identity] then return end
    visited[identity] = true

    local clips, clipsError = safeCall(folder, "GetClipList")
    if clipsError then error("GetClipList failed: " .. clipsError) end
    for _, item in ipairs(clips or {}) do
        local clipType, typeError = safeCall(item, "GetClipProperty", "Type")
        local name, nameError = safeCall(item, "GetName")
        if not typeError and not nameError and clipType == "Fusion Title" then
            local normalized = string.lower(tostring(name or ""))
            if normalized == "text+" or normalized == "textplus"
                or string.find(normalized, "text+", 1, true)
                or string.find(normalized, "text plus", 1, true)
            then
                table.insert(matches, { item = item, name = name })
            end
        end
    end

    local folders, foldersError = safeCall(folder, "GetSubFolderList")
    if foldersError then error("GetSubFolderList failed: " .. foldersError) end
    for _, subfolder in ipairs(folders or {}) do
        findTemplate(subfolder, matches, visited)
    end
end

local function readTrackItems(timeline, trackIndex)
    local items, itemsError = safeCall(timeline, "GetItemListInTrack", "video", trackIndex)
    if itemsError then return nil, itemsError end
    if items == nil then return {} end
    if type(items) ~= "table" then
        return nil, "GetItemListInTrack returned " .. type(items)
    end
    return items
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

local function methodAvailability(object, label, names)
    local found = {}
    for _, name in ipairs(names) do
        local ok, method = pcall(function() return object[name] end)
        if ok and method ~= nil then
            table.insert(found, name)
        end
    end
    print(label .. " selection methods: "
        .. (#found > 0 and table.concat(found, ", ") or "none"))
    return #found > 0
end

local function timelineItemDetails(item)
    local startFrame, startError = safeCall(item, "GetStart")
    local endFrame, endError = safeCall(item, "GetEnd")
    local name, nameError = safeCall(item, "GetName")
    if startError or endError then return nil end
    return startFrame, endFrame, nameError and "<unavailable>" or tostring(name)
end

local function getStyle(tool)
    local inputs = { "Font", "Size", "Red1", "Green1", "Blue1", "Alpha1" }
    local values = {}
    for _, input in ipairs(inputs) do
        local value, inputError = safeCall(tool, "GetInput", input)
        if inputError then
            values[input] = "<ERROR: " .. inputError .. ">"
        else
            values[input] = value
        end
    end
    return values, inputs
end

local function printStyle(label, values, inputs)
    for _, input in ipairs(inputs) do
        print(string.format("%s %s=%s", label, input, describe(values[input])))
    end
end

local function stylesMatch(original, candidate, inputs)
    for _, input in ipairs(inputs) do
        if original[input] == nil or candidate[input] == nil
            or (type(original[input]) == "string"
                and string.find(original[input], "<ERROR:", 1, true) == 1)
            or (type(candidate[input]) == "string"
                and string.find(candidate[input], "<ERROR:", 1, true) == 1)
            or original[input] ~= candidate[input]
        then
            return false
        end
    end
    return true
end

local function getCreatedItem(timeline, trackIndex, expectedStart, expectedEnd)
    local items, itemsError = readTrackItems(timeline, trackIndex)
    if not items then return nil, itemsError end
    for _, item in ipairs(items) do
        local startFrame, endFrame = timelineItemDetails(item)
        if tonumber(startFrame) == expectedStart and tonumber(endFrame) == expectedEnd then
            return item
        end
    end
    return nil, string.format("no clip found at exact frames %d..%d", expectedStart, expectedEnd)
end

local summary = {
    playheadLookupWorks = false,
    selectionApiExists = false,
    exportImportRoundTrip = false,
    styleSurvives = false,
    deleteThenAppendExact = false,
}

local function printSummary()
    print("SUMMARY")
    print("Playhead lookup works: " .. (summary.playheadLookupWorks and "yes" or "no"))
    print("Selection API exists: " .. (summary.selectionApiExists and "yes" or "no"))
    print("Export/import round trip: " .. (summary.exportImportRoundTrip and "yes" or "no"))
    print("Style survives: " .. (summary.styleSurvives and "yes" or "no"))
    print("Delete-then-append on same track exact: "
        .. (summary.deleteThenAppendExact and "yes" or "no"))
end

local function main()
    local resolve
    if type(_G.Resolve) == "function" then
        local ok, result = pcall(_G.Resolve)
        if ok then resolve = result end
    end
    resolve = resolve or _G.resolve
    if not resolve then
        print("FAILED: Resolve connection unavailable.")
        printSummary()
        return
    end

    local projectManager = safeCall(resolve, "GetProjectManager")
    local project = safeCall(projectManager, "GetCurrentProject")
    local timeline = safeCall(project, "GetCurrentTimeline")
    if not project or not timeline then
        print("FAILED: Open a project and timeline first.")
        printSummary()
        return
    end

    local trackCount, trackCountError = safeCall(timeline, "GetTrackCount", "video")
    local timecode, timecodeError = safeCall(timeline, "GetCurrentTimecode")
    local frameRate = safeCall(project, "GetSetting", "timelineFrameRate")
    local playheadFrame = timecodeToFrame(timecode, frameRate)
    print("Playhead timecode: " .. (timecodeError and ("ERROR " .. timecodeError)
        or describe(timecode)))
    print("Playhead frame: " .. describe(playheadFrame))
    print("Timeline:GetCurrentVideoItem(): " ..
        describe(safeCall(timeline, "GetCurrentVideoItem")))

    local selectionNames = {
        "GetSelectedItems", "GetSelectedClips", "GetSelectedItem",
        "GetSelectedTimelineItems", "GetSelectedVideoItems", "GetSelectedTracks",
    }
    local timelineHasSelection = methodAvailability(timeline, "Timeline", selectionNames)
    local projectHasSelection = methodAvailability(project, "Project", selectionNames)
    summary.selectionApiExists = timelineHasSelection or projectHasSelection

    local originalItem
    if not trackCountError and tonumber(trackCount) and playheadFrame then
        for trackIndex = tonumber(trackCount), 1, -1 do
            local items = readTrackItems(timeline, trackIndex)
            if items then
                for _, item in ipairs(items) do
                    local startFrame, endFrame = timelineItemDetails(item)
                    if tonumber(startFrame) and tonumber(endFrame)
                        and tonumber(startFrame) <= playheadFrame
                        and playheadFrame < tonumber(endFrame)
                    then
                        local tool, toolError = getTextTool(item)
                        if tool then
                            local text = safeCall(tool, "GetInput", "StyledText")
                            print(string.format(
                                "PLAYHEAD TEXT+: track=V%d start=%s end=%s text=%s",
                                trackIndex, tostring(startFrame), tostring(endFrame),
                                describe(text)
                            ))
                            originalItem = item
                            summary.playheadLookupWorks = true
                            break
                        elseif toolError then
                            print(string.format(
                                "V%d item at playhead has no TextPlus tool: %s",
                                trackIndex, toolError
                            ))
                        end
                    end
                end
            end
            if originalItem then break end
        end
    else
        print("Playhead lookup unavailable: could not read track count or parse timecode.")
    end
    if not originalItem then print("PLAYHEAD TEXT+: not found") end

    local exportedPath
    local exportedFileSize
    local originalTool
    if originalItem then
        originalTool = getTextTool(originalItem)
        exportedPath = os.tmpname() .. ".setting"
        local exportResult, exportError = safeCall(originalItem, "ExportFusionComp", exportedPath)
        print("ExportFusionComp(" .. exportedPath .. ") returned: "
            .. (exportError and ("ERROR " .. exportError) or describe(exportResult)))
        local file = io.open(exportedPath, "rb")
        if file then
            exportedFileSize = file:seek("end")
            file:close()
        end
        print("Exported file size: " .. describe(exportedFileSize))
    end

    local mediaPool = safeCall(project, "GetMediaPool")
    local root = safeCall(mediaPool, "GetRootFolder")
    local templates = {}
    if root then
        local searchOk, searchError = pcall(findTemplate, root, templates, {})
        if not searchOk then print("Media Pool search failed: " .. tostring(searchError)) end
    end
    table.sort(templates, function(left, right)
        local leftName = string.lower(tostring(left.name or ""))
        local rightName = string.lower(tostring(right.name or ""))
        local leftExact = leftName == "text+" or leftName == "textplus"
        local rightExact = rightName == "text+" or rightName == "textplus"
        if leftExact ~= rightExact then return leftExact end
        return leftName < rightName
    end)
    local template = templates[1]
    if not template then
        print("FAILED: No Text+ Fusion Title found in the Media Pool.")
    else
        print("Using Media Pool template: " .. tostring(template.name))
    end

    local newTrack
    if template and playheadFrame and not trackCountError and tonumber(trackCount) then
        local beforeTrackCount = tonumber(trackCount)
        local addResult, addError = safeCall(timeline, "AddTrack", "video")
        local afterTrackCount, afterTrackError = safeCall(timeline, "GetTrackCount", "video")
        print("AddTrack(video) returned: "
            .. (addError and ("ERROR " .. addError) or describe(addResult)))
        if not afterTrackError and tonumber(afterTrackCount) == beforeTrackCount + 1 then
            newTrack = tonumber(afterTrackCount)
            local initialItems, initialError = readTrackItems(timeline, newTrack)
            if initialError then
                print("FAILED: Cannot verify new V" .. newTrack .. ": " .. initialError)
                newTrack = nil
            elseif #initialItems ~= 0 then
                print("FAILED: New V" .. newTrack .. " is not empty; stopping without modifying it.")
                newTrack = nil
            end
        else
            print("FAILED: AddTrack did not add exactly one video track.")
        end
    end

    if newTrack then
        local testStart = playheadFrame
        local testEnd = testStart + 100
        local testText = "Text+ ops experiment test"
        local appendResult, appendError = safeCall(mediaPool, "AppendToTimeline", {
            {
                mediaPoolItem = template.item,
                startFrame = 0,
                endFrame = 100,
                recordFrame = testStart,
                trackIndex = newTrack,
            },
        })
        print("Initial AppendToTimeline returned: "
            .. (appendError and ("ERROR " .. appendError) or describe(appendResult)))
        local testItem, testItemError = getCreatedItem(timeline, newTrack, testStart, testEnd)
        if not testItem then
            print("FAILED: Could not identify the created 100-frame test clip: " .. testItemError)
        else
            local testTool, testToolError = getTextTool(testItem)
            if testTool then
                local setResult, setError = safeCall(testTool, "SetInput", "StyledText", testText)
                local textReadback, readbackError =
                    safeCall(testTool, "GetInput", "StyledText")
                print("Set test text returned: "
                    .. (setError and ("ERROR " .. setError) or describe(setResult)))
                print("Test text readback: "
                    .. (readbackError and ("ERROR " .. readbackError)
                        or describe(textReadback)))
            else
                print("FAILED: Created test clip has no TextPlus tool: " .. tostring(testToolError))
            end

            local deleteResult, deleteError = safeCall(timeline, "DeleteClips", { testItem }, false)
            print("DeleteClips({created test item}, false) returned: "
                .. (deleteError and ("ERROR " .. deleteError) or describe(deleteResult)))
            local afterDeleteItems, afterDeleteError = readTrackItems(timeline, newTrack)
            local trackEmptyAfterDelete =
                not afterDeleteError and afterDeleteItems and #afterDeleteItems == 0
            print("New track empty after delete: " .. tostring(not not trackEmptyAfterDelete))

            if trackEmptyAfterDelete then
                local firstStart, splitFrame, finalEnd = testStart, testStart + 40, testEnd
                local pairResult, pairError = safeCall(mediaPool, "AppendToTimeline", {
                    {
                        mediaPoolItem = template.item,
                        startFrame = 0,
                        endFrame = 40,
                        recordFrame = firstStart,
                        trackIndex = newTrack,
                    },
                    {
                        mediaPoolItem = template.item,
                        startFrame = 0,
                        endFrame = 60,
                        recordFrame = splitFrame,
                        trackIndex = newTrack,
                    },
                })
                print("Two-clip AppendToTimeline returned: "
                    .. (pairError and ("ERROR " .. pairError) or describe(pairResult)))

                local items, itemsError = readTrackItems(timeline, newTrack)
                local firstItem = getCreatedItem(timeline, newTrack, firstStart, splitFrame)
                local secondItem = getCreatedItem(timeline, newTrack, splitFrame, finalEnd)
                local exactPair = not itemsError and items and #items == 2
                    and firstItem ~= nil and secondItem ~= nil
                local firstActualStart, firstActualEnd
                local secondActualStart, secondActualEnd
                if firstItem then
                    firstActualStart, firstActualEnd = timelineItemDetails(firstItem)
                end
                if secondItem then
                    secondActualStart, secondActualEnd = timelineItemDetails(secondItem)
                end
                print(string.format(
                    "Two clips on V%d: count=%s first=%s..%s second=%s..%s exact=%s",
                    newTrack, tostring(items and #items or "ERROR"),
                    tostring(firstActualStart or "missing"),
                    tostring(firstActualEnd or "missing"),
                    tostring(secondActualStart or "missing"),
                    tostring(secondActualEnd or "missing"),
                    tostring(not not exactPair)
                ))

                local fileExists = false
                if exportedPath then
                    local file = io.open(exportedPath, "rb")
                    if file then fileExists = true; file:close() end
                end
                if exactPair and originalTool and fileExists and (exportedFileSize or 0) > 0 then
                    local importsSucceeded = true
                    for index, item in ipairs({ firstItem, secondItem }) do
                        local importResult, importError =
                            safeCall(item, "ImportFusionComp", exportedPath)
                        print(string.format(
                            "V%d clip %d ImportFusionComp returned: %s",
                            newTrack, index,
                            importError and ("ERROR " .. importError) or describe(importResult)
                        ))
                        if importError or importResult == false then importsSucceeded = false end
                    end
                    summary.exportImportRoundTrip = importsSucceeded

                    local originalStyle, styleInputs = getStyle(originalTool)
                    local firstTool = getTextTool(firstItem)
                    local secondTool = getTextTool(secondItem)
                    if firstTool and secondTool then
                        local firstStyle = getStyle(firstTool)
                        local secondStyle = getStyle(secondTool)
                        printStyle("Original", originalStyle, styleInputs)
                        printStyle("New clip 1", firstStyle, styleInputs)
                        printStyle("New clip 2", secondStyle, styleInputs)
                        local firstMatches = stylesMatch(originalStyle, firstStyle, styleInputs)
                        local secondMatches = stylesMatch(originalStyle, secondStyle, styleInputs)
                        print("Style matches original: clip 1=" .. tostring(firstMatches)
                            .. " clip 2=" .. tostring(secondMatches))
                        summary.styleSurvives = firstMatches and secondMatches
                    else
                        print("Style comparison unavailable: TextPlus tool missing after import.")
                    end
                else
                    print("Import/style comparison skipped: exact pair or non-empty exported file unavailable.")
                end
                summary.deleteThenAppendExact = not not exactPair
            else
                print("FAILED: Cannot safely append the pair; new track was not empty after delete.")
            end
        end
    end

    printSummary()
end

local ok, err = pcall(main)
if not ok then
    print("EXPERIMENT ERROR: " .. tostring(err))
    printSummary()
end
