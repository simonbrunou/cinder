# Media Info: Audio Languages + Subtitles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture each acquired file's true audio languages + embedded/sidecar subtitle languages at import (movies + TV), store them on the row, import release-shipped sidecar files, backfill existing library, and show it all on the detail pages.

**Architecture:** One `ffprobe` call per imported file yields audio + subtitle stream languages; a shared sidecar helper hardlinks loose `.srt`-family files next to the video and reports their languages. All three lists ride the existing `quality` map that `Cinder.Library`'s `place/7` already returns and the pollers already write onto the row via `imported_*` columns. A Mix task backfills already-imported media. Display is two `<dl>` rows (movie) + per-episode badges (series).

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + ecto_sqlite3, Mox, ExUnit, ffprobe (behaviour-wrapped).

## Global Constraints

- `mix test` (the alias) is the source of truth: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Every task ends green.
- External services reached ONLY through behaviours resolved via `Application.get_env(:cinder, key)` at runtime (`fetch_env!`/`get_env`, never `compile_env`). Tests never touch disk or network — `filesystem: Cinder.Library.FilesystemMock`, `media_info` opted-in per-test as `Cinder.Library.MediaInfoMock`.
- Every movie status write goes through `Cinder.Catalog.transition`; episode pipeline writes through `transition_episode`/`finish_grab`. `set_media_info/2` (this plan) is a **descriptive** writer (not a status transition), in the style of `set_movie_language/2` — it must not touch status/file_path/grab_id.
- Language codes stored lowercase ISO; `"und"` for an unresolvable track/file.
- Stored fields on both `movies` and `episodes`: `imported_audio_languages`, `imported_embedded_subtitles`, `imported_sidecar_subtitles`, each `{:array, :string}`.
- New user-facing strings use `gettext(...)`. Run `mix gettext.extract --merge` **last** (after all lib edits) — `#:` line refs drift and fail CI's `--check-up-to-date` otherwise.
- ecto_sqlite3 pins the test pool to `pool_size: 1`; an intermittent "connection not available"/"Database busy" on an unrelated test is the known flake — re-run to confirm, don't chase.

---

### Task 1: Schema fields, migration, descriptive writer

**Files:**
- Create: `priv/repo/migrations/20260707000000_add_media_info_to_movies_and_episodes.exs`
- Modify: `lib/cinder/catalog/movie.ex` (schema + `transition_changeset` cast list; add `media_info_changeset/2`)
- Modify: `lib/cinder/catalog/episode.ex` (schema + `transition_changeset` cast list; add `media_info_changeset/2`)
- Modify: `lib/cinder/catalog.ex` (add `set_media_info/2`; add the 3 fields to every `imported_* : nil` reset block)
- Test: `test/cinder/catalog/media_info_test.exs`

**Interfaces:**
- Produces:
  - `Movie` / `Episode` schema fields `imported_audio_languages`, `imported_embedded_subtitles`, `imported_sidecar_subtitles` (`{:array, :string}`), castable by `transition_changeset/2` and by new `media_info_changeset/2`.
  - `Cinder.Catalog.set_media_info(%Movie{} | %Episode{}, %{audio_languages: [String.t()], embedded_subtitles: [String.t()], sidecar_subtitles: [String.t()]}) :: {:ok, struct} | {:error, Ecto.Changeset.t()}`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Cinder.Repo.Migrations.AddMediaInfoToMoviesAndEpisodes do
  use Ecto.Migration

  def change do
    for table <- [:movies, :episodes] do
      alter table(table) do
        add :imported_audio_languages, {:array, :string}
        add :imported_embedded_subtitles, {:array, :string}
        add :imported_sidecar_subtitles, {:array, :string}
      end
    end
  end
end
```

- [ ] **Step 2: Add schema fields + cast lists**

In `lib/cinder/catalog/movie.ex`, add to the `schema "movies"` block after `field :imported_source, :string`:

```elixir
    field :imported_audio_languages, {:array, :string}
    field :imported_embedded_subtitles, {:array, :string}
    field :imported_sidecar_subtitles, {:array, :string}
