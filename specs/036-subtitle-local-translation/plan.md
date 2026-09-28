# Local Subtitle Extraction and Translation Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Fill configured subtitle languages from matching OpenSubtitles results or, only after a successful provider miss, from embedded or sidecar SRT subtitles translated through self-hosted LibreTranslate.

**Architecture:** Cinder.Subtitles remains the per-language coordinator. It records Cinder-owned subtitle provenance in one hidden JSON manifest beside a video, so only current moviehash matches are stable and ID/local outputs can be upgraded later. The existing MediaInfo and Filesystem seams gain narrow extraction/read operations; a new LibreTranslate behaviour keeps the external HTTP call mockable.

**Tech Stack:** Elixir 1.15, Phoenix, Req, Jason, FFmpeg/ffprobe, Mox, ExUnit, Gettext.

## Global Constraints

- Do not add a database table, migration, or dependency. Jason and Req are already present; the production Docker image already contains FFmpeg.
- The existing subtitle_languages setting, bootstrapped by SUBTITLE_LANGUAGES, is the complete target-language list. DB settings override bootstrap environment values.
- OpenSubtitles selection is per target language: moviehash match first, then ID match. Only an empty successful provider response permits local fallback.
- Provider errors, quota, and translation/extraction failures are best-effort misses: never fail or park a video import and never overwrite the current subtitle.
- Local priority is exact embedded text track, then default non-forced embedded text track translated to each remaining target, then existing SRT sidecar. Do not OCR image tracks or translate ASS, SSA, SUB, or VTT.
- Preserve normal video.lang.srt sidecar names. Never overwrite a sidecar with no Cinder manifest entry; it is user-owned.
- A current opensubtitles_hash manifest entry is stable. opensubtitles_id, embedded, translated, and release_sidecar entries are provisional and sweepable.
- All external services stay behind behaviours; all tests use Mox or Req.Test and make no network or FFmpeg calls.
- Run mix format, mix gettext.extract --merge after label changes, graphify update ., and mix test before the final commit.

---

## File structure

- Create: lib/cinder/subtitles/translator.ex — translation-service behaviour.
- Create: lib/cinder/subtitles/translator/libre_translate.ex — bounded Req client for the self-hosted server.
- Create: test/cinder/subtitles/translator/libre_translate_test.exs — Req.Test contract tests.
- Modify: config/config.exs, config/runtime.exs, config/test.exs, test/test_helper.exs — runtime resolver, env bootstrap, test mock/config.
- Modify: lib/cinder/settings.ex, lib/cinder_web/settings_labels.ex, test/cinder/settings_test.exs, priv/gettext/default.pot, priv/gettext/fr/LC_MESSAGES/default.po — encrypted LibreTranslate settings and translated labels.
- Modify: lib/cinder/library/media_info.ex, lib/cinder/library/media_info/ffprobe.ex, test/cinder/library/media_info/ffprobe_test.exs — extractable embedded text-track seam.
- Modify: lib/cinder/library/filesystem.ex, lib/cinder/library/filesystem/disk.ex, test/cinder/library/filesystem/disk_test.exs — read primitive for source SRTs.
- Modify: lib/cinder/library/sidecars.ex, test/cinder/library/sidecars_test.exs — discover SRT-only fallback candidates.
- Create: lib/cinder/subtitles/srt.ex, test/cinder/subtitles/srt_test.exs — parse/rebuild SRT cue dialogue without modifying timing/control lines.
- Create: lib/cinder/subtitles/manifest.ex, test/cinder/subtitles/manifest_test.exs — hidden JSON provenance storage and stable/provisional predicates.
- Modify: lib/cinder/subtitles.ex, test/cinder/subtitles_test.exs — lock, select, write, provenance, local fallback, and media refresh orchestration.
- Modify: lib/cinder/subtitles/sweeper.ex, test/cinder/subtitles/sweeper_test.exs — pass media kind and revisit only missing/provisional targets.
- Modify: lib/cinder/library.ex, test/cinder/library_subtitles_test.exs — hand off media kind and freshly linked release-sidecar languages to the async subtitle task.
- Modify: README.md, .env.example, docs/operating.md — LibreTranslate setup and revised provenance/upgrade behaviour.

