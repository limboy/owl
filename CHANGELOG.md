# Changelog

## [Unreleased]

## [1.0.2] - 2026-08-27
- Improve contrast and visibility of the video player controls and scrubber
- Adjust grid item size and subtitle font in the library browser for improved spacing and readability
- Remove redundant fullscreen player overlay toggle from controls
- Update playback speed menu icon to a gauge and remove hover tooltips in video list

## [1.0.1] - 2026-08-27
- Improve reliability of local installation and app replacement

## [1.0.0] - 2026-08-27
- Add optional metadata sync with TMDB, displaying matched titles, descriptions, and poster artwork
- Cache parsed video metadata and folder cover images across launches to speed up library loading
- Mark videos as watched or unwatched directly from the browser, with watched badges and progress indicators
- Adapt the user interface to follow macOS light and dark appearance modes
- Move playback options (shuffle, repeat) and layout picker to the window toolbar
- Add "Show in Finder" context menu action for library root folders
- Expand the video player to fill the window and automatically hide the toolbar during playback
- Automatically select and focus newly added folders in the sidebar

## [0.3.2] - 2026-08-11
- Add Increase/Decrease/Reset Subtitle Delay to the subtitle menu, with a HUD showing the current delay; the chosen delay is remembered per file and reapplied when it's reopened

## [0.3.1] - 2026-08-07
- Remove the "Owl" text from the main window's title bar
- Give video and folder rows in the browser the same height, and add a video icon to video entries

## [0.3.0] - 2026-08-07
- The app is now called Owl. It installs alongside an existing MVPlayer rather than replacing it, so remove the old app by hand; to keep your library and playback progress, move `~/Library/Application Support/MVPlayer` to `~/Library/Application Support/Owl`.
- Remove support for playing standalone audio files (mp3, flac, wav, etc.); only video containers are accepted now. Embedded audio-track selection for videos is unaffected.
- New app icon.
- Fix the folder list jumping on the first click while browsing inside a folder.

## [0.2.5] - 2026-08-06
- Enlarge the clickable area of the back button in the folder browser, making it easier to tap

## [0.2.4] - 2026-08-05
- The mouse cursor now hides automatically after a moment of inactivity in full screen, matching the playback controls

## [0.2.3] - 2026-08-05
- When leaving full screen, a click-to-return prompt now appears immediately instead of waiting for the screen transition to finish

## [0.2.2] - 2026-08-05
- Lower the minimum window width so the player can be resized narrower (480pt instead of 560pt)

## [0.2.1] - 2026-08-04
- The video list now automatically scrolls to keep the currently playing file in view
- Folders in the library root now show a folder icon
- The current folder's path moved from the sidebar into the status bar

## [0.2.0] - 2026-08-04
- Add support for playing audio files
- Automatically advance to the next file when playback ends naturally
- Restart the current video from the beginning instead of only skipping back within the first 3 seconds played
- Fix losing the highlighted selection when navigating back, and simplify the empty-state placeholder text

## [0.1.2] - 2026-08-04
- Fix Previous/Next sometimes not responding and losing the highlighted selection

## [0.1.1] - 2026-08-04
- Add playback speed control, with presets from 0.5x to 2x
- Repeat button in a single-video window now toggles repeat on/off directly,
  instead of cycling through an all/one distinction that didn't apply

## [0.1.0] - 2026-08-04
- First tagged release, distributed as a signed and notarized DMG on GitHub
  Releases with Sparkle auto-update
- Folder-based library with filesystem watching, plus single-file playback
  in its own window
- Playback progress kept per file and shared across windows
- Timeline scrubbing with hover frame previews, generated via AVFoundation,
  Homebrew ffmpeg, or mpv depending on the container
- Embedded subtitle and audio track selection, plus external subtitle loading
- Queue controls: previous, next, shuffle, repeat all, repeat one
- Full screen playback, Now Playing integration, and media-key/remote controls
- Broad local video support through a bundled libmpv/ffmpeg runtime, so the
  app runs without Homebrew installed