```

Add the same three keys to the `cast(attrs, [...])` list inside `transition_changeset/2`. Then add the descriptive changeset:

```elixir
  @doc "Changeset for the import-time media-info capture / backfill. Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/file/download fields."
  def media_info_changeset(movie, attrs) do
    cast(movie, attrs, [
      :imported_audio_languages,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
  end
```

Apply the identical three changes to `lib/cinder/catalog/episode.ex` (schema block, `transition_changeset/2` cast list, and a `media_info_changeset/2`).

- [ ] **Step 3: Add `set_media_info/2` to `lib/cinder/catalog.ex`**

Place near `set_movie_language/2` (~line 397). Model its broadcast on the existing patterns (`{:movie_updated, m}` for movies; `broadcast_series/1` for episodes):

```elixir
  @doc """
  Persists the probed media info (audio languages + embedded/sidecar subtitle languages) onto a
  movie or episode. Descriptive-only — used by the import capture and the backfill task; not a
  status transition.
  """
  def set_media_info(%Movie{} = movie, info) do
    with {:ok, updated} <- movie |> Movie.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def set_media_info(%Episode{} = episode, info) do
    with {:ok, updated} <- episode |> Episode.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast_series(series_id_for_episode(updated))
      {:ok, updated}
    end
  end

  # Translate the bare-keyed capture map to the imported_* column names the changeset casts.
  defp media_info_attrs(info) do
    %{
      imported_audio_languages: Map.get(info, :audio_languages, []),
      imported_embedded_subtitles: Map.get(info, :embedded_subtitles, []),
      imported_sidecar_subtitles: Map.get(info, :sidecar_subtitles, [])
    }
  end
```

Note: `set_media_info/2` accepts a **bare-keyed** map (`%{audio_languages:, embedded_subtitles:, sidecar_subtitles:}`) — the same key shape the import quality map uses — and `media_info_attrs/1` maps them to the `imported_*` columns. The import path (Task 4) does not call `set_media_info`; it writes the `imported_*` columns directly in the poller/`finish_grab`.

If no `series_id_for_episode/1` helper exists, load it inline: `Repo.one(from s in Season, join: e in Episode, on: e.season_id == s.id, where: e.id == ^episode.id, select: s.series_id)`. (Check `series_id_for_grab/1` at catalog.ex:1757 for the existing pattern; reuse or mirror it.)

- [ ] **Step 4: Extend the `imported_* : nil` reset blocks**

The 3 new fields must be nulled anywhere the existing `imported_*` fields are reset (retry / delete-file), so a re-grab doesn't show stale media info. Find them:

Run: `grep -rn "imported_source: nil" lib/cinder/catalog.ex`
Known sites include the episode delete-file reset (~catalog.ex:945) and the movie reset (~catalog.ex:1014). At **each** block that sets `imported_resolution: nil, imported_size: nil, imported_language: nil, imported_source: nil`, add:

```elixir
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil,
```

- [ ] **Step 5: Write the failing test**

```elixir
defmodule Cinder.Catalog.MediaInfoTest do
  use Cinder.DataCase, async: true

  alias Cinder.Catalog

  test "set_media_info persists the three lists on a movie" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    {:ok, updated} =
      Catalog.set_media_info(movie, %{
        audio_languages: ["en", "fr"],
        embedded_subtitles: ["en"],
        sidecar_subtitles: ["fr"]
      })

    assert updated.imported_audio_languages == ["en", "fr"]
    assert updated.imported_embedded_subtitles == ["en"]
    assert updated.imported_sidecar_subtitles == ["fr"]
    assert Catalog.get_movie!(updated.id).imported_sidecar_subtitles == ["fr"]
  end

  test "set_media_info persists on an episode" do
    ep = episode_fixture(%{file_path: "/tv/S (2020)/Season 01/S (2020) - S01E01.mkv"})

    {:ok, updated} =
      Catalog.set_media_info(ep, %{audio_languages: ["ja"], embedded_subtitles: ["en"], sidecar_subtitles: []})

    assert updated.imported_audio_languages == ["ja"]
    assert updated.imported_embedded_subtitles == ["en"]
    assert updated.imported_sidecar_subtitles == []
  end
end
```

Use whatever movie/episode fixtures the suite already provides (grep `test/support` for `movie_fixture`/`episode_fixture`; if the episode fixture needs a season/series, follow an existing episode test's setup).

- [ ] **Step 6: Run migration + test, verify it passes**

Run: `mix ecto.migrate && mix test test/cinder/catalog/media_info_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/cinder/catalog test/cinder/catalog/media_info_test.exs
git commit -m "feat(catalog): store audio-language + subtitle info on movies/episodes"
```

---

### Task 2: `MediaInfo.probe/1` — one ffprobe call, audio + subtitle streams

**Files:**
- Modify: `lib/cinder/library/media_info.ex` (replace the `audio_languages/1` callback with `probe/1`)
- Modify: `lib/cinder/library/media_info/ffprobe.ex` (one probe, bucket by codec_type)
- Modify: `lib/cinder/library.ex` (`check_audio/3` reads `.audio`)
- Modify: existing tests that stub `audio_languages`: `test/cinder/library_media_info_test.exs`, `test/cinder/download/poller_test.exs` (grep both for `audio_languages`)
- Test: `test/cinder/library/media_info/ffprobe_test.exs` (create if absent; else extend `library_media_info_test.exs`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `@callback probe(path :: String.t()) :: {:ok, %{audio: [String.t()], subtitles: [String.t()]}} | {:error, term()}` on `Cinder.Library.MediaInfo`. Codes lowercased; `und`/`unknown`/empty dropped.

- [ ] **Step 1: Write the failing test** (`ffprobe_test.exs`)

```elixir
defmodule Cinder.Library.MediaInfo.FfprobeTest do
  use ExUnit.Case, async: true
  alias Cinder.Library.MediaInfo.Ffprobe

  test "parse buckets audio + subtitle streams by codec_type, dropping und/empty" do
    out = "video,\naudio,eng\naudio,fre\nsubtitle,eng\nsubtitle,und\naudio,\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end
end
```

(`parse/1` becomes public — `def parse(out)` — so it's unit-testable without shelling out. It already exists as a private helper; widen it and change its shape.)

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder/library/media_info/ffprobe_test.exs`
Expected: FAIL (`parse/1` private or returns a list, not the map).

- [ ] **Step 3: Change the behaviour callback**

In `lib/cinder/library/media_info.ex`, replace the `audio_languages` `@callback` and its doc with:

```elixir
  @doc """
  Probes `path`'s streams. Returns `{:ok, %{audio: [code], subtitles: [code]}}` — the language
  codes of the audio and subtitle streams (lowercased; untagged/`und` dropped) — or
  `{:error, reason}` if the probe can't run. The importer treats an error as "can't verify" and
  imports anyway; the audio park check reads `.audio` and parks only on a *positive* mismatch.
  """
  @callback probe(path :: String.t()) :: {:ok, %{audio: [String.t()], subtitles: [String.t()]}} | {:error, term()}
```

- [ ] **Step 4: Rewrite the Ffprobe impl**

`lib/cinder/library/media_info/ffprobe.ex`:

```elixir
defmodule Cinder.Library.MediaInfo.Ffprobe do
  @moduledoc """
  `Cinder.Library.MediaInfo` via the `ffprobe` CLI (FFmpeg). Reads every stream's `codec_type`
  and `language` tag in one call, buckets audio vs subtitle streams, and drops untagged/`und`
  streams. Returns `{:ok, %{audio: codes, subtitles: codes}}` or `{:error, reason}` when `ffprobe`
  is missing or exits non-zero — the importer treats an error (or empty lists) as "can't verify"
  and imports anyway, so a host without `ffprobe` degrades rather than blocking imports.

  The binary is `ffprobe` on `PATH` by default; override with `config :cinder, :ffprobe_bin`.
  """
  @behaviour Cinder.Library.MediaInfo

  @ignored ~w(und unknown)

  @impl true
  def probe(path) do
    case System.cmd(bin(), args(path), stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, e}
  end

  # One line per stream: "codec_type,language" (language empty when the stream has no tag).
  defp args(path),
    do: ~w(-v error -show_entries stream=codec_type:stream_tags=language -of csv=p=0) ++ [path]

  @doc false
  def parse(out) do
    rows =
      out
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(&parse_row/1)

    %{
      audio: for({"audio", lang} <- rows, lang != nil, do: lang),
      subtitles: for({"subtitle", lang} <- rows, lang != nil, do: lang)
    }
  end

  # "audio,eng" -> {"audio", "eng"}; "video," / "audio,und" -> {_, nil} (dropped downstream).
  defp parse_row(line) do
    case String.split(line, ",", parts: 2) do
      [type, lang] -> {String.trim(type), normalize(lang)}
      [type] -> {String.trim(type), nil}
    end
  end

  defp normalize(lang) do
    code = lang |> String.trim() |> String.downcase()
    if code == "" or code in @ignored, do: nil, else: code
  end

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
end
```

- [ ] **Step 5: Update `check_audio/3` in `lib/cinder/library.ex`**

```elixir
  defp check_audio(impl, source, target) do
    case impl.probe(source) do
      {:ok, %{audio: []}} -> :ok
      {:ok, %{audio: langs}} -> audio_result(Language.audio_satisfies?(target, langs))
      {:error, _reason} -> :ok
    end
  end
```

- [ ] **Step 6: Update existing stubs**

Grep and update every `expect(Cinder.Library.MediaInfoMock, :audio_languages, ...)` to `:probe`, returning the new shape. Example transform:

```elixir
# was:
expect(MediaInfoMock, :audio_languages, fn _ -> {:ok, ["eng"]} end)
# now:
expect(MediaInfoMock, :probe, fn _ -> {:ok, %{audio: ["eng"], subtitles: []}} end)
```

Run: `grep -rn "audio_languages" test lib` — every hit must be gone (the callback no longer exists).

- [ ] **Step 7: Run tests, verify pass**

Run: `mix test test/cinder/library/media_info/ffprobe_test.exs test/cinder/library_media_info_test.exs test/cinder/download/poller_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/library test/cinder
git commit -m "refactor(media-info): probe/1 returns audio + subtitle stream languages"
```

---

### Task 3: `Cinder.Library.Sidecars` — parse, find, link loose subtitles

**Files:**
- Create: `lib/cinder/library/sidecars.ex`
- Test: `test/cinder/library/sidecars_test.exs`

**Interfaces:**
- Consumes: `Cinder.Library.Filesystem` via `Cinder.Library`'s `fs/0` — but to stay self-contained, `Sidecars` reads the fs impl the same way: `Application.get_env(:cinder, :filesystem)`.
- Produces:
  - `Cinder.Library.Sidecars.language(filename :: String.t()) :: String.t()` — the ISO code from a sidecar filename (`"Movie.en.srt" -> "en"`, `"Movie.eng.forced.srt" -> "en"`, `"subs.srt" -> "und"`).
  - `Cinder.Library.Sidecars.files(source_video :: String.t()) :: [{path :: String.t(), lang :: String.t()}]` — sidecar files in the source video's folder that belong to it (stem match, or any sub when the folder holds exactly one video).
  - `Cinder.Library.Sidecars.link(source_video :: String.t(), dest_video :: String.t()) :: [String.t()]` — hardlinks each belonging sidecar next to `dest_video` renamed `<dest_stem>.<lang>[.forced].<ext>`; returns the linked languages (best-effort: a per-file `ln` error is logged and skipped, never raised).

**Details:**
- Subtitle extensions: `~w(.srt .ass .ssa .sub .vtt)`.
- Flag tokens (not languages): `~w(forced sdh cc hi)`. When the token before the extension is a flag, the language token is the one before it (`Movie.en.forced.srt` → lang `en`, flag `forced`); a bare `Movie.forced.srt` → lang `und`, flag preserved.
- Language alias map: reuse `Cinder.Acquisition.Parser.audio_codes/0` (`%{"fr" => ["fr","fra","fre"], ...}`) inverted to `code_alias -> iso1`, plus full English names when cheap (`"english" => "en"`, `"french" => "fr"` — derive from `Parser.language_tags/0` downcased if convenient). Unknown token → `"und"`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cinder.Library.SidecarsTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!

  alias Cinder.Library.Sidecars
  alias Cinder.Library.FilesystemMock

  test "language/1 maps filename tokens to iso codes; flags ignored; unknown -> und" do
    assert Sidecars.language("Movie (2020).en.srt") == "en"
    assert Sidecars.language("Movie (2020).eng.forced.srt") == "en"
    assert Sidecars.language("Movie (2020).fre.srt") == "fr"
    assert Sidecars.language("subs.srt") == "und"
    assert Sidecars.language("Movie (2020).forced.srt") == "und"
  end

  test "files/1 returns stem-matching sidecars with languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {"#{dir}/Movie (2020).mkv", 900},
         {"#{dir}/Movie (2020).en.srt", 10},
         {"#{dir}/Movie (2020).fr.srt", 10},
         {"#{dir}/other.txt", 1}
       ]}
    end)

    assert Sidecars.files(src) == [
             {"#{dir}/Movie (2020).en.srt", "en"},
             {"#{dir}/Movie (2020).fr.srt", "fr"}
           ]
  end

  test "link/2 hardlinks each sidecar next to the dest, renamed, returns languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {"#{dir}/Movie (2020).en.srt", 10}]}
    end)

    expect(FilesystemMock, :ln, fn "#{dir}/Movie (2020).en.srt",
                                    "/lib/Movie (2020)/Movie (2020).en.srt" ->
      :ok
    end)

    assert Sidecars.link(src, dest) == ["en"]
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder/library/sidecars_test.exs`
Expected: FAIL (module/functions undefined).

- [ ] **Step 3: Implement `lib/cinder/library/sidecars.ex`**

```elixir
defmodule Cinder.Library.Sidecars do
  @moduledoc """
  Loose subtitle files (`.srt`/`.ass`/…) that ship alongside a downloaded video. On import we
  hardlink each belonging sidecar next to the imported video (renamed to the media-server's
  `<video>.<lang>[.forced].<ext>` convention) so Jellyfin/Plex pick them up, and report their
  languages for storage. Filesystem access goes through `Cinder.Library.Filesystem`.
  """
  require Logger

  alias Cinder.Acquisition.Parser

  @sub_exts ~w(.srt .ass .ssa .sub .vtt)
  @flags ~w(forced sdh cc hi)
  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # iso-alias -> iso1 (e.g. "fra"/"fre"/"fr" -> "fr"), plus full-word names.
  @aliases (for {iso1, codes} <- Parser.audio_codes(), code <- codes, into: %{}, do: {code, iso1})
  @names (for {iso1, tag} <- Parser.language_tags(), into: %{}, do: {String.downcase(tag), iso1})

  @doc "ISO code from a sidecar filename; flags stripped; unknown/absent -> \"und\"."
  def language(filename) do
    tokens =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> String.split(".")
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 in @flags))

    Enum.find_value(Enum.reverse(tokens), "und", fn tok -> @aliases[tok] || @names[tok] end)
  end

  @doc "Sidecar files belonging to `source_video` (stem match, or any sub when the folder holds one video)."
  def files(source_video) do
    dir = Path.dirname(source_video)

    with true <- fs().dir?(dir),
         {:ok, entries} <- fs().find_files(dir) do
      paths = Enum.map(entries, fn {p, _size} -> p end)
      subs = Enum.filter(paths, &(String.downcase(Path.extname(&1)) in @sub_exts))
      stem = Path.rootname(Path.basename(source_video))
      lone_video? = Enum.count(paths, &(String.downcase(Path.extname(&1)) in @video_exts)) == 1

      subs
      |> Enum.filter(fn p -> lone_video? or String.starts_with?(Path.basename(p), stem) end)
      |> Enum.map(fn p -> {p, language(p)} end)
    else
      _ -> []
    end
  end

  @doc "Hardlinks belonging sidecars next to `dest_video`; returns linked languages (best-effort)."
  def link(source_video, dest_video) do
    dest_stem = Path.rootname(dest_video)

    for {path, lang} <- files(source_video), do_link(path, dest_dir_name(dest_stem, path, lang)) == :ok do
      lang
    end
  end

  defp dest_dir_name(dest_stem, src_path, lang) do
    flag = src_path |> flags_of() |> Enum.map(&".#{&1}") |> Enum.join()
    "#{dest_stem}.#{lang}#{flag}#{String.downcase(Path.extname(src_path))}"
  end

  defp flags_of(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.split(".")
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(&1 in @flags))
  end

  defp do_link(src, dest) do
    case fs().ln(src, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("sidecar link failed #{src} -> #{dest}: #{inspect(reason)}")
        :error
    end
  end

  defp fs, do: Application.get_env(:cinder, :filesystem)
end
```

- [ ] **Step 4: Run the test, verify pass**

Run: `mix test test/cinder/library/sidecars_test.exs`
Expected: PASS. (If the `files/1` ordering assertion is brittle, sort both sides by path.)

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/library/sidecars.ex test/cinder/library/sidecars_test.exs
git commit -m "feat(library): sidecar subtitle discovery, language parse, hardlink"
```

---

### Task 4: Capture wiring — probe + sidecars into the import quality map

**Files:**
- Modify: `lib/cinder/library.ex` (`capture_media/2`; merge into `new_quality`; `place/7` links sidecars on a fresh/replace placement; extend `old_quality/1`)
- Modify: `lib/cinder/download/poller.ex` (two write sites: ~171 and ~299 — add the 3 fields)
- Modify: `lib/cinder/catalog.ex` (`finish_grab/2` write, ~1289 — add the 3 fields)
- Test: extend `test/cinder/library_test.exs` (or wherever `import_movie`/`import_episodes` are tested — grep) with capture assertions.

**Interfaces:**
- Consumes: `Cinder.Library.Sidecars.link/2`; `MediaInfo.probe/1` (Task 2); `set_media_info` fields (Task 1).
- Produces: the `quality` map returned by `import_movie/2` and each tuple of `import_episodes/2` gains keys `:audio_languages`, `:embedded_subtitles`, `:sidecar_subtitles` (lists). The pollers/`finish_grab` map them to the `imported_*` columns.

**Design notes (read before coding):**
- `place/7` returns `{:ok, quality}` today. Keep that shape. Compute media info **into** `new_quality` up front (probe is over the source, whose content equals the dest hardlink); `old_quality/1` gains the 3 stored fields so the keep-branch carries them.
- Sidecar **linking** is a side effect that must run only when a new file is actually placed — do it inside `place/7`'s fresh (`ln == :ok`), cross-fs (`:exdev`), and upgrade-replace branches, NOT the keep/idempotent branch. `Sidecars.link/2` is best-effort and never fails the import.
- The sidecar **languages** in the quality map come from `Sidecars.files(source)` (a scan, no linking) so they're known even before/without linking; `link/2` links the same set. One extra `find_files` scan on the rare keep path is acceptable (`# ponytail: re-scans source on keep; import is infrequent`).

- [ ] **Step 1: Write the failing test** (movie capture)

```elixir
test "import_movie captures audio + embedded + sidecar languages into quality", %{} = ctx do
  # media_info opt-in for this test
  Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
  on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

  movie = movie_fixture(%{status: :downloaded, file_path: "/dl/M (2020)/M (2020).1080p.mkv", preferred_language: "any"})
  # ... stub fs().lstat, ln, mkdir_p, find_files (sidecar), media_server scan as the existing
  # import_movie tests do; add:
  expect(MediaInfoMock, :probe, fn _ -> {:ok, %{audio: ["eng", "fre"], subtitles: ["eng"]}} end)
  # find_files for the source dir returns the video + one .fr.srt; expect an ln for that sidecar.

  {:ok, _dest, q} = Cinder.Library.import_movie(movie)

  assert q.audio_languages == ["eng", "fre"]
  assert q.embedded_subtitles == ["eng"]
  assert q.sidecar_subtitles == ["fr"]
end
```

Model the fs stubs on the nearest existing `import_movie` test (grep `test/cinder/library_test.exs` for `import_movie` and copy its Mox setup; add the `probe` expectation and the sidecar `find_files`/`ln`).

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder/library_test.exs -k "captures audio"` (or the file + line)
Expected: FAIL (`q` has no `:audio_languages`).

- [ ] **Step 3: Add `capture_media/1` and merge it into `new_quality` call sites**

In `lib/cinder/library.ex`, add:

```elixir
  # Audio + embedded subtitle languages (one probe) and the release's sidecar languages (a folder
  # scan). Empty lists when media_info is disabled or the probe errors — never blocks the import.
  defp capture_media(source) do
    %{audio: audio, subtitles: embedded} =
      case media_info() do
        nil -> %{audio: [], subtitles: []}
        impl -> case impl.probe(source), do: ({:ok, m} -> m; {:error, _} -> %{audio: [], subtitles: []})
      end

    %{
      audio_languages: audio,
      embedded_subtitles: embedded,
      sidecar_subtitles: source |> Cinder.Library.Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    }
  end
```

At the two `new_q = new_quality(parsed, size)` sites (in `import_movie/2` ~line 66 and `place_episode_file/4` ~line 446), merge in the media info:

```elixir
         new_q = Map.merge(new_quality(parsed, size), capture_media(source)),
```

- [ ] **Step 4: Extend `old_quality/1` and link sidecars on placement**

Extend `old_quality/1` (~line 136) so the keep-branch carries the stored lists:

```elixir
  defp old_quality(record) do
    %{
      resolution: record.imported_resolution,
      size: record.imported_size,
      language: record.imported_language,
      source: record.imported_source,
      audio_languages: record.imported_audio_languages,
      embedded_subtitles: record.imported_embedded_subtitles,
      sidecar_subtitles: record.imported_sidecar_subtitles
    }
  end
```

In `place/7`, link sidecars on the three *placed* branches. The fresh `ln == :ok` branch:

```elixir
      :ok ->
        Cinder.Library.Sidecars.link(source, dest)
        {:ok, new_q}
```

The `:exdev` branch and the `do_resolve(..., false, true, ...)` replace branch each do `with :ok <- replace(source, dest)` — after the replace succeeds, add `Cinder.Library.Sidecars.link(source, dest)` before returning `{:ok, new_q}`. Do **not** add it to the keep branch or the same-inode idempotent branch.

- [ ] **Step 5: Thread the 3 fields through the write sites**

`lib/cinder/download/poller.ex` — at **both** transition write maps (~171 and ~299), add after `imported_source: q.source`:

```elixir
                 imported_audio_languages: q.audio_languages,
                 imported_embedded_subtitles: q.embedded_subtitles,
                 imported_sidecar_subtitles: q.sidecar_subtitles,
```

`lib/cinder/catalog.ex` — in `finish_grab/2`'s `Repo.update_all(... set: [...])` (~1294), add:

```elixir
              imported_audio_languages: q.audio_languages,
              imported_embedded_subtitles: q.embedded_subtitles,
              imported_sidecar_subtitles: q.sidecar_subtitles,
```

- [ ] **Step 6: Write the TV capture test + run all**

Add an `import_episodes` test mirroring Step 1 (grep the existing TV import tests for the fs setup; assert the returned `{ep_id, dest, q}` tuple's `q.audio_languages`/`embedded_subtitles`/`sidecar_subtitles`). Then:

Run: `mix test test/cinder/library_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs`
Expected: PASS. Fix any existing import test that now needs a `probe` stub (media_info is nil by default, so tests that DON'T opt in get `capture_media` → empty lists and need no probe stub; only opted-in ones do).

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/library.ex lib/cinder/download/poller.ex lib/cinder/catalog.ex test/cinder
git commit -m "feat(library): capture audio/subtitle languages + import sidecars at import"
```

---

### Task 5: Backfill Mix task

**Files:**
- Create: `lib/mix/tasks/cinder.media_info.backfill.ex`
- Test: `test/mix/tasks/cinder_media_info_backfill_test.exs`

**Interfaces:**
- Consumes: `Catalog.set_media_info/2`, `MediaInfo.probe/1`, `Sidecars.files/1`, `Cinder.Repo`.
- Produces: `mix cinder.media_info.backfill` — fills the 3 fields on every `:available` movie + every episode with a `file_path`. Idempotent.

**Design:** put the reusable logic in a plain function `Cinder.Library.Backfill.run/0` (so the test calls it directly without `Mix.Task.run`), and make the Mix task a thin `app.start` + `run/0` wrapper. For each item: probe its `file_path`; scan its `file_path`'s folder for sidecars via `Sidecars.files/1`; `set_media_info/2`. **Stated limitation** (docstring): sidecars dropped by pre-feature imports are unrecoverable; this reports embedded + whatever `.srt` sits next to the file now.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Mix.Tasks.Cinder.MediaInfo.BackfillTest do
  use Cinder.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  test "fills media info on an available movie from probe + sidecar scan" do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ -> {:ok, %{audio: ["eng"], subtitles: ["eng"]}} end)
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, [{"/lib/M (2020)/M (2020).fr.srt", 10}]} end)

    Cinder.Library.Backfill.run()

    m = Cinder.Catalog.get_movie!(movie.id)
    assert m.imported_audio_languages == ["eng"]
    assert m.imported_embedded_subtitles == ["eng"]
    assert m.imported_sidecar_subtitles == ["fr"]
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/mix/tasks/cinder_media_info_backfill_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement backfill logic + task**