### Task 1: LibreTranslate behaviour, configuration, and settings

**Files:**
- Create: lib/cinder/subtitles/translator.ex
- Create: lib/cinder/subtitles/translator/libre_translate.ex
- Create: test/cinder/subtitles/translator/libre_translate_test.exs
- Modify: config/config.exs
- Modify: config/runtime.exs
- Modify: config/test.exs
- Modify: test/test_helper.exs
- Modify: lib/cinder/settings.ex
- Modify: lib/cinder_web/settings_labels.ex
- Modify: test/cinder/settings_test.exs
- Modify: priv/gettext/default.pot
- Modify: priv/gettext/fr/LC_MESSAGES/default.po

**Interfaces:**
- Consumes: Req and the existing settings registry pattern in Cinder.Settings.
- Produces: Cinder.Subtitles.Translator.translate/2 returning either translated cue bodies or a reason; Application config key subtitles_translator resolved at runtime.

- [ ] **Step 1: Write the failing translator HTTP tests**

Create test/cinder/subtitles/translator/libre_translate_test.exs with tests that configure a Req.Test plug and prove the request body, successful array response, HTTP failure, and missing URL behaviour:

~~~elixir
defmodule Cinder.Subtitles.Translator.LibreTranslateTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Translator.LibreTranslate

  test "translate/2 posts ordered cue bodies with autodetection and HTML preservation" do
    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      assert conn.request_path == "/translate"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "q" => ["<i>Hello</i>", "Goodbye"],
               "source" => "auto",
               "target" => "fr",
               "format" => "html"
             }

      Req.Test.json(conn, %{"translatedText" => ["<i>Bonjour</i>", "Au revoir"]})
    end)

    assert {:ok, ["<i>Bonjour</i>", "Au revoir"]} =
             LibreTranslate.translate(["<i>Hello</i>", "Goodbye"], "fr")
  end

  test "translate/2 returns not_configured without an HTTP call" do
    saved = Application.get_env(:cinder, LibreTranslate)
    Application.put_env(:cinder, LibreTranslate, base_url: nil)
    on_exit(fn -> Application.put_env(:cinder, LibreTranslate, saved) end)

    assert {:error, :not_configured} = LibreTranslate.translate(["Hello"], "fr")
  end
end
~~~

- [ ] **Step 2: Run the new test to verify it fails**

Run: mix test test/cinder/subtitles/translator/libre_translate_test.exs

Expected: compilation fails because Cinder.Subtitles.Translator.LibreTranslate does not exist.

- [ ] **Step 3: Add the behaviour and the minimal bounded HTTP client**

Create lib/cinder/subtitles/translator.ex:

~~~elixir
defmodule Cinder.Subtitles.Translator do
  @callback translate(cues :: [String.t()], target_language :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}
end
~~~

Create lib/cinder/subtitles/translator/libre_translate.ex. Use a 5-second connect timeout and
15-second receive timeout, trim one trailing slash from base_url, and send the exact JSON shape
tested above. Include api_key only when configured. Accept only a 200 response with a
translatedText list whose length equals the input cue count; return {:error, :invalid_response}
for every other successful-but-malformed response and {:error, {:http, status}} for non-200
responses:

~~~elixir
@impl true
def translate(cues, target) when is_list(cues) do
  with base when is_binary(base) and base != "" <- cfg(:base_url),
       {:ok, %{status: 200, body: %{"translatedText" => translated}}}
       when is_list(translated) and length(translated) == length(cues) <-
         Req.post(String.trim_trailing(base, "/") <> "/translate",
           json: request_body(cues, target),
           receive_timeout: 15_000,
           connect_options: [timeout: 5_000]
         ) do
    {:ok, translated}
  else
    nil -> {:error, :not_configured}
    "" -> {:error, :not_configured}
    {:ok, %{status: status}} -> {:error, {:http, status}}
    {:error, reason} -> {:error, reason}
    _ -> {:error, :invalid_response}
  end
end
~~~

Implement request_body/2 so api_key is omitted, not sent as nil. Resolve its module config with
Application.get_env exactly as the OpenSubtitles client does.

- [ ] **Step 4: Wire runtime configuration, Mox, and settings**

Make the following exact additions:

