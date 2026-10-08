#!/usr/bin/env python3
"""Turns catalog/verified.json (from scripts/check-catalog.py, then checked on the phone with tests/probe.m)
into the packaged suggestion list layout/Library/NewsstandRSS/Catalog.plist."""
import json, plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
verified = json.loads((ROOT / 'catalog' / 'verified.json').read_text())
catalog = {
    'version': 1,
    'general': verified['general'],
    'countries': [{'code': code, 'es': c['es'], 'en': c['en'], 'feeds': c['feeds']}
                  for code, c in sorted(verified['countries'].items(), key=lambda kv: kv[1]['es'])],
}
out = ROOT / 'layout' / 'Library' / 'NewsstandRSS' / 'Catalog.plist'
out.write_bytes(plistlib.dumps(catalog, fmt=plistlib.FMT_BINARY))
print('%d general, %d countries, %d country feeds -> %s' % (len(catalog['general']), len(catalog['countries']),
      sum(len(c['feeds']) for c in catalog['countries']), out))
