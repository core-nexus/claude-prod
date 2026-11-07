#!/usr/bin/env python3
"""Extract loose-end signal from Claude Code session logs.

Reads the JSONL transcripts under $CLAUDE_CONFIG_DIR/projects (default
~/.claude/projects) and, for every session touched in the last N days,
pulls out the fields that tell you whether the work actually finished:
the git branch, the task list, the last thing the assistant said, and
any PR numbers mentioned.

Writes JSON to --out and prints a one-line-per-session digest to stdout.

Usage:
    extract_sessions.py --days 7 --out /tmp/sessions.json
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

# Text blocks starting with these are harness noise, not something a human typed.
SYNTHETIC_PREFIXES = ('<', 'Base directory for this skill:', '[Request interrupted')
PR_RE = re.compile(r'(?:pull/|#)(\d{3,5})')
# A final message ending in one of these reads as a completed thought. Anything
# else — a colon, a dangling clause — is where a crash or interrupt cut in.
SENTENCE_END = ('.', '!', '?', '`', ')', '"', ':**', '—')


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--days', type=int, default=7, help='how far back to look (default 7)')
    p.add_argument('--out', default='sessions.json', help='where to write the JSON')
    p.add_argument('--root', default=None, help='override the projects dir')
    return p.parse_args()


def text_of(content):
    """Flatten a message's content to plain text, whatever shape it is."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            b.get('text', '')
            for b in content
            if isinstance(b, dict) and b.get('type') == 'text'
        ]
        return '\n'.join(p for p in parts if p)
    return ''


def is_human(entry, body):
    """True when this user entry is something the developer actually typed.

    Tool results, skill preambles and attachments all arrive as role=user
    too, so filter on origin plus the synthetic-prefix list.
    """
    if entry.get('isSidechain'):
        return False
    if not body or not body.strip():
        return False
    if body.startswith(SYNTHETIC_PREFIXES):
        return False
    return entry.get('origin', {}).get('kind') == 'human' or entry.get('userType') == 'external'


def scan(path):
    """Pull one session's worth of signal out of a transcript file."""
    s = {
        'path': path,
        'project': path.split('/projects/')[1].split('/')[0] if '/projects/' in path else '?',
        'session_id': os.path.basename(path).replace('.jsonl', ''),
        'title': None,
        'branch': None,
        'cwd': None,
        'first_prompt': None,
        'last_prompts': [],
        'last_assistant': None,
        'last_ts': None,
        'tasks': [],
        'prs': set(),
        'n_human_msgs': 0,
    }
    prompts = []
    try:
        fh = open(path, errors='replace')
    except OSError as exc:
        print(f'warn: cannot read {path}: {exc}', file=sys.stderr)
        return None

    with fh:
        for line in fh:
            try:
                e = json.loads(line)
            except (ValueError, TypeError):
                continue

            kind = e.get('type')
            if e.get('timestamp'):
                s['last_ts'] = e['timestamp']
            if kind == 'custom-title' and not s['title']:
                s['title'] = e.get('customTitle')
            if e.get('gitBranch'):
                s['branch'] = e['gitBranch']
            if e.get('cwd'):
                s['cwd'] = e['cwd']

            if kind == 'user':
                body = text_of((e.get('message') or {}).get('content'))
                if is_human(e, body):
                    s['n_human_msgs'] += 1
                    prompts.append({'ts': e.get('timestamp'), 'text': body[:800]})

            elif kind == 'assistant':
                for b in (e.get('message') or {}).get('content') or []:
                    if not isinstance(b, dict):
                        continue
                    if b.get('type') == 'text' and b.get('text', '').strip():
                        s['last_assistant'] = {'ts': e.get('timestamp'), 'text': b['text'][:2500]}
                        s['prs'].update(PR_RE.findall(b['text']))
                    elif b.get('type') == 'tool_use' and b.get('name') in (
                        'TaskCreate',
                        'TaskUpdate',
                        'TodoWrite',
                    ):
                        s['tasks'].append({'tool': b['name'], 'input': b.get('input')})

    if prompts:
        s['first_prompt'] = prompts[0]['text']
        s['last_prompts'] = prompts[-3:]
    s['prs'] = sorted(s['prs'])
    return s


def open_task_subjects(tasks):
    """Replay TaskCreate/TaskUpdate in order; return subjects never completed.

    Task ids are 1-based and assigned in creation order, which is what lets
    a later TaskUpdate be matched back to the TaskCreate it refers to.
    """
    created, done = {}, set()
    for t in tasks:
        data = t.get('input') or {}
        if t['tool'] == 'TaskCreate':
            created[str(len(created) + 1)] = data.get('subject', '(untitled)')
        elif t['tool'] == 'TaskUpdate' and data.get('status') in ('completed', 'deleted'):
            done.add(str(data.get('taskId')))
        elif t['tool'] == 'TodoWrite':
            # Older transcripts carry the whole list on every call; last wins.
            todos = data.get('todos') or []
            created = {str(i + 1): x.get('content', '?') for i, x in enumerate(todos)}
            done = {
                str(i + 1) for i, x in enumerate(todos) if x.get('status') == 'completed'
            }
    return [subj for tid, subj in created.items() if tid not in done]


def looks_interrupted(session):
    la = session.get('last_assistant')
    if not la:
        return False
    return not la['text'].rstrip().endswith(SENTENCE_END)


def main():
    args = parse_args()
    root = args.root or os.path.join(
        os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude')), 'projects'
    )
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)

    sessions = []
    for path in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True):
        # Subagent transcripts duplicate their parent's work; read them only
        # on demand, when a parent session turns out to need the detail.
        if '/subagents/' in path:
            continue
        try:
            if datetime.fromtimestamp(os.path.getmtime(path), timezone.utc) < cutoff:
                continue
        except OSError:
            continue
        found = scan(path)
        if found:
            sessions.append(found)

    sessions.sort(key=lambda x: x['last_ts'] or '')
    for s in sessions:
        s['open_tasks'] = open_task_subjects(s['tasks'])
        s['interrupted'] = looks_interrupted(s)

    with open(args.out, 'w') as fh:
        json.dump(sessions, fh, indent=1)

    print(f'{len(sessions)} sessions in the last {args.days} days -> {args.out}\n')
    for s in sessions:
        flags = []
        if s['interrupted']:
            flags.append('INTERRUPTED')
        if s['open_tasks']:
            flags.append(f'{len(s["open_tasks"])}-open-tasks')
        print(
            f'{(s["last_ts"] or "?")[:16]}  {s["session_id"][:8]}  '
            f'{(s["branch"] or "-")[:44]:<44} '
            f'prs={",".join(s["prs"][:4]) or "-":<20} {" ".join(flags)}'
        )


if __name__ == '__main__':
    main()