~~~elixir
# config/config.exs
config :cinder, subtitles_translator: Cinder.Subtitles.Translator.LibreTranslate

# config/runtime.exs
if url = System.get_env("LIBRETRANSLATE_URL") do
  config :cinder, Cinder.Subtitles.Translator.LibreTranslate,
    base_url: url,
    api_key: System.get_env("LIBRETRANSLATE_API_KEY")
end

# config/test.exs
config :cinder,
  subtitles_translator: Cinder.Subtitles.TranslatorMock

config :cinder, Cinder.Subtitles.Translator.LibreTranslate,
  base_url: "https://libretranslate.test",
  req_options: [plug: {Req.Test, Cinder.LibreTranslateStub}, retry: false]

# test/test_helper.exs
Mox.defmock(Cinder.Subtitles.TranslatorMock, for: Cinder.Subtitles.Translator)
~~~

Add libretranslate_url as a non-secret field mapped to
Cinder.Subtitles.Translator.LibreTranslate :base_url and libretranslate_api_key as a secret field
mapped to :api_key in the existing subtitles group. Add both module env values to
Cinder.SettingsTest @env_keys. Add their two labels to CinderWeb.SettingsLabels.known/0. Add tests
that saving each setting overlays its module config and that clearing it restores the test bootstrap.

- [ ] **Step 5: Run focused tests and register translations**

Run: mix test test/cinder/subtitles/translator/libre_translate_test.exs test/cinder/settings_test.exs test/cinder_web/no_hardcoded_strings_test.exs

Expected: PASS.

Run: mix gettext.extract --merge

Expected: default.pot and fr.po contain LibreTranslate URL and LibreTranslate API key entries.

- [ ] **Step 6: Commit the independently usable translator seam**

Run:

~~~sh
git add \
  lib/cinder/subtitles/translator.ex \
  lib/cinder/subtitles/translator/libre_translate.ex \
  test/cinder/subtitles/translator/libre_translate_test.exs \
  config/config.exs config/runtime.exs config/test.exs test/test_helper.exs \
  lib/cinder/settings.ex lib/cinder_web/settings_labels.ex test/cinder/settings_test.exs \
  priv/gettext/default.pot priv/gettext/fr/LC_MESSAGES/default.po
git commit -m "feat: configure LibreTranslate subtitles"
~~~

### Task 2: Embedded text-track and SRT-source seams

**Files:**
- Modify: lib/cinder/library/media_info.ex
- Modify: lib/cinder/library/media_info/ffprobe.ex
- Modify: test/cinder/library/media_info/ffprobe_test.exs
- Modify: lib/cinder/library/filesystem.ex
- Modify: lib/cinder/library/filesystem/disk.ex
- Modify: test/cinder/library/filesystem/disk_test.exs
- Modify: lib/cinder/library/sidecars.ex
- Modify: test/cinder/library/sidecars_test.exs
- Create: lib/cinder/subtitles/srt.ex
- Create: test/cinder/subtitles/srt_test.exs

**Interfaces:**
- Consumes: the existing Cinder.Library.MediaInfo and Cinder.Library.Filesystem runtime seams.
- Produces: ordered text-track metadata, SRT extraction bytes, SRT-only sidecar discovery, and safe cue-body extraction/rebuild for the translator.

- [ ] **Step 1: Write failing media-track, filesystem-read, sidecar, and SRT tests**

Add tests with these exact assertions:

~~~elixir
assert Ffprobe.parse_subtitle_tracks(%{
         "streams" => [
           %{
             "index" => 2,
             "codec_name" => "subrip",
             "tags" => %{"language" => "eng"},
             "disposition" => %{"default" => 1, "forced" => 0}
           },
           %{
             "index" => 3,
             "codec_name" => "hdmv_pgs_subtitle",
             "tags" => %{"language" => "fra"},
             "disposition" => %{"default" => 0, "forced" => 0}
           }
         ]
       }) == [%{index: 2, language: "en", default?: true, forced?: false}]

assert {:ok, srt} = Srt.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n\n")
assert Srt.dialogue(srt) == ["<i>Hello</i>"]
assert Srt.render(srt, ["<i>Bonjour</i>"]) ==
         "1\n00:00:01,000 --> 00:00:02,000\n<i>Bonjour</i>\n\n"
