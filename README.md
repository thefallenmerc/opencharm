# OpenCharm

Open-source macOS screen recorder with polished output: screen + webcam + mic +
system audio, styled canvas (background, padding, rounded corners, shadow),
webcam bubble overlay, and one-toggle noise removal. GPL-3.0. macOS 14+.

An open alternative in the spirit of [Screen Charm](https://screencharm.com).

## Build

    brew install xcodegen swiftformat
    make build     # generates OpenCharm.xcodeproj and builds
    make test      # runs package unit tests

Open `OpenCharm.xcodeproj` (after `make gen`) to run from Xcode.
