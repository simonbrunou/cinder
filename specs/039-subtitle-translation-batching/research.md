# Subtitle translation batching — design

**Date:** 2026-07-11
**Status:** implemented (follow-up to `2026-07-10-subtitle-local-translation-fallback`).
**Council review:** n/a — the approach was vetted by the LibreTranslate-deploy correctness council, which read this exact module to find the blocker below; this is its direct, tested remedy.

## Problem

`Cinder.Subtitles.Translator.LibreTranslate.translate/2` posted **all** of a file's cues as a single `q` array in one `POST /translate` with a **15 s** client timeout and no chunking. A self-hosted LibreTranslate instance translates on CPU sequentially and slowly; a movie SRT is ~1000–1500 cues, an episode ~300–700, so a real file exceeds 15 s → cinder returns `{:error, :timeout}`, logs a best-effort miss, and **writes no sidecar** (while the LibreTranslate worker burns CPU on the abandoned request for up to its gunicorn timeout, ~2400 s). A single-word smoke test passes in <1 s and hides this entirely. The feature could not produce translated sidecars for real inputs.

## Change

`lib/cinder/subtitles/translator/libre_translate.ex` only. The behaviour contract is unchanged (`translate(cues, target) :: {:ok,[String]} | {:error,term}`, same length in/out, all-or-nothing); batching is internal.

- Split cues with `Enum.chunk_every(cues, batch_size)`; translate each batch **sequentially** (the engine is CPU-bound with a low thread ceiling — concurrency would only contend, and could trip a rate limit), concatenating results **in order**.
- `Enum.reduce_while` short-circuits on the first batch `{:error, _}` → the whole call fails, so `Srt.render` never gets a partial list and no bad sidecar is written.
- Empty cue list → `{:ok, []}` with **no** HTTP call.
- The timeout is now **per batch**, so it is safe to raise: default `receive_timeout` **60 s** (was 15 s).
- **Tuning knobs** (`batch_size` default 50, `receive_timeout` default 60 000 ms) are read from config with those defaults, overridable via optional env `LIBRETRANSLATE_BATCH_SIZE` / `LIBRETRANSLATE_TIMEOUT` (`config/runtime.exs`). CPU throughput varies per box, so batch size is meant to be tuned empirically without a code change.

Wall time for a movie ≈ (cues / batch_size) batches × a few seconds each = minutes — acceptable, since subtitle work is off the import path and runs in the async 12 h sweeper best-effort.

## Verification

TDD, `Req.Test.stub` pattern: a >batch-size list fans out to N ordered `/translate` calls and concatenates in order; a mid-batch error halts with that error; an empty list makes no call; existing single-request / non-200 / not-configured tests stay green. `mix test` (ExUnit + credo) green on the translator suite; full `test/cinder/subtitles` suite (36) passes; `mix format` clean.

## Out of scope

The LibreTranslate service itself is a separate homelab-stacks deploy (CT 123). `format:"html"` cue handling is unchanged.
