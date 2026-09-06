#!/bin/bash
# One-shot publisher, run AFTER the release commit exists: builds a universal
# Nota.app, zips it, tags the version, pushes, opens the GitHub release, and
# bumps the Homebrew tap cask. Every step fails loudly rather than half-do it.
#
#   RELEASE_NOTES=path/to/notes.md ./release.sh   # use these notes instead of generating them
#   TAP_DIR=/path/to/homebrew-nota ./release.sh   # tap checkout, default ~/me/talk/homebrew-nota
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "$(git status --porcelain)" ]; then
    echo "release.sh: working tree is not clean; commit or stash first" >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "release.sh: gh is not logged in; run 'gh auth login' first" >&2
    exit 1
fi

version=$(sed -n 's/.*static let current = "\([0-9][0-9.]*\)".*/\1/p' Sources/Nota/Version.swift)
if [ -z "$version" ]; then
    echo "release.sh: could not read the version from Sources/Nota/Version.swift" >&2
    exit 1
fi
tag="v$version"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if [ "$(git rev-parse "$tag")" != "$(git rev-parse HEAD)" ]; then
        echo "release.sh: tag $tag already exists but does not point at HEAD" >&2
        exit 1
    fi
else
    git tag -a "$tag" -m "Nota v$version"
fi

./build.sh --universal

zip="Nota-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent Nota.app "$zip"
sha256=$(shasum -a 256 "$zip" | awk '{print $1}')
echo "release.sh: $zip  $sha256"

notes_file="${RELEASE_NOTES:-}"
if [ -z "$notes_file" ]; then
    notes_file="$(mktemp -d)/notes.md"
    prev_tag=$(git tag --sort=-v:refname -l 'v*' | grep -v "^$tag\$" | head -1 || true)
    {
        echo "## Install"
        echo
        echo '```sh'
        echo "brew install --cask manfad/nota/nota"
        echo "# or"
        echo "curl --proto '=https' --tlsv1.2 -LsSf https://nota-app.xyz/install.sh | sh"
        echo '```'
        echo
        echo "Or download \`$zip\` from this release directly."
        echo
        echo "## Changes"
        echo
        if [ -n "$prev_tag" ]; then
            git log --format='- %s' "$prev_tag..HEAD"
        else
            git log --format='- %s'
        fi
        echo
        echo "## Gatekeeper"
        echo
        echo "Nota is not notarized yet. If macOS blocks it after a browser or Homebrew"
        echo "download, allow it once under System Settings › Privacy & Security. The curl"
        echo "installer's download isn't quarantined, so it opens straight away."
    } > "$notes_file"
fi

git push origin main --tags

if gh release view "$tag" >/dev/null 2>&1; then
    echo "release.sh: release $tag already exists on GitHub" >&2
    exit 1
fi
release_url=$(gh release create "$tag" "$zip" --title "Nota $version" --notes-file "$notes_file")

TAP_DIR="${TAP_DIR:-$HOME/me/talk/homebrew-nota}"
if git -C "$TAP_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -C "$TAP_DIR" pull --ff-only
fi

mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/nota.rb" <<CASK
cask "nota" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/manfad/Nota/releases/download/v#{version}/Nota-#{version}.zip"
  name "Nota"
  desc "Little native notepad for text files, Markdown, and everything you're reading"
  homepage "https://www.nota-app.xyz/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Nota.app"

  zap trash: [
    "~/Library/Application Support/Nota",
    "~/Library/Preferences/com.manfad.nota.plist",
    "~/Library/Saved Application State/com.manfad.nota.savedState",
  ]

  caveats <<~EOS
    Nota is not notarized yet. If macOS refuses to open it, allow it once
    under System Settings › Privacy & Security, or install with
    --no-quarantine.
  EOS
end
CASK

if [ ! -f "$TAP_DIR/README.md" ]; then
    cat > "$TAP_DIR/README.md" <<'TAPREADME'
# homebrew-nota

Homebrew tap for [Nota](https://github.com/manfad/Nota). Install with `brew install --cask manfad/nota/nota`.
TAPREADME
fi

tap_commit=""
if [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
    git -C "$TAP_DIR" add -A
    git -C "$TAP_DIR" commit -m "nota $version"
    git -C "$TAP_DIR" push origin HEAD:main
    tap_commit=$(git -C "$TAP_DIR" rev-parse --short HEAD)
else
    tap_commit="(nothing changed)"
fi

echo
echo "== Nota $version released =="
echo "tag:          $tag"
echo "zip:          $zip  ($sha256)"
echo "release:      $release_url"
echo "tap commit:   $tap_commit"
