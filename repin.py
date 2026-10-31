#!/usr/bin/env python3
"""Re-pin byte counts and SHA-256 values after editing files in the checkout.

Usage: repin.py [--check]

Three layers pin each other: lock files (any pinned JSON file in a component)
pin assembled paths in rows holding "path", "bytes" and "sha256"; each
component.yaml pins its files; manifest.yaml pins each component.yaml. Custom
package PKGBUILDs repeat their inputs' SHA-256 values in sha256sums, which
are rewritten from those pins in source=() order. This updates every layer,
in that order, for every pinned file present in the checkout,
and repeats until nothing changes, since a lock can pin another lock. Files
absent from the checkout (fetched inputs and ones built from the owner's
firmware) keep their pins and are listed. With --check nothing is written
and the exit status is 1 when any pin is stale.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

COLLECTION = Path(__file__).resolve().parent


def dump(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def source_names(pkgbuild_text):
    """Return the file name makepkg uses for each source=() entry, by sourcing the PKGBUILD in bash."""
    script = 'source /dev/stdin && printf "%s\\0" "${source[@]}"'
    result = subprocess.run(["bash", "-c", script], input=pkgbuild_text, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("bash could not source a PKGBUILD:\n" + result.stderr)
    return [s.split("::", 1)[0] if "::" in s else s.rsplit("/", 1)[-1]
            for s in result.stdout.split("\0")[:-1]]


class Checkout:
    def __init__(self, root):
        self.root = root
        self.manifest = json.loads((root / "manifest.yaml").read_bytes())
        self.components = {}
        self.sources = {}
        for entry in self.manifest["components"]:
            path = root / entry["manifest"]
            component = json.loads(path.read_bytes())
            self.components[entry["manifest"]] = component
            for row in component.get("files", []):
                self.sources[row["destination"]] = path.parent / row["source"]
        self.pending = {}

    def text(self, path):
        return self.pending[path] if path in self.pending else path.read_bytes()

    def current(self, path):
        data = self.text(path)
        return len(data), hashlib.sha256(data).hexdigest()

    def present(self, destination):
        path = self.sources.get(destination)
        return path if path is not None and (path in self.pending or path.is_file()) else None

    def stage(self, path, value, changes, label):
        data = dump(value)
        if data != self.text(path):
            self.pending[path] = data
            changes.append(label)

    def locks(self, changes):
        for destination, path in sorted(self.sources.items()):
            if not destination.endswith(".json") or self.present(destination) is None:
                continue
            try:
                value = json.loads(self.text(path))
            except ValueError:
                continue
            if self.text(path) != dump(value):
                continue  # not in the indent-2 layout this tool writes; leave it alone
            touched = []

            def refresh(target, node):
                if isinstance(target, str) and isinstance(node, dict) and {"bytes", "sha256"} <= node.keys():
                    source = self.present(target)
                    if source is not None and source != path:
                        size, digest = self.current(source)
                        if (node["bytes"], node["sha256"]) != (size, digest):
                            node["bytes"], node["sha256"] = size, digest
                            touched.append(target)

            def walk(node):
                if isinstance(node, dict):
                    refresh(node.get("path"), node)
                    for key, child in node.items():
                        refresh(key, child)  # {"packages/x/PKGBUILD": {"bytes": ..., "sha256": ...}}
                        walk(child)
                elif isinstance(node, list):
                    for child in node:
                        walk(child)

            walk(value)
            if touched:
                self.stage(path, value, changes, f"{destination}: " + ", ".join(sorted(set(touched))))

    def pkgbuilds(self, changes):
        """Rewrite each custom package's sha256sums from its inputs.json artifacts and recipe pins."""
        lock_path = self.present("locks/packages.json")
        if lock_path is None:
            return
        lock = json.loads(self.text(lock_path))
        artifacts = {row["id"]: row for row in lock["artifacts"]}
        for name in lock.get("additional_locks", []):
            other = self.present(name)
            if other is not None:
                artifacts.update({row["id"]: row for row in json.loads(self.text(other))["artifacts"]})
        for package in lock["packages"]:
            if package.get("kind") != "custom":
                continue
            recipe = package["recipe"]
            pkgbuild, spec = self.present(recipe + "/PKGBUILD"), self.present(recipe + "/inputs.json")
            if pkgbuild is None or spec is None:
                continue
            expected = {entry["filename"]: artifacts[entry["artifact_id"]]["sha256"]
                        for entry in json.loads(self.text(spec))["inputs"]}
            for file in package.get("recipe_files", {}):
                base = file.rsplit("/", 1)[-1]
                if base not in ("PKGBUILD", "inputs.json") and self.present(file) is not None:
                    expected[base] = self.current(self.present(file))[1]
            text = self.text(pkgbuild).decode()
            names = source_names(text)
            missing = [n for n in names if n not in expected]
            if missing:
                raise SystemExit(f"{recipe}/PKGBUILD: no pin for source {', '.join(missing)}")
            sums = re.search(r"^sha256sums=\((.*?)\)", text, re.M | re.S)
            if not sums:
                raise SystemExit(f"{recipe}/PKGBUILD: no sha256sums array")
            values = [expected[n] for n in names]
            if "\n" in sums[1]:
                block = "\n" + "".join(f"  '{v}'\n" for v in values)
            else:
                block = " ".join(f"'{v}'" for v in values)
            updated = text[:sums.start(1)] + block + text[sums.end(1):]
            if updated != text:
                self.pending[pkgbuild] = updated.encode()
                changes.append(f"{recipe}/PKGBUILD: sha256sums")

    def component_files(self, changes, absent):
        for name, component in self.components.items():
            base = self.root / name
            touched = []
            for row in component.get("files", []):
                source = base.parent / row["source"]
                if source not in self.pending and not source.is_file():
                    absent.add(row["destination"])
                    continue
                size, digest = self.current(source)
                if (row["bytes"], row["sha256"]) != (size, digest):
                    row["bytes"], row["sha256"] = size, digest
                    touched.append(row["source"])
            if touched:
                self.stage(base, component, changes, f"{name}: " + ", ".join(touched))

    def manifest_hashes(self, changes):
        touched = []
        for entry in self.manifest["components"]:
            digest = self.current(self.root / entry["manifest"])[1]
            if entry["sha256"] != digest:
                entry["sha256"] = digest
                touched.append(entry["manifest"])
        if touched:
            self.stage(self.root / "manifest.yaml", self.manifest, changes, "manifest.yaml: " + ", ".join(touched))


def main():
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__.split("\n\n")[1])
    checkout = Checkout(COLLECTION)
    changes, absent = [], set()
    for _ in range(8):
        before = len(changes)
        checkout.locks(changes)
        checkout.pkgbuilds(changes)
        checkout.locks(changes)
        checkout.component_files(changes, absent)
        checkout.manifest_hashes(changes)
        if len(changes) == before:
            break
    else:
        sys.exit("Pins did not settle after 8 passes")
    for line in changes:
        print(("stale  " if check else "pinned ") + line)
    if absent:
        print(f"{len(absent)} pinned files are absent from the checkout and keep their pins", file=sys.stderr)
    if check:
        sys.exit(1 if changes else 0)
    for path, data in checkout.pending.items():
        partial = path.with_name(path.name + ".repin")
        partial.write_bytes(data)
        os.replace(partial, path)


if __name__ == "__main__":
    main()
