"""The architecture this checkout builds for.

Cargo compiles the renderer for the build host and the app links that build
statically, so an app and its renderer always carry one architecture and a
release cannot be universal. Everything that names an architecture in a file
name, a requirement line or a build setting asks this module, so the published
image, the manifest and the in-app updater cannot disagree.
"""
from __future__ import annotations

import platform

# `platform.machine()` is the interpreter's architecture, which on macOS is the
# host's: "arm64" on Apple silicon and "x86_64" on Intel.
ARCHITECTURE = platform.machine()

# How each architecture is named to a user.
DISPLAY_NAMES = {"arm64": "Apple silicon (arm64)", "x86_64": "Intel (x86_64)"}


def display_name(architecture=None):
    """A readable name for an architecture, e.g. in a release requirement line."""
    architecture = architecture or ARCHITECTURE
    return DISPLAY_NAMES.get(architecture, architecture)
