local function printValue(value)
    if type(value) ~= "table" then
        return tostring(value)
    end

    local parts = {}
    for key, entry in pairs(value) do
        table.insert(parts, tostring(key) .. "=" .. tostring(entry))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function callMethod(object, methodName, ...)
    if object == nil then return nil, "object is nil" end
    local arguments = {...}
    local unpackValues = table.unpack or unpack
    local ok, result = pcall(function()
        return object[methodName](object, unpackValues(arguments))
    end)
    if not ok then return nil, tostring(result) end
    return result
end

local function readTimelineItem(item, label)
    local name, nameError = callMethod(item, "GetName")
    local startFrame, startError = callMethod(item, "GetStart")
    local duration, durationError = callMethod(item, "GetDuration")
    local endFrame, endError = callMethod(item, "GetEnd")
    if nameError or startError or durationError or endError then
        return nil, string.format(
            "%s: GetName=%s GetStart=%s GetDuration=%s GetEnd=%s",
            label, tostring(nameError), tostring(startError),
            tostring(durationError), tostring(endError)
        )
    end
    return {
        item = item,
        name = name,
        startFrame = startFrame,
        duration = duration,
        endFrame = endFrame,
        identity = tostring(item),
    }
end

local function getTrackItems(timeline, trackType, trackIndex)
    local items, err = callMethod(timeline, "GetItemListInTrack", trackType, trackIndex)
    if err then
        error(string.format(
            "GetItemListInTrack(%s, %d) failed: %s", trackType, trackIndex, err
        ))
    end
    if items == nil then return {} end
    if type(items) ~= "table" then
        error(string.format(
            "GetItemListInTrack(%s, %d) returned %s instead of a table",
            trackType, trackIndex, type(items)
        ))
    end
    return items
end

