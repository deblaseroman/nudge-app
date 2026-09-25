#!/usr/bin/env python3
"""Export Claude Code session transcripts for this project as markdown notes.

Reads ~/.claude/projects/<this project>/*.jsonl and writes one note per
session into the folder given on the command line (an Obsidian vault
folder works). Keeps the conversation: user messages and assistant text.
Tool calls collapse to one line each; tool results are omitted. Existing
notes are overwritten, so re-running after new sessions is safe.

  usage: scripts/export-claude-sessions.py <output folder>
"""
import glob, json, os, sys, datetime, re

if len(sys.argv) != 2:
    print(__doc__); sys.exit(2)
out_dir = os.path.expanduser(sys.argv[1]); os.makedirs(out_dir, exist_ok=True)
proj = os.path.expanduser('~/.claude/projects/-Users-romandeblase-NudgeLocal-Nudge')

def text_of(content):
    if isinstance(content, str): return content
    parts = []
    for block in content or []:
        t = block.get('type')
        if t == 'text': parts.append(block.get('text', ''))
        elif t == 'tool_use':
            name = block.get('name', 'tool'); inp = block.get('input', {}) or {}
            hint = inp.get('description') or inp.get('command') or inp.get('file_path') or inp.get('prompt') or ''
            hint = str(hint).strip().split('\n')[0][:110]
            parts.append(f'> _tool: {name}_ {hint}')
        elif t == 'tool_result': continue
    return '\n\n'.join(p for p in parts if p.strip())

written = 0
for path in sorted(glob.glob(os.path.join(proj, '*.jsonl'))):
    turns, first, last = [], None, None
    for line in open(path, encoding='utf-8', errors='replace'):
        try: rec = json.loads(line)
        except Exception: continue
        if rec.get('type') not in ('user', 'assistant'): continue
        ts = rec.get('timestamp'); first = first or ts; last = ts or last
        msg = rec.get('message', {}) or {}
        body = text_of(msg.get('content'))
        if not body.strip(): continue
        if rec.get('type') == 'user' and body.lstrip().startswith(('<local-command', '<command-name', '<system-reminder')): continue
        turns.append((rec['type'], ts, body))
    if not turns: continue
    day = (first or '')[:10] or 'undated'
    sid = os.path.basename(path)[:8]
    name = f'Nudge session {day} {sid}.md'
    with open(os.path.join(out_dir, name), 'w', encoding='utf-8') as f:
        f.write(f'---\nproject: Nudge\nsession: {os.path.basename(path)[:-6]}\nstarted: {first}\nended: {last}\nturns: {len(turns)}\ntags: [nudge, claude-code]\n---\n\n')
        f.write(f'# Nudge session {day}\n\n')
        for role, ts, body in turns:
            label = 'Roman' if role == 'user' else 'Claude'
            stamp = (ts or '')[11:16]
            f.write(f'## {label} {stamp}\n\n{body}\n\n')
    written += 1
    print(f'{name}  ({len(turns)} turns)')
print(f'{written} note(s) written to {out_dir}')
