# Subtitle search by moviehash — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute the OSDb moviehash of an imported video file, send it alongside the existing OpenSubtitles id search, and prefer hash-synced subtitle candidates — falling back to the current id search.

**Architecture:** A pure `Cinder.Subtitles.Moviehash.compute/3` (the hash algorithm, tested with vectors) plus `of_file/1` that reads the file's size + first/last 64 KiB through one new filesystem behaviour callback `moviehash_data/1`. `Cinder.Subtitles.fetch_missing/2` computes the hash once and merges `:moviehash` into the search criteria; `best/2` prefers `moviehash_match: true` candidates. The `Provider`/`OpenSubtitles` types and query params gain moviehash.

**Tech Stack:** Elixir, Mox (behaviour mocks), Req.Test (provider HTTP stub), ExUnit.

## Global Constraints

- `mix test` (the alias) must stay green: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Run it as the source of truth.
- External services reached only through behaviours; **tests never hit the network or touch disk via the behaviour** (Mox). A direct unit test of the real `Disk` impl against a temp file is allowed (that is how the real impl is tested — see `test/cinder/library/filesystem/disk_test.exs`).
- Best-effort ethos: a moviehash failure must never block the subtitle fetch — omit the hash and let the id search proceed.
- Follow existing house style: pure logic in dedicated modules (`Parser`/`Scorer` pattern), malformed external data degrades instead of raising.

---

### Task 1: `Moviehash` module + `moviehash_data/1` filesystem callback

**Files:**
- Create: `lib/cinder/subtitles/moviehash.ex`
- Modify: `lib/cinder/library/filesystem.ex` (add the `moviehash_data/1` callback)
- Modify: `lib/cinder/library/filesystem/disk.ex` (implement it)
- Test: `test/cinder/subtitles/moviehash_test.exs` (pure `compute/3` + `of_file/1` via Mox fs)
- Test: `test/cinder/library/filesystem/disk_test.exs` (real temp-file `moviehash_data/1`)

**Interfaces:**
- Produces: `Cinder.Subtitles.Moviehash.compute(size :: non_neg_integer, head :: binary, tail :: binary) :: String.t()` — head/tail are 65536-byte binaries; returns 16-char lowercase hex.
- Produces: `Cinder.Subtitles.Moviehash.of_file(path :: String.t()) :: {:ok, String.t()} | :too_small | {:error, term()}`.
- Produces (behaviour): `Cinder.Library.Filesystem.moviehash_data(path :: String.t()) :: {:ok, {non_neg_integer, binary, binary}} | :too_small | {:error, term()}`.
- Consumes: the fs impl resolved via `Application.fetch_env!(:cinder, :filesystem)` (mock in test is `Cinder.Library.FilesystemMock`).

- [ ] **Step 1: Write the failing `compute/3` vector tests**

Create `test/cinder/subtitles/moviehash_test.exs`:

```elixir
defmodule Cinder.Subtitles.MoviehashTest do
  use ExUnit.Case, async: true

  import Mox
  setup :verify_on_exit!

  alias Cinder.Subtitles.Moviehash

  @chunk_bits 65_536 * 8

  test "compute/3: all-zero bytes => hash equals the file size (16-hex, zero-padded)" do
    zeros = <<0::size(@chunk_bits)>>
    # 131_072 = 0x20000
    assert Moviehash.compute(131_072, zeros, zeros) == "0000000000020000"
  end

  test "compute/3: sums little-endian u64 words of head and tail with the size" do
    # one word = 1 in the head, everything else zero, size 0 => total 1
    head = <<1::little-unsigned-64, 0::size(@chunk_bits - 64)>>
    tail = <<0::size(@chunk_bits)>>
    assert Moviehash.compute(0, head, tail) == "0000000000000001"
  end

  test "compute/3: wraps at 2^64 (a max u64 word + size 1 overflows to 0)" do
    head = <<0xFFFFFFFFFFFFFFFF::little-unsigned-64, 0::size(@chunk_bits - 64)>>
    tail = <<0::size(@chunk_bits)>>
    assert Moviehash.compute(1, head, tail) == "0000000000000000"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/subtitles/moviehash_test.exs`
Expected: FAIL — `Cinder.Subtitles.Moviehash` is undefined.

- [ ] **Step 3: Implement `compute/3` and `of_file/1`**

Create `lib/cinder/subtitles/moviehash.ex`:

