#!/usr/bin/env python3
"""Reject private-development files in the tracked public repository inventory.

This is a filename guard, not a replacement for content review or secret scanning.
"""
from fnmatch import fnmatchcase
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PRIVATE_PATTERNS = (
    '.env', '.env.*', '*.pem', '*.key', '*.p12', '*.p8', '*.mobileprovision',
    '*.ipa', '*.sqlite', '*.sqlite3', '*.db', '*.lumacapture.json',
    'credentials*.json', 'service-account*.json', 'AGENTS.md',
    '*-Build-Prompt*.md', '*-Execution-Plan.md', '*chat-export*', '*conversation-export*',
    'AI_USAGE*.md', 'CAC-*-SUBMISSION.md', 'CAC-*-PRESENTATION-SCRIPT.md',
    '*PRESENTATION-CONTENT-BRIEF.md', 'STATUS_*.md', 'WORK_SPLIT.md',
)
PRIVATE_DIRECTORIES = {
    '.codex', '.claude', '.agents', '.impeccable', 'graphify-out', 'Distribution',
    'ReferenceImages', 'xcuserdata', '.local-data', '.venv', '__pycache__',
}


def main():
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    rejected = []
    for name in filter(None, tracked):
        path = Path(name)
        if path.name == '.env.example':
            continue
        if PRIVATE_DIRECTORIES.intersection(path.parts[:-1]) or any(
            fnmatchcase(path.name.casefold(), pattern.casefold()) for pattern in PRIVATE_PATTERNS
        ):
            rejected.append(name)
    if rejected:
        raise SystemExit('Private file paths must not be published:\n' + '\n'.join(sorted(rejected)))
    print('Public file inventory passed. Review content and run a secret scanner separately.')


if __name__ == '__main__':
    main()
