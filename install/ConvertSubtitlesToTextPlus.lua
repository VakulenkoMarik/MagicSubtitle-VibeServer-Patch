local function reportFailure(message)
    print("Convert to Text+: " .. tostring(message))
end

local function isTextPlusName(name)
    local value = string.lower(tostring(name or ""))
    return string.find(value, "text+", 1, true) ~= nil
        or string.find(value, "textplus", 1, true) ~= nil
        or string.find(value, "text plus", 1, true) ~= nil
end

local function findTextPlus(folder, visited)
    local identity = tostring(folder)
    if visited[identity] then return nil end
    visited[identity] = true

    local clips = folder:GetClipList() or {}
    for _, mediaPoolItem in ipairs(clips) do
        local clipType = mediaPoolItem:GetClipProperty("Type")
        if string.lower(tostring(clipType or "")) ~= "timeline"
            and isTextPlusName(mediaPoolItem:GetName())
        then
            return mediaPoolItem
        end
    end

    for _, subfolder in ipairs(folder:GetSubFolderList() or {}) do
        local found = findTextPlus(subfolder, visited)
        if found then return found end
    end
    return nil
end

local function getItems(timeline, trackType, trackIndex)
    local items = timeline:GetItemListInTrack(trackType, trackIndex)
    if items == nil then return {} end
    if type(items) ~= "table" then
        error(string.format(
            "GetItemListInTrack(%s, %d) returned %s",
            trackType, trackIndex, type(items)
        ))
    end
    return items
end

local function timelineItemsFromResult(value, output, visited)
    if value == nil then return end
    local ok, method = pcall(function() return value.GetStart end)
    if ok and type(method) == "function" then
        table.insert(output, value)
        return
    end
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    for _, nested in pairs(value) do
        timelineItemsFromResult(nested, output, visited)
    end
end

local function readTextTool(timelineItem)
    local comp = timelineItem:GetFusionCompByIndex(1)
    if not comp then return nil, "Fusion comp unavailable" end
    local tools = comp:GetToolList(false, "TextPlus")
    if type(tools) ~= "table" then
        return nil, "TextPlus tool list unavailable"
    end
    for _, tool in pairs(tools) do
        return tool
    end
    return nil, "TextPlus tool not found"
end

local function setAndVerifyText(timelineItem, text)
    local textTool, toolError = readTextTool(timelineItem)
    if not textTool then return false, toolError end
    local setResult = textTool:SetInput("StyledText", text)
    if setResult == false then return false, "SetInput returned false" end
    local readback = textTool:GetInput("StyledText")
    return readback == text, "readback=" .. tostring(readback)
end