`lib/cinder/library/backfill.ex`:

```elixir
defmodule Cinder.Library.Backfill do
  @moduledoc """
  One-time media-info backfill for media imported before the feature landed. Probes each
  `:available` movie / filed episode and scans for present sidecars, writing the three
  `imported_*` language lists. Idempotent. Cannot recover sidecars that pre-feature imports left
  in the download folder (only the video was hardlinked then) — reports embedded tracks + whatever
  `.srt` currently sits next to the file.
  """
  require Logger
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Library.Sidecars
  alias Cinder.Repo

  def run do
    movies = Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
    episodes = Repo.all(from e in Episode, where: not is_nil(e.file_path))
    Enum.each(movies ++ episodes, &backfill_one/1)
  end

  defp backfill_one(record) do
    info = %{
      sidecar_subtitles: record.file_path |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    }

    info =
      case probe(record.file_path) do
        {:ok, %{audio: a, subtitles: s}} -> Map.merge(info, %{audio_languages: a, embedded_subtitles: s})
        _ -> Map.merge(info, %{audio_languages: [], embedded_subtitles: []})
      end

    case Catalog.set_media_info(record, info) do
      {:ok, _} -> :ok
      {:error, e} -> Logger.warning("backfill failed for #{record.file_path}: #{inspect(e)}")
    end
  end

  defp probe(path) do
    case Application.get_env(:cinder, :media_info) do
      nil -> :error
      impl -> impl.probe(path)
    end
  end
end
```

