#!/usr/bin/env python3
"""
make_podcast.py: notebook -> sources -> verify -> generate -> poller, as ONE command.

Part of the pi `open-notebook-podcast` skill (docs/13 Phase E, 2026-09-24).

WHY THIS IS A SCRIPT. Under Hermes the model drove every step from SKILL.md prose:
a dozen curl calls, a hand-built JSON body per source, a verification snippet and
a systemd-run line. Each step had a documented failure that looked like success:
  - the attached document never added, so the episode was generic web coverage (2026-08-17);
  - a 0-character source titled after the paper, with generation triggered anyway,
    producing a fluent episode from nothing (2026-08-22);
  - the verification snippet that read every source as empty, because the list
    endpoint has no full_text (2026-09-24);
  - hand-interpolated markdown breaking the JSON body.
Prose is advisory; an exit code is not. The model's job is now what needs judgement:
find the sources, choose the profile and write the briefing. This script does the rest,
and it refuses to generate when the evidence is missing.

Usage:
  make_podcast.py --name "Episode title" [--profile tech_discussion]
                  [--briefing "what to focus on"] [--description "one sentence"]
                  [--doc PATH[::TITLE]]... [--url URL[::TITLE]]...
                  [--notebook notebook:xxx] [--no-generate]

  --doc   a converted document (markdown or text) that is a PRIMARY source.
          A PDF is refused: convert it with the ocr-and-documents skill first.
          A .md with a marker sidecar must pass marker_verify.sh.
          Any empty --doc aborts the run.
  --url   a web source. One that extracts to nothing, or to fewer than
          MIN_URL_CHARS (a block page, a login wall), is removed from the
          notebook and reported; it does not abort the run.

Before generating, the whole notebook is token-counted against the language
model's own window. If it leaves less than RESERVE_TOKENS for the outline and
transcript, nothing is generated and stderr lists the sources by size.

An episode whose --name matches one whose poller is still running is refused
before anything is created: exit 0 is final for a request, not a draft to improve.

Prints a JSON summary on stdout. Exit 0 = generation started and the poller is
running. Non-zero = nothing was generated; stderr says why.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = os.environ.get("OPEN_NOTEBOOK_API", "http://127.0.0.1:5055")
HERE = Path(__file__).resolve().parent
POLLER = HERE / "poll_and_notify.sh"
VERIFY = HERE.parent.parent / "ocr-and-documents" / "scripts" / "marker_verify.sh"
# Extraction of a link source takes seconds; a large text source, 10-30 s to embed.
# Five minutes is generous, and a source still empty after it is treated as empty.
SOURCE_WAIT_SECS = int(os.environ.get("SOURCE_WAIT_SECS", "300"))
# A link source that extracts to a few characters is a block page or a login wall,
# not a source: a Reddit thread came back as 16 characters and was kept, and the
# summary said "nothing dropped" (2026-10-10). Documents are exempt (a short note
# can be a real primary source); only an EMPTY document aborts.
MIN_URL_CHARS = int(os.environ.get("MIN_URL_CHARS", "500"))
# Open Notebook puts every source's full text into EVERY prompt: the outline, and
# each segment's transcript call, which also carries the outline and the transcript
# so far (podcast_creator nodes.py; outline max_tokens 3000, transcript 5000). Six
# sources, two of them whole Hacker News threads (396K of 456K chars), made a
# 129,598-token outline prompt on a 131,072-token window; the outline was cut off
# at 1,474 tokens, all three retries failed identically, and the run died five
# minutes in (2026-10-10). The model server is the one Open Notebook's language
# roles point at; its /tokenize and /props give the exact count and the per-slot
# window. If it does not answer, fall back to PODCAST_CONTEXT and chars / 3
# (that run measured 3.5 chars per token; 3 overestimates, which is the safe side).
LLM_URL = os.environ.get("PODCAST_LLM_URL", "http://127.0.0.1:8088")
FALLBACK_CONTEXT = int(os.environ.get("PODCAST_CONTEXT", "131072"))
RESERVE_TOKENS = int(os.environ.get("RESERVE_TOKENS", "32768"))


def die(msg):
    print(f"make_podcast: {msg}", file=sys.stderr)
    sys.exit(1)


def call(method, path, body=None, timeout=60, retries=4):
    """One API call; die with the server's message on failure.

    HTTP 500 is retried. Adding sources back to back collides with the previous
    source's embed job in SurrealDB ("read or write conflict. This transaction can
    be retried"), and the server passes that through as a bare 500 (observed on this
    script's first run, 2026-09-24, on the second of three sources). The failed
    transaction did not commit, so a retry does not duplicate the source.
    """
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries + 1):
        req = urllib.request.Request(API + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode(errors="replace")
            if e.code == 500 and attempt < retries:
                time.sleep(1 + 2 * attempt)
                continue
            die(f"{method} {path} -> HTTP {e.code}: {detail}")
        except urllib.error.URLError as e:
            die(f"{method} {path} -> {e.reason} (is Open Notebook up? docker ps | grep open-notebook)")


# The poller unit's Description carries the episode name, so a second launch for the
# same request can be found while the first is still generating. On 2026-10-16 the
# agent read an 8.6K-token notebook as "under the 32K floor" (the 32K is what the
# sources must LEAVE free, not a minimum), ran this script again with one more source,
# and the user got two near-identical episodes from two pollers ~2 minutes apart.
POLLER_DESC = "podcast: "


def norm(name):
    return " ".join(name.casefold().split())


def running_episode(name):
    """Return the active poller unit already generating `name`, or None."""
    try:
        r = subprocess.run(["systemctl", "--user", "list-units", "podcast-poller-*",
                            "--state=active", "--plain", "--no-legend",
                            "--output=json"], capture_output=True, text=True, timeout=10)
        units = json.loads(r.stdout or "[]")
    except Exception as e:  # noqa: BLE001 - systemd unreadable: say so, do not block
        print(f"make_podcast: could not list running pollers ({e}); "
              "duplicate check skipped", file=sys.stderr)
        return None
    for u in units:
        desc = u.get("description", "")
        if desc.startswith(POLLER_DESC) and norm(desc[len(POLLER_DESC):]) == norm(name):
            return u.get("unit")
    return None


def split_title(arg):
    val, _, title = arg.partition("::")
    return val.strip(), title.strip()


def resolve_profile(name):
    """Episode profile -> its speaker profile's NAME, which /generate wants.

    The pair must match: the episode profile names its speaker config, and passing
    one without the other got a 2-hour run delivered in unexpected voices (2026-08-23).
    """
    if "vibevoice" in name:
        die(f"{name}: podcasts are voiced by Kokoro since 2026-09-24 and nothing starts "
            "vibevoice-api for them any more; the run would fail at synthesis after the "
            "outline and transcript are spent. Use a Kokoro profile.")
    eps = {p["name"]: p for p in call("GET", "/api/episode-profiles")}
    if name not in eps:
        die(f"no episode profile {name!r}; have: {', '.join(sorted(eps))}")
    spk = {p["id"]: p["name"] for p in call("GET", "/api/speaker-profiles")}
    sid = eps[name].get("speaker_config")
    if sid not in spk:
        die(f"episode profile {name!r} names speaker config {sid!r}, which does not exist")
    return spk[sid], eps[name].get("num_segments")


def check_doc(path):
    p = Path(path).expanduser()
    if not p.is_file():
        die(f"--doc {path}: no such file")
    if p.suffix.lower() in (".pdf", ".docx", ".pptx", ".epub"):
        die(f"--doc {path}: convert it first (ocr-and-documents skill, marker_run.sh) and "
            "pass the markdown it prints. Never transcribe it yourself.")
    # Anything that looks like marker output must carry marker's provenance: the
    # sidecar, marker's own <stem>_meta.json beside it (written for every document,
    # whatever the output dir), or the default /tmp/marker-out path. An LLM
    # transcription saved there looks exactly like the real thing (2026-08-23).
    looks_marker = (p.with_suffix(".marker-ok").exists()
                    or (p.parent / f"{p.stem}_meta.json").exists()
                    or "marker-out" in str(p))
    if looks_marker:
        r = subprocess.run(["bash", str(VERIFY), str(p)], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"--doc {path} failed provenance check:\n{r.stderr.strip()}")
    text = p.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        die(f"--doc {path} is empty")
    return p, text


def full_text(sid):
    s = call("GET", "/api/sources/" + urllib.parse.quote(sid))
    return (s.get("full_text") or "").strip(), s.get("status")


def llm(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(LLM_URL + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def count_tokens(texts):
    """[text] -> ([tokens per text], window, exact). Falls back to an estimate."""
    try:
        window = llm("/props")["default_generation_settings"]["n_ctx"]
        return [len(llm("/tokenize", {"content": t})["tokens"]) for t in texts], window, True
    except Exception as e:  # noqa: BLE001 - any failure means "estimate instead"
        print(f"make_podcast: {LLM_URL} did not answer /props or /tokenize ({e}); "
              f"estimating at 3 chars/token against {FALLBACK_CONTEXT}", file=sys.stderr)
        return [len(t) // 3 + 1 for t in texts], FALLBACK_CONTEXT, False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=True, help="episode title")
    ap.add_argument("--notebook-name", help="default: the episode title")
    ap.add_argument("--description", default="")
    ap.add_argument("--profile", default="tech_discussion")
    ap.add_argument("--briefing", default="", help="briefing_suffix: what to focus on")
    ap.add_argument("--doc", action="append", default=[])
    ap.add_argument("--url", action="append", default=[])
    ap.add_argument("--notebook", help="add to an existing notebook:xxx instead")
    ap.add_argument("--no-generate", action="store_true",
                    help="build and verify the notebook, but do not generate")
    a = ap.parse_args()

    if not a.doc and not a.url and not a.notebook:
        die("no sources: pass --doc and/or --url")
    if not a.no_generate and (unit := running_episode(a.name)):
        die(f"an episode named {a.name!r} is already generating ({unit}); its poller "
            "will deliver it. Nothing was created. Do not run this again for the same "
            "request, even with more sources: that sends the user a second episode. Tell "
            "the user it is on its way.")
    try:
        urllib.request.urlopen(API + "/health", timeout=10).read()
    except Exception as e:  # noqa: BLE001 - any failure here means "down"
        die(f"Open Notebook is not answering on {API}/health ({e}). Tell the user; "
            "do not fall back to espeak or another TTS.")
    speaker, segments = resolve_profile(a.profile)
    docs = [(check_doc(p), t) for p, t in map(split_title, a.doc)]

    if a.notebook:
        nb = a.notebook
    else:
        nb = call("POST", "/api/notebooks", {
            "name": a.notebook_name or a.name,
            "description": a.description or a.name})["id"]
    print(f"make_podcast: notebook {nb}", file=sys.stderr)

    # Documents first: they are the primary source (skill §1).
    added = []  # (source_id, title, kind)
    for (p, text), title in docs:
        title = title or p.stem
        s = call("POST", "/api/sources/json", {
            "type": "text", "content": text, "title": f"{title} (source document)",
            "notebooks": [nb], "embed": True, "async_processing": True})
        added.append((s["id"], title, "doc"))
    for url, title in map(split_title, a.url):
        # `notebooks` must be a real array; /api/sources (no /json) 422s on JSON.
        s = call("POST", "/api/sources/json", {
            "type": "link", "url": url, "title": title or url,
            "notebooks": [nb], "embed": True, "async_processing": True})
        added.append((s["id"], title or url, "url"))

    # Wait for extraction, then check every source's text individually. The list
    # endpoint does not return full_text, so only the per-source GET can tell.
    deadline = time.time() + SOURCE_WAIT_SECS
    pending = {sid for sid, _, _ in added}
    texts = {}
    while pending and time.time() < deadline:
        for sid in list(pending):
            text, status = full_text(sid)
            if text or status in ("failed", "error"):
                texts[sid] = text
                pending.discard(sid)
        if pending:
            time.sleep(5)
    for sid in pending:
        texts[sid] = full_text(sid)[0]

    kept, kept_texts, dropped = [], [], []
    for sid, title, kind in added:
        n = len(texts.get(sid, ""))
        if kind == "doc" and n == 0:
            die(f"document source {title!r} reached the notebook EMPTY ({sid}). Not "
                "generating: an empty notebook plus a briefing is a fabrication generator.")
        if kind == "doc" or n >= MIN_URL_CHARS:
            kept.append({"title": title, "kind": kind, "chars": n})
            kept_texts.append(texts[sid])
        else:
            call("DELETE", "/api/sources/" + urllib.parse.quote(sid))
            dropped.append(f"{title} ({n} chars)")
    if a.notebook:  # existing sources count too, toward the budget as well
        for s in call("GET", "/api/sources?notebook_id=" + urllib.parse.quote(nb)):
            if s["id"] not in texts:
                text = full_text(s["id"])[0]
                if text:
                    kept.append({"title": s.get("title"), "kind": "existing", "chars": len(text)})
                    kept_texts.append(text)
    if not kept:
        die(f"every source extracted to nothing (dropped: {dropped}). Find sources that "
            "render as text, or ask the user; do not generate from an empty notebook.")

    tokens, window, exact = count_tokens(kept_texts)
    for k, t in zip(kept, tokens):
        k["tokens"] = t
    budget = window - RESERVE_TOKENS
    if sum(tokens) > budget:
        by_size = sorted(kept, key=lambda k: -k["tokens"])
        listing = "\n".join(f"  {k['tokens']:>7} tokens  {k['title']}" for k in by_size)
        die(f"the sources total {sum(tokens)} tokens{'' if exact else ' (estimated)'}, over "
            f"the {budget}-token budget ({window} window minus {RESERVE_TOKENS} reserved for "
            "the outline and transcript). Open Notebook sends ALL of it with every call, so "
            "the outline would be cut off. Nothing was generated. Largest first:\n"
            f"{listing}\nDrop or replace the biggest sources (a whole forum thread is rarely "
            f"worth it) and run again. Notebook {nb} was left as it is.")

    summary = {"notebook": nb, "sources": kept, "dropped": dropped,
               "episode_profile": a.profile, "speaker_profile": speaker,
               "segments": segments, "source_tokens": sum(tokens), "window": window}
    if a.no_generate:
        print(json.dumps(summary, indent=1))
        return

    job = call("POST", "/api/podcasts/generate", {
        "episode_profile": a.profile, "speaker_profile": speaker,
        "episode_name": a.name, "notebook_id": nb,
        "briefing_suffix": a.briefing or None})
    job_id = job.get("job_id") or die(f"generate returned no job_id: {job}")
    summary["job_id"] = job_id

    # A transient unit, so the poller outlives pi-signal restarts; --collect so a
    # failed poller does not linger in `systemctl --user list-units`.
    unit = f"podcast-poller-{int(time.time())}"
    path = f"{Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin"
    r = subprocess.run(["systemd-run", "--user", "--collect", f"--unit={unit}",
                        f"--description={POLLER_DESC}{a.name}",
                        f"--setenv=PATH={path}", "/bin/bash", str(POLLER),
                        job_id, a.name, "signal"], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"generation STARTED ({job_id}) but the poller did not launch: {r.stderr.strip()}"
            f" -- nobody will be notified. Launch it by hand: bash {POLLER} {job_id} '{a.name}'")
    summary["poller_unit"] = unit
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
