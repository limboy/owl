# Owl

A native SwiftUI video player for macOS 26+ on Apple silicon, built on
`libmpv`. It plays nearly anything — MKV, MP4, MOV, AVI, WebM, 4K HDR — with
hardware acceleration, and needs no Homebrew to run.

![](Assets/screenshots/screenshot1.jpg)
![](Assets/screenshots/screenshot2.jpg)

## Download

Get the signed, notarized DMG from
[GitHub Releases](https://github.com/limboy/owl/releases/latest). Owl updates
itself through [Sparkle](https://sparkle-project.org).

## Features

- **Folder library** — add folders and browse them as a grid of thumbnails;
  they are watched for changes. Search a folder by file name or matched title
  (`⌘F`), and sort it by name, date added, or recently watched.
- **Metadata sync** — match videos against
  [The Movie Database](https://www.themoviedb.org) for titles, descriptions,
  and artwork. On by default; switch it off from the Options menu.
- **Resume anywhere** — every file keeps its position and watched state; cards
  show progress at a glance.
- **Player windows** — each video plays in its own window, sized to the video,
  with Liquid Glass controls that hide when you stop moving. Pin a window to
  keep it on top.
- **Finder previews** — bundled Quick Look extensions provide video thumbnails
  and a QuickTime-style Space-bar player for registered video formats,
  including MKV and WebM.
- **Timeline previews** — hover the timeline to see frames, in any format.
- **Subtitles that stay put** — embedded or sidecar tracks, Dual Subtitles, and
  per-file track and delay remembered. Sidecar files are found even when
  named for another release.
- **Live Text** — select, copy, and translate text in a paused frame,
  subtitles included.
- **Screenshots** — save the frame at the video's full size to your screenshot
  folder, with or without the subtitles (Playback ▸ Include Subtitles in
  Screenshots).
- Audio track selection, speed from 0.5× to 2×, chapters, Open Recent, Now
  Playing, and media keys.

## Finder previews

Install Owl in Applications and launch it once so macOS can register its
Quick Look extensions. If needed, enable **Owl Preview** and **Owl Thumbnail**
in System Settings → General → Login Items & Extensions → Quick Look.
Finder’s View Options must have **Show icon preview** enabled for thumbnails.
These extensions work independently of which app is the default video player;
macOS chooses between installed providers for a given file type.

The preview opens sized to the video and starts playing, with a QuickTime-style
glass bar for play/pause, seeking, and volume that fades out during playback;
click the picture to play or pause. Frames are software-rendered at up to 1280 pixels on
the long edge and 30 updates per second to work inside Finder’s remote view.
Full-resolution/HDR playback remains in Owl. The extensions load the runtime
from Owl’s bundle, which their sandbox can only read in `/Applications`.
Files without a decodable video stream cannot produce a video thumbnail.
The extension sandbox grants access to the selected file, so adjacent external
subtitles are not loaded. Closing the preview stops its decoder.

Development builds also require `scripts/bundle-mpv-deps.sh`: Finder extensions
use the bundled runtime rather than a user's Homebrew installation.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Space` | Play or pause |
| `←` / `→` | Seek 10 seconds back / forward |
| `↑` / `↓` | Volume up / down 5% |
| `Page Up` / `Page Down` | Previous / next chapter |
| `Z` / `⇧Z` | Subtitles 0.25s earlier / later |
| `J` | Next subtitle track, then off |
| `O` | Show the position |
| `S` | Take a screenshot |
| `⌃⌘F` | Toggle full screen |

## Build

Requires Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
Homebrew `mpv` and `ffmpeg` on the build machine.

```sh
brew install mpv ffmpeg
xcodegen generate
./scripts/bundle-mpv-deps.sh   # vendor libmpv/ffmpeg into deps/ (optional for debug)
xcodebuild -project Owl.xcodeproj -scheme Owl -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
```

The app lands in `build/Build/Products/Release/Owl.app`. Without `deps/`, a
build loads `libmpv` and `ffmpeg` from Homebrew at runtime; override the paths
with `OWL_LIBMPV_PATH`, `OWL_FFMPEG_PATH`, or `OWL_MPV_PATH`.

To enable metadata sync, add a TMDB key and regenerate the local config:

```sh
echo 'TMDB_API_KEY=<your key>' >> .env
scripts/write-local-config.sh
```

## Releasing

`scripts/release.sh` builds, signs, notarizes, and publishes a GitHub Release
(credentials in [`.env.example`](.env.example)); pushing a `vX.Y.Z` tag does the
same in CI. Release notes come from [`CHANGELOG.md`](CHANGELOG.md).

## License

[GPLv3](LICENSE), because Owl bundles GPL-licensed builds of `libmpv` and
`ffmpeg`.
