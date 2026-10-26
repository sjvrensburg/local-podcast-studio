#!/usr/bin/env bash
# Poll an Open Notebook podcast generation job to completion, then notify on Signal.
# Part of the pi `open-notebook-podcast` skill (local-podcast-studio pi-skills/, until 2026-10-09
# halo-prep config/pi/skills/; deployed to
# ~/.pi/agent/skills/). Ported from the Hermes skill of the same name on 2026-09-24,
# when Hermes was removed (docs/13 Phase E); `git show 5aa8f04:config/hermes/skills/...`
# has the original.
#
# Usage: poll_and_notify.sh <job_id> <episode_name> [deliver_target]
#   job_id          e.g. command:dpyskjwt3gnbi0mpvrlw (from POST /api/podcasts/generate)
#   episode_name    human-readable name, used in the notification text
#   deliver_target  accepted for compatibility with deep-research-podcast.py, which
#                   passes it as $3; only "signal" exists now
#
# ── LAUNCH IT LIKE THIS (make_podcast.py does) ───────────────────────────
#   systemd-run --user --collect --unit="podcast-poller-$(date +%s)" \
#     --setenv=PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
#     /bin/bash ~/.pi/agent/skills/open-notebook-podcast/scripts/poll_and_notify.sh \
#     "<job_id>" "<episode name>" signal
#
# A transient unit, not a child of the agent: under Hermes a backgrounded child died
# with `systemctl --user restart hermes-gateway` (2026-08-17, mid-job, the episode
# completed into silence). pi-signal restarts the same way, so the rule carries over.
#
# Delivery is ~/.local/bin/signal-send, which needs no agent and no model.
set -uo pipefail

JOB_ID="${1:?usage: poll_and_notify.sh <job_id> <episode_name> [deliver_target]}"
EPISODE_NAME="${2:?usage: poll_and_notify.sh <job_id> <episode_name> [deliver_target]}"
DELIVER_TARGET="${3:-signal}"

API="${ON_API:-http://127.0.0.1:5055/api}"   # overridable for testing against a stub
PODCASTS_DIR="${ON_PODCASTS_DIR:-${HOME}/Music/open-notebook-podcasts}"   # likewise
FAIL_LOG="${HOME}/.local/state/pi-jobs/podcast-notify-failures.log"

# Wall-clock budget rather than a poll count, so changing the interval schedule
# below can't silently change how long we wait. 3h soft (warn, keep watching),
# 6h hard (give up). The old 1h ceiling reported a healthy 72.5-min VibeVoice
# run as stuck, so the soft mark warns instead of abandoning.
SOFT_CEILING_SECS="${SOFT_CEILING_SECS:-10800}"
HARD_CEILING_SECS="${HARD_CEILING_SECS:-21600}"
# No new audio clip for this long => probably wedged. With Claude writing, outline + transcript
# took ~1-2.5 min before the first clip (four episodes, 2026-10-16/17) and clips then arrive
# every few seconds, so 25 min is generous; it was sized for the Ornith era's 3-4 min segments.
STALL_SECS="${STALL_SECS:-1500}"
# The re-voice tool (see the "completed" branch below; still named drama-revoice). Like the lease helper, a path
# into halo-prep, overridable; a missing or non-executable file means Kokoro only.
DRAMA_REVOICE="${DRAMA_REVOICE:-${HOME}/Projects/halo-prep/scripts/drama-revoice.py}"

START_TS="$(date +%s)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [poll] $*" >&2; }

# ── Delivery, with the exit code actually checked ────────────────────────
# The v1 script ignored its sender's result, so a failed send exited 0 having
# told nobody — the audio existed and the user never heard.
notify() {
    local msg="$1"
    # signal-send exits non-zero on any failed delivery and retries transport errors
    # itself, so no loop here. "MEDIA:<path>" is the old Hermes attachment syntax,
    # kept as this script's internal convention; it becomes --attach.
    if [[ "${msg}" == MEDIA:* ]]; then
        signal-send --attach "${msg#MEDIA:}" "" && return 0
    else
        signal-send "${msg}" && return 0
    fi
    log "signal-send failed (rc=$?)"
    # Last resort: leave a breadcrumb so the work is recoverable by hand.
    mkdir -p "$(dirname "${FAIL_LOG}")"
    printf '%s\tjob=%s\ttarget=%s\tmsg=%s\n' \
        "$(date -Is)" "${JOB_ID}" "${DELIVER_TARGET}" "${msg}" >>"${FAIL_LOG}"
    log "UNDELIVERED — recorded in ${FAIL_LOG}"
    return 1
}

