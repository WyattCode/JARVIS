#!/usr/bin/env bash
# Isolate suites whose fixtures import production modules with the same names.
set -euo pipefail
jarvis_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$jarvis_repo_root"
"${JARVIS_PYTHON:-python3}" - <<'PY'
import ctypes.util
from pathlib import Path
if not ctypes.util.find_library('opencc') or not Path('/usr/share/opencc/t2s.json').is_file():
    raise SystemExit('Missing OpenCC runtime/data. On Ubuntu 24.04, install libopencc1.1 and libopencc-data.')
PY
jarvis_suite_count=0
for jarvis_test_file in tests/*_test.py; do
  "${JARVIS_PYTHON:-python3}" -m unittest discover -s tests -p "${jarvis_test_file##*/}" -v
  jarvis_suite_count=$((jarvis_suite_count + 1))
done
printf 'Passed %s isolated Python regression files.\n' "$jarvis_suite_count"
