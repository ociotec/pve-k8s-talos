#!/usr/bin/env python3
"""Supply omitted S3 locals while leaving cluster HCL expressions intact."""

import argparse
from pathlib import Path
import re


def render(source):
    declared = re.search(r"^\s*garage_s3_public_endpoint\s*=", source, re.M)
    default = "" if declared else '  garage_s3_public_endpoint = ""\n'
    return "# Generated optional S3 defaults. Do not edit.\nlocals {\n" + default + "}\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--constants", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(render(args.constants.read_text()))
