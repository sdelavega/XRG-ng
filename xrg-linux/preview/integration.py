#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Optional per-user desktop integration. Application settings are never touched."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

APP_ID = "com.sdelavega.xrg-ng"
MARKER = ".xrg-ng-install.json"
BUNDLE = Path(__file__).resolve().parent


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected symbolic link in application tree: {path}")
        if path.is_file() and path != directory / MARKER:
            result[str(path.relative_to(directory))] = digest(path)
        elif not path.is_file() and not path.is_dir():
            raise ValueError(f"Unexpected special file: {path}")
    return result


def locations(prefix):
    return {
        "launcher": prefix / "bin/xrg-ng-linux",
        "desktop": prefix / f"share/applications/{APP_ID}.desktop",
        "icon": prefix / f"share/icons/hicolor/scalable/apps/{APP_ID}.svg",
    }


def owned_install(app, prefix):
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"Refusing to replace an unowned application path: {app}")
    marker = app / MARKER
    if marker.is_symlink():
        raise ValueError("Installation marker must be a regular file")
    record = json.loads(marker.read_text())
    if (record.get("format") != "xrg-ng-install" or record.get("version") != 1
            or record.get("prefix") != str(prefix)):
        raise ValueError(f"Unrecognized installation marker: {marker}")
    if record.get("files") != inventory(app):
        raise ValueError("Installed application files have changed; preserving them")
    for key, path in locations(prefix).items():
        expected = record["integration"][key]
        if key == "launcher":
            valid = path.is_symlink() and os.readlink(path) == expected
        else:
            valid = path.is_file() and not path.is_symlink() and digest(path) == expected
        if not valid:
            raise ValueError(f"Desktop integration has changed; preserving {path}")
    return record


def desktop_quote(value):
    # Desktop string unescaping happens before Exec argument unescaping.
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("The installation path cannot contain control characters")
    escaped = "".join("\\" + c if c in '\\"`$' else c for c in value)
    return '"' + escaped.replace("\\", "\\\\").replace("%", "%%") + '"'


def replace_file(path, content):
    fd, name = tempfile.mkstemp(prefix=".xrg-ng-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def refresh(prefix):
    executable = shutil.which("update-desktop-database")
    if executable:
        subprocess.run([executable, str(prefix / "share/applications")], check=False)


def install(prefix):
    app = prefix / "lib/xrg-ng"
    paths = locations(prefix)
    desktop = (BUNDLE / f"share/applications/{APP_ID}.desktop").read_text()
    # GIO checks the executable before expanding %% field codes. Keep that
    # executable fixed, passing the launcher as a quoted script argument so an
    # installation directory containing a literal percent sign still launches.
    desktop = desktop.replace("Exec=xrg-ng-linux", "Exec=/bin/sh " + desktop_quote(str(app / "xrg-ng-linux")))
    contents = {
        "desktop": desktop.encode(),
        "icon": (BUNDLE / f"share/icons/hicolor/scalable/apps/{APP_ID}.svg").read_bytes(),
    }
    if app.exists() or app.is_symlink():
        owned_install(app, prefix)
    else:
        for path in paths.values():
            if path.exists() or path.is_symlink():
                raise ValueError(f"Refusing to overwrite an existing file: {path}")
    if BUNDLE == app or app in BUNDLE.parents or BUNDLE in app.parents:
        raise ValueError("Install from an extracted archive outside the installation directory")
    for path in [app, *paths.values()]:
        path.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".xrg-ng-stage-", dir=app.parent))
    backup = staging / "previous"
    prepared = staging / "application"
    originals = {}
    for key, path in paths.items():
        if path.is_symlink():
            originals[key] = ("link", os.readlink(path))
        elif path.exists():
            originals[key] = ("file", path.read_bytes())
    replaced = []
    activated = False
    successful = False
    try:
        shutil.copytree(BUNDLE, prepared)
        # A source archive is required in every binary bundle, including installs.
        manifest = json.loads((prepared / "manifest.json").read_text())
        actual = inventory(prepared)
        if {k: v for k, v in actual.items() if k != "manifest.json"} != manifest["files"]:
            raise ValueError("Archive contents do not match the package manifest")
        record = {
            "format": "xrg-ng-install", "version": 1, "prefix": str(prefix), "files": actual,
            "integration": {key: hashlib.sha256(value).hexdigest() for key, value in contents.items()},
        }
        record["integration"]["launcher"] = str(app / "xrg-ng-linux")
        (prepared / MARKER).write_text(json.dumps(record, indent=2) + "\n")
        if app.exists():
            os.replace(app, backup)
        os.replace(prepared, app)
        activated = True
        for key, path in paths.items():
            if key == "launcher":
                link = staging / "launcher"
                link.symlink_to(app / "xrg-ng-linux")
                os.replace(link, path)
            else:
                replace_file(path, contents[key])
            replaced.append(key)
        successful = True
    except BaseException:
        for key in reversed(replaced):
            path = paths[key]
            previous = originals.get(key)
            if previous is None:
                path.unlink(missing_ok=True)
            elif previous[0] == "file":
                replace_file(path, previous[1])
            else:
                path.unlink(missing_ok=True)
                path.symlink_to(previous[1])
        if activated:
            shutil.rmtree(app)
        if backup.exists():
            os.replace(backup, app)
        raise
    finally:
        # Preserve the previous installation if a rollback itself cannot finish.
        if successful or not backup.exists():
            shutil.rmtree(staging)
        else:
            print(f"Previous installation preserved at {backup}", file=sys.stderr)
    refresh(prefix)
    print(f"Installed XRG-ng Preview in {app}")
    print(f"Launch: {paths['launcher']}")
    if str(prefix / "bin") not in os.environ.get("PATH", "").split(os.pathsep):
        print(f"Add {prefix / 'bin'} to PATH to use xrg-ng-linux from a terminal.")


def uninstall(prefix):
    app = prefix / "lib/xrg-ng"
    owned_install(app, prefix)
    for path in locations(prefix).values():
        path.unlink()
    shutil.rmtree(app)
    refresh(prefix)
    print("Uninstalled XRG-ng Preview. Saved settings and legacy applications were preserved.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local")
    args = parser.parse_args()
    if not args.prefix.is_absolute():
        parser.error("--prefix must be an absolute path")
    prefix = args.prefix.resolve()
    desktop_quote(str(prefix))
    if args.action == "install":
        install(prefix)
    else:
        uninstall(prefix)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"XRG-ng integration: {error}", file=sys.stderr)
        sys.exit(1)