local function main()
    print("Convert to Text+: finding Text+ in the Media Pool")
    local resolve = Resolve() or resolve
    if not resolve then
        reportFailure("Resolve connection unavailable.")
        return
    end
    local projectManager = resolve:GetProjectManager()
    local project = projectManager and projectManager:GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not project or not timeline then
        reportFailure("Open a project and timeline first.")
        return
    end

    local mediaPool = project:GetMediaPool()
    local root = mediaPool and mediaPool:GetRootFolder()
    local mediaPoolItem = root and findTextPlus(root, {})
    if not mediaPoolItem then
        print("Text+ not found. Drag Text+ from Effects > Titles into the Media Pool, then click Convert to Text+ again.")
        return
    end

    print("Convert to Text+: reading subtitle track 1")
    local subtitleItems = getItems(timeline, "subtitle", 1)
    local subtitles = {}
    local skipped = 0
    for index, item in ipairs(subtitleItems) do
        local text = item:GetName()
        local startFrame = item:GetStart()
        local duration = item:GetDuration()
        if tonumber(duration) and tonumber(duration) <= 0 then
            skipped = skipped + 1
        elseif tonumber(startFrame) and tonumber(duration) then
            table.insert(subtitles, {
                sourceIndex = index,
                text = tostring(text),
                startFrame = startFrame,
                duration = duration,
            })
        else
            skipped = skipped + 1
            print(string.format("Skipped subtitle %d: invalid start or duration.", index))
        end
    end
    print(string.format(
        "Convert to Text+: read %d subtitle(s), skipped %d with duration <= 0 or invalid timing",
        #subtitleItems, skipped
    ))
    if #subtitles == 0 then
        print("Convert to Text+: no valid subtitles; no video track added")
        return
    end

    print("Convert to Text+: adding a new video track")
    local originalTrackCount = timeline:GetTrackCount("video") or 0
    local addResult = timeline:AddTrack("video")
    local newTrack = timeline:GetTrackCount("video") or 0
    if newTrack ~= originalTrackCount + 1 then
        reportFailure("Could not add exactly one video track (AddTrack returned "
            .. tostring(addResult) .. ", track count " .. tostring(newTrack) .. ").")
        return
    end

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

    print(string.format(
        "Convert to Text+: batch appending %d item(s) to V%d",
        #subtitles, newTrack
    ))
    local batchOk, batchResult = pcall(function()
        return mediaPool:AppendToTimeline(appendArguments)
    end)
    local returnedItems = {}
    if batchOk then
        timelineItemsFromResult(batchResult, returnedItems, {})
    else
        print("Convert to Text+: batch append failed: " .. tostring(batchResult))
    end

    local trackItems = getItems(timeline, "video", newTrack)
    local createdById = {}
    for _, item in ipairs(trackItems) do createdById[tostring(item)] = item end
    local createdItems = {}
    local usedItems = {}
    local assigned = {}

    local function associate(item, subtitle)
        local identity = tostring(item)
        if usedItems[identity] then return false end
        usedItems[identity] = true
        createdItems[subtitle.sourceIndex] = item
        assigned[subtitle.sourceIndex] = true
        return true
    end

    for index, item in ipairs(returnedItems) do
        local subtitle = subtitles[index]
        if subtitle and createdById[tostring(item)] then
            associate(item, subtitle)
        end
    end

    for _, item in ipairs(trackItems) do
        if not usedItems[tostring(item)] then
            local actualStart = item:GetStart()
            local actualDuration = item:GetDuration()
            for _, subtitle in ipairs(subtitles) do
                if not assigned[subtitle.sourceIndex]
                    and tonumber(actualStart) == tonumber(subtitle.startFrame)
                    and tonumber(actualDuration) == tonumber(subtitle.duration)
                then
                    associate(item, subtitle)
                    break
                end
            end
        end
    end

    for _, subtitle in ipairs(subtitles) do
        if not assigned[subtitle.sourceIndex] then
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
            local oneItems = {}
            if oneOk then
                timelineItemsFromResult(oneResult, oneItems, {})
            end
            local item = oneItems[1]
            if not item then
                for _, candidate in ipairs(getItems(timeline, "video", newTrack)) do
                    if not usedItems[tostring(candidate)]
                        and tonumber(candidate:GetStart()) == tonumber(subtitle.startFrame)
                        and tonumber(candidate:GetDuration()) == tonumber(subtitle.duration)
                    then
                        item = candidate
                        break
                    end
                end
            end
            if item then
                associate(item, subtitle)
            else
                print(string.format(
                    "Convert to Text+: subtitle %d append failed%s",
                    subtitle.sourceIndex, oneOk and "" or (": " .. tostring(oneResult))
                ))
            end
        end
    end

    print("Convert to Text+: setting and verifying text")
    local textVerified = 0
    local exactStarts = 0
    local exactEnds = 0
    for _, subtitle in ipairs(subtitles) do
        local item = createdItems[subtitle.sourceIndex]
        if item then
            local textOk, textResult, textDetail = pcall(setAndVerifyText, item, subtitle.text)
            if textOk and textResult then
                textVerified = textVerified + 1
            else
                print(string.format(
                    "Convert to Text+: subtitle %d text not verified (%s)",
                    subtitle.sourceIndex, tostring(textOk and textDetail or textResult)
                ))
            end
            local actualStart = item:GetStart()
            local actualEnd = item:GetEnd()
            if tonumber(actualStart) == tonumber(subtitle.startFrame) then
                exactStarts = exactStarts + 1
            end
            if tonumber(actualEnd)
                == tonumber(subtitle.startFrame) + tonumber(subtitle.duration)
            then
                exactEnds = exactEnds + 1
            end
        end
    end

    local finalItems = getItems(timeline, "video", newTrack)
    local createdCount = #finalItems
    local failed = {}
    for _, subtitle in ipairs(subtitles) do
        if not createdItems[subtitle.sourceIndex] then
            table.insert(failed, subtitle)
        end
    end
    if createdCount < #subtitles then
        for _, subtitle in ipairs(failed) do
            print(string.format(
                "Convert to Text+: failed subtitle %d at frame %s (%q)",
                subtitle.sourceIndex, tostring(subtitle.startFrame), subtitle.text
            ))
        end
    end
    print(string.format(
        "Convert to Text+ summary: subtitles=%d, created=%d, skipped=%d, exact starts=%d/%d, exact ends=%d/%d, texts verified=%d/%d, track=V%d",
        #subtitleItems, createdCount, skipped, exactStarts, #subtitles,
        exactEnds, #subtitles, textVerified, #subtitles, newTrack
    ))
end

local ok, err = pcall(main)
if not ok then reportFailure(err) end
