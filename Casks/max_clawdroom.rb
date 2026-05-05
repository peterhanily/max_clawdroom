# Homebrew Cask for max_clawdroom.
#
# This repo IS the tap. Users install with:
#   brew tap peterhanily/max_clawdroom https://github.com/peterhanily/max_clawdroom.git
#   brew install --cask max_clawdroom
#
# Or, one-liner once the tap is installed:
#   brew install --cask peterhanily/max_clawdroom/max_clawdroom
#
# Maintainer note: bump `version` and regenerate `sha256` after every
# release. `shasum -a 256 dist/max_clawdroom-<version>.dmg` produces
# the hash. See RELEASE.md for the full release checklist.
cask "max_clawdroom" do
  version "0.4.0"
  sha256 "0312a10f6f9547f6fae8eb03525e4d9d04dc350d69ed7972d1ea50a88e8c8943"

  url "https://github.com/peterhanily/max_clawdroom/releases/download/v#{version}/max_clawdroom-#{version}.dmg"
  name "max_clawdroom"
  desc "Desktop companion that lives on your Mac and chats via Claude Code"
  homepage "https://maxclawdroom.app"

  # macOS 14 (Sonoma) is the minimum; matches LSMinimumSystemVersion
  # and the SwiftPM platforms list.
  depends_on macos: ">= :sonoma"

  # max_clawdroom uses Sparkle for in-app updates. Let users choose
  # one update mechanism; `auto_updates true` tells Homebrew not to
  # bump the version automatically on brew upgrade.
  auto_updates true

  app "max_clawdroom.app"

  # Matches the "Data deletion" block in PRIVACY.md so
  # `brew uninstall --zap max_clawdroom` wipes the same things.
  zap trash: [
    "~/Library/Application Support/Companion",
    "~/Library/Preferences/com.peterhanily.max_clawdroom.plist",
    "~/Library/Caches/com.peterhanily.max_clawdroom",
    "~/Library/Saved Application State/com.peterhanily.max_clawdroom.savedState",
    "~/Library/HTTPStorages/com.peterhanily.max_clawdroom",
  ]
end