local function captureVideoTrack(timeline, trackIndex, label)
    local items = getTrackItems(timeline, "video", trackIndex)
    local snapshot = {}
    print(string.format("%s V%d clip count=%d", label, trackIndex, #items))
    for index, item in ipairs(items) do
        local details, err = readTimelineItem(item, string.format("%s V%d item %d", label, trackIndex, index))
        if not details then error(err) end
        print(string.format(
            "%s V%d item %d: name=%q start=%s end=%s duration=%s",
            label, trackIndex, index, tostring(details.name),
            tostring(details.startFrame), tostring(details.endFrame),
            tostring(details.duration)
        ))
        table.insert(snapshot, details)
    end
    return snapshot
end

local function compareVideoTrackSnapshots(before, after)
    local changes = {}
    if #before ~= #after then
        table.insert(changes, string.format("clip count changed from %d to %d", #before, #after))
    end

    local matched = {}
    for _, old in ipairs(before) do
        local found
        for index, current in ipairs(after) do
            if not matched[index]
                and (current.item == old.item or current.identity == old.identity)
            then
                found = current
                matched[index] = true
                break
            end
        end
        if not found then
            table.insert(changes, string.format("existing clip disappeared: %q", tostring(old.name)))
        elseif old.name ~= found.name
            or old.startFrame ~= found.startFrame
            or old.endFrame ~= found.endFrame
            or old.duration ~= found.duration
        then
            table.insert(changes, string.format(
                "%q changed: name=%q/%q start=%s/%s end=%s/%s duration=%s/%s",
                tostring(old.name), tostring(old.name), tostring(found.name),
                tostring(old.startFrame), tostring(found.startFrame),
                tostring(old.endFrame), tostring(found.endFrame),
                tostring(old.duration), tostring(found.duration)
            ))
        end
    end

    for index, current in ipairs(after) do
        if not matched[index] then
            table.insert(changes, string.format("new clip appeared: %q", tostring(current.name)))
        end
    end
    return changes
end

local function enumerateMediaFolder(folder, folderPath, entries, visited)
    local folderIdentity = tostring(folder)
    if visited[folderIdentity] then return end
    visited[folderIdentity] = true

    local clips, clipsError = callMethod(folder, "GetClipList")
    if clipsError then error("GetClipList failed in " .. folderPath .. ": " .. clipsError) end
    if clips == nil then clips = {} end
    if type(clips) ~= "table" then
        error("GetClipList returned " .. type(clips) .. " in " .. folderPath)
    end

    for _, mediaItem in ipairs(clips) do
        local name, nameError = callMethod(mediaItem, "GetName")
        local clipType, typeError = callMethod(mediaItem, "GetClipProperty", "Type")
        if nameError then
            print("Could not read Media Pool item name in " .. folderPath .. ": " .. nameError)
        end
        if typeError then
            print("Could not read Media Pool item Type in " .. folderPath .. ": " .. typeError)
        end
        table.insert(entries, {
            item = mediaItem,
            name = name,
            clipType = clipType,
            typeError = typeError,
            folderPath = folderPath,
        })
    end

    local subfolders, foldersError = callMethod(folder, "GetSubFolderList")
    if foldersError then error("GetSubFolderList failed in " .. folderPath .. ": " .. foldersError) end
    if subfolders == nil then return end
    if type(subfolders) ~= "table" then
        error("GetSubFolderList returned " .. type(subfolders) .. " in " .. folderPath)
    end
    for index, subfolder in ipairs(subfolders) do
        local name = callMethod(subfolder, "GetName")
        enumerateMediaFolder(
            subfolder,
            folderPath .. "/" .. tostring(name or ("folder-" .. index)),
            entries,
            visited
        )
    end
end

local function isTimelineType(clipType)
    return string.lower(tostring(clipType or "")):match("^%s*timeline%s*$") ~= nil
end

local function isTextPlusName(name)
    local normalized = string.lower(tostring(name or ""))
    return string.find(normalized, "text+", 1, true) ~= nil
        or string.find(normalized, "textplus", 1, true) ~= nil
        or string.find(normalized, "text plus", 1, true) ~= nil
end

local function extractTimelineItems(value, output, visited)
    if value == nil then return end
    local isItem = false
    local methodOk, method = pcall(function() return value.GetStart end)
    if methodOk and type(method) == "function" then isItem = true end
    if isItem then
        table.insert(output, value)
        return
    end
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    for _, nested in pairs(value) do
        extractTimelineItems(nested, output, visited)
    end
end

local function getTextTool(timelineItem)
    local comp, compError = callMethod(timelineItem, "GetFusionCompByIndex", 1)
    if compError or not comp then
        return nil, "GetFusionCompByIndex(1) failed: " .. tostring(compError or comp)
    end
    local tools, toolsError = callMethod(comp, "GetToolList", false, "TextPlus")
    if toolsError then return nil, "GetToolList failed: " .. toolsError end
    if type(tools) ~= "table" then
        return nil, "GetToolList returned " .. type(tools) .. ": " .. printValue(tools)
    end
    for _, tool in pairs(tools) do
        return tool
    end
    return nil, "GetToolList returned no TextPlus tool"
end

local function setAndVerifyText(timelineItem, text)
    local textTool, toolError = getTextTool(timelineItem)
    if not textTool then return false, toolError end
    local setResult, setError = callMethod(textTool, "SetInput", "StyledText", text)
    if setError then return false, "SetInput failed: " .. setError end
    if setResult == false then return false, "SetInput returned false" end
    local readback, readError = callMethod(textTool, "GetInput", "StyledText")
    if readError then return false, "GetInput verification failed: " .. readError end
    return readback == text, "SetInput returned " .. printValue(setResult)
        .. "; readback=" .. printValue(readback)
end

local function snapshotAppendedTrack(timeline, trackIndex)
    local items = getTrackItems(timeline, "video", trackIndex)
    local snapshot = {}
    for _, item in ipairs(items) do
        local details, err = readTimelineItem(item, "new video track item")
        if details then
            table.insert(snapshot, details)
        else
            print("Could not inspect new video track item: " .. err)
        end
    end
    return snapshot
end

local function reportV1Result(timeline, before)
    local ok, after = pcall(function() return captureVideoTrack(timeline, 1, "AFTER") end)
    if not ok then
        print("V1 after-state could not be verified: " .. tostring(after))
        return false
    end
    local changes = compareVideoTrackSnapshots(before, after)
    if #changes == 0 then
        print("V1 comparison: unchanged (same clip count, names, starts, ends, durations, and identities).")
        return true
    end
    print("V1 comparison: changed or not identical:")
    for _, change in ipairs(changes) do print("  " .. change) end
    return false
end

local function main()
    print("STEP: Connect to Resolve")
    local resolve
    local resolveError
    if type(_G.Resolve) == "function" then
        local resolveOk, resolveResult = pcall(_G.Resolve)
        if resolveOk then
            resolve = resolveResult
        else
            resolveError = tostring(resolveResult)
        end
    else
        resolveError = "Resolve global function is unavailable"
    end
    if not resolve then
        resolve = _G.resolve
        if not resolve then
            print("FAILED: Resolve() unavailable and no global resolve fallback: " .. tostring(resolveError))
            return
        end
        print("Resolve() unavailable; using global resolve fallback.")
    else
        print("Resolve() returned: " .. printValue(resolve))
    end

    local projectManager, pmError = callMethod(resolve, "GetProjectManager")
    local project, projectError = callMethod(projectManager, "GetCurrentProject")
    local timeline, timelineError = callMethod(project, "GetCurrentTimeline")
    if not project or not timeline then
        print("FAILED: Could not get the current project/timeline: "
            .. tostring(pmError or projectError or timelineError))
        return
    end

    local timelineStartFrame, startFrameError = callMethod(timeline, "GetStartFrame")
    print("Timeline start frame: " .. (startFrameError and ("ERROR " .. startFrameError)
        or printValue(timelineStartFrame)))

    print("STEP: Find Text+ in the Media Pool (recursive; excluding Type=Timeline)")
    local mediaPool, poolError = callMethod(project, "GetMediaPool")
    local root, rootError = callMethod(mediaPool, "GetRootFolder")
    if not root then
        print("FAILED: Could not get Media Pool root folder: " .. tostring(poolError or rootError))
        return
    end
    local poolEntries = {}
    local searchOk, searchError = pcall(function()
        enumerateMediaFolder(root, "root", poolEntries, {})
    end)
    if not searchOk then
        print("FAILED: Media Pool search failed: " .. tostring(searchError))
        return
    end

    local textPlusItems = {}
    for _, entry in ipairs(poolEntries) do
        if isTimelineType(entry.clipType) then
            print(string.format(
                "Ignoring Type=Timeline item: name=%q folder=%s",
                tostring(entry.name), entry.folderPath
            ))
        elseif not entry.typeError
            and (isTextPlusName(entry.name) or isTextPlusName(entry.clipType))
        then
            table.insert(textPlusItems, entry)
            print(string.format(
                "Text+ candidate %d: name=%q Type=%s folder=%s",
                #textPlusItems, tostring(entry.name), printValue(entry.clipType), entry.folderPath
            ))
        end
    end
    if #textPlusItems == 0 then
        print("FAILED: No Text+ item found in the Media Pool after recursively searching all folders (Type=Timeline items were ignored).")
        return
    end
    if #textPlusItems > 1 then
        print("Multiple Text+ items found; using the first in Media Pool traversal order.")
    end
    local mediaPoolItem = textPlusItems[1].item

    print("STEP: Read subtitle track 1")
    local subtitleItemsOk, subtitleItems = pcall(function()
        return getTrackItems(timeline, "subtitle", 1)
    end)
    if not subtitleItemsOk then
        print("FAILED: Could not read subtitle track 1: " .. tostring(subtitleItems))
        return
    end
    local subtitles = {}
    for index, item in ipairs(subtitleItems) do
        local name, nameError = callMethod(item, "GetName")
        local startFrame, startError = callMethod(item, "GetStart")
        local duration, durationError = callMethod(item, "GetDuration")
        if nameError or startError or durationError then
            print(string.format(
                "Subtitle %d could not be read: GetName=%s GetStart=%s GetDuration=%s",
                index, tostring(nameError), tostring(startError), tostring(durationError)
            ))
        elseif tonumber(startFrame) == nil or tonumber(duration) == nil then
            print(string.format(
                "Subtitle %d has non-numeric timing; cannot append it: name=%q start=%s duration=%s",
                index, tostring(name), tostring(startFrame), tostring(duration)
            ))
        else
            local subtitle = {
                sourceIndex = index,
                text = tostring(name),
                startFrame = startFrame,
                duration = duration,
            }
            table.insert(subtitles, subtitle)
            print(string.format(
                "Subtitle %d: GetName=%q GetStart=%s GetDuration=%s",
                index, subtitle.text, tostring(startFrame), tostring(duration)
            ))
        end
    end
    print(string.format(
        "Subtitles read: %d valid of %d item(s) returned by subtitle track 1.",
        #subtitles, #subtitleItems
    ))
    if #subtitles == 0 then
        print("No readable subtitles to convert; no video track was added.")
        return
    end

    local trackCount, trackCountError = callMethod(timeline, "GetTrackCount", "video")
    if trackCountError or tonumber(trackCount) == nil then
        print("FAILED: Could not read current video track count: "
            .. tostring(trackCountError or trackCount))
        return
    end
    local v1BeforeOk, v1Before = pcall(function() return captureVideoTrack(timeline, 1, "BEFORE") end)
    if not v1BeforeOk then
        print("FAILED: Could not capture V1 before conversion: " .. tostring(v1Before))
        return
    end

    print("STEP: Add one video track")
    local addResult, addError = callMethod(timeline, "AddTrack", "video")
    local newTrackCount, newTrackCountError = callMethod(timeline, "GetTrackCount", "video")
    print("AddTrack(video) returned: " .. (addError and ("ERROR " .. addError) or printValue(addResult)))
    print("GetTrackCount(video) after add returned: "
        .. (newTrackCountError and ("ERROR " .. newTrackCountError) or printValue(newTrackCount)))
    local newTrack = tonumber(newTrackCount)
    if newTrackCountError or not newTrack or newTrack ~= tonumber(trackCount) + 1 then
        print("FAILED: AddTrack did not add exactly one new video track; stopping before appending.")
        reportV1Result(timeline, v1Before)
        return
    end
    local initialTrackItems = snapshotAppendedTrack(timeline, newTrack)

    local appendArguments = {}
    for _, subtitle in ipairs(subtitles) do
        table.insert(appendArguments, {
            mediaPoolItem = mediaPoolItem,
            startFrame = 0,
            endFrame = subtitle.duration,
            recordFrame = subtitle.startFrame,
            trackIndex = newTrack,
        })
    end

    print(string.format("STEP: Batch append %d Text+ item(s) on V%d", #subtitles, newTrack))
    local batchOk, batchResult = pcall(function()
        return mediaPool:AppendToTimeline(appendArguments)
    end)
    if batchOk then
        print("Batch AppendToTimeline raw return: " .. printValue(batchResult))
    else
        print("Batch AppendToTimeline raised: " .. tostring(batchResult))
    end
    local returnedItems = {}
    if batchOk then extractTimelineItems(batchResult, returnedItems, {}) end
    print("Batch AppendToTimeline returned TimelineItem count: " .. #returnedItems)

    local batchTrackItems = snapshotAppendedTrack(timeline, newTrack)
    local createdItems = {}
    local usedItems = {}
    local sourceToCreated = {}

    local function associate(item, subtitle, label)
        if not item or not subtitle then return false end
        local identity = tostring(item)
        if usedItems[identity] then return false end
        local details, detailsError = readTimelineItem(item, label)
        if not details then
            print("Could not read appended item: " .. detailsError)
            return false
        end
        usedItems[identity] = true
        table.insert(createdItems, details)
        sourceToCreated[subtitle.sourceIndex] = details
        details.subtitle = subtitle
        return true
    end

    if #returnedItems == #subtitles then
        for index, item in ipairs(returnedItems) do
            associate(item, subtitles[index], "AppendToTimeline returned item " .. index)
        end
    else
        for _, details in ipairs(batchTrackItems) do
            for _, subtitle in ipairs(subtitles) do
                if not sourceToCreated[subtitle.sourceIndex]
                    and tonumber(details.startFrame) == tonumber(subtitle.startFrame)
                    and tonumber(details.duration) == tonumber(subtitle.duration)
                then
                    associate(details.item, subtitle, "batch-created track item")
                    break
                end
            end
        end
    end

    local missingAfterBatch = {}
    for _, subtitle in ipairs(subtitles) do
        if not sourceToCreated[subtitle.sourceIndex] then
            table.insert(missingAfterBatch, subtitle)
        end
    end
    if #missingAfterBatch > 0 then
        print(string.format(
            "Batch produced %d identifiable item(s) for %d subtitle(s); trying unassigned subtitle(s) individually.",
            #createdItems, #subtitles
        ))
        for _, subtitle in ipairs(missingAfterBatch) do
            print(string.format(
                "Individual fallback for source subtitle %d: start=%s duration=%s",
                subtitle.sourceIndex, tostring(subtitle.startFrame), tostring(subtitle.duration)
            ))
            local oneOk, oneResult = pcall(function()
                return mediaPool:AppendToTimeline({
                    {
                        mediaPoolItem = mediaPoolItem,
                        startFrame = 0,
                        endFrame = subtitle.duration,
                        recordFrame = subtitle.startFrame,
                        trackIndex = newTrack,
                    },
                })
            end)
            if oneOk then
                print("Individual AppendToTimeline raw return: " .. printValue(oneResult))
                local oneItems = {}
                extractTimelineItems(oneResult, oneItems, {})
                if #oneItems == 1 then
                    associate(oneItems[1], subtitle, "individual AppendToTimeline result")
                end
            else
                print("Individual AppendToTimeline raised: " .. tostring(oneResult))
            end
            if not sourceToCreated[subtitle.sourceIndex] then
                local currentTrackItems = snapshotAppendedTrack(timeline, newTrack)
                for _, details in ipairs(currentTrackItems) do
                    if not usedItems[details.identity]
                        and tonumber(details.startFrame) == tonumber(subtitle.startFrame)
                        and tonumber(details.duration) == tonumber(subtitle.duration)
                    then
                        associate(details.item, subtitle, "individual track scan")
                        break
                    end
                end
            end
        end
    end

    print("STEP: Set and verify StyledText")
    local verifiedTexts = 0
    for _, details in ipairs(createdItems) do
        local subtitle = details.subtitle
        local verified, message = setAndVerifyText(details.item, subtitle.text)
        details.textVerified = verified
        if verified then verifiedTexts = verifiedTexts + 1 end
        print(string.format(
            "Source subtitle %d text %q: %s (%s)",
            subtitle.sourceIndex, subtitle.text,
            verified and "VERIFIED" or "FAILED", tostring(message)
        ))
    end

    local exactStarts, exactEnds = 0, 0
    for _, details in ipairs(createdItems) do
        local subtitle = details.subtitle
        local actualStart, startError = callMethod(details.item, "GetStart")
        local actualEnd, endError = callMethod(details.item, "GetEnd")
        local expectedEnd = tonumber(subtitle.startFrame) + tonumber(subtitle.duration)
        local startMatches = not startError and tonumber(actualStart) == tonumber(subtitle.startFrame)
        local endMatches = not endError and tonumber(actualEnd) == expectedEnd
        if startMatches then exactStarts = exactStarts + 1 end
        if endMatches then exactEnds = exactEnds + 1 end
        print(string.format(
            "Source subtitle %d timing: source start=%s duration=%s expected end=%s | actual start=%s end=%s | exact start/end=%s/%s",
            subtitle.sourceIndex, tostring(subtitle.startFrame), tostring(subtitle.duration),
            tostring(expectedEnd), tostring(actualStart), tostring(actualEnd),
            tostring(startMatches), tostring(endMatches)
        ))
    end

    local finalTrackItems = snapshotAppendedTrack(timeline, newTrack)
    local finalTrackRawItems = getTrackItems(timeline, "video", newTrack)
    local initialIdentities = {}
    for _, details in ipairs(initialTrackItems) do initialIdentities[details.identity] = true end
    local newClipCount = 0
    for _, item in ipairs(finalTrackRawItems) do
        if not initialIdentities[tostring(item)] then newClipCount = newClipCount + 1 end
    end
    local failedSources = {}
    for _, subtitle in ipairs(subtitles) do
        if not sourceToCreated[subtitle.sourceIndex] then
            table.insert(failedSources, subtitle)
        end
    end
    print(string.format(
        "New track V%d contains %d new clip(s) for %d subtitle(s).",
        newTrack, newClipCount, #subtitles
    ))
    if newClipCount < #subtitles or #failedSources > 0 then
        print("FAILED subtitle conversion(s):")
        for _, subtitle in ipairs(failedSources) do
            print(string.format(
                "  source subtitle %d: text=%q start=%s duration=%s",
                subtitle.sourceIndex, subtitle.text,
                tostring(subtitle.startFrame), tostring(subtitle.duration)
            ))
        end
        if #failedSources == 0 then
            print("  Track clip count is short although every source was matched to an API result; listing all affected source subtitles for inspection:")
            for _, subtitle in ipairs(subtitles) do
                print(string.format(
                    "  source subtitle %d: text=%q start=%s duration=%s",
                    subtitle.sourceIndex, subtitle.text,
                    tostring(subtitle.startFrame), tostring(subtitle.duration)
                ))
            end
        end
    end

    print("STEP: Verify existing V1 clips")
    local v1Unchanged = reportV1Result(timeline, v1Before)
    print(string.format(
        "CONVERSION SUMMARY | subtitles read=%d | Text+ created=%d | exact starts=%d/%d | exact ends=%d/%d | texts verified=%d/%d | new track=V%d | V1 unchanged=%s",
        #subtitles, newClipCount, exactStarts, #subtitles, exactEnds, #subtitles,
        verifiedTexts, #createdItems,
        newTrack, tostring(v1Unchanged)
    ))
end

local ok, err = pcall(main)
if not ok then print("FAILED: Converter stopped with error: " .. tostring(err)) end