`lib/mix/tasks/cinder.media_info.backfill.ex`:

```elixir
defmodule Mix.Tasks.Cinder.MediaInfo.Backfill do
  @shortdoc "Backfill audio/subtitle language info onto already-imported media"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Cinder.Library.Backfill.run()
    Mix.shell().info("Media-info backfill complete.")
  end
end
```

- [ ] **Step 4: Run the test, verify pass**

Run: `mix test test/mix/tasks/cinder_media_info_backfill_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/library/backfill.ex lib/mix/tasks test/mix
git commit -m "feat(library): mix cinder.media_info.backfill for existing library"
```

---

### Task 6: Display — movie detail rows + series episode badges

**Files:**
- Modify: `lib/cinder_web/live/movie_detail_live.ex` (two `<dl>` rows in the "Downloaded file" panel, ~line 148)
- Modify: `lib/cinder_web/live/series_detail_live.ex` (compact badges on each imported episode row)
- Run: `mix gettext.extract --merge` (LAST)
- Test: extend `test/cinder_web/live/movie_detail_live_test.exs` and `.../series_detail_live_test.exs`

**Interfaces:**
- Consumes: `@movie.imported_audio_languages` etc. (Task 1 fields), already loaded on the assign.

- [ ] **Step 1: Write the failing render test (movie)**

