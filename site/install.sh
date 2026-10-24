#!/bin/sh
# Installs SlideScroll, a scrolling window manager for macOS.
#
#   curl -fsSL https://slidescroll.majnioui.me/install.sh | sh
#
# Downloads the latest release from GitHub, checks it against the release's
# SHA256SUMS, puts SlideScroll.app in /Applications (or ~/Applications when
# /Applications isn't writable) and opens it. Running it again updates.
#
#   SLIDESCROLL_VERSION=0.2.0   install that version instead of the latest
#   SLIDESCROLL_NO_OPEN=1       don't open the app afterwards
#
# Source: https://github.com/majnioui/SlideScroll

# Everything is inside main, called on the last line, so a download cut off
# halfway runs nothing.
main() {
    set -eu
    repo="majnioui/SlideScroll"
    app="SlideScroll.app"

    say() { printf '%s\n' "$*"; }
    fail() { printf 'slidescroll install: %s\n' "$*" >&2; exit 1; }

    [ "$(uname -s)" = "Darwin" ] || fail "SlideScroll runs on macOS only."
    [ "$(uname -m)" = "arm64" ] || fail "SlideScroll needs a Mac with Apple silicon."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "${major}" -ge 13 ] || fail "SlideScroll needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."
    for tool in curl shasum ditto; do
        command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is missing."
    done

    if [ -n "${SLIDESCROLL_VERSION:-}" ]; then
        version="${SLIDESCROLL_VERSION#v}"
    else
        # The latest release's page redirects to its tag, e.g. .../tag/v0.2.0.
        latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest") \
            || fail "couldn't reach GitHub to find the latest release."
        version="${latest##*/v}"
    fi
    case "${version}" in
        *[!0-9.]* | "") fail "couldn't work out which version to install (got \"${version}\")." ;;
    esac

    base="https://github.com/${repo}/releases/download/v${version}"
    zip="SlideScroll-${version}.zip"
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT INT TERM

    say "Downloading SlideScroll ${version}..."
    curl -fsSL --retry 3 -o "${tmp}/${zip}" "${base}/${zip}" || fail "download failed: ${base}/${zip}"
    curl -fsSL --retry 3 -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS" || fail "download failed: ${base}/SHA256SUMS"

    expected=$(awk -v f="${zip}" '$2 == f { print $1 }' "${tmp}/SHA256SUMS")
    actual=$(shasum -a 256 "${tmp}/${zip}" | awk '{ print $1 }')
    [ -n "${expected}" ] || fail "SHA256SUMS has no entry for ${zip}."
    [ "${expected}" = "${actual}" ] || fail "the download doesn't match its checksum; nothing was installed."

    ditto -x -k "${tmp}/${zip}" "${tmp}/unpacked"
    [ -d "${tmp}/unpacked/${app}" ] || fail "the release doesn't contain ${app}."

    dest="/Applications"
    if [ ! -w "${dest}" ]; then
        dest="${HOME}/Applications"
        mkdir -p "${dest}"
    fi

    # Quit a running copy first: quitting puts every window back on screen.
    if pgrep -x slidescroll >/dev/null 2>&1; then
        say "Quitting the running SlideScroll..."
        osascript -e 'tell application "SlideScroll" to quit' >/dev/null 2>&1 || true
        i=0
        while pgrep -x slidescroll >/dev/null 2>&1 && [ "${i}" -lt 20 ]; do
            sleep 0.5
            i=$((i + 1))
        done
    fi

    rm -rf "${dest:?}/${app}"
    ditto "${tmp}/unpacked/${app}" "${dest}/${app}"
    # Downloaded with curl, so macOS hasn't marked it; clear it in case.
    xattr -dr com.apple.quarantine "${dest}/${app}" 2>/dev/null || true

    say "Installed SlideScroll ${version} in ${dest}."
    say "On first launch, allow it in System Settings, Privacy & Security, Accessibility."
    say "After an update, you may need to remove it from that list and allow it again."
    if [ -z "${SLIDESCROLL_NO_OPEN:-}" ]; then
        open "${dest}/${app}"
    fi
}

main "$@"
