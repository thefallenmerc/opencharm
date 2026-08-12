# Manual smoke checklist (run before each release)

Capture cannot run on CI — walk this list on real hardware.

1. Fresh permissions: revoke all three in System Settings, launch. Dock appears;
   clicking any source opens the permission popover; deep links land on the right
   pane; after granting, sources start normally.
2. Launch: dock + live webcam bubble appear with no clicks. Camera/Mic tiles show
   the selected device name (ellipsized). Camera toggle off → bubble hides AND camera
   light turns off; on → live again. The ▾ caret on Camera/Mic opens a device picker
   (switching the camera updates the live bubble). The Settings gear opens frame rate /
   Open Project / Quit.
3. Display + camera + mic + system audio, 60 fps, 10 s with music and speech:
   click Display → countdown → dock morphs to a compact pill (red dot + MM:SS timer);
   clicking the red dot stops, dragging the timer moves the pill; tracks exist, styled
   preview opens on stop (properties in a fixed left sidebar, preview fills the rest),
   mic/system audible, no drift.
4. Window mode on a Safari window; Area mode on a ~800×600 region — the overlay dims
   bluish with the selection area clear and L-brackets at its corners; drag → countdown
   starts immediately: exported dimensions match (even-rounded).
5. Neither the dock, the stop bar, nor the bubble appear anywhere in any
   recording; bubble draggable while recording; dock draggable always, and its
   position persists across relaunch. On a fullscreen app, four-finger-swipe to
   another Space: the bubble follows and the stop bar stays reachable.
6. ✕ hides the dock; menu bar → Show Dock brings it back. Open Project… (menu,
   ⌘O, and dock right-click) opens a chosen .opencharm; bad selection shows an
   error alert.
7. Noise removal toggle: audible hiss reduction; second toggle instant (cache).
8. Auto Zoom: record a full-screen (or Area) clip clicking around a few spots. In
   Studio → Auto Zoom → enable: the preview smoothly zooms toward each click region,
   holds, and eases out; Zoom level / Speed sliders take effect; toggling off returns
   to a static frame. (Window recordings show "no click data" — expected.) Export and
   confirm the zoom is baked into the file.
8b. Timeline editor (below the preview): the playhead scrubs by dragging the ruler/
   track; play/pause and skip-to-ends work; current/total time update. Auto-zoom shows
   as yellow "N×" tags; two clicks in the zoom lane create a manual zoom focused on the
   cursor (preview zooms there); selecting a tag shows a level slider + Delete; dragging
   a tag moves it. Drag the white trim handles / press Cut to shorten the clip — the
   export is shorter and tags still line up. The "100%" slider zooms the timeline; the
   webcam bubble is large by default and roughly halves while a zoom holds.
9. Export Source/1080p/4K in both codecs; files play in QuickTime; the webcam
   overlay fills its circle (no squeeze/stretch); Reveal in Finder works.
10. Kill the app (Force Quit) 5 s into a recording. Relaunch: recovery prompt at
    launch; recovered project opens in the Studio and plays up to ~2 s before the
    kill.
11. Unplug an external webcam mid-recording: recording continues; stop succeeds;
    idle preview resumes on the remaining camera (or hides bubble if none).
12. Save project: record → tweak a zoom → close the Studio → a "Save this project?"
    prompt appears → Save… → pick `~/Desktop/Demo.charmproj` → the file is written and
    the window closes. Menu bar → Open Project… → pick that `.charmproj` → Studio
    restores the project (zooms/trim/webcam/audio). Close it unedited → no prompt.
    Edit again → ⌘S updates the same file (no panel). Quit with an unsaved recording →
    prompt (Cancel keeps the app running).
13. Redesigned Studio chrome (Screen Charm-style): the Studio opens as a dark
    edge-to-edge window — traffic lights over the toolbar, project name + faded
    ".charmproj" centered (an "Edited" dot appears after a change), folder/undo/redo
    icons on the left, New recording + purple Export chips on the right. The left
    icon rail switches General / Cursor / Sound / Camera panels.
14. General panel: camera-layout thumbnails move/hide the bubble; Aspect Ratio chips
    (Auto/16:9/4:3/1:1/9:16) reshape the preview canvas immediately and the export
    matches; wallpaper thumbnails, gradient swatches, color picker, Pick random and
    Upload custom all change the background; Background blur softens it; Playback
    Speed chips change preview tempo (voice pitch preserved) and the export duration
    scales (zooms/trim still line up); Zoom Level sets new/auto zoom magnification.
15. Undo/redo: after several edits, ⌘Z steps back through them one by one (a slider
    drag counts as ONE step), ⇧⌘Z re-applies; the toolbar arrows enable/disable to
    match; timeline zoom edits and Cut are undoable too.
16. Smooth zoom: with auto-zoom on, the zoom-in has no kick at start/end (spring
    settle), rapid nearby clicks cause no jitter, and a far click makes the view
    glide (never snap) with the magnification held — shake-free in preview AND export.
17. Camera panel: Content zoom tightens the face crop inside the bubble; position
    chips move it corner to corner.