# ── A failed run has no job to poll ──────────────────────────────────────
# The deep-research-podcast pipeline notifies on failure as well as success, and
# it does so by handing this poller the literal job id "failed" (its notify()
# says so outright: "a poller that cannot interpret it still fires and still
# tells someone"). Until 2026-08-23 nothing here interpreted it, so a stopped or
# crashed research run -- which never reached trigger_podcast() and therefore has
# no job at all -- took the full new-job path: acquire the ~8 GiB vibevoice
# lease, GET /api/podcasts/jobs/failed five times for five HTTP 500s over 40
# seconds, then release. Three costs, all real, all observed twice within
# fifteen minutes on 2026-08-23: an 8 GiB spike during a shutdown the operator
# had usually triggered *because* memory was tight; ~45 s added to every stop
# (the pipeline runs this synchronously); and a Signal message reading "I can't
# read its job status ... Check: .../jobs/failed", which sends someone to a URL
# that cannot ever work, about a job that never existed.
#
# Ahead of the lock as well as the lease: the lock key is derived from the job
# id, so every failed run in the system shares one "podcast-poller-failed.lock"
# and two overlapping failures would silence the second notification entirely.
if [ "${JOB_ID}" = "failed" ]; then
    log "run failed before a podcast job was created -- notifying, nothing to poll"
    notify "⚠️ The deep research run for \"${EPISODE_NAME}\" failed before any podcast was generated. No episode is in progress and there is no audio to wait for. The reason is in the run log: journalctl --user -u 'deep-research-podcast-*' (or the log file the run printed at launch)."
    exit 1
fi

# ── Single poller per job ────────────────────────────────────────────────
# Without this, a retry loop in the agent that fires the launch twice gets you
# two pollers, and the user gets duplicate "ready" messages AND duplicate audio
# attachments. Today's agent looped 15 times on one tool call, so this is not
# hypothetical.
LOCK_FILE="/tmp/podcast-poller-${JOB_ID//[^a-zA-Z0-9]/_}.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "another poller already owns ${JOB_ID} (lock: ${LOCK_FILE}) — exiting" >&2
    exit 0
fi

# ── The TTS server's lease lives here ────────────────────────────────────
# `vibevoice-api` is on-demand as of 2026-08-23 and every consumer starts it
# AND tears it down (operator's instruction that day). This poller is where a
# podcast job's teardown belongs: it is the only thing that outlives the agent
# turn and knows when the episode is actually finished. The trap covers every
# exit path — success, hard ceiling, the duplicate-poller bail-out above, and a
# `systemctl --user stop` of this transient unit.
#
# Teardown goes through the lease helper, never a bare `systemctl stop`: a
# voice message or a second episode can be synthesizing at the same moment, and
# the refcount is what stops this from cutting their audio off mid-clip.
# Passing $$ lets the helper prune this lease if the poller is killed outright.
#
# ── OFF BY DEFAULT SINCE 2026-09-24: podcasts are Kokoro now. ──
# The operator moved podcasts from VibeVoice to Kokoro (preferred on listening;
# ~2x faster; CPU-only and always on in the open-notebook compose stack, so no
# lease and no GPU). Until then every episode took this lease, Kokoro ones
# included, "a spurious ~8 GiB for the life of one episode" -- acceptable while
# VibeVoice was the default, pure waste once it is not. VibeVoice stays for the
# voice-message skill, which leases it itself.
#
# Set PODCAST_VIBEVOICE_LEASE=1 in the poller's environment to get the old
# behaviour for a deliberate `_vibevoice`-profile run. Without it such a run
# fails at synthesis, because Open Notebook will not start vibevoice-api -- the
# same failure the lease was added to prevent, now opt-in rather than paid by
# every Kokoro job.
#
# Overridable so this file stays usable on a box where halo-prep lives
# elsewhere (or not at all): unset the path to something non-executable and
# the poller just logs a warning and manages nothing.
LEASE_HELPER="${VIBEVOICE_LEASE_HELPER:-${HOME}/Projects/halo-prep/scripts/vibevoice-lease.sh}"
TTS_TAG="podcast-${JOB_ID//[^a-zA-Z0-9]/_}"
release_tts() {
    [ -x "${LEASE_HELPER}" ] && bash "${LEASE_HELPER}" release "${TTS_TAG}" || true
}
if [ "${PODCAST_VIBEVOICE_LEASE:-0}" != "1" ]; then
    :   # Kokoro (the default): no TTS server to manage.
