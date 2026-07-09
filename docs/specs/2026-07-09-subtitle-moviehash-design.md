# Subtitle search by moviehash — design (2026-07-09)

## Context

`Cinder.Subtitles` fetches subtitle sidecars from OpenSubtitles by **imdb_id / tmdb_id**
(both on import via `fetch_after_import/2` and on the 12h `Sweeper`), picking the candidate
with the most downloads (`best/2`). The engine's own module doc names the gap:

> `ponytail:` global token (single-instance app); id-based search only — moviehash is the
> sync-accuracy upgrade path.

Id-based search returns *any* subtitle for the movie, which may be timed to a different release
than the file we imported. The **OSDb moviehash** lets OpenSubtitles return subtitles synced to
*this exact rip* (`moviehash_match: true`). That sync accuracy is the whole payoff of this change.

This design supersedes only the "id-based only" limitation in
`2026-07-07-subtitles-engine-design.md`; everything else in that engine is unchanged.

## Scope

- **In:** compute the moviehash of the imported file, send it alongside the existing id search,
  and prefer hash-matched (sync-accurate) candidates. Applies to both import and the sweep.
- **Out:** free-text **title** search. Cinder always has a `tmdb_id`, and id search is strictly
  better than title matching, so a title path would never fire or improve results (YAGNI).
- **Out:** dropping the id search. Hash matches don't always exist; the id search remains the
  fallback so we never lose a subtitle we find today.
- **Out:** any new setting, env var, or UI. Moviehash is automatic whenever a file path exists.

## The moviehash (OSDb)

A 64-bit hash: `filesize + Σ(first 64 KiB as u64 little-endian words) + Σ(last 64 KiB as u64 LE
words)`, taken mod 2⁶⁴ and rendered as a 16-char lowercase, zero-padded hex string. Requires a
file ≥ 128 KiB (64 KiB head + 64 KiB tail); real movie files always satisfy this.

## Components

### New: `Cinder.Subtitles.Moviehash`

A small module — the pure algorithm plus one filesystem orchestration function.

- `compute(size, head, tail) :: String.t()` — **pure.** `head`/`tail` are 65536-byte binaries.
  Sums their u64 little-endian words with `size`, mod 2⁶⁴, renders 16-hex lowercase. This is the
  money logic and carries the test.
- `of_file(path) :: {:ok, hex} | :too_small | {:error, term}` — `lstat` for size; if
  `size < 131072` → `:too_small`; else `read_chunk` the first 64 KiB (offset 0) and last 64 KiB
  (offset `size - 65536`), then `compute`. Resolves the fs impl the same way `Cinder.Subtitles`
  does (`Application.fetch_env!(:cinder, :filesystem)`).

### Changed: `Cinder.Library.Filesystem` (+ `Disk` impl, + Mox mock)

One new callback:

```elixir
@callback read_chunk(path :: String.t(), offset :: non_neg_integer(), length :: pos_integer()) ::
            {:ok, binary()} | {:error, term()}
```

`Disk` impl: `File.open(path, [:read, :binary])` → `:file.pread(io, offset, length)` → close.
The Mox mock (`Cinder.Library.FilesystemMock`) gains it in tests.

### Changed: `Cinder.Subtitles`

- `fetch_missing/2`: before the per-language loop, call `Moviehash.of_file(path)` once; on
  `{:ok, hex}` merge `:moviehash` into `criteria_base`. On `:too_small`/`{:error, _}` omit it —
  the id search proceeds unchanged (best-effort ethos: a hash failure never blocks subtitles).
- `best/2`: prefer hash-matched candidates by sorting on the tuple
  `{moviehash_match, downloads}` (lexicographic → a synced match outranks a more-downloaded
  non-match). The existing language / hearing-impaired / ai-translated / non-nil-file filters
  are unchanged.

### Changed: `Cinder.Subtitles.Provider` + `OpenSubtitles`

- `criteria` type gains `optional(:moviehash) => String.t() | nil`.
- `result` type gains `moviehash_match: boolean()`.
- `OpenSubtitles.search_params/1` adds `moviehash: criteria[:moviehash]` (the existing
  nil/empty reject drops it when absent).
- `OpenSubtitles.normalize/1` reads `attributes["moviehash_match"] || false`; the malformed
  clause defaults it `false`.

## Data flow

```
import / sweep
  └─ Subtitles.fetch_missing(criteria_base, path)
       ├─ Moviehash.of_file(path)              # lstat + 2× read_chunk + compute
       ├─ merge :moviehash into criteria_base  # only on {:ok, hex}
       └─ per language:
            provider.search(%{…id…, moviehash, languages})
              → candidates flagged moviehash_match
            best/2 → prefers a synced match, else most-downloaded
            download → write sidecar
```

## Edge cases

- **File < 128 KiB / unreadable:** `of_file` returns `:too_small`/`{:error, _}`; `:moviehash`
  omitted; id search still runs.
- **Garbled provider entry:** `normalize/1` malformed clause sets `moviehash_match: false`
  (already drops such rows in `best/2` via the nil-`file_id` filter).
- **No id and no hash match:** no results — identical to today's behaviour.

## Testing

- `Moviehash.compute/3` (the required money-logic check):
  - all-zero-bytes vector → hash equals size: `compute(131072, <<0::size(524288)>>,
    <<0::size(524288)>>) == "0000000000020000"` (independently verifiable: zero words sum to 0).
  - a non-zero-word vector to cover little-endian summation and 2⁶⁴ wraparound.
- `Cinder.Subtitles` (Mox fs + Mox provider):
  - criteria carries `:moviehash` when the file is hashable (mock `lstat` + `read_chunk`).
  - `best/2` picks the `moviehash_match: true` candidate over a higher-`downloads` non-match.

## Deliberately skipped (add when measured)

- Title fallback — id search covers it.
- Caching the computed hash — it's one 128 KiB read per fetch at household scale.
- A second subtitle provider / provider-agnostic hashing — one provider today.
