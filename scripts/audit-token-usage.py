#!/usr/bin/env python3
"""Read-only, independent comparison of a v2 numeric journal with its source prefixes.

Run against a private copy of tokens.json. Sources must still have the same inode
and at least the committed size. Output contains numeric diagnostics, never text.
"""
import argparse
import json, sys, datetime, collections
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('journal', type=Path, help='Private copy of the v2 tokens.json journal')
args = parser.parse_args()
state = json.loads(args.journal.read_text())
if state.get('version') != 2:
    parser.error('Expected journal version 2')

def source_lines(path, cursor):
    source = Path(path)
    info = source.stat()
    if info.st_ino != cursor['inode'] or info.st_size < cursor['offset']:
        raise ValueError('Source rotated or truncated since the snapshot')
    with source.open('rb') as stream:
        remaining = cursor['offset']
        while remaining:
            line = stream.readline(remaining)
            if not line:
                break
            remaining -= len(line)
            yield line
errors = []
totals = collections.Counter()
residual = collections.Counter()
links = 0
for path, cursor in state['files'].items():
    session = cursor['parser'].get('session')
    if not session:
        continue
    provider = session['provider']
    sid = session['sessionID']
    expected = {}
    parents = {}
    head = None
    for raw in source_lines(path, cursor):
        try:
            r = json.loads(raw)
        except ValueError:
            continue
        t = r.get('type')
        p = r.get('payload') or {}
        stamp = r.get('timestamp')
        if t in ('session_meta', 'session') and head is None:
            head = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
        if not stamp or head is None:
            continue
        if datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')) < head:
            continue
        if provider == 'codex' and t == 'token_usage_record' and (p.get('thread_id') == sid):
            u = p.get('usage', {})
            rid = p.get('response_id')
            if not rid:
                continue
            c = {'input': u['input_tokens'], 'output': u['output_tokens']}
            for dest, src in [('cached', 'cached_input_tokens'), ('cacheWrite', 'cache_write_input_tokens'), ('reasoning', 'reasoning_output_tokens')]:
                if src in u:
                    c[dest] = u[src]
            if rid in expected and expected[rid][0] != c:
                errors.append(('source_conflict', provider))
            expected.setdefault(rid, (c, p.get('turn_id'), p.get('root_turn_id')))
        if provider == 'pi':
            rid = r.get('id')
            msg = r.get('message') or {}
            parent = r.get('parentId')
            if rid:
                parents[rid] = rid if msg.get('role') == 'user' else parents.get(parent)
            if t == 'message' and msg.get('role') == 'assistant' and isinstance(msg.get('usage'), dict):
                u = msg['usage']
                c = {'input': u.get('input', 0) + u.get('cacheRead', 0) + u.get('cacheWrite', 0), 'output': u.get('output', 0)}
                for dest, src in [('cached', 'cacheRead'), ('cacheWrite', 'cacheWrite'), ('reasoning', 'reasoning')]:
                    if src in u:
                        c[dest] = u[src]
                expected.setdefault(rid, (c, parents.get(rid), None))
    actual = session.get('requests', {})
    if set(expected) != set(actual):
        errors.append(('request_identity', provider, len(expected), len(actual)))
    for rid, (c, turn, root_turn) in expected.items():
        got = actual.get(rid, {})
        if c != got.get('counts'):
            errors.append(('numeric', provider, rid, c, got.get('counts')))
        if turn != got.get('turnID'):
            errors.append(('turn', provider))
        if root_turn != got.get('rootTurnID'):
            errors.append(('root_turn', provider))
        if root_turn:
            links += 1
        totals[provider + '_requests'] += 1
        totals[provider + '_input'] += c['input']
        totals[provider + '_output'] += c['output']
    byturn = collections.Counter()
    for request in actual.values():
        byturn[request['aggregateID']] += request['counts']['input'] + request['counts']['output']
    for turn, summary in session['turns'].items():
        n = summary['counts']['input'] + summary['counts']['output'] - byturn[turn]
        if n < 0:
            errors.append(('negative_remainder', provider))
        elif n > 0:
            residual[provider + '_historical_tokens'] += n
            residual[provider + '_historical_turns'] += 1
report = {'schema': state['version'], 'files': len(state['files']), 'requests': dict(totals), 'root_links_checked': links, 'historical_summaries': dict(residual), 'errors': errors[:12], 'error_count': len(errors)}
print(json.dumps(report, indent=2))
sys.exit(1 if errors else 0)