```elixir
test "shows audio + subtitle languages when present", %{conn: conn} do
  movie = movie_fixture(%{status: :available, file_path: "/l/M/M.mkv",
    imported_audio_languages: ["en", "fr"],
    imported_embedded_subtitles: ["en"], imported_sidecar_subtitles: ["fr"]})

  {:ok, _lv, html} = live(conn, ~p"/movies/#{movie.id}")
  assert html =~ "Audio"
  assert html =~ "en"
  assert html =~ "fr"
  assert html =~ "embedded"
  assert html =~ "sidecar"
end
```

(Match the route + auth setup the existing movie_detail test uses.)

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder_web/live/movie_detail_live_test.exs -k "audio + subtitle"`
Expected: FAIL.

- [ ] **Step 3: Add the movie `<dl>` rows**

In `movie_detail_live.ex`, inside the existing `<dl>` (after the Language `<div>`, ~line 151), add:

```elixir
            <div :if={@movie.imported_audio_languages not in [nil, []]}>
              <dt class="text-base-content/60">{gettext("Audio")}</dt>
              <dd class="flex flex-wrap gap-1 font-medium">
                <span :for={l <- @movie.imported_audio_languages} class="badge badge-ghost badge-xs">{l}</span>
              </dd>
            </div>
            <div :if={
              @movie.imported_embedded_subtitles not in [nil, []] or
                @movie.imported_sidecar_subtitles not in [nil, []]
            }>
              <dt class="text-base-content/60">{gettext("Subtitles")}</dt>
              <dd class="flex flex-wrap gap-1 font-medium">
                <span :for={l <- @movie.imported_embedded_subtitles || []} class="badge badge-ghost badge-xs">
                  {l} <span class="opacity-60">{gettext("embedded")}</span>
                </span>
                <span :for={l <- @movie.imported_sidecar_subtitles || []} class="badge badge-outline badge-xs">
                  {l} <span class="opacity-60">{gettext("sidecar")}</span>
                </span>
              </dd>
            </div>