assert {:error, :invalid_srt} = Srt.parse("not a cue")
~~~

Add a Disk.read/1 test using a temporary SRT file and a Sidecars.srt_files/1 test proving that an
ASS sidecar is excluded while the matching SRT remains.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: mix test test/cinder/library/media_info/ffprobe_test.exs test/cinder/library/filesystem/disk_test.exs test/cinder/library/sidecars_test.exs test/cinder/subtitles/srt_test.exs

Expected: compilation fails because subtitle_tracks, read, srt_files, and Cinder.Subtitles.Srt do not exist.

- [ ] **Step 3: Extend MediaInfo and FFmpeg extraction**

Add these callbacks to Cinder.Library.MediaInfo without changing probe/1 or its existing stored
language representation:

~~~elixir
@type subtitle_track :: %{
        required(:index) => non_neg_integer(),
        required(:language) => String.t(),
        required(:default?) => boolean(),
        required(:forced?) => boolean()
      }

@callback subtitle_tracks(path :: String.t()) ::
            {:ok, [subtitle_track()]} | {:error, term()}

@callback extract_subtitle(path :: String.t(), index :: non_neg_integer()) ::
            {:ok, binary()} | {:error, term()}
~~~

In Ffprobe, query subtitle streams as JSON using:

~~~elixir
~w(-v error -select_streams s
  -show_entries stream=index,codec_name:stream_disposition=default,forced:stream_tags=language
  -of json) ++ [path]
~~~

Parse with Jason.decode/1. Keep only codec names subrip, ass, ssa, mov_text, text, and webvtt;
normalize eng to en and fre/fra to fr using the parser audio-code aliases already used by
Sidecars. Preserve ffprobe order. Implement extract_subtitle/2 with the configured ffmpeg_bin
(default ffmpeg):

~~~elixir
["-nostdin", "-v", "error", "-i", path, "-map", "0:#{index}",
 "-c:s", "srt", "-f", "srt", "pipe:1"]
~~~

Return stdout only on exit status 0; otherwise return {:error, {:ffmpeg_exit, status, trimmed_stderr}}.
Rescue missing binaries to the same error tuple shape used by probe/1.

- [ ] **Step 4: Add filesystem read, SRT-only discovery, and the SRT transformer**

Add this filesystem callback and Disk implementation:

~~~elixir
@callback read(path :: String.t()) :: {:ok, binary()} | {:error, term()}

@impl true
def read(path), do: File.read(path)
~~~

Add Sidecars.srt_files/1 by filtering the existing Sidecars.files/1 result on the lowercase
.srt extension; do not alter release-sidecar import behaviour for other formats.

Create Cinder.Subtitles.Srt with exactly three public operations:

~~~elixir
@spec parse(binary()) :: {:ok, t()} | {:error, :invalid_srt}
@spec dialogue(t()) :: [String.t()]
@spec render(t(), [String.t()]) :: binary()
~~~

Parse complete numbered SRT cues only: a numeric sequence line, a timing line containing -->, and
at least one dialogue line. Preserve each cue prefix, dialogue, and original blank separator.
render/2 must reject a mismatched translated-cue count with {:error, :cue_count_mismatch}. The
translator client already sends format html, so retained SRT inline HTML markup is not stripped or
translated as control text.

- [ ] **Step 5: Run the seam tests**

Run: mix test test/cinder/library/media_info/ffprobe_test.exs test/cinder/library/filesystem/disk_test.exs test/cinder/library/sidecars_test.exs test/cinder/subtitles/srt_test.exs

Expected: PASS.

- [ ] **Step 6: Commit local-source primitives**

Run:

~~~sh
git add \
  lib/cinder/library/media_info.ex lib/cinder/library/media_info/ffprobe.ex \
  test/cinder/library/media_info/ffprobe_test.exs \
  lib/cinder/library/filesystem.ex lib/cinder/library/filesystem/disk.ex \
  test/cinder/library/filesystem/disk_test.exs \
  lib/cinder/library/sidecars.ex test/cinder/library/sidecars_test.exs \
  lib/cinder/subtitles/srt.ex test/cinder/subtitles/srt_test.exs
git commit -m "feat: add local subtitle source seams"
~~~