```elixir
defmodule Cinder.Subtitles.Moviehash do
  @moduledoc """
  The OpenSubtitles OSDb moviehash: `filesize + Σ(u64 little-endian words of the first 64 KiB) +
  Σ(same of the last 64 KiB)`, taken mod 2^64 and rendered as 16-char lowercase hex. Sent as the
  `moviehash` search param so OpenSubtitles can return subtitles synced to this exact rip.

  `compute/3` is pure (tested with vectors). `of_file/1` reads size + the two 64 KiB chunks
  through the `Cinder.Library.Filesystem` behaviour, so tests use the Mox mock and never touch
  disk. A file smaller than 128 KiB (never a real movie) is `:too_small`.
  """

  import Bitwise

  @u64 0xFFFF_FFFF_FFFF_FFFF

  @doc "Pure OSDb hash of a file's `size` and its 65536-byte `head`/`tail` chunks."
  @spec compute(non_neg_integer(), binary(), binary()) :: String.t()
  def compute(size, head, tail) do
    (size + sum_words(head) + sum_words(tail))
    |> band(@u64)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  @doc "Hash of the file at `path`, or `:too_small` / `{:error, _}` (best-effort — never raises for the caller to handle)."
  @spec of_file(String.t()) :: {:ok, String.t()} | :too_small | {:error, term()}
  def of_file(path) do
    case fs().moviehash_data(path) do
      {:ok, {size, head, tail}} -> {:ok, compute(size, head, tail)}
      other -> other
    end
  end

  defp sum_words(bin) do
    for <<word::little-unsigned-64 <- bin>>, reduce: 0 do
      acc -> acc + word
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
```

- [ ] **Step 4: Run the `compute/3` tests to verify they pass**

Run: `mix test test/cinder/subtitles/moviehash_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Add the `moviehash_data/1` behaviour callback**

In `lib/cinder/library/filesystem.ex`, add after the `write/2` callback (last line before `end`):

```elixir
  @callback moviehash_data(path :: String.t()) ::
              {:ok, {non_neg_integer(), binary(), binary()}} | :too_small | {:error, term()}
```

- [ ] **Step 6: Write the failing `of_file/1` tests (Mox fs)**

Append to `test/cinder/subtitles/moviehash_test.exs` (inside the module):

```elixir
  test "of_file/1: hashes {size, head, tail} from the filesystem" do
    zeros = <<0::size(@chunk_bits)>>

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn "/lib/M/M.mkv" ->
      {:ok, {131_072, zeros, zeros}}
    end)

    assert Moviehash.of_file("/lib/M/M.mkv") == {:ok, "0000000000020000"}
  end

  test "of_file/1: passes :too_small and {:error, _} straight through" do
    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    assert Moviehash.of_file("/lib/small.mkv") == :too_small

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> {:error, :enoent} end)
    assert Moviehash.of_file("/lib/gone.mkv") == {:error, :enoent}
  end
```

- [ ] **Step 7: Run to verify the `of_file/1` tests fail**

Run: `mix test test/cinder/subtitles/moviehash_test.exs`
Expected: FAIL — `Cinder.Library.FilesystemMock` has no `moviehash_data` expectation defined (the mock is generated from the behaviour, so it needs recompilation from Step 5; the failure is the missing expectation / unknown function).

- [ ] **Step 8: Implement `moviehash_data/1` in the Disk impl**

In `lib/cinder/library/filesystem/disk.ex`, add the implementation (module attribute near the top, function among the others). The chunk size and min-size are OSDb constants:

```elixir
  @moviehash_chunk 65_536
  @moviehash_min 2 * @moviehash_chunk

  @impl true
  def moviehash_data(path) do
    with {:ok, %{size: size}} <- lstat(path),
         true <- size >= @moviehash_min || :too_small,
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, head} <- :file.pread(io, 0, @moviehash_chunk),
             {:ok, tail} <- :file.pread(io, size - @moviehash_chunk, @moviehash_chunk) do
          {:ok, {size, head, tail}}
        end
      after
        File.close(io)
      end
    else
      :too_small -> :too_small
      {:error, _} = err -> err
    end
  end
```

Note: `lstat/1` already exists in this module — reuse it. If `lstat` returns a bare `File.Stat`
struct rather than a map, match `%File.Stat{size: size}` instead of `%{size: size}` to be explicit.

- [ ] **Step 9: Run the moviehash test file to verify `of_file/1` passes**

Run: `mix test test/cinder/subtitles/moviehash_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 10: Write the failing Disk temp-file test**