elif [ -x "${LEASE_HELPER}" ]; then
    bash "${LEASE_HELPER}" acquire "${TTS_TAG}" "$$" || log "could not acquire the TTS lease — continuing; generation may fail at synthesis"
    trap release_tts EXIT
else
    log "WARNING: ${LEASE_HELPER} missing — not managing vibevoice-api for this job"
fi

# ── Job status, with the HTTP code kept ──────────────────────────────────
# v1 did `.get("status","?")` on whatever came back and treated "?" as running.
# A deleted or mistyped job id returns HTTP 500 {"detail":"Failed to fetch job
# status"} (verified), so "?" meant three hours of polling a job that never
# existed, followed by a misleading "may be stuck". Keep the code, fail fast.
http_code=""
job_status=""
fetch_status() {
    local resp
    resp="$(curl -s -m 10 -w '\n%{http_code}' "${API}/podcasts/jobs/${JOB_ID}" 2>/dev/null)"
    http_code="$(printf '%s' "${resp}" | tail -n1)"
    local body
    body="$(printf '%s' "${resp}" | sed '$d')"
    job_status="$(printf '%s' "${body}" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "")"
    printf '%s' "${body}"
}

audio_path_from_job() {
    curl -s -m 10 "${API}/podcasts/jobs/${JOB_ID}" 2>/dev/null | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("result",{}).get("audio_file_path",""))' 2>/dev/null
}

# ── Progress signal ──────────────────────────────────────────────────────
# Files on the host, not the API and (since 2026-10-20) not the container log.
#   - The API has no progress: the job's `progress` field is never set, and the episode's
#     `outline` and `transcript` populate only at completion. Its status is all it gives.
#   - The container log ("segment N/M", "Generated audio clip") was the source until the
#     operator left the docker group on 2026-10-20 (it is root-equivalent). Reading it now
#     needs sudo; a poller doing so got "permission denied", saw no progress, and would have
#     sent a false "may be wedged" on every run over STALL_SECS.
#   - podcast-creator writes each clip to <PODCASTS_DIR>/episodes/<uuid>/clips/NNNN.mp3 as it
#     is synthesised (world-readable, bind-mounted from the container). outline.json and
#     transcript.json are written at the end only, so there is no per-segment signal: the
#     outline/transcript phase counts as one stretch, which is short now that Claude writes.
#
# The directory name is a fresh uuid with no job id, so the episode is the newest directory
# created since this poller started (less a slack for a worker that picked the job up before
# the poller launched). Same caveat the log had: two concurrent generations would be
# indistinguishable, and one runs at a time in practice. Ignoring older directories is what
# stops a fresh poller reporting the previous episode's clips as its own (the 2026-08-17
# "segment 5/7" bug, which was the log-window version of this).
EPISODE_DIR=""
find_episode_dir() {
    [ -n "${EPISODE_DIR}" ] && return 0
    local d
    d="$(find "${PODCASTS_DIR}/episodes" -mindepth 1 -maxdepth 1 -type d \
            -newermt "@$(( START_TS - 120 ))" -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | cut -d' ' -f2-)"
    [ -n "${d}" ] && EPISODE_DIR="${d}" && log "episode directory: ${d}"
}

# Call find_episode_dir in the loop itself, not inside $(...): a subshell's EPISODE_DIR is lost.
audio_clips_done() {
    [ -n "${EPISODE_DIR}" ] || return 0
    find "${EPISODE_DIR}/clips" -maxdepth 1 -name '*.mp3' 2>/dev/null | wc -l
}

