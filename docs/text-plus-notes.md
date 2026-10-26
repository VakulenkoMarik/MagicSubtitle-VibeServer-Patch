# Text+ Converter Notes

These findings are based only on the test results reported in this conversation.

## Works

- A Text+ item manually dragged into the Media Pool is reported as Type `Fusion Title`.
- `mediaPool:AppendToTimeline` places it on the chosen new video track using:

  ```lua
  {
      mediaPoolItem = item,
      startFrame = 0,
      endFrame = duration,
      recordFrame = start,
      trackIndex = newTrack,
  }
  ```

- Batch append works. The test reported exact start, end, and duration—including a clip longer than the default 150 frames—placement on the chosen new track, and no changes to existing V1 clips.
- Text can be set through the `TextPlus` tool's `StyledText` input in the clip's Fusion comp, then verified by reading the input back.
- Subtitle track 1 is readable with `timeline:GetItemListInTrack("subtitle", 1)` and each item's `GetName`, `GetStart`, and `GetDuration`. These are absolute frames; the reported timeline start frame was `108000` at 30 fps.
- Recursive Media Pool search must skip items whose Type is `Timeline`.

## Does Not Work

- `InsertFusionTitleIntoTimeline` splits clips, pushes tails to the right, ignores other tracks being disabled, always lands on V1, and provides no duration control.
- `SetProperty("Duration", ...)` and `SetProperty("End", ...)` return `false`.
- The FCPXML route cannot export or import Fusion Titles as Text+ in Resolve.

## Backlog

- Automatically add Text+ to the Media Pool; currently, the user must drag it in manually.
- Carry subtitle-track styling and position over to Text+.
- Clean up logs in the main script.
- Guard against an empty audio track.
- Clamp subtitles that fall outside the timeline.
- Set up the WAV codec manually instead of relying on the Audio Only preset.
