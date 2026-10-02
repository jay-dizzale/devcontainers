#!/usr/bin/env python3
"""run.py — entry point for the `devtool` package: the environment/service picker,
stop/list/logs/build-base, the whitelist-proxy manager (`proxy`), and one-time host setup
(`setup`). See devtool/cli.py for the actual dispatch logic.
"""
import sys

from devtool.cli import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