# Interval schedule: tight early so an immediate failure is caught fast, then
# relaxed. v1's flat 20s meant 45-540 requests for zero added responsiveness.
interval_for() {
    local elapsed="$1"
    if   [ "${elapsed}" -lt 120 ]; then echo 10
    elif [ "${elapsed}" -lt 600 ]; then echo 30
    else echo 60
    fi
}

log "watching ${JOB_ID} (${EPISODE_NAME}) -> ${DELIVER_TARGET}"

consecutive_errors=0
last_clips=0
last_progress="${START_TS}"
warned_stall=0
warned_soft=0

while true; do
    now="$(date +%s)"
    elapsed=$((now - START_TS))

    fetch_status >/dev/null

    case "${http_code}" in
    200)
        consecutive_errors=0
        ;;
    "")
        # curl itself failed — Open Notebook down, or the container restarting.
        consecutive_errors=$((consecutive_errors + 1))
        log "no response from API (${consecutive_errors} in a row)"
        ;;
    404|500|502|503)
        consecutive_errors=$((consecutive_errors + 1))
        log "HTTP ${http_code} from job endpoint (${consecutive_errors} in a row)"
        ;;
    *)
        consecutive_errors=$((consecutive_errors + 1))
        log "unexpected HTTP ${http_code} (${consecutive_errors} in a row)"
        ;;
    esac

    # Five consecutive failures is a couple of minutes early on — long enough to
    # ride out a container restart, short enough that a bogus job id fails in
    # minutes instead of hours.
    if [ "${consecutive_errors}" -ge 5 ]; then
        notify "Podcast \"${EPISODE_NAME}\" — I can't read its job status (HTTP ${http_code:-no response}, 5 tries). The job id may be wrong or Open Notebook may be down. Check: ${API}/podcasts/jobs/${JOB_ID}"
        exit 1
    fi

    case "${job_status}" in
    completed)
        rel_path="$(audio_path_from_job)"
        if [ -z "${rel_path}" ]; then
            notify "Podcast \"${EPISODE_NAME}\" finished generating, but I couldn't find the audio file path in the job result. Check the Open Notebook UI (http://127.0.0.1:8502) or the job directly: ${API}/podcasts/jobs/${JOB_ID}"
            exit 0
        fi
        audio_path="${PODCASTS_DIR}/${rel_path}"
        # ── Re-voice (on the EVO-X3, since 2026-10-18) ──
        # Open Notebook voices the episode with Kokoro; where halo-prep's drama-revoice exists,
        # the finished transcript is rendered again in locked voices and THAT file is delivered:
        # with Fish S2-Pro since 2026-10-26 (Drama 3 before, and now its second chance; halo-prep
        # docs/19 §5). Kokoro's file stays the fallback: if the re-voice fails, the Kokoro audio
        # is sent with a note. S2-Pro takes about as long as the episode lasts. The engine that
        # rendered is in the tool's "engine:" line and in the .log beside its MP3, since only
        # three lines are logged here. PODCAST_DRAMA=0 turns it off.
        if [ "${PODCAST_DRAMA:-1}" = "1" ] && [ -x "${DRAMA_REVOICE}" ] && [ -f "${audio_path}" ]; then
            notify "🎙️ \"${EPISODE_NAME}\": the script is done. Re-voicing it now, which takes about as long as the episode lasts. I'll send it when it's ready."
            drama_out="$("${DRAMA_REVOICE}" --by-audio "${rel_path}" 2>&1)"; drama_rc=$?
            log "drama-revoice rc=${drama_rc}: $(printf '%s' "${drama_out}" | tail -n 3 | tr '\n' ' ')"
            drama_path="$(printf '%s' "${drama_out}" | sed -n 's/^wrote \(.*\) in [0-9]* s$/\1/p' | tail -n1)"
            engine="$(printf '%s' "${drama_out}" | sed -n 's/^engine: //p' | tail -n1)"
            if [ "${drama_rc}" -eq 0 ] && [ -f "${drama_path}" ]; then
                notify "🎙️ Your podcast \"${EPISODE_NAME}\" is ready."
                notify "MEDIA:${drama_path}"
                log "done in $(( ($(date +%s) - START_TS) / 60 ))m (${engine:-re-voice})"
                exit 0
            fi
            notify "The re-voice of \"${EPISODE_NAME}\" failed ($(printf '%s' "${drama_out}" | tail -n1 | cut -c1-200)). Sending the Kokoro version instead."
        fi
        notify "🎙️ Your podcast \"${EPISODE_NAME}\" is ready."
        if [ -f "${audio_path}" ]; then
            notify "MEDIA:${audio_path}"
        else
            notify "(File should be at ${audio_path} but I can't find it there -- check ${PODCASTS_DIR})"
        fi
        log "done in $((elapsed / 60))m"
        exit 0
        ;;
    failed|error)
        # Summarised, never pasted whole. error_message can carry the model's
        # entire rejected output: 2026-09-26 a langchain "Invalid json output"
        # was 10.8 KB of transcript JSON, and it arrived on Signal as what
        # looked like the episode's script, not as a failure. The full text
        # stays in the job record and in this unit's journal.
        err="$(curl -s -m 10 "${API}/podcasts/jobs/${JOB_ID}" | python3 -c '