### Task 3: Provenance manifest and per-language subtitle coordinator

**Files:**
- Create: lib/cinder/subtitles/manifest.ex
- Create: test/cinder/subtitles/manifest_test.exs
- Modify: lib/cinder/subtitles.ex
- Modify: test/cinder/subtitles_test.exs
- Modify: lib/cinder/library.ex

**Interfaces:**
- Consumes: Translator.translate/2, MediaInfo.subtitle_tracks/1, MediaInfo.extract_subtitle/2,
  Sidecars.srt_files/1, Filesystem read/write/rename/lstat, Moviehash.of_file/1, and the existing
  OpenSubtitles provider.
- Produces: fetch_missing/3 and fetch_after_import/4 with per-language stable/provisional state;
  Cinder.Library.refresh/2 for the post-sidecar media-server scan.

- [ ] **Step 1: Write failing manifest and coordinator tests**

Create manifest tests for deterministic path, missing/corrupt JSON fallback, stable hash status,
and video-hash invalidation:

~~~elixir
state = %{video_moviehash: "old", tracks: %{"fr" => %{origin: "opensubtitles_hash"}}}
refute Manifest.stable?(state, "new", "fr")
assert Manifest.provisional?(state, "new", "fr")
~~~

Replace the existing "existing sidecar skips provider" test in test/cinder/subtitles_test.exs
with concrete tests for each policy branch:

~~~elixir
test "an ID result is provisional and a later hash result replaces it" do
  video = "/lib/M/M.mkv"
  target = "/lib/M/M.fr.srt"

  stub(FilesystemMock, :moviehash_data, fn ^video -> :too_small end)
  expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
    {:ok, [%{file_id: 1, language: "fr", downloads: 1, hearing_impaired: false,
             ai_translated: false, moviehash_match: false}]}
  end)
  expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, "ID SRT"} end)
  expect(FilesystemMock, :rename, fn temp, ^target ->
    assert String.contains?(temp, ".cinder-subtitle-")
    :ok
  end)

  assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies)
  assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(video)
end

test "provider failure does not call an embedded source or LibreTranslate" do
  expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)
  assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, "/lib/M/M.mkv", :movies)
end

test "an empty provider result extracts an exact embedded target track" do
  expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
  expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn _ ->
    {:ok, [%{index: 2, language: "fr", default?: false, forced?: false}]}
  end)
  expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn _, 2 -> {:ok, "FR SRT"} end)
  assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, "/lib/M/M.mkv", :movies)
end

test "a default embedded track translates each still-missing target" do
  expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
  expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn _ ->
    {:ok, [%{index: 3, language: "en", default?: true, forced?: false}]}
  end)
  expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn _, 3 ->
    {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
  end)
  expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" -> {:ok, ["Bonjour"]} end)
  assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, "/lib/M/M.mkv", :movies)
end
~~~

Add separate named tests for the two remaining source-safety cases: when MediaInfo returns no
usable track, Sidecars.srt_files/1 and FilesystemMock.read/1 provide the translation source; and
an unmarked target sidecar receives neither FilesystemMock.write/2 nor FilesystemMock.rename/2
even when a provider candidate exists.

Use Mox expectations to assert write to a unique temporary sibling then rename to the exact
video.lang.srt path. Assert MediaServerMock.scan(:movies) after a successful commit.

- [ ] **Step 2: Run the coordinator tests to verify they fail**

Run: mix test test/cinder/subtitles/manifest_test.exs test/cinder/subtitles_test.exs

Expected: compilation fails because Cinder.Subtitles.Manifest and the three-argument
fetch_missing/3 API do not exist.

- [ ] **Step 3: Implement the hidden manifest**

Create Cinder.Subtitles.Manifest. Use the exact hidden adjacent path:

~~~elixir
def path(video_path) do
  Path.join(Path.dirname(video_path), "." <> Path.basename(video_path) <> ".cinder-subtitles.json")
end
~~~

