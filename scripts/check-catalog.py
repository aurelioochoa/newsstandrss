#!/usr/bin/env python3
"""Fetches every catalog candidate and keeps the feeds that parse as RSS/Atom and published within 30 days.
Writes catalog/verified.json; prints a report. Usage: scripts/check-catalog.py [candidates.json]"""
import json, sys, urllib.request, email.utils, datetime, re, gzip
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Mobile/10B329 NewsstandRSS/1.0'
NOW = datetime.datetime.now(datetime.timezone.utc)


def newest(root):
    dates = []
    for el in root.iter():
        tag = el.tag.split('}')[-1].lower()
        if tag in ('pubdate', 'published', 'updated', 'date') and el.text:
            text = el.text.strip()
            try:
                d = email.utils.parsedate_to_datetime(text)
            except Exception:
                try:
                    d = datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))
                except Exception:
                    continue
            if d.tzinfo is None:
                d = d.replace(tzinfo=datetime.timezone.utc)
            dates.append(d)
    return max(dates) if dates else None


def check(entry):
    name, url = entry
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Encoding': 'gzip'})
        with urllib.request.urlopen(req, timeout=25) as r:
            data = r.read(9 * 1024 * 1024)
            if r.headers.get('Content-Encoding') == 'gzip':
                data = gzip.decompress(data)
            final = r.geturl()
        root = ET.fromstring(data)
        kind = root.tag.split('}')[-1].lower()
        if kind not in ('rss', 'rdf', 'feed'):
            return name, url, None, 'not a feed (%s)' % kind
        items = [e for e in root.iter() if e.tag.split('}')[-1] in ('item', 'entry')]
        if not items:
            return name, url, None, 'no items'
        last = newest(root)
        if last and (NOW - last).days > 30:
            return name, url, None, 'stale (%s)' % last.date()
        return name, final, len(items), 'ok%s' % ('' if last else ' (no dates)')
    except Exception as e:
        return name, url, None, '%s: %s' % (type(e).__name__, str(e)[:60])


src = json.loads(Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'catalog' / 'candidates.json').read_text())
jobs = [('general', None, None, e) for e in src['general']]
for code, (es, en, feeds) in src['countries'].items():
    jobs += [(code, es, en, e) for e in feeds]
with ThreadPoolExecutor(16) as pool:
    results = list(pool.map(lambda j: (j, check(j[3])), jobs))

verified = {'general': [], 'countries': {}}
for (group, es, en, _), (name, url, count, status) in results:
    print('%-8s %-6s %-28s %s' % ('OK' if count else 'DROP', group, name, status if not count else '%d items %s' % (count, url)))
    if not count:
        continue
    if group == 'general':
        verified['general'].append({'title': name, 'url': url})
    else:
        verified['countries'].setdefault(group, {'es': es, 'en': en, 'feeds': []})['feeds'].append({'title': name, 'url': url})
(ROOT / 'catalog' / 'verified.json').write_text(json.dumps(verified, ensure_ascii=False, indent=1))
print('general %d, countries %d, feeds %d' % (len(verified['general']), len(verified['countries']),
      sum(len(c['feeds']) for c in verified['countries'].values())))