In `test/cinder/library/filesystem/disk_test.exs`, add (follow the file's existing temp-file setup/pattern; this uses `System.tmp_dir!` + a unique name):

```elixir
  test "moviehash_data/1 returns {size, head, tail} for a >=128KiB file and :too_small below it" do
    dir = Path.join(System.tmp_dir!(), "cinder-moviehash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    big = Path.join(dir, "big.mkv")
    File.write!(big, :binary.copy(<<0>>, 200_000))
    assert {:ok, {200_000, head, tail}} = Cinder.Library.Filesystem.Disk.moviehash_data(big)
    assert byte_size(head) == 65_536
    assert byte_size(tail) == 65_536

    small = Path.join(dir, "small.mkv")
    File.write!(small, :binary.copy(<<0>>, 1000))
    assert :too_small = Cinder.Library.Filesystem.Disk.moviehash_data(small)

    assert {:error, _} = Cinder.Library.Filesystem.Disk.moviehash_data(Path.join(dir, "nope.mkv"))
  end
```

- [ ] **Step 11: Run the Disk test to verify it passes**

Run: `mix test test/cinder/library/filesystem/disk_test.exs`
Expected: PASS (existing tests + the new one). If the pre-existing tests use a shared `setup` for the temp dir, adapt the new test to reuse it rather than making its own.

- [ ] **Step 12: Full suite + commit**

Run: `mix test`
Expected: PASS (existing subtitle/library tests still green — Task 1 adds a new fs function that nothing else calls yet, so nothing else changes).

```bash
git add lib/cinder/subtitles/moviehash.ex lib/cinder/library/filesystem.ex \
        lib/cinder/library/filesystem/disk.ex \
        test/cinder/subtitles/moviehash_test.exs test/cinder/library/filesystem/disk_test.exs
git commit -m "feat: OSDb moviehash computation + moviehash_data fs callback"
```

---

### Task 2: Thread moviehash through the `Provider` + `OpenSubtitles`

**Files:**
- Modify: `lib/cinder/subtitles/provider.ex` (`criteria` + `result` types)
- Modify: `lib/cinder/subtitles/provider/open_subtitles.ex` (`search_params/1` + `normalize/1`)
- Test: `test/cinder/subtitles/provider/open_subtitles_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `search/1` accepts `criteria` with an optional `:moviehash` (string) and sends it as the `moviehash` query param; normalized `result` maps now include `moviehash_match: boolean()`.

- [ ] **Step 1: Write the failing provider tests**

Add to `test/cinder/subtitles/provider/open_subtitles_test.exs`:

```elixir
  test "search/1 sends the moviehash param and normalizes moviehash_match" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["moviehash"] == "0123456789abcdef"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "attributes" => %{
              "language" => "en",
              "download_count" => 5,
              "hearing_impaired" => false,
              "ai_translated" => false,
              "moviehash_match" => true,
              "files" => [%{"file_id" => 7}]
            }
          }
        ]
      })
    end)

    assert {:ok, [r]} =
             OpenSubtitles.search(%{
               imdb_id: "tt0111161",
               moviehash: "0123456789abcdef",
               languages: ["en"]
             })

    assert r == %{
             file_id: 7,
             language: "en",
             downloads: 5,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: true
           }
  end

  test "search/1 defaults moviehash_match to false when the attribute is absent" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{"attributes" => %{"language" => "en", "download_count" => 1, "files" => [%{"file_id" => 1}]}}
        ]
      })
    end)

    assert {:ok, [%{moviehash_match: false}]} =
             OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
  end
```

Also update the **existing** `"search/1 sends Api-Key + query params and normalizes results"` test's expected map (line ~37) to include the new key:

```elixir
    assert r == %{
             file_id: 42,
             language: "en",
             downloads: 500,
             hearing_impaired: false,
             ai_translated: false,
             moviehash_match: false
           }
```

- [ ] **Step 2: Run to verify failures**

Run: `mix test test/cinder/subtitles/provider/open_subtitles_test.exs`
Expected: FAIL — the new `moviehash` param is not sent; normalized maps lack `moviehash_match`; the updated existing assertion mismatches.

- [ ] **Step 3: Add `moviehash` to `search_params/1` and `moviehash_match` to `normalize/1`**

In `lib/cinder/subtitles/provider/open_subtitles.ex`, add the param inside `search_params/1`'s keyword list (after `episode_number:`):

```elixir
      episode_number: criteria[:episode],
      moviehash: criteria[:moviehash],
```

(The existing trailing `|> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)` already drops it when absent.)

In both `normalize/1` clauses, add the field. The `%{"attributes" => a}` clause:

```elixir
      ai_translated: a["ai_translated"] || false,
      moviehash_match: a["moviehash_match"] || false
```

The malformed fallthrough clause:

```elixir
  defp normalize(_malformed) do
    %{
      file_id: nil,
      language: nil,
      downloads: 0,
      hearing_impaired: false,
      ai_translated: false,
      moviehash_match: false
    }
  end