```

- [ ] **Step 4: Add the series per-episode badges**

In `series_detail_live.ex`, locate the per-episode row (the element rendering `ep.episode_number`/title with the monitor toggle + delete-file control). For an imported episode, add compact badges. Insert near the episode's title cell:

```elixir
            <span :if={ep.file_path && ep.imported_audio_languages not in [nil, []]} class="ml-2 inline-flex flex-wrap gap-1 align-middle">
              <span :for={l <- ep.imported_audio_languages} class="badge badge-ghost badge-xs" aria-label={gettext("audio %{lang}", lang: l)}>{l}</span>
              <span
                :for={l <- (ep.imported_embedded_subtitles || []) ++ (ep.imported_sidecar_subtitles || [])}
                class="badge badge-outline badge-xs"
                aria-label={gettext("subtitle %{lang}", lang: l)}
              >{l}</span>
            </span>
```

(Series-detail episodes are already preloaded — confirm the assign includes the new fields; schema preload carries them automatically. Keep it minimal per the spec.)

- [ ] **Step 5: Add a series render test**

Mirror Step 1 for a filed episode with the fields set; assert the badge languages appear. Follow the existing `series_detail_live_test.exs` setup (admin auth + a series/season/episode fixture).

- [ ] **Step 6: Extract translations (LAST)**

Run: `mix gettext.extract --merge`
Then: `mix test test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/series_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Full suite + commit**

