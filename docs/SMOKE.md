# Manual smoke checklist (run before each release)

Capture cannot run on CI — walk this list on real hardware.

1. Fresh permissions: revoke all three in System Settings, launch, panel shows
   onboarding rows, deep links land on the right pane.
2. Full-screen + webcam + mic + system audio, 60 fps, 10 s with music playing
   and speech: tracks exist, styled preview plays, mic/system audible, no drift
   between cursor motion on screen and click sounds.
3. Window mode on a Safari window; area mode on a ~800×600 region: exported
   dimensions match (even-rounded).
4. Self-view bubble never appears in the recording; bubble draggable while recording.
5. Noise removal toggle: audible hiss reduction; second toggle instant (cache).
6. Export Source/1080p/4K in both codecs; files play in QuickTime; canvas aspect
   preserved; Reveal in Finder works.
7. Kill the app (Activity Monitor → Force Quit) 5 s into a recording. Relaunch:
   recovery prompt appears; recovered project opens and plays everything up to
   ~2 s before the kill.
8. Unplug an external webcam mid-recording: recording continues; stop succeeds;
   bubble simply ends in the preview.
9. Reopen a day-old project via ⌘O: settings restored exactly, re-export works.