Implement read/1 through Filesystem.read/1 and Jason.decode/1. Missing, unreadable, or malformed
manifests return %{video_moviehash: nil, tracks: %{}} and log a warning for malformed JSON. Implement
put/4, stable?/3, and provisional?/3 over the five origins named in the design. Write JSON through
a unique sibling temporary path and Filesystem.rename/2. Write the subtitle first, then the
manifest: an interruption can leave an untracked sidecar but cannot misclassify an old subtitle as
a stable hash match.

- [ ] **Step 4: Replace the existing-sidecar short circuit with per-language selection**

Change Cinder.Subtitles public APIs to:

~~~elixir
@spec fetch_missing(map(), String.t(), :movies | :tv) :: :ok | :quota_exceeded
def fetch_missing(criteria_base, video_path, kind)

@spec fetch_after_import((-> map()), String.t(), :movies | :tv, [String.t()]) :: :ok
def fetch_after_import(criteria_fun, video_path, kind, release_sidecar_languages)
~~~

Keep a two-argument fetch_missing/2 wrapper that delegates with :movies only for the existing
direct context tests; all production callers must use the three-argument form.

Inside a :global.trans lock keyed by {Cinder.Subtitles, video_path}:

1. Compute the moviehash lazily and read manifest state.
2. Skip only a current opensubtitles_hash target.
3. Search OpenSubtitles before looking at the target path. Make best/2 return
   {:hash, result}, {:id, result}, or nil after the existing language, HI, AI, and file-id filters.
4. On :hash, atomically write only a missing or Cinder-managed target and record
   opensubtitles_hash. On :id, write only a missing or provisional Cinder target and record
   opensubtitles_id; if the current provisional file already has an ID origin, do not redownload it.
5. On nil from a successful search, list MediaInfo.subtitle_tracks/1. Prefer an exact target
   language, otherwise extract the first default non-forced track once, Srt.parse/1 it, call
   Translator.translate/2 for each remaining target, and render the translated cues.
6. If no usable embedded track exists, call Sidecars.srt_files/1. Prefer an exact-language source;
   otherwise read the first SRT, parse it, and translate it. Never feed non-SRT sidecars to the
   translator.
7. Provider failures and quota return without entering steps 5 or 6. Extraction, parsing,
   translation, and write failures log and leave the existing target intact.

Mark passed release_sidecar_languages as release_sidecar only when the normal target path exists,
so the current import's ordinary linked source is managed but a pre-existing manual target is not.

Extract the existing private Library scan into public Cinder.Library.refresh/2 with the same
rescue/catch/log behaviour, then call it after a successful subtitle commit. Update import code to
call refresh/2 in place of the former private scan/2.

- [ ] **Step 5: Run manifest and coordinator tests**

Run: mix test test/cinder/subtitles/manifest_test.exs test/cinder/subtitles_test.exs test/cinder/library_test.exs

Expected: PASS.

- [ ] **Step 6: Commit provenance-aware subtitle selection**

Run:

~~~sh
git add \
  lib/cinder/subtitles/manifest.ex test/cinder/subtitles/manifest_test.exs \
  lib/cinder/subtitles.ex test/cinder/subtitles_test.exs \
  lib/cinder/library.ex
git commit -m "feat: add subtitle fallback provenance"
~~~

### Task 4: Import/sweeper wiring, documentation, and full verification

**Files:**
- Modify: lib/cinder/subtitles/sweeper.ex
- Modify: test/cinder/subtitles/sweeper_test.exs
- Modify: lib/cinder/library.ex
- Modify: test/cinder/library_subtitles_test.exs
- Modify: README.md
- Modify: .env.example
- Modify: docs/operating.md

**Interfaces:**
- Consumes: Task 3 fetch_after_import/4 and fetch_missing/3.
- Produces: correct movie/TV media kinds and current-release sidecar provenance from both import paths; operator instructions for the self-hosted service.

- [ ] **Step 1: Write failing import and sweeper integration tests**

Update test/cinder/library_subtitles_test.exs so the async import expectations prove the new
arguments and preserve the non-blocking task boundary:

~~~elixir
expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
  send(parent, :subtitle_search)
  {:error, :down}
end)

assert {:ok, ^dest, quality} = Library.import_movie(movie)
assert quality.sidecar_subtitles == []
assert_receive :subtitle_search, 2_000
~~~

Add a folder-import test with a linked Movie.en.srt asserting fetch_after_import receives
:movies and ["en"]. Add the episode equivalent asserting :tv and the episode quality's linked
languages.

