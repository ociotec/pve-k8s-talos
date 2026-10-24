#!/usr/bin/env python3
"""Read-only JSON metadata validation; report paths/errors, never trace payloads."""
import argparse
import json
from pathlib import Path
import sys


def validate(root):
    root = Path(root)
    if not root.is_dir(): raise ValueError('Tempo trace directory is not mounted or does not exist.')
    invalid, checked = [], 0
    for path in sorted(root.rglob('*.json')):
        checked += 1
        try:
            json.loads(path.read_bytes())
        except (json.JSONDecodeError, UnicodeError, OSError) as exc:
            invalid.append({'path': str(path.relative_to(root)), 'error': type(exc).__name__,
                            'bytes': path.stat().st_size if path.exists() else None})
    return {'checked_json_files': checked, 'invalid': invalid}


def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('trace_directory'); a = p.parse_args()
    result = validate(a.trace_directory); print(json.dumps(result, sort_keys=True))
    return 1 if result['invalid'] else 0

if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as exc:
        print('Error: Tempo metadata validation failed (' + type(exc).__name__ + ').', file=sys.stderr); sys.exit(1)
