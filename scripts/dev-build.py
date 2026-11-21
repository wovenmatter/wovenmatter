#!/usr/bin/env python3
"""The profile of a development instance: its bundle identifier, product name
and data folder. Each instance has its own; none is the installed app's."""
import argparse
import json
from pathlib import Path
import re


def profile(instance):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", instance or ""):
        raise SystemExit("Name the instance with --instance: up to 64 lowercase letters, digits and hyphens.")
    bundle = f"wovenmatter.desktop.dev.{instance}"
    return dict(instance=instance, bundle=bundle, product=f"Woven Matter {instance} Dev",
                support=str(Path.home() / "Library/Application Support" / bundle))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--instance", required=True)
    args = parser.parse_args()
    print(json.dumps(profile(args.instance)))


if __name__ == "__main__":
    main()
