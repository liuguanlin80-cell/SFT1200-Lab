#!/bin/bash
# SFT1200-Lab: preserve the device SDK configuration before customization.
set -euo pipefail

if [ ! -f Makefile ] || [ ! -f .config ] || [ ! -f feeds.conf.default ]; then
    echo 'ERROR: Run this script from the prepared OpenWrt SDK directory.' >&2
    exit 1
fi

if ! grep -qx 'CONFIG_TARGET_siflower_sf19a28_fullmask_SF19A28-GL-SFT1200=y' .config; then
    echo 'ERROR: The SDK configuration is not for GL-SFT1200.' >&2
    exit 1
fi

# The workflow replaces .config later; retain the SDK-generated device baseline.
mkdir -p .sft1200-lab
cp .config .sft1200-lab/base.config
cp feeds.conf.default .sft1200-lab/feeds.conf.default.original
if [ -f feeds.conf ]; then
    cp feeds.conf .sft1200-lab/feeds.conf.original
fi

# Keep the SDK feeds. Pin any branch-based feed to the checkout already obtained
# by gen_config.py, so the next feed update does not silently move that revision.
python3 - <<'PY'
from pathlib import Path
import re
import subprocess

manifest = []
for filename in ('feeds.conf.default', 'feeds.conf'):
    config = Path(filename)
    if not config.is_file():
        continue
    updated = []
    for line in config.read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'(src-git(?:-full)?\s+)(\w+)(\s+)(\S+)\s*', line)
        if match is None:
            updated.append(line)
            continue
        prefix, name, spacing, source = match.groups()
        checkout = Path('feeds') / name
        if not (checkout / '.git').exists():
            raise SystemExit(f'ERROR: SDK feed checkout is missing: {checkout}')
        revision = subprocess.check_output(
            ['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True
        ).strip()
        if not re.fullmatch(r'[0-9a-f]{40}', revision):
            raise SystemExit(f'ERROR: Invalid revision for feed {name}')
        repository = source.split('^', 1)[0].split(';', 1)[0]
        updated.append(f'{prefix}{name}{spacing}{repository}^{revision}')
        manifest.append(f'{name} {repository} {revision}')
    config.write_text('\n'.join(updated) + '\n', encoding='utf-8')

if not manifest:
    raise SystemExit('ERROR: No SDK Git feeds were found.')
Path('.sft1200-lab/feed-revisions.txt').write_text(
    '\n'.join(manifest) + '\n', encoding='utf-8'
)
print('\n'.join(manifest))
PY

if [ -n "${LOG_DIR:-}" ]; then
    mkdir -p "$LOG_DIR"
    cp .sft1200-lab/base.config "$LOG_DIR/sdk-base.config"
    cp .sft1200-lab/feed-revisions.txt "$LOG_DIR/feed-revisions.txt"
    if [ -f feeds.conf ]; then
        cp feeds.conf "$LOG_DIR/feeds.conf"
    fi
fi

echo 'SDK configuration saved; existing feed revisions pinned for this build.'
