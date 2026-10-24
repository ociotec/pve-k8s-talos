#!/usr/bin/env python3
"""Supply optional monitoring locals without changing independent clusters."""

import argparse
from pathlib import Path
import re


DEFAULTS = {
    "grafana_datasource_suffix": '""',
    "grafana_remote_clusters": "{}",
    "monitoring_api_consumers": "[]",
    "monitoring_query_api": "{}",
}


def render(source):
    # Values stay in HCL and are evaluated by OpenTofu, never by this helper.
    defined = set(re.findall(r"^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=", source, re.M))
    lines = [f"  {name} = {value}" for name, value in DEFAULTS.items() if name not in defined]
    return "# Generated optional monitoring defaults. Do not edit.\nlocals {\n" + "\n".join(lines) + "\n}\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--constants", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(render(args.constants.read_text()))