Run: `mix test`
Expected: green (fix any residual `audio_languages`→`probe` stub or gettext line-ref drift). Then:

```bash
git add lib/cinder_web priv/gettext test/cinder_web
git commit -m "feat(web): show audio + subtitle languages on movie/series detail"
```

---

## Self-Review

**Spec coverage:**
- Capture audio/embedded/sidecar → Tasks 2 (probe), 3 (sidecars), 4 (wiring). ✓
- Storage as 3 arrays × movies+episodes → Task 1. ✓
- One ffprobe call, `probe/1` replacing `audio_languages/1`, audio-park unchanged → Task 2. ✓
- Import release-shipped sidecars (hardlink) → Tasks 3 + 4 (place branches). ✓
- Capture runs unconditionally (not gated on preferred-language) → Task 4: `capture_media` is called at `new_quality` merge, independent of `verify_audio`'s nil short-circuit. ✓
- Backfill task + stated limitation → Task 5. ✓
- Display movie `<dl>` + series per-episode badges + gettext-last → Task 6. ✓
- Non-goals (picker untouched, no forced/SDH fields, no OpenSubtitles change) → nothing in the plan touches them. ✓

**Placeholder scan:** no TBD/TODO; every code step shows code; commands have expected output. ✓

**Type consistency:** `probe/1` returns `%{audio:, subtitles:}` everywhere (Task 2 impl, Task 4 `capture_media`, Task 5 backfill). Quality-map keys `:audio_languages/:embedded_subtitles/:sidecar_subtitles` are consistent across Task 4 (produce), poller/finish_grab (consume), and column names `imported_audio_languages/…`. `set_media_info/2` takes `%{audio_languages:, embedded_subtitles:, sidecar_subtitles:}` — matches Tasks 4/5 callers and the `media_info_changeset` cast keys (Task 1). ⚠ One deliberate asymmetry: `set_media_info` input keys are the bare names, mapped by `media_info_changeset` to the `imported_*` columns — confirm the changeset casts `imported_*` and the caller maps (in Task 1 the changeset casts the column names, so `set_media_info` must build column-keyed attrs; **Task 1 Step 3 passes `info` straight to the changeset — the caller must key `info` by `imported_audio_languages` etc.**).

Resolved: standardize on **column-keyed** info maps end to end. In Tasks 4 & 5, build the info/quality with `:imported_audio_languages`-style keys? No — the quality map already uses bare keys for `resolution/size/language/source` and the pollers map them explicitly. So keep bare keys in the quality map, and have `set_media_info/2` translate: change Task 1 Step 3 to cast via an explicit map:

```elixir
  def set_media_info(record, %{audio_languages: a, embedded_subtitles: e, sidecar_subtitles: s}) do
    attrs = %{imported_audio_languages: a, imported_embedded_subtitles: e, imported_sidecar_subtitles: s}
    # ...changeset(attrs)...
  end
```

Apply that translation in `set_media_info/2` (both clauses) so backfill/Task 5 pass bare-keyed maps and the columns get the `imported_*` names. The import path (Task 4) does NOT use `set_media_info` — it writes columns directly in the poller/finish_grab, so it already uses `imported_*`. Consistent.
