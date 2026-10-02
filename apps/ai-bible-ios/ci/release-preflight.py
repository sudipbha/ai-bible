#!/usr/bin/env python3
"""Release preflight: refuses a store build while release values are placeholders or missing.

    python3 ci/release-preflight.py --root <apps/ai-bible-ios folder> [--bundle-id <id>]

Checks, reporting every problem at once (exit 1), or exit 0 when all pass:
- the app's bundle ID (--bundle-id, else project.yml's AIBible target) is a real reverse-DNS ID,
  not a placeholder such as com.example.*;
- AppConfig.fullBookProductID is set and not a placeholder, and StoreKit/Products.storekit uses
  the same product ID (so local purchase tests exercise the real one);
- AppConfig.privacyPolicyURLString and supportURLString are https URLs on a real host.
It never chooses or writes any value. Standard library only.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

ID_PATTERN = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
PLACEHOLDER_WORDS = ("example", "placeholder", "changeme", "todo", "yourcompany", "yourname")
PLACEHOLDER_HOSTS = ("example.com", "example.org", "example.net", "localhost")


def is_placeholder_id(value):
    lowered = value.lower()
    return lowered.startswith("com.example.") or any(word in lowered for word in PLACEHOLDER_WORDS)


def app_bundle_id(project_yml):
    """The AIBible application target's PRODUCT_BUNDLE_IDENTIFIER (the first target in project.yml)."""
    match = re.search(r"\n  AIBible:\n(.*?)(?=\n  \S|\nschemes:|\Z)", project_yml, re.S)
    if not match:
        return None
    found = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*([^\s#]+)", match.group(1))
    return found.group(1) if found else None


def swift_literal(source, name):
    """Value of `static let <name> = "..."` or `static let <name>: String? = "..." | nil`."""
    match = re.search(rf"static let {name}(?::\s*String\??)?\s*=\s*(nil|\"([^\"\\\\]*)\")", source)
    if not match:
        return "missing-declaration"
    return None if match.group(1) == "nil" else match.group(2)


def check(root, bundle_override=None):
    problems = []
    project = (root / "project.yml").read_text(encoding="utf-8")
    config = (root / "AIBible" / "App" / "AppModel.swift").read_text(encoding="utf-8")
    storekit = json.loads((root / "StoreKit" / "Products.storekit").read_text(encoding="utf-8"))

    bundle_id = bundle_override or app_bundle_id(project)
    source = "--bundle-id" if bundle_override else "project.yml (AIBible target)"
    if not bundle_id:
        problems.append("bundle ID: none found in project.yml for the AIBible target")
    elif not ID_PATTERN.match(bundle_id):
        problems.append(f"bundle ID from {source} is not a reverse-DNS identifier: {bundle_id}")
    elif is_placeholder_id(bundle_id):
        problems.append(f"bundle ID from {source} is a placeholder: {bundle_id}")

    product_id = swift_literal(config, "fullBookProductID")
    if product_id in (None, "missing-declaration", ""):
        problems.append("AppConfig.fullBookProductID is not set")
    elif not re.match(r"^[A-Za-z0-9._-]+$", product_id):
        problems.append(f"AppConfig.fullBookProductID has characters App Store Connect doesn't allow: {product_id}")
    elif is_placeholder_id(product_id):
        problems.append(f"AppConfig.fullBookProductID is a placeholder: {product_id}")
    storekit_ids = [p.get("productID") for p in storekit.get("nonRenewingSubscriptions", []) + storekit.get("products", [])]
    if product_id and product_id not in ("missing-declaration",) and storekit_ids != [product_id]:
        problems.append(f"StoreKit/Products.storekit product IDs {storekit_ids} don't match AppConfig.fullBookProductID "
                        f"({product_id}); update the local StoreKit configuration to the same single product")

    for name, label in (("privacyPolicyURLString", "privacy policy"), ("supportURLString", "support")):
        value = swift_literal(config, name)
        if value in (None, "missing-declaration", ""):
            problems.append(f"AppConfig.{name} is not set: the {label} URL is required for submission")
            continue
        parts = urlsplit(value)
        host = (parts.hostname or "").lower()
        if parts.scheme != "https" or not host or "." not in host:
            problems.append(f"AppConfig.{name} must be an https URL with a real host: {value}")
        elif host in PLACEHOLDER_HOSTS or host.endswith(tuple("." + h for h in PLACEHOLDER_HOSTS)) \
                or any(word in value.lower() for word in PLACEHOLDER_WORDS if word != "example"):
            problems.append(f"AppConfig.{name} is a placeholder: {value}")
    return bundle_id, product_id, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True, type=Path, help="the apps/ai-bible-ios folder to check")
    parser.add_argument("--bundle-id", help="the bundle ID the release build will use (overrides project.yml)")
    args = parser.parse_args(argv)
    bundle_id, product_id, problems = check(args.root, args.bundle_id)
    if problems:
        print("release preflight failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"release preflight passed: bundle ID {bundle_id}, product ID {product_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
