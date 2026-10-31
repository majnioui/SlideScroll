# Homebrew formula: builds SlideScroll from source.
#
#   brew tap majnioui/slidescroll https://github.com/majnioui/SlideScroll
#   brew install slidescroll
#
# Swift comes with the Command Line Tools, which Homebrew already needs.
# Each release updates `url` and `sha256` (the sha256 of the tag's source
# tarball).
class Slidescroll < Formula
  desc "Scrolling window manager for macOS"
  homepage "https://slidescroll.majnioui.me"
  url "https://github.com/majnioui/SlideScroll/archive/refs/tags/v0.3.1.tar.gz"
  sha256 "373411341bc50a7298496917f4160889eff305ccefa4178d2a22a65edb1cead7"
  license "MIT"
  head "https://github.com/majnioui/SlideScroll.git", branch: "main"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    # SwiftPM can't start its own sandbox inside Homebrew's.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/bundle.sh"
    prefix.install "build/SlideScroll.app"
  end

  def caveats
    <<~EOS
      To find SlideScroll in Launchpad and Spotlight, link it into Applications:
        ln -sf #{opt_prefix}/SlideScroll.app /Applications/SlideScroll.app

      Open it, then allow it in System Settings → Privacy & Security →
      Accessibility. A build from source has a new signature each time, so
      after `brew upgrade slidescroll`, remove SlideScroll from that list and
      allow it again.

      SlideScroll leaves updating to Homebrew when it's installed this way.
    EOS
  end

  test do
    assert_path_exists prefix/"SlideScroll.app/Contents/MacOS/slidescroll"
  end
end