Add a movie and episode sweep test that each uses a successful provider result and asserts the
kind passed to the post-sidecar refresh:

~~~elixir
test "movie sweep refreshes the movies library after a committed subtitle" do
  _movie = movie_fixture(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)
  expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
  {:ok, pid} = start_supervised({Sweeper, name: :movie_kind_sweeper})
  assert :ok = Sweeper.poll(pid)
end

test "episode sweep refreshes the TV library after a committed subtitle" do
  series = series_fixture(tmdb_id: 42)
  season = season_fixture(series, %{season_number: 1})
  _episode = episode_fixture(season, %{episode_number: 2, file_path: "/lib/S/S01E02.mkv"})
  expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
  {:ok, pid} = start_supervised({Sweeper, name: :episode_kind_sweeper})
  assert :ok = Sweeper.poll(pid)
end
~~~

Keep the sweeper suite focused on its own contract: it must supply the correct movie/TV kind and
must still halt only on :quota_exceeded. Stable-hash skip, ID recheck without a second download,
and hash replacement are asserted in the coordinator's direct test file.

- [ ] **Step 2: Run the integration tests to verify they fail**

Run: mix test test/cinder/library_subtitles_test.exs test/cinder/subtitles/sweeper_test.exs

Expected: failures from the old two-argument dispatch and old "sidecar exists means skip" assumptions.

- [ ] **Step 3: Wire both import paths and the sweeper**

In Library.import_movie/2, pass :movies and quality.sidecar_subtitles to fetch_subtitles after
maybe_link_sidecars/5. In fetch_episode_subtitles/2, destructure each quality map and pass :tv
plus Map.get(quality, :sidecar_subtitles, []).

Update the private fetch_subtitles helper to call:

~~~elixir
Cinder.Subtitles.fetch_after_import(criteria_fun, dest, kind, release_sidecar_languages)
~~~

Update Sweeper.sweep/0 units to carry media kind and invoke:

~~~elixir
Subtitles.fetch_missing(criteria_fun.(), path, kind)
~~~

Keep quota handling exactly as today: only :quota_exceeded halts a sweep tick.

- [ ] **Step 4: Update user-facing configuration and behaviour documentation**

Make these documentation changes:

- Add LIBRETRANSLATE_URL and LIBRETRANSLATE_API_KEY, labelled optional fallback translation, to
  .env.example immediately after the OpenSubtitles block.
- Amend the README Subtitles configuration row and bootstrap-variable example to mention
  LibreTranslate URL/key and provisional local/ID subtitle upgrades.
- Replace docs/operating.md's obsolete id-only matching description with moviehash-first, ID
  fallback, local embedded/SRT fallback, and the rule that only configured target languages are
  generated. State that LibreTranslate must be self-hosted separately and is used only after an
  empty successful OpenSubtitles response.

- [ ] **Step 5: Format, update the graph, and run the full project check**

Run:

~~~sh
mix format
graphify update .
mix test
~~~

Expected: all compile warnings, formatting, Credo, migrations, and ExUnit tests pass.

- [ ] **Step 6: Commit the wired feature**

Run:

~~~sh
git add \
  lib/cinder/library.ex lib/cinder/subtitles/sweeper.ex \
  test/cinder/library_subtitles_test.exs test/cinder/subtitles/sweeper_test.exs \
  README.md .env.example docs/operating.md graphify-out
git commit -m "feat: translate local subtitle fallbacks"
~~~

## Plan self-review

- Spec coverage: Task 1 covers the LibreTranslate settings and external behaviour. Task 2 covers text-track discovery, extraction, source reads, and SRT integrity. Task 3 covers provenance, provider priority, local fallback, manual-sidecar protection, atomic replacement, and media refresh. Task 4 covers import and sweep dispatch plus operator configuration.
- Placeholder scan: the plan names every changed file, public interface, test assertion, command, and commit. It contains no deferred implementation markers.
- Type consistency: Translator.translate/2, MediaInfo.subtitle_tracks/1, MediaInfo.extract_subtitle/2, Manifest stable?/3, fetch_missing/3, and fetch_after_import/4 are defined before their consuming tasks.
