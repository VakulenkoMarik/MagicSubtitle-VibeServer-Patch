local function reportFailure(message)
    print("Convert to Text+: " .. tostring(message))
end

local function findTemplates(folder, templateName, visited, matches, fusionTitleNames)
    local identity = tostring(folder)
    if visited[identity] then return nil end
    visited[identity] = true

    local clips = folder:GetClipList() or {}
    for _, mediaPoolItem in ipairs(clips) do
        local clipType = mediaPoolItem:GetClipProperty("Type")
        if clipType == "Fusion Title" then
            local name = mediaPoolItem:GetName()
            table.insert(fusionTitleNames, tostring(name or ""))
            if name == templateName then
                table.insert(matches, mediaPoolItem)
            end
        end
    end

    for _, subfolder in ipairs(folder:GetSubFolderList() or {}) do
        findTemplates(subfolder, templateName, visited, matches, fusionTitleNames)
    end
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

    local templateName = tostring(
        tool and tool.TemplateName and tool.TemplateName[0] or "Text+"
    )
    local mediaPool = project:GetMediaPool()
    local root = mediaPool and mediaPool:GetRootFolder()
    local matches = {}
    local fusionTitleNames = {}
    if root then
        findTemplates(root, templateName, {}, matches, fusionTitleNames)
    end
    if #matches == 0 then
        local names = {}
        for index = 1, math.min(5, #fusionTitleNames) do
            table.insert(names, fusionTitleNames[index])
        end
        print(string.format(
            'Template "%s" not found. Fusion Titles in Media Pool: %s',
            templateName,
            #names > 0 and table.concat(names, ", ") or "none"
        ))
        return
    end
    local mediaPoolItem = matches[1]
    if #matches > 1 then
        print(string.format(
            'Found %d Fusion Title items named "%s"; using the first.',
            #matches, templateName
        ))
    end
    print("Template: " .. templateName)

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

    local function appendSubtitle(subtitle)
        return pcall(function()
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
    end

    print(string.format(
        "Convert to Text+: appending verification item to V%d",
        newTrack
    ))
    local firstOk, firstResult = appendSubtitle(subtitles[1])
    local firstReturnedItems = {}
    if firstOk then
        timelineItemsFromResult(firstResult, firstReturnedItems, {})
    else
        print("Convert to Text+: verification append failed: " .. tostring(firstResult))
    end
    local verificationTrackItems = getItems(timeline, "video", newTrack)
    local firstItem
    local firstReturnedItem = firstReturnedItems[1]
    if firstReturnedItem then
        for _, candidate in ipairs(verificationTrackItems) do
            if tostring(candidate) == tostring(firstReturnedItem) then
                firstItem = candidate
                break
            end
        end
    end
    if not firstItem then
        for _, candidate in ipairs(verificationTrackItems) do
            if tonumber(candidate:GetStart()) == tonumber(subtitles[1].startFrame)
                and tonumber(candidate:GetDuration()) == tonumber(subtitles[1].duration)
            then
                firstItem = candidate
                break
            end
        end
    end
    if not firstItem then
        reportFailure("Could not verify the first appended clip; delete the new V"
            .. tostring(newTrack) .. " track.")
        return
    end

    local verificationOk, textTool = pcall(readTextTool, firstItem)
    if not verificationOk or not textTool then
        print('The chosen item "' .. templateName .. '" is not a Text+ template.')
        local itemIdentity = tostring(firstItem)
        local deleteOk = pcall(function()
            return timeline:DeleteClips({ firstItem }, false)
        end)
        local clipRemains = false
        for _, item in ipairs(getItems(timeline, "video", newTrack)) do
            if tostring(item) == itemIdentity then
                clipRemains = true
                break
            end
        end
        if deleteOk and not clipRemains then
            print("Removed the verification clip from V" .. tostring(newTrack) .. ".")
        else
            print("Please delete the new V" .. tostring(newTrack)
                .. " track; the verification clip could not be removed safely.")
        end
        return
    end

    local returnedItems = { firstItem }
    if #subtitles > 1 then
        local appendArguments = {}
        for index = 2, #subtitles do
            local subtitle = subtitles[index]
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
            #appendArguments, newTrack
        ))
        local batchOk, batchResult = pcall(function()
            return mediaPool:AppendToTimeline(appendArguments)
        end)
        if batchOk then
            timelineItemsFromResult(batchResult, returnedItems, {})
        else
            print("Convert to Text+: batch append failed: " .. tostring(batchResult))
        end
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
