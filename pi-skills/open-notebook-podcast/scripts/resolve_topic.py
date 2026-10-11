#!/usr/bin/env python3
"""Resolve "topic #N" (or a title fragment) against the newest podcast-topic-discovery shortlist.

Why this is a script: the Signal chat session is long-lived and carries old shortlists in its
context, so a model resolving "#1" from memory picked 2026-09-29's #1 on 2026-10-01. Prose in
the skill ("read the newest file") was skipped; a non-zero exit is not. The shortlist is
delivered by signal-send, outside the chat session, so the file is the only record of today's.

Usage: resolve_topic.py <N | title fragment> [--no-log]
Prints the shortlist's date, the chosen item's title, its source URLs and its description.
Exit 1: no shortlist, shortlist older than 1 day, or no match. Exit 2: ambiguous title.
Logs the pick for preference-mining (skip with --no-log).
"""
import datetime as dt, glob, os, re, subprocess, sys

# pi-job saves the shortlist here (it went to ~/Downloads until 2026-10-09).
DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                   "pi-jobs/podcast-topic-discovery")
PREF_LOG = os.path.expanduser("~/.pi/agent/jobs/scripts/pref_log.py")

def die(msg, code=1):
    print(f"resolve_topic: {msg}", file=sys.stderr); sys.exit(code)

args = [a for a in sys.argv[1:] if a != "--no-log"]
if not args: die("usage: resolve_topic.py <N | title fragment> [--no-log]")
query = " ".join(args).strip().lstrip("#")

files = sorted(glob.glob(f"{DIR}/podcast-topic-discovery-*.md"))
if not files: die(f"no shortlist found in {DIR}")
path = files[-1]
m = re.search(r"(\d{4}-\d{2}-\d{2})\.md$", path)
date = dt.date.fromisoformat(m.group(1))
age = (dt.date.today() - date).days
if age > 1:
    die(f"newest shortlist is {path} ({age} days old). Do NOT guess; ask the user which topic they mean.")

# The shortlist is model-written and its item format drifts between days: "## 1. T" (most),
# "### 1. T" (2026-10-11), "**1. T**" (10-03, 10-07), and sources as bare "- https://…" or as
# "- [title](https://…)" (10-07, 10-08). Until 2026-10-11 only "## " and bare URLs parsed, so
# 3 of 10 shortlists refused every "#N" reply and linked sources were silently dropped. The job
# prompt now pins the format; this stays tolerant anyway, because a refusal costs an episode.
ITEM = re.compile(r"(?m)^(?:#{2,4}[ \t]+(?:\*\*)?|\*\*)(?=\d+\.[ \t])")
items = {}
for blk in ITEM.split(open(path).read())[1:]:
    head, _, body = blk.partition("\n")
    n, title = head.split(". ", 1)
    urls = re.findall(r"^[-*] (?:\[[^\]]*\]\()?(https?://[^\s)]+)", body, re.M)
    desc = re.split(r"\n\s*Sources?:", body)[0].strip()
    items[int(n)] = (title.strip().strip("*").strip(), urls, desc)
if not items: die(f"no numbered items parsed from {path}")

if query.isdigit():
    n = int(query)
    if n not in items: die(f"no item {n} in {path} (has 1-{max(items)})")
else:
    hits = [k for k, v in items.items() if query.lower() in v[0].lower()]
    if not hits: die(f"no title in {path} matches {query!r}")
    if len(hits) > 1: die(f"{query!r} matches items {hits}; ask the user", 2)
    n = hits[0]

title, urls, desc = items[n]
if "--no-log" not in sys.argv[1:] and os.path.exists(PREF_LOG):
    cmd = ["python3", PREF_LOG, "add", "--domain", "podcast-topics", "--action", "chosen", "--title", title]
    if urls: cmd += ["--url", urls[0]]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, check=False)

print(f"SHORTLIST: {path} (dated {date}, {age} day(s) old)")
print(f"ITEM {n} of {len(items)}: {title}")
print("SOURCES:"); [print(f"  {u}") for u in urls]
print(f"DESCRIPTION: {desc}")
print("\nSay this title back to the user in your first reply.")
