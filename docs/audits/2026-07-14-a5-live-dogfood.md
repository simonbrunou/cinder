# A5 live dogfood: production Plex sign-off (Jellyfin descoped)

**Date:** 2026-07-14
**Phase:** A5 — Live dogfood and sign-off (`ROADMAP.md`, "Live single-episode, episode-range,
full-season-batch, story-special, cross-season-pack, and dual-audio-release imports into a real
Jellyfin and a real Plex library")
**Prod commit under test:** `0389165` (main HEAD carrying A0–A4.5; live traffic served by the
prod cinder container on CT121)
**Companion doc:** `docs/audits/2026-07-14-a5-corpus-rerun.md` (A0 corpus re-run against current
TMDB/Prowlarr behavior, same day, 7/7 pass)

## Descope: Plex only, no Jellyfin

**No Jellyfin is deployed in this homelab.** The household's only production media server is
Plex (CT100, "media-server", `:32400`). ROADMAP's A5 Build/Done-when text was written assuming
both were available; the operator explicitly descopes A5 to Plex-only for this phase — every
"land in Jellyfin and Plex" checkpoint below is judged against Plex alone. This is recorded here
and in the ROADMAP status line, not silently dropped.

## Method

Six real acquisitions were run against the live prod instance (real TMDB, real Prowlarr, real
usenet/SAB, real Plex), one per A5 Build case, using titles already present or newly added to the
watchlist. Nothing was run against mocks. Evidence below is transcribed from the operator's
verbatim session notes (grab/search-attempt counts, ffprobe output, blocklist reasons, Plex
`ratingKey`s, hardlink `nlink`).

## Per-case summary

| # | Case | Title | Release(s) | Verdict | Data moved |
| --- | --- | --- | --- | --- | --- |
| 1 | Single-episode | Bleach, abs-366 | none (0 candidates ever existed) | **SAFE-STOP** | 0 GB |
| 2 | Episode-range | Re:Zero, abs 25–28 | none (0 candidates ever existed) | **SAFE-STOP** | 0 GB |
| 3 | Story-special | Re:Zero-verse S00E77 (substituted for TMDB movie "Memory Snow") | none (parser gap excluded the one real batch) | **SAFE-STOP** | 0 GB |
| 4 | Cross-season-pack | Attack on Titan S01E25 + S02E01 | 2× FROGWeb CR WEB-DL (individual grabs) | **SAFE-STOP** (held, verification_blocked) | 2.93 GB (downloaded, not imported) |
| 5 | Dual-audio | Your Name (2016) | Deathrow (imported); TAiCHi / D-Z0N3 / TAiCHi-Obfuscated / Chotab (rejected+blocklisted) | **CORRECT** | 6.24 GB imported |
| 6 | Full-season-batch | Demon Slayer: Kimetsu no Yaiba (2019) S01 | 26× Kitsune CR WEB-DL DUAL | **CORRECT** | 40.04 GB imported |

2/6 landed cleanly in Plex. 4/6 safe-stopped — three with zero grabs at all (correctly rejecting
everything on offer), one with a real grab that downloaded and then correctly held at
post-download verification. Zero wrong auto-imports across all six.

## Case narratives

### 1. Single-episode — Bleach, absolute episode 366

Monitored a single episode by absolute number. Coordinate mapping was verified correct
independently: abs 366 = `S01E366`, "Changing History, Unchanging Heart," per TMDB's continuous
single-season numbering for Bleach. But **zero standalone releases exist on any configured
indexer** for this episode — the only matches on offer were 6.1–330 GB batch archives spanning
large episode ranges. All of them were correctly rejected by the newly-configured size band (see
F1) before ever becoming a grab candidate. `search_attempts` exhausted at 10/10; the episode
parked with zero grabs. This is a SAFE-STOP driven entirely by indexer supply, not a cinder defect
— the coordinate math and the size-band rejection both did exactly what they should.

### 2. Episode-range — Re:Zero, absolute episodes 25–28

Monitored a 4-episode absolute range. TMDB id 65942's episode-group is a **type-2 "absolute"
group that interleaves the main series with Re:PETIT shorts**: abs 25 → `S01E13`, abs 26 →
`S00E13`, abs 27 → `S01E14`, abs 28 → `S00E14`. Critically, this TMDB id **has no season 2 at
all** — its second-season content was merged into an 85-episode Season 1 — while every real
release in the wild tags episodes `S02Exx`. Cinder is faithful to the TMDB tree by design (no
metadata signal is trusted enough to override it — see A0/A1), so it correctly never matched any
real-world `S02Exx` release against this coordinate set. All 4 monitored episodes exhausted
`search_attempts` at 10/10 with zero grabs and zero GB moved. **This is the A6 trigger evidence**
— see F2.

### 3. Story-special — substitution required, then parser gap

The originally-intended story special, "Memory Snow," turned out to be catalogued in TMDB as a
**standalone movie (id 532321)**, not a `S00` television special — so it was never a valid target
for the episode-classification pipeline in the first place, and the operator substituted a real
`story_special`-classified `S00E77` ("The Golden Lion and the Sword Saint") for the test instead.
One real Nyaa batch existed for it (`总第67~77`, ~174 MB), but `AnimeParser`'s range regex only
recognizes the ASCII hyphen `-` as a range separator, not the CJK wave-dash `~` used in the
release's own title — so the batch was **never even considered as a candidate**, not rejected for
cause. The episode parked at `search_attempts` 10/10, zero grabs. See F3.

### 4. Cross-season-pack — Attack on Titan S01E25 + S02E01

Monitored both sides of a season boundary to see whether a boundary-spanning pack would resolve
correctly. No such pack existed on any indexer, so both boundary episodes were grabbed
**individually** instead — FROGWeb CR WEB-DL, 1.45 GB and 1.47 GB — and each resolved to the
correct coordinate on its own side of the boundary (no cross-season confusion). Both downloaded
successfully, then **both were held at `verification_blocked`**: `ffprobe` reported no language
tag at all on the audio stream, so `Cinder.Catalog.ReleaseVerification`'s `PolicyVerifier` recorded
`{:unavailable, {:unprobeable_audio, ...}}` against the required `"ja"` policy rather than
guessing pass or fail. `retry_grab_verification` was run and re-blocked consistently (not a
one-off probe hiccup). Nothing was imported; both files remain on disk in
`/media/downloads/complete` (~2.93 GB combined), pending an operator decision (see Operator
follow-ups). This is exactly the A4 verification-hold behavior working as designed on a real,
previously-unseen failure mode (untagged audio, as opposed to A4's originally-tested
wrong-language case) — see F5.

### 5. Dual-audio — Your Name (2016)

With `anime_audio_mode=:dual` and `preferred_language=french`, the frozen release-policy snapshot
required both `["ja", "fr"]`. Four "Dual Audio" (JP+EN) releases were downloaded in full and then
**correctly rejected and blocklisted** — `{:release_policy_mismatch, missing_audio: ["fr"]}` —
against TAiCHi, D-Z0N3, TAiCHi-Obfuscated, and Chotab; three unrelated usenet download failures
were also blocklisted in the same sweep. After the operator reverted `anime_audio_mode` back to
`:original` (see F4 — the `:dual`+French combination was never going to succeed against a JP+EN
release population, and the setting was silently holding the title with no DB-visible signal), the
Deathrow release was grabbed and **imported correctly**: `ffprobe` confirmed `TAG:language=jpn` on
the audio track, `imported_audio_languages: ["jpn"]`, hardlinked (`nlink=2`) onto `/mnt/media2`,
6.24 GB, and it landed in Plex's Movies section as `ratingKey` 1637 against the correct TMDB match.

### 6. Full-season-batch — Demon Slayer: Kimetsu no Yaiba (2019) Season 1

Monitored exactly the 26 episodes of Season 1. One sweep grabbed all 26 as individual Kitsune CR
WEB-DL DUAL releases (not a single season-pack archive — none was needed since per-episode
releases satisfied set-cover). All 26 resolved, verified, and imported to
`Demon Slayer Kimetsu no Yaiba (2019) {tmdb-85937}/Season 01/`, hardlinked (`nlink=2`) across both
mergerfs branches, 40.04 GB total. Plex's TV section shows `ratingKey` 9545 with `leafCount=26` —
every episode accounted for, none missing or duplicated.

## Findings

**F1 — no size bands configured.** The instance had **no** `tv`/`movie` size bands set at the
start of this phase, meaning a single-episode monitor of a long-running show could legally match
a 330 GB batch archive and attempt to grab it. Sane bands (`tv` 0.05–4 GB, `movies` 0.3–15 GB, per
wanted unit) were set mid-phase and **kept**. This belongs on the operator setup checklist, not
just this one instance's settings — a fresh deploy with unset bands has the same exposure.

**F2 — TMDB's Re:Zero tree diverges from scene numbering.** Interleaved Re:PETIT shorts inside
the main absolute numbering, and no season 2 at all (an 85-episode season-1 merge) against a wild
release population that uses `S02Exx`. Cinder stays faithful to TMDB by design (A0/A1 finding: no
metadata signal was reliable enough to override it), so this produces a real, evidenced
SAFE-STOP rather than a wrong mapping. **This is the A6 trigger evidence** — see
`ROADMAP.md` A6.

**F3 — `AnimeParser`'s range regex has no CJK wave-dash `~` support.** Only ASCII `-` is
recognized as a range separator; a real Nyaa release titled with `总第67~77` was silently never a
candidate rather than being considered and rejected. Confirmed with a real title (`总第67~77`,
~174 MB) from case 3 above.

**F4 — `anime_audio_mode` is global-only and fails silently when it can't be satisfied.** A
non-default `anime_audio_mode` value (e.g. `:dual`) combined with a `preferred_language` that no
available release population can satisfy holds **every** matching anime title indefinitely, with
only a repeating log line (`"anime search held ... invalid preferences"` roughly every 5s) and
**no DB-visible marker** — indistinguishable, from the UI/DB, from a title that simply hasn't been
swept yet. Reproduced directly by the Demon Slayer/Your Name settings interaction mid-phase.

**F5 — positive: the A4 ffprobe verification pipeline worked exactly as designed, twice, on real
never-before-seen data.** Case 4 (untagged audio, a new failure mode vs. A4's originally-tested
wrong-language case) and case 5 (wrong-language JP+EN dual releases against a French requirement)
both correctly rejected/held rather than guessing. **Zero wrong auto-imports occurred anywhere in
this phase.**

## Library and settings changes

- **Added to the library:** Bleach, Re:Zero, and Attack on Titan entries exist on the watchlist
  with the coordinates above monitored (no files imported for any of them). Demon Slayer Season 1
  imported in full (40.04 GB). Your Name (2016) imported (6.24 GB).
- **Verified untouched:** the 5 pre-existing non-anime titles in the library were spot-checked and
  confirmed unaffected by any of the above.
- **Settings kept from this phase:** `tv`/`movie` size bands (F1) stay configured going forward.
  `anime_audio_mode` was reverted to `:original` after the Your Name experiment (F4) — this is the
  instance's steady-state value, not a lingering `:dual` leftover.

## Operator follow-ups (not blocking phase sign-off)

1. **AoT held files** — two FROGWeb CR WEB-DL files (~2.93 GB) sit in `/media/downloads/complete`
   held at `verification_blocked` (untagged audio, case 4). Operator decision pending: manually
   confirm the audio language out-of-band and force-import, re-grab from a release group that tags
   its streams, or leave parked. Not urgent — nothing is silently wrong, it's a documented hold.
2. **SAB leftovers from rejected Your Name candidates** — the four blocklisted "Dual Audio"
   downloads (TAiCHi, D-Z0N3, TAiCHi-Obfuscated, Chotab) plus 3 unrelated usenet failures remain in
   SAB's history/download directory. Per
   `feedback_cinder_sab_cleanup_retention` (SAB `history_retention_number` raised 1→10000 so
   cinder's own `move_on_import` cleanup can find its history entry), these won't self-clean via
   SAB retention alone — durable fix is cinder deleting by `content_path` directly (filed as
   cinder#81, still open). Manual purge is an option in the meantime.
3. **Pre-existing ~273 GB in `/media/downloads/complete`**, including Frieren dev-era leftovers —
   unrelated to this phase's cases, but flagged here since it was visible during the case-4/case-5
   investigation. Orthogonal cleanup, not gating A5.

## Disposition vs the A5 Done-when

Corpus fixtures still pass (companion doc, 7/7). Every one of the six live cases either landed
correctly or stopped safely with a documented, evidenced reason — none silently mis-filed, zero
wrong auto-imports. The standard (non-anime) suite is green (`mix test`, 1606 passed, 0 failures,
`credo --strict`/format/warnings-as-errors clean — see the corpus re-run doc's commit boundary).
The only deviation from the literal Done-when text is Jellyfin: not deployed in this household, so
every "lands in Jellyfin and Plex" checkpoint above was judged Plex-only, by explicit operator
descope (see above). **A5 is signed off on this evidence.**
