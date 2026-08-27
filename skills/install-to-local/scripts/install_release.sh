#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install_release.sh [options]

Build and package Owl for Apple-silicon macOS, then install the app locally.

Options:
  --project-dir DIR       Owl repository root (default: current directory)
  --derived-data-dir DIR  Xcode derived data directory (default: project/build)
  --install-dir DIR       Application destination (default: /Applications)
  --no-install            Build and package without copying the app to disk
  --no-generate           Use the existing Xcode project without running XcodeGen
  --no-vendor             Skip vendoring libmpv/ffmpeg; the built app falls back
                          to Homebrew mpv/ffmpeg on this Mac at runtime
  --trash-duplicates      Move same-bundle-id copies in other Applications
                          folders to the Trash instead of only warning
  --launch                Open the installed app after copying it
  -h, --help              Show this help
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command '$1'."
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$project_dir" "$1" ;;
  esac
}

real_path() {
  (cd "$1" >/dev/null 2>&1 && pwd -P)
}

bundle_identifier_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Move an app bundle to the Trash without clobbering an existing entry, then
# print the destination.
trash_app() {
  local app="$1" destination
  destination="$HOME/.Trash/$(basename "$app")"
  if [[ -e "$destination" ]]; then
    destination="$destination.$(date +%Y%m%d-%H%M%S)"
  fi
  mv "$app" "$destination" || return 1
  printf '%s\n' "$destination"
}

project_dir="$(pwd -P)"
derived_data_arg=""
install_dir_arg=""
should_install=true
should_generate=true
should_vendor_deps=true
should_launch=false
should_trash_duplicates=false

while (($# > 0)); do
  case "$1" in
    --project-dir)
      (($# >= 2)) || fail "--project-dir requires a directory."
      project_dir="$2"
      shift 2
      ;;
    --derived-data-dir)
      (($# >= 2)) || fail "--derived-data-dir requires a directory."
      derived_data_arg="$2"
      shift 2
      ;;
    --install-dir)
      (($# >= 2)) || fail "--install-dir requires a directory."
      install_dir_arg="$2"
      shift 2
      ;;
    --no-install)
      should_install=false
      shift
      ;;
    --no-generate)
      should_generate=false
      shift
      ;;
    --no-vendor)
      should_vendor_deps=false
      shift
      ;;
    --trash-duplicates)
      should_trash_duplicates=true
      shift
      ;;
    --launch)
      should_launch=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option '$1'. Run with --help for usage."
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This skill requires macOS."
[[ -d "$project_dir" ]] || fail "Project directory does not exist: $project_dir"
project_dir="$(cd "$project_dir" && pwd -P)"

[[ -f "$project_dir/project.yml" ]] || fail "project.yml not found in $project_dir"
[[ -f "$project_dir/Owl.xcodeproj/project.pbxproj" ]] || fail "Owl.xcodeproj not found in $project_dir"

if [[ -n "$derived_data_arg" ]]; then
  derived_data_dir="$(resolve_path "$derived_data_arg")"
else
  derived_data_dir="$project_dir/build"
fi

if [[ -n "$install_dir_arg" ]]; then
  install_dir="$(resolve_path "$install_dir_arg")"
else
  install_dir="/Applications"
fi

[[ "$should_launch" == false || "$should_install" == true ]] || fail "--launch requires installation; remove --no-install."
[[ "$should_trash_duplicates" == false || "$should_install" == true ]] || fail "--trash-duplicates requires installation; remove --no-install."
[[ "$should_trash_duplicates" == false || -n "${HOME:-}" ]] || fail "--trash-duplicates requires HOME to be set."

require_command xcodebuild
require_command ditto

# Before the build, not during it: build settings are resolved when xcodebuild
# starts, so an xcconfig written any later would not be read. Safe to run every
# time — with no key in .env it writes an empty one, which is what a working
# copy without a key should build.
if [[ -x "$project_dir/scripts/write-local-config.sh" ]]; then
  info "Writing Owl/Support/Local.xcconfig from .env"
  "$project_dir/scripts/write-local-config.sh"
fi

