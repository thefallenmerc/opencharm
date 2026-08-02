# Manual smoke checklist (run before each release)

Capture cannot run on CI — walk this list on real hardware.

1. Fresh permissions: revoke all three in System Settings, launch. Dock appears;
   clicking any source opens the permission popover; deep links land on the right
   pane; after granting, sources start normally.
2. Launch: dock + live webcam bubble appear with no clicks. Camera/Mic tiles show
   the selected device name (ellipsized). Camera toggle off → bubble hides AND camera
   light turns off; on → live again. Right-click Camera/Mic to switch devices. The
   Settings gear opens frame rate / Open Project / Quit.
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
8. Export Source/1080p/4K in both codecs; files play in QuickTime; the webcam
   overlay fills its circle (no squeeze/stretch); Reveal in Finder works.
9. Kill the app (Force Quit) 5 s into a recording. Relaunch: recovery prompt at
   launch; recovered project opens in the Studio and plays up to ~2 s before the
   kill.
10. Unplug an external webcam mid-recording: recording continues; stop succeeds;
    idle preview resumes on the remaining camera (or hides bubble if none).
