#!/usr/bin/env python3
"""Write the update manifest the in-app updater reads instead of the GitHub API.

Anonymous GitHub API requests are limited to 60 an hour per public IP address, shared
by every app and device behind it, so a busy network can leave the updater locked out.
A release asset is not an API request: the app fetches
`https://github.com/<repository>/releases/latest/download/WallpaperMachine-update.json`,
which github.com redirects to this file on the release marked Latest.

The manifest is the release object in the REST API's shape (`tag_name`, `html_url`,
`prerelease`, `body`, `assets` with `browser_download_url`, `size` and a `sha256:`
`digest`), so the app parses both with `GitHubReleaseParser`. Everything in it is
derived from the tag, the notes file that becomes the release body and the image bytes;
the name is `AppUpdateConfiguration.manifestName` in the app.

    python3 scripts/update_manifest.py --tag v1.0.3 --repository owner/name --notes notes.md \\
        WallpaperMachine-1.0.3-<architecture>.dmg

Called by .github/workflows/build.yml before publishing; writes the manifest beside the
image and prints its path. The architecture in the name is the build host's: a renderer
is built for the Mac that builds it, so an image carries exactly one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from lib.dmg import image_name
from lib.glyphs import markers

MARK = markers()
MANIFEST_NAME = "WallpaperMachine-update.json"
VERSION_TAG = re.compile(r"^v(\d+\.\d+\.\d+)$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class ManifestError(Exception):
    """A condition that stops writing the manifest; the message is the whole report."""


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(tag, repository, notes, image):
    """The manifest for one release, as a dict ready for JSON."""
    match = VERSION_TAG.match(tag)
    if not match:
        raise ManifestError(f"{tag!r} is not a release tag like v1.2.3.")
    if not REPOSITORY.match(repository):
        raise ManifestError(f"{repository!r} is not an owner/name repository.")
    image = Path(image)
    expected = image_name(match.group(1))
    if image.name != expected:
        raise ManifestError(f"{image.name} is not {expected}, the image the updater installs for {tag}.")
    base = f"https://github.com/{repository}/releases"
    return {
        "tag_name": tag,
        "html_url": f"{base}/tag/{tag}",
        "prerelease": False,
        "body": Path(notes).read_text(encoding="utf-8"),
        "assets": [{
            "name": image.name,
            "browser_download_url": f"{base}/download/{tag}/{image.name}",
            "size": image.stat().st_size,
            "digest": f"sha256:{sha256(image)}",
        }],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="Version tag the release belongs to, like v1.2.3.")
    parser.add_argument("--repository", required=True, help="owner/name of the repository the release is in.")
    parser.add_argument("--notes", required=True, help="Markdown file that becomes the release body.")
    parser.add_argument("image", help="The disk image the release publishes.")
    args = parser.parse_args(argv)
    for path in (args.notes, args.image):
        if not Path(path).is_file():
            raise ManifestError(f"Not a file: {path}")
    output = Path(args.image).with_name(MANIFEST_NAME)
    content = manifest(args.tag, args.repository, args.notes, args.image)
    output.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)
    print(f"{MARK.ok} {output.name} for {args.tag}: {content['assets'][0]['digest']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