if [[ "$should_generate" == true ]]; then
  require_command xcodegen
  info "Regenerating Owl.xcodeproj from project.yml"
  (cd "$project_dir" && xcodegen generate)
fi

if [[ "$should_vendor_deps" == true ]]; then
  info "Vendoring libmpv and ffmpeg so the installed app is self-contained"
  "$project_dir/scripts/bundle-mpv-deps.sh"
else
  printf 'warning: Skipping dependency vendoring (--no-vendor); the installed app will require Homebrew mpv/ffmpeg on this Mac at runtime.\n' >&2
  if command -v brew >/dev/null 2>&1; then
    if brew --prefix mpv >/dev/null 2>&1; then
      info "Found Homebrew mpv"
    else
      printf 'warning: Homebrew mpv is not installed; Owl playback will not work until it is.\n' >&2
    fi
  else
    printf 'warning: Homebrew is not installed; Owl playback requires a libmpv installation.\n' >&2
  fi
fi

xcode_version_line="$(xcodebuild -version 2>/dev/null | sed -n '1p')"
xcode_version_number="${xcode_version_line#Xcode }"
xcode_major="${xcode_version_number%%.*}"
xcode_minor="${xcode_version_number#*.}"
use_legacy_icon=false
if [[ "$xcode_major" == "26" && "$xcode_minor" =~ ^[0-9]+$ ]] && (( xcode_minor >= 5 )) && [[ -d "$project_dir/Assets/owl.icon" ]]; then
  use_legacy_icon=true
  printf 'warning: %s has an Icon Composer build regression; using a generated legacy .icns fallback.\n' "$xcode_version_line" >&2
fi

info "Building Owl Release for macOS arm64"
xcodebuild_args=(
  -project "$project_dir/Owl.xcodeproj" \
  -scheme Owl \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_dir"
)
if [[ "$use_legacy_icon" == true ]]; then
  xcodebuild_args+=(EXCLUDED_SOURCE_FILE_NAMES=owl.icon)
fi
xcodebuild "${xcodebuild_args[@]}" clean build

built_app="$derived_data_dir/Build/Products/Release/Owl.app"
app_executable="$built_app/Contents/MacOS/Owl"
app_info_plist="$built_app/Contents/Info.plist"
[[ -d "$built_app" ]] || fail "Release app was not produced: $built_app"
[[ -x "$app_executable" ]] || fail "Release app executable is missing: $app_executable"
[[ -f "$app_info_plist" ]] || fail "Release app Info.plist is missing: $app_info_plist"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$app_info_plist" >/dev/null || fail "Release app Info.plist is invalid."
fi

package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/owl-release.XXXXXX")"
trap 'rm -rf "$package_tmp_dir"' EXIT