import json, sys
e = json.load(sys.stdin).get("error_message") or "unknown error"
if e.startswith("Invalid json output") or "OUTPUT_PARSING_FAILURE" in e:
    s = "the transcript model returned malformed JSON for a segment"
else:
    s = " ".join(e.split())
    s = s if len(s) <= 300 else s[:300] + "..."
print(f"{s} ({len(e)} chars in full)")
print(e, file=sys.stderr)
' || echo "unknown error")"
        notify "Podcast \"${EPISODE_NAME}\" failed to generate: ${err}. Full error: curl -s ${API}/podcasts/jobs/${JOB_ID} | jq -r .error_message"
        exit 1
        ;;
    esac

    # ── Progress / stall tracking ────────────────────────────────────────
    # Only trust the episode directory once the API has actually confirmed this job
    # exists. It carries no job id, so on a bogus job id it describes
    # whatever OTHER episode is generating — a test with a mistyped id happily
    # announced "7 segments" for a job that did not exist. One generation runs
    # at a time in practice, but attributing another job's progress to this one
    # is wrong in exactly the case you most need a truthful message.
    if [ "${http_code}" != "200" ]; then
        sleep "$(interval_for "${elapsed}")"
        continue
    fi

    # Logged, not pushed to Signal: a two-speaker episode is a hundred-odd clips.
    find_episode_dir
    clips="$(audio_clips_done)"
    if [ -n "${clips}" ] && [ "${clips}" -gt "${last_clips}" ] 2>/dev/null; then
        log "progress: ${clips} audio clip(s) synthesised"
        last_clips="${clips}"
        last_progress="${now}"
        warned_stall=0
    fi

    if [ $((now - last_progress)) -ge "${STALL_SECS}" ] && [ "${warned_stall}" -eq 0 ]; then
        warned_stall=1
        if [ "${last_clips}" -gt 0 ]; then
            where="audio synthesis (${last_clips} clips done)"
        else
            where="the outline and transcript (no audio yet)"
        fi
        notify "Podcast \"${EPISODE_NAME}\" hasn't advanced past ${where} in $((STALL_SECS / 60)) min. It may be wedged — still watching. Logs: sudo docker logs --tail 50 open-notebook"
    fi

    # ── Ceilings ─────────────────────────────────────────────────────────
    if [ "${elapsed}" -ge "${HARD_CEILING_SECS}" ]; then
        notify "Giving up on podcast \"${EPISODE_NAME}\" after $((elapsed / 3600))h. If it does finish, the audio will still land in ${PODCASTS_DIR}. Job: ${API}/podcasts/jobs/${JOB_ID}"
        exit 1
    fi
    if [ "${elapsed}" -ge "${SOFT_CEILING_SECS}" ] && [ "${warned_soft}" -eq 0 ]; then
        warned_soft=1
        notify "Podcast \"${EPISODE_NAME}\" is still generating after $((elapsed / 60)) min — longer than any run observed on this box. Still watching, but something may be stuck. Job: ${API}/podcasts/jobs/${JOB_ID}"
    fi

    sleep "$(interval_for "${elapsed}")"
done
