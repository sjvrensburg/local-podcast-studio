---
name: open-notebook-podcast
description: >-
  Make a podcast episode on a topic, URL or attached document with Open Notebook (researched sources, Kokoro voices, delivered on Signal when done). Use for "make a podcast about X", and whenever the user refers to a shortlist item: "3", "#3", "topic 3", "podcast on #3", "generate the one about X". Always resolve those with scripts/resolve_topic.py, never from memory. Not for reading text aloud (voice_message) or deep multi-hour research (deep-research-podcast).
---

# Podcast: research, notebook, episode

Ported from the Hermes skills `open-notebook-podcast` and `podcast-workflow` on 2026-09-24
(halo-prep `docs/13` Phase E). The mechanics are one script, `scripts/make_podcast.py`, which
creates the notebook, adds and verifies the sources, starts generation and launches the
poller that delivers the audio on Signal. Your job is what needs judgement: routing, sources,
profile and briefing.

## 0. Is it a podcast?

- One voice reading given text ("read this back", "send me a voice note") is **not** a
  podcast: use the `voice_message` tool. Under a minute, no research.
- "Deep research", "a deep dive", "intensively research", "I'll listen tonight": use the
  `deep-research-podcast` skill.
- Genuinely ambiguous between those: ask one short question and end the turn. A wrong guess
  costs 20-60 minutes of GPU.

### A shortlist reference ("3", "#3", "topic #3", "generate the podcast on #3", or a title)

The daily `podcast-topic-discovery` job sends a numbered shortlist through `signal-send`, which
is outside this chat session: **you have not seen today's list, and any list in your context is
older.** On 2026-10-01 "topic #1" was resolved from 09-29's list and the wrong episode ran. So
the first action is always:

```bash
python3 ~/.pi/agent/skills/open-notebook-podcast/scripts/resolve_topic.py 3   # or a title fragment
```

It reads the newest `~/.local/share/pi-jobs/podcast-topic-discovery/podcast-topic-discovery-*.md`, logs the pick for preference
mining, and prints the item's title, source links and description. Use only what it prints. A
non-zero exit (shortlist older than a day, no such item, ambiguous title) means **stop and ask
the user which topic they mean**; do not fall back to context. Your first reply line must state
the resolved title (and the shortlist date), so a wrong resolution is visible before 20-60
minutes of GPU are spent.

## 1. Sources (5-8 total)

- **A URL given**: it is the primary source. Add 4-7 more that give real grounding: the
  primary/official source first (docs, paper, repo), then independent analysis.
- **A bare topic**: search SearXNG, then apply the same bar:
  `curl -s 'http://127.0.0.1:8888/search?format=json&q=<query>' | jq -r '.results[:10][] | "\(.title)\n  \(.url)\n  \(.content[:200])"'`
- **A document** (a Signal attachment, "this paper"): it is THE primary source and must end up
  in the notebook. Convert it with the `ocr-and-documents` skill (marker), then pass the
  markdown path as `--doc`. Research supporting URLs around it. On 2026-08-17 a notebook
  built "from" a set of class notes contained only Wikipedia and scikit-learn; the episode
  sounded right and the notes were absent. The script refuses a PDF as `--doc` for this reason.

Only pass URLs you have checked resolve to real content (a quick `curl -sL <url> | head`).
Pages that extract to nothing, or to under 500 characters (a block page), are dropped by the
script and listed in its output.

**Size matters as much as relevance.** Every source's full text goes into every outline and
transcript call, and the model's window is 131,072 tokens. The script refuses to generate when
the sources are too BIG, leaving less than 32K of the window free, and lists them by size.
There is no minimum: a notebook of 8K tokens is fine, and the script decides that, not you.
Prefer focused pages (a repo README, an article, a spec page) over whole forum threads: on
2026-10-10 two Hacker News threads that never mentioned the topic were 108K of 128K tokens, and
the outline was cut off. When the script refuses, drop the largest off-topic source; do not
retry the same list.

## 2. Profile

| `--profile` | Speakers | Use for |
|---|---|---|
| `tech_discussion` | 2 | **Default.** Most requests |
| `solo_expert` | 1 | A single straightforward explainer |
| `business_analysis` | 3 | Explicitly business/market/strategy topics |
| `deep_dive` | 2 (10 segments) | Long-form; normally reached via `deep-research-podcast` |

All are voiced by Kokoro (the operator's choice since 2026-09-24). Do not create profiles, and
do not use a `_vibevoice` one: the script refuses them, because nothing starts that TTS server
for podcasts any more. Format is low-stakes; don't ask about it.

## 3. Run it

```bash
python3 ~/.pi/agent/skills/open-notebook-podcast/scripts/make_podcast.py \
  --name "<descriptive episode title>" --profile tech_discussion \
  --description "<one sentence: what the notebook covers>" \
  --briefing "<what to focus on, from the user's request>" \
  [--doc "/path/to/converted.md::Document title"] \
  --url "https://...::Short title" --url "https://...::Short title"
```

It takes ~10-60 s (waiting for extraction) and prints JSON: the notebook, the sources kept with
their character counts, those dropped, and the `job_id`. **Exit 0 is final**: the episode is
generating and its poller will deliver it. Do not run the script again for the same request,
not even with more or better sources; a second run is a second episode on the user's phone
(2026-10-16), and the script refuses a repeat `--name` while the first is still generating. If
sources were dropped, say so in your reply. **A non-zero exit means nothing was generated**;
relay its message and fix the cause (usually: find better sources). Never work around it by
calling the Open Notebook API yourself: every check in it exists because an episode once
shipped built on nothing.

**The briefing is instructions, not content.** If the material to answer a question is not in
the sources, putting the question in `--briefing` does not research it; it tells the model to
sound authoritative about something it was never given. Add a source instead. Keep the
briefing to angle and emphasis ("focus on why it runs well on a CPU, for a listener who runs
local models"); do not put facts in it. The first run under pi (2026-09-24) wrote an
architecture summary into the briefing, including a claim none of its sources made, and the
episode model treats the briefing as ground truth.

## 4. Reply and stop

Tell the user, in one short message: generation started, which sources are in it (from the
JSON, and any dropped), and that it takes roughly 20-60 minutes. The poller sends its own
message with the real segment count, then the audio file when done, or the error if it fails.
Do not wait for it.

## If Open Notebook is down

The script says so. Tell the user and stop. There is no fallback voice on purpose: the
operator would rather have a failure than an espeak episode (2026-09-24), so do not synthesise
one with espeak, piper or anything else, and do not offer to. Check with
`curl -s localhost:5055/health` and `docker ps | grep open-notebook`.

## Useful facts

- API on `:5055`. Sources for a notebook: `GET /api/sources?notebook_id=<id>`
  (`/api/notebooks/<id>/sources` does not exist and 404s). The list omits `full_text`; only
  `GET /api/sources/<id>` has it.
- Audio lands in `~/Music/open-notebook-podcasts/`. The UI is `http://127.0.0.1:8502`.
- Outline and transcript are written by the Ornith 35B on `:8088`. If outlines ever fail with
  "length limit was reached", that is the episode profile's `max_tokens` (set to 12000 on all
  profiles on 2026-08-17), not the context window.
- A running poller: `systemctl --user list-units 'podcast-poller-*'`, and its log via
  `journalctl --user -u <unit>`.