if [[ "$use_legacy_icon" == true ]]; then
  icon_source_image="$project_dir/Assets/owl.icon/owl.png"
  if [[ -f "$icon_source_image" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    info "Embedding a legacy Owl.icns fallback"
    iconset_dir="$package_tmp_dir/Owl.iconset"
    mkdir -p "$iconset_dir"
    for icon_size in 16 32 128 256 512; do
      double_size=$((icon_size * 2))
      sips -z "$icon_size" "$icon_size" "$icon_source_image" --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
      sips -z "$double_size" "$double_size" "$icon_source_image" --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
    done
    mkdir -p "$built_app/Contents/Resources"
    iconutil -c icns "$iconset_dir" -o "$built_app/Contents/Resources/Owl.icns"
    if ! /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Owl.icns" "$app_info_plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Owl.icns" "$app_info_plist" >/dev/null
    fi
    entitlements_path="$derived_data_dir/Build/Intermediates.noindex/Owl.build/Release/Owl.build/Owl.app.xcent"
    if [[ -f "$entitlements_path" ]]; then
      codesign --force --sign - --options runtime --entitlements "$entitlements_path" "$built_app" >/dev/null
    else
      codesign --force --sign - --options runtime "$built_app" >/dev/null
    fi
  else
    printf 'warning: Could not create Owl.icns; the installed app will use the default macOS icon.\n' >&2
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$built_app" >/dev/null 2>&1 || fail "Release app failed code-signature validation."
fi

package_dir="$derived_data_dir/Release"
package_path="$package_dir/Owl.zip"
mkdir -p "$package_dir"

info "Creating Release package"
ditto -c -k --sequesterRsrc --keepParent "$built_app" "$package_tmp_dir/Owl.zip"
mv -f "$package_tmp_dir/Owl.zip" "$package_path"

if [[ "$should_install" == true ]]; then
  mkdir -p "$install_dir" || fail "Cannot create install directory: $install_dir"
  installed_app="$install_dir/Owl.app"
  info "Installing Owl to $installed_app"
  ditto --rsrc --extattr --acl "$built_app" "$installed_app" || \
    fail "Cannot install to $installed_app. Try --install-dir ~/Applications."
  [[ -x "$installed_app/Contents/MacOS/Owl" ]] || fail "Installed app is incomplete: $installed_app"

  # A copy of Owl left in another Applications folder keeps the same bundle
  # identifier, and LaunchServices may resolve that stale copy instead of the one
  # just installed. Opening Owl then silently runs the old build.
  installed_real="$(real_path "$installed_app")"
  installed_identifier="$(bundle_identifier_of "$installed_app")"
  applications_dirs=(/Applications)
  if [[ -n "${HOME:-}" ]]; then
    applications_dirs+=("$HOME/Applications")
  fi
  duplicate_apps=()
  for applications_dir in "${applications_dirs[@]}"; do
    duplicate_app="$applications_dir/Owl.app"
    [[ -d "$duplicate_app" ]] || continue
    duplicate_real="$(real_path "$duplicate_app")"
    [[ -n "$duplicate_real" && "$duplicate_real" != "$installed_real" ]] || continue
    [[ -z "$installed_identifier" || "$(bundle_identifier_of "$duplicate_app")" == "$installed_identifier" ]] || continue
    duplicate_apps+=("$duplicate_real")
  done

  for duplicate_app in "${duplicate_apps[@]+"${duplicate_apps[@]}"}"; do
    if [[ "$should_trash_duplicates" == true ]]; then
      info "Trashing an older Owl copy at $duplicate_app"
      if trashed_app="$(trash_app "$duplicate_app")"; then
        printf 'Moved to %s\n' "$trashed_app"
      else
        printf 'warning: Could not move %s to the Trash; remove it manually or Owl may open that older copy.\n' \
          "$duplicate_app" >&2
      fi
    else
      printf 'warning: Another Owl.app with the same bundle identifier is installed at %s.\n' "$duplicate_app" >&2
      printf 'warning: Opening Owl may launch that copy instead of the build just installed.\n' >&2
      printf 'warning: Re-run with --trash-duplicates, or remove that copy by hand.\n' >&2
    fi
  done

  # Teach LaunchServices about the freshly installed copy. The bundle identifier
  # may stay bound to a previous location until the app is opened once.
  lsregister_tool="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
  if [[ -x "$lsregister_tool" ]]; then
    info "Registering the installed app with LaunchServices"
    "$lsregister_tool" -f -R -trusted "$installed_app" >/dev/null 2>&1 || \
      printf 'warning: Could not register %s with LaunchServices.\n' "$installed_app" >&2
  fi

  if command -v osascript >/dev/null 2>&1 && [[ -n "$installed_identifier" ]]; then
    resolved_app="$(osascript -e "POSIX path of (path to application id \"$installed_identifier\")" 2>/dev/null || true)"
    resolved_app="${resolved_app%/}"
    if [[ -n "$resolved_app" && "$(real_path "$resolved_app")" != "$installed_real" ]]; then
      printf 'warning: LaunchServices still opens %s for %s.\n' "$resolved_app" "$installed_identifier" >&2
      printf 'warning: Remove that copy, then open %s once to rebind it.\n' "$installed_app" >&2
    fi
  fi

  if [[ "$should_launch" == true ]]; then
    require_command open
    info "Opening installed Owl"
    open "$installed_app"
  fi
else
  installed_app="(installation skipped)"
fi

printf '\nRelease build complete.\n'
printf 'Built app: %s\n' "$built_app"
printf 'Package: %s\n' "$package_path"
printf 'Installed app: %s\n' "$installed_app"