```

- [ ] **Step 4: Update the behaviour types**

In `lib/cinder/subtitles/provider.ex`, add `:moviehash` to `criteria` (after `:episode`) and `moviehash_match` to `result`:

```elixir
  @type criteria :: %{
          optional(:imdb_id) => String.t() | nil,
          optional(:tmdb_id) => integer() | nil,
          optional(:season) => integer() | nil,
          optional(:episode) => integer() | nil,
          optional(:moviehash) => String.t() | nil,
          required(:languages) => [String.t()]
        }

  @type result :: %{
          file_id: term(),
          language: String.t(),
          downloads: integer(),
          hearing_impaired: boolean(),
          ai_translated: boolean(),
          moviehash_match: boolean()
        }
```

- [ ] **Step 5: Run the provider tests to verify they pass**

Run: `mix test test/cinder/subtitles/provider/open_subtitles_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/subtitles/provider.ex lib/cinder/subtitles/provider/open_subtitles.ex \
        test/cinder/subtitles/provider/open_subtitles_test.exs
git commit -m "feat: send moviehash param + normalize moviehash_match in OpenSubtitles provider"
```

---

### Task 3: Merge the hash into `fetch_missing` + prefer hash matches in `best/2`

**Files:**
- Modify: `lib/cinder/subtitles.ex` (`fetch_missing/2`, `best/2`)
- Test: `test/cinder/subtitles_test.exs`
- Test (stub touch-ups): `test/cinder/subtitles/sweeper_test.exs`, `test/cinder/library_subtitles_test.exs`

**Interfaces:**
- Consumes: `Cinder.Subtitles.Moviehash.of_file/1` (Task 1); the `moviehash`/`moviehash_match` provider shape (Task 2).
- Produces: `fetch_missing/2` now merges `:moviehash` into the criteria when the file hashes; `best/2` prefers `moviehash_match: true` candidates.

- [ ] **Step 1: Write the failing behavioural tests**

Add to `test/cinder/subtitles_test.exs`. These set an explicit `moviehash_data` expectation (overriding the default stub added in Step 4):

```elixir
  test "fetch_missing/2 merges the file's moviehash into the search criteria" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    zeros = <<0::size(65_536 * 8)>>

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn "/lib/M/M.mkv" -> {:ok, {131_072, zeros, zeros}} end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", moviehash: "0000000000020000", languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)
    |> expect(:download, fn 1 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 prefers a moviehash-matched candidate over a higher-downloads non-match" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    zeros = <<0::size(65_536 * 8)>>

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn _ -> {:ok, {131_072, zeros, zeros}} end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{languages: ["en"]} ->
      {:ok,
       [
         %{file_id: 1, language: "en", downloads: 999, hearing_impaired: false, ai_translated: false, moviehash_match: false},
         %{file_id: 2, language: "en", downloads: 5, hearing_impaired: false, ai_translated: false, moviehash_match: true}
       ]}
    end)
    |> expect(:download, fn 2 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 still searches by id when the file is not hashable" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn _ -> :too_small end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn criteria ->
      refute Map.has_key?(criteria, :moviehash)
      {:ok, [%{file_id: 1, language: "en", downloads: 1, hearing_impaired: false, ai_translated: false, moviehash_match: false}]}
    end)
    |> expect(:download, fn 1 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `mix test test/cinder/subtitles_test.exs`
Expected: FAIL — `fetch_missing` does not call `moviehash_data`, does not merge `:moviehash`, and `best/2` ignores `moviehash_match`. Many pre-existing tests in this file ALSO fail now, because `fetch_missing` will call `moviehash_data` which they don't stub — Step 4 fixes those.

- [ ] **Step 3: Implement the `fetch_missing/2` merge and the `best/2` preference**

In `lib/cinder/subtitles.ex`, change `fetch_missing/2` to compute the hash once and merge it:

```elixir
  @spec fetch_missing(map(), String.t()) :: :ok | :quota_exceeded
  def fetch_missing(criteria_base, dest_path) do
    criteria_base = with_moviehash(criteria_base, dest_path)

    Enum.reduce_while(wanted_languages(), :ok, fn lang, _acc ->
      case fetch_one(criteria_base, lang, dest_path) do
        :quota_exceeded -> {:halt, :quota_exceeded}
        _ -> {:cont, :ok}
      end
    end)
  end

  # Best-effort: a hashable file adds :moviehash (sync-accurate matches); :too_small / error just
  # leaves the id search as-is. Computed once per fetch, not per language.
  defp with_moviehash(criteria_base, dest_path) do
    case Cinder.Subtitles.Moviehash.of_file(dest_path) do
      {:ok, hash} -> Map.put(criteria_base, :moviehash, hash)
      _ -> criteria_base
    end
  end
```

Change `best/2` to prefer hash matches (tuple compares lexicographically; `Map.get/3` tolerates a candidate that omits the key):

```elixir
  # Best candidate: exact language, not hearing-impaired, not machine-translated, has a file_id.
  # Prefer a moviehash-synced match, then most downloads.
  defp best(results, lang) do
    results
    |> Enum.filter(fn r ->
      String.downcase(r.language || "") == lang and not r.hearing_impaired and not r.ai_translated and
        not is_nil(r.file_id)
    end)
    |> Enum.max_by(&{(Map.get(&1, :moviehash_match, false) && 1) || 0, &1.downloads}, fn -> nil end)
  end
```

- [ ] **Step 4: Add the default `moviehash_data` stub to pre-existing tests that reach `fetch_missing`**

`fetch_missing` now always calls `moviehash_data`. Existing tests that don't care must stub it as `:too_small` so behaviour is unchanged.

In `test/cinder/subtitles_test.exs`, add to the `setup` block (after the `Application.put_env` line, before `:ok`):

```elixir
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
```

The three tests from Step 1 set an explicit `expect(:moviehash_data, …)`, which takes precedence over the stub — no conflict. Note: `Subtitles.fetch_missing/2`'s `"no languages"` test never reaches `with_moviehash`? It does (with_moviehash runs before the language loop) — but `wanted_languages() == []`... `with_moviehash` runs regardless, so it WILL call `moviehash_data`. The stub covers it. (This is fine: hashing a file with no wanted languages is one wasted stat in that one no-op test; in production `fetch_after_import`/the sweeper only call `fetch_missing` when languages are configured — the sweeper guards on `wanted_languages() == []` and the library only fetches when configured. If you prefer to avoid the wasted hash entirely, short-circuit: `if wanted_languages() == [], do: :ok, else: …` at the top of `fetch_missing` — optional, not required for correctness.)

In `test/cinder/subtitles/sweeper_test.exs`: it already uses `stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)`. Add alongside it (in the same test bodies that reach a fetch, or the shared setup if there is one):

```elixir
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
```

In `test/cinder/library_subtitles_test.exs`: the two import tests dispatch the fetch on a Task using global Mox. Add the same stub next to the existing `stub(Cinder.Library.FilesystemMock, :lstat, …)` so the Task's `fetch_missing` finds it:

```elixir
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
```

- [ ] **Step 5: Run the affected test files to verify green**

Run: `mix test test/cinder/subtitles_test.exs test/cinder/subtitles/sweeper_test.exs test/cinder/library_subtitles_test.exs`
Expected: PASS. If a sweeper/library test still errors on an unexpected `moviehash_data` call, the stub was added in the wrong scope (it must be registered in the same process/mode the fetch runs in — global-mode tests need it before the Task starts).

- [ ] **Step 6: Full suite + commit**

Run: `mix test`
Expected: PASS (full alias green — compile/format/credo/tests).

```bash
git add lib/cinder/subtitles.ex test/cinder/subtitles_test.exs \
        test/cinder/subtitles/sweeper_test.exs test/cinder/library_subtitles_test.exs
git commit -m "feat: search subtitles by moviehash, preferring sync-accurate matches"
```

---

## Self-Review

- **Spec coverage:** `Moviehash.compute/of_file` (Task 1) ✓; `moviehash_data/1` fs callback + Disk + mock (Task 1) ✓; `Provider`/`OpenSubtitles` criteria+result+search_params+normalize (Task 2) ✓; `fetch_missing` merge + `best/2` preference (Task 3) ✓; both import and sweep inherit it via `fetch_missing` ✓; edge cases (too_small/error → id search; malformed → `moviehash_match: false`) covered by tests in Tasks 1–3 ✓. No new setting/env/UI — none planned ✓.
- **Placeholder scan:** none — every code step shows full code.
- **Type consistency:** `moviehash_data/1` return `{:ok, {size, head, tail}} | :too_small | {:error, term}` is identical across the behaviour (Task 1 Step 5), Disk impl (Step 8), `of_file` (Step 3), and every test stub. `compute/3` returns a 16-hex string used verbatim as the `:moviehash` criteria and asserted in the provider param test. `moviehash_match` boolean added consistently to `result`, `normalize/1`, and every candidate map in the Task 3 tests. `best/2` reads it via `Map.get/3` (tolerates absence).
- **Ordering:** Task 3 depends on Tasks 1 and 2 (both merged first). Tasks 1 and 2 are independent.
