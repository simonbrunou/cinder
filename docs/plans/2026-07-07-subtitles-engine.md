# Subtitles Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fetch `.srt` subtitle sidecars for imported movies and episodes from OpenSubtitles.com, in the household's chosen languages, at import time and via a periodic retry sweep — best-effort, never blocking a video import.

**Architecture:** A new `Cinder.Subtitles.Provider` behaviour (OpenSubtitles `Req` impl + Mox mock, config-resolved like Cinder's other four services). A thin `Cinder.Subtitles` context owns pick-best + sidecar-write via the existing `Cinder.Library.Filesystem` behaviour. Two triggers share one code path: best-effort hooks in `Cinder.Library.import_movie/2` + `import_episodes/2`, and a `:start_poller`-gated 12h `Cinder.Subtitles.Sweeper` GenServer that derives "needs subtitles" from the filesystem (no schema). Credentials + the language list live in the `Cinder.Settings` store.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8, `Req` HTTP, Ecto + `ecto_sqlite3`, Mox + `Req.Test`, Cloak (secret encryption), daisyUI/gettext (settings UI).

## Global Constraints

- `mix test` (the alias) must stay green: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Every task ends green.
- External services are reached ONLY through their behaviour; the impl is resolved at **runtime** via `Application.fetch_env!(:cinder, key)` / `Application.get_env` — never `compile_env!` (Mox mock is defined at runtime; compile-time resolution breaks `--warnings-as-errors`).
- Tests NEVER hit the network or disk: provider mocked with Mox, HTTP stubbed with `Req.Test`, filesystem mocked with `Cinder.Library.FilesystemMock`.
- Every state-changing movie/episode write goes through `Catalog.transition` / `transition_episode`. **Subtitles add no pipeline state** — they are derived from the filesystem, so this feature introduces no new writer through the choke-point and no migration.
- Best-effort discipline: a subtitle failure must never turn a placed file into `:import_failed`. Mirror `Cinder.Library.scan/2` exactly (`rescue` + `catch`, log-only).
- New user-facing strings must be `gettext`'d AND registered in `CinderWeb.SettingsLabels.known/0` (the `no_hardcoded_strings_test` asserts the settings label set ⊆ `known/0`).
- `mix gettext.extract --merge` runs LAST, after all lib edits (the `#:` line refs drift and fail CI's `--check-up-to-date` otherwise).
- OpenSubtitles.com REST: base `https://api.opensubtitles.com/api/v1`; `Api-Key` header + a real `User-Agent` on every call; `/login` (username+password) → JWT for `Authorization: Bearer` on `/download`; free account = 20 **downloads**/day (search is not download-quota-limited); `406` on download = quota exceeded.

---

## File Structure

**Create:**
- `lib/cinder/subtitles/provider.ex` — the behaviour (`search/1`, `download/1`, `health/0`).
- `lib/cinder/subtitles/provider/open_subtitles.ex` — the `Req` impl (token cache, search, download, health).
- `lib/cinder/subtitles.ex` — the context (`wanted_languages/0`, `sidecar_path/2`, `fetch_missing/2`).
- `lib/cinder/subtitles/sweeper.ex` — the periodic GenServer.
- `test/cinder/subtitles_test.exs`, `test/cinder/subtitles/provider/open_subtitles_test.exs`, `test/cinder/subtitles/sweeper_test.exs`.

**Modify:**
- `lib/cinder/library/filesystem.ex` (+ `write/2` callback), `lib/cinder/library/filesystem/disk.ex` (+ impl).
- `lib/cinder/library.ex` (best-effort hooks in `import_movie/2` and `do_import_episodes/3`).
- `lib/cinder/catalog.ex` (`list_available_movies_with_file/0`, `list_episodes_with_file/0`).
- `lib/cinder/settings.ex` (`@groups` + 4 `@base_config_fields` entries).
- `lib/cinder_web/settings_labels.ex`, `lib/cinder_web/components/settings_components.ex` (Test button clauses).
- `lib/cinder/health.ex` (`check_service(:subtitles)` + guarded `check_all`).
- `lib/cinder/application.ex` (supervise `Sweeper`).
- `config/config.exs` (prod default), `config/test.exs` (mock + stub), `config/runtime.exs` (env bootstrap), `test/test_helper.exs` (`defmock`), `test/cinder/settings_test.exs` (`@env_keys`).
- `priv/gettext/fr/LC_MESSAGES/default.po` (translations), `docs/operating.md` (revise the Subtitles section), `CHANGELOG.md`.

---

## Task 1: Filesystem `write/2`

The sidecar write goes through the existing `Filesystem` behaviour so the context stays disk-free in tests.

**Files:**
- Modify: `lib/cinder/library/filesystem.ex`
- Modify: `lib/cinder/library/filesystem/disk.ex`
- Test: `test/cinder/library/filesystem/disk_test.exs` (create if absent)

**Interfaces:**
- Produces: `@callback write(path :: String.t(), content :: iodata()) :: :ok | {:error, term()}` on `Cinder.Library.Filesystem`; `Cinder.Library.Filesystem.Disk.write/2`.

- [ ] **Step 1: Add the callback.** In `lib/cinder/library/filesystem.ex`, after the `rmdir/1` callback line, add:

```elixir
  @callback write(path :: String.t(), content :: iodata()) :: :ok | {:error, term()}
```

- [ ] **Step 2: Write the failing test.** Create `test/cinder/library/filesystem/disk_test.exs`:

```elixir
defmodule Cinder.Library.Filesystem.DiskTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.Filesystem.Disk

  test "write/2 writes bytes to disk" do
    dir = Path.join(System.tmp_dir!(), "cinder-fs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "out.srt")

    assert :ok = Disk.write(path, "1\n00:00:01,000 --> 00:00:02,000\nhi\n")
    assert File.read!(path) == "1\n00:00:01,000 --> 00:00:02,000\nhi\n"
  end
end
```

- [ ] **Step 3: Run it, verify it fails.** Run: `mix test test/cinder/library/filesystem/disk_test.exs`. Expected: FAIL (`function Disk.write/2 is undefined`).

- [ ] **Step 4: Implement.** In `lib/cinder/library/filesystem/disk.ex`, after the `cp/2` impl, add:

```elixir
  @impl true
  def write(path, content), do: File.write(path, content)
```

- [ ] **Step 5: Run it, verify it passes.** Run: `mix test test/cinder/library/filesystem/disk_test.exs`. Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/library/filesystem.ex lib/cinder/library/filesystem/disk.ex test/cinder/library/filesystem/disk_test.exs
git commit -m "feat(subtitles): add Filesystem.write/2 for sidecar writes"
```

---

## Task 2: Provider behaviour + Mox mock + config wiring

Define the seam and wire the mock/prod/test config so later tasks resolve an impl.

**Files:**
- Create: `lib/cinder/subtitles/provider.ex`
- Modify: `test/test_helper.exs`, `config/config.exs`, `config/test.exs`

**Interfaces:**
- Produces: behaviour `Cinder.Subtitles.Provider` with
  - `@callback search(criteria :: map()) :: {:ok, [map()]} | {:error, term()}` — `criteria` keys `:imdb_id`, `:tmdb_id`, `:season`, `:episode`, `:languages` (a `[String.t()]`); each result map has keys `:file_id`, `:language`, `:downloads` (integer), `:hearing_impaired` (bool), `:ai_translated` (bool).
  - `@callback download(file_id :: term()) :: {:ok, binary()} | {:error, term()}`
  - `@callback health() :: :ok | {:error, term()}`
- Produces: mock `Cinder.Subtitles.ProviderMock`; config key `:subtitles_provider`.

- [ ] **Step 1: Write the behaviour.** Create `lib/cinder/subtitles/provider.ex`:

```elixir
defmodule Cinder.Subtitles.Provider do
  @moduledoc """
  Behaviour for a subtitle source. Config-resolved at runtime
  (`Application.fetch_env!(:cinder, :subtitles_provider)`) so tests use a Mox mock and never hit
  the network. One impl today: `Cinder.Subtitles.Provider.OpenSubtitles`.

  `search/1` returns normalized candidate maps (the "pick the best one" policy lives in
  `Cinder.Subtitles`, not here). `download/1` turns a chosen `file_id` into raw `.srt` bytes.
  """

  @type criteria :: %{
          optional(:imdb_id) => String.t() | nil,
          optional(:tmdb_id) => integer() | nil,
          optional(:season) => integer() | nil,
          optional(:episode) => integer() | nil,
          required(:languages) => [String.t()]
        }

  @type result :: %{
          file_id: term(),
          language: String.t(),
          downloads: integer(),
          hearing_impaired: boolean(),
          ai_translated: boolean()
        }

  @callback search(criteria()) :: {:ok, [result()]} | {:error, term()}
  @callback download(file_id :: term()) :: {:ok, binary()} | {:error, term()}
  @callback health() :: :ok | {:error, term()}
end
```

- [ ] **Step 2: Define the Mox mock.** In `test/test_helper.exs`, after the `MediaInfoMock` line, add:

```elixir
Mox.defmock(Cinder.Subtitles.ProviderMock, for: Cinder.Subtitles.Provider)
```

- [ ] **Step 3: Prod default.** In `config/config.exs`, in the external-services block (near `config :cinder, notifier: Cinder.Notifier.Discord`), add:

```elixir
config :cinder, subtitles_provider: Cinder.Subtitles.Provider.OpenSubtitles
```

- [ ] **Step 4: Test override + HTTP stub.** In `config/test.exs`, add `subtitles_provider:` to the mocked-services block and a stub config block:

```elixir
# in the `config :cinder, tmdb: ... ` mocked-services block, add the line:
  subtitles_provider: Cinder.Subtitles.ProviderMock,
```

```elixir
# and, alongside the other per-impl Req.Test stubs:
config :cinder, Cinder.Subtitles.Provider.OpenSubtitles,
  base_url: "https://api.opensubtitles.test/api/v1",
  api_key: "test-key",
  username: "user",
  password: "pass",
  languages: "en,fr",
  req_options: [plug: {Req.Test, Cinder.OpenSubtitlesStub}, retry: false]
```

- [ ] **Step 5: Compile.** Run: `mix compile --warnings-as-errors`. Expected: clean (the impl module named in config doesn't exist yet, but config is data — compile passes; it's referenced only at runtime).

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/subtitles/provider.ex test/test_helper.exs config/config.exs config/test.exs
git commit -m "feat(subtitles): Provider behaviour, Mox mock, config wiring"
```

---

## Task 3: OpenSubtitles impl (`Req` client)

The only network code. Token cached in `:persistent_term`; re-login once on a 401.

**Files:**
- Create: `lib/cinder/subtitles/provider/open_subtitles.ex`
- Test: `test/cinder/subtitles/provider/open_subtitles_test.exs`

**Interfaces:**
- Consumes: config `Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles)` → `[base_url:, api_key:, username:, password:, languages:, req_options:]`.
- Produces: `@behaviour Cinder.Subtitles.Provider` — `search/1`, `download/1`, `health/0`.

- [ ] **Step 1: Write the failing tests.** Create `test/cinder/subtitles/provider/open_subtitles_test.exs`:

```elixir
defmodule Cinder.Subtitles.Provider.OpenSubtitlesTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Provider.OpenSubtitles

  setup do
    # Isolate the token cache between tests (persistent_term is global).
    on_exit(fn -> :persistent_term.erase({OpenSubtitles, :token}) end)
    :ok
  end

  test "search/1 sends Api-Key + query params and normalizes results" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]
      assert conn.request_path == "/api/v1/subtitles"
      params = URI.decode_query(conn.query_string)
      assert params["imdb_id"] == "tt0111161"
      assert params["languages"] == "en"

      Req.Test.json(conn, %{
        "data" => [
          %{"attributes" => %{
              "language" => "en", "download_count" => 500,
              "hearing_impaired" => false, "ai_translated" => false,
              "files" => [%{"file_id" => 42}]}}
        ]
      })
    end)

    assert {:ok, [r]} = OpenSubtitles.search(%{imdb_id: "tt0111161", languages: ["en"]})
    assert r == %{file_id: 42, language: "en", downloads: 500,
                  hearing_impaired: false, ai_translated: false}
  end

  test "download/1 logs in for a token, then downloads the link body" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" ->
          Req.Test.json(conn, %{"token" => "jwt-123"})

        "/api/v1/download" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-123"]
          Req.Test.json(conn, %{"link" => "https://dl.opensubtitles.test/f/42.srt"})

        "/f/42.srt" ->
          Plug.Conn.send_resp(conn, 200, "SRT-BYTES")
      end
    end)

    assert {:ok, "SRT-BYTES"} = OpenSubtitles.download(42)
  end

  test "download/1 maps HTTP 406 to :quota_exceeded" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      case conn.request_path do
        "/api/v1/login" -> Req.Test.json(conn, %{"token" => "jwt-123"})
        "/api/v1/download" -> Plug.Conn.send_resp(conn, 406, ~s({"message":"quota"}))
      end
    end)

    assert {:error, :quota_exceeded} = OpenSubtitles.download(42)
  end

  test "health/0 is :ok on a 200 from an api-key-only endpoint" do
    Req.Test.stub(Cinder.OpenSubtitlesStub, fn conn ->
      assert conn.request_path == "/api/v1/infos/formats"
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert :ok = OpenSubtitles.health()
  end
end
```

- [ ] **Step 2: Run them, verify they fail.** Run: `mix test test/cinder/subtitles/provider/open_subtitles_test.exs`. Expected: FAIL (module undefined).

- [ ] **Step 3: Implement.** Create `lib/cinder/subtitles/provider/open_subtitles.ex`:

```elixir
defmodule Cinder.Subtitles.Provider.OpenSubtitles do
  @moduledoc """
  OpenSubtitles.com REST API v1 client. `search/1` needs only the Api-Key; `download/1` needs a
  JWT from `/login`, cached in `:persistent_term` and re-fetched once on a 401. Downloads consume
  a daily quota (20/day free) — a `406` surfaces as `{:error, :quota_exceeded}` so the caller can
  stop for the tick. `ponytail:` global token (single-instance app); id-based search only —
  moviehash is the sync-accuracy upgrade path.
  """
  @behaviour Cinder.Subtitles.Provider

  require Logger

  @default_base "https://api.opensubtitles.com/api/v1"
  @token_key {__MODULE__, :token}

  @impl true
  def search(criteria) do
    case request(:get, "/subtitles", params: search_params(criteria)) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, Enum.map(data, &normalize/1)}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(file_id), do: download(file_id, _retried? = false)

  @impl true
  def health do
    case request(:get, "/infos/formats", []) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- download with one re-login retry on 401 ---

  defp download(file_id, retried?) do
    with {:ok, token} <- token(),
         {:ok, %{status: 200, body: %{"link" => link}}} <-
           request(:post, "/download", json: %{file_id: file_id}, auth: token),
         {:ok, %{status: 200, body: body}} <- fetch(link) do
      {:ok, body}
    else
      {:ok, %{status: 401}} when not retried? ->
        :persistent_term.erase(@token_key)
        download(file_id, true)

      {:ok, %{status: 406}} ->
        {:error, :quota_exceeded}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- token cache ---

  defp token do
    case :persistent_term.get(@token_key, nil) do
      nil -> login()
      jwt -> {:ok, jwt}
    end
  end

  defp login do
    body = %{username: cfg(:username), password: cfg(:password)}

    case request(:post, "/login", json: body) do
      {:ok, %{status: 200, body: %{"token" => jwt}}} ->
        :persistent_term.put(@token_key, jwt)
        {:ok, jwt}

      {:ok, %{status: status}} ->
        {:error, {:login, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- request building ---

  defp search_params(criteria) do
    [
      imdb_id: imdb_number(criteria[:imdb_id]),
      parent_tmdb_id: criteria[:season] && criteria[:tmdb_id],
      tmdb_id: is_nil(criteria[:season]) && criteria[:tmdb_id] || nil,
      season_number: criteria[:season],
      episode_number: criteria[:episode],
      languages: criteria[:languages] |> List.wrap() |> Enum.join(",")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  # OpenSubtitles wants the numeric imdb id (no "tt" prefix).
  defp imdb_number(nil), do: nil
  defp imdb_number("tt" <> digits), do: digits
  defp imdb_number(other), do: other

  defp normalize(%{"attributes" => a}) do
    %{
      file_id: a |> Map.get("files", []) |> List.first(%{}) |> Map.get("file_id"),
      language: a["language"],
      downloads: a["download_count"] || 0,
      hearing_impaired: a["hearing_impaired"] || false,
      ai_translated: a["ai_translated"] || false
    }
  end

  # --- HTTP ---

  defp request(method, path, opts) do
    {auth, opts} = Keyword.pop(opts, :auth)

    Req.request(
      [
        method: method,
        url: base_url() <> path,
        headers: headers(auth)
      ] ++ Keyword.merge(req_options(), opts)
    )
  end

  defp fetch(link), do: Req.request([method: :get, url: link] ++ req_options())

  defp headers(auth) do
    base = [{"api-key", cfg(:api_key)}, {"user-agent", user_agent()}]
    if auth, do: [{"authorization", "Bearer " <> auth} | base], else: base
  end

  defp user_agent, do: "Cinder/#{Application.spec(:cinder, :vsn) || "dev"}"

  defp base_url, do: cfg(:base_url) || @default_base
  defp req_options, do: cfg(:req_options) || []

  defp cfg(field) do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(field)
  end
end
```

- [ ] **Step 4: Run tests, verify they pass.** Run: `mix test test/cinder/subtitles/provider/open_subtitles_test.exs`. Expected: PASS (4 tests). If `search_params` ordering trips the query assertion, note the test decodes the query map so order is irrelevant.

- [ ] **Step 5: Commit.**

```bash
git add lib/cinder/subtitles/provider/open_subtitles.ex test/cinder/subtitles/provider/open_subtitles_test.exs
git commit -m "feat(subtitles): OpenSubtitles.com REST client with token cache"
```

---

## Task 4: `Cinder.Subtitles` context (pick-best + write sidecar)

Owns the policy: which language, which candidate, where the sidecar lands, skip-if-present.

**Files:**
- Create: `lib/cinder/subtitles.ex`
- Test: `test/cinder/subtitles_test.exs`

**Interfaces:**
- Consumes: `Cinder.Subtitles.Provider` (mocked), `Cinder.Library.Filesystem` (mocked), config `Application.get_env(:cinder, :subtitles_provider)` and `...OpenSubtitles)[:languages]`.
- Produces:
  - `wanted_languages() :: [String.t()]` (downcased; `[]` when the setting is blank → feature off).
  - `sidecar_path(dest_path :: String.t(), lang :: String.t()) :: String.t()`.
  - `fetch_missing(criteria_base :: map(), dest_path :: String.t()) :: :ok` — for each wanted language whose sidecar is absent, search→pick→download→write. Always returns `:ok` (best-effort); errors logged.

- [ ] **Step 1: Write the failing tests.** Create `test/cinder/subtitles_test.exs`:

```elixir
defmodule Cinder.SubtitlesTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Subtitles

  setup :verify_on_exit!

  setup do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
    on_exit(fn -> Application.delete_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles) end)
    :ok
  end

  test "wanted_languages/0 parses csv, downcases, and is [] when blank" do
    assert Subtitles.wanted_languages() == ["en", "fr"]
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "  ")
    assert Subtitles.wanted_languages() == []
  end

  test "sidecar_path/2 swaps the video extension for .<lang>.srt" do
    dest = "/lib/Movie (2020) {tmdb-1}/Movie (2020) {tmdb-1}.mkv"
    assert Subtitles.sidecar_path(dest, "en") ==
             "/lib/Movie (2020) {tmdb-1}/Movie (2020) {tmdb-1}.en.srt"
  end

  test "fetch_missing/2 picks highest-downloads non-HI non-AI result and writes the sidecar" do
    dest = "/lib/M/M.mkv"

    # 'en' sidecar missing, 'fr' sidecar already present.
    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:lstat, fn "/lib/M/M.fr.srt" -> {:ok, %File.Stat{}} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", languages: ["en"]} ->
      {:ok,
       [
         %{file_id: 1, language: "en", downloads: 10, hearing_impaired: false, ai_translated: false},
         %{file_id: 2, language: "en", downloads: 99, hearing_impaired: true, ai_translated: false},
         %{file_id: 3, language: "en", downloads: 50, hearing_impaired: false, ai_translated: false}
       ]}
    end)
    |> expect(:download, fn 3 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, dest)
  end

  test "fetch_missing/2 is a no-op when no languages are configured" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    # No provider/filesystem expectations => any call fails verify_on_exit!.
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 swallows a provider error (best-effort) and writes nothing" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn _ -> {:error, :boom} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end
end
```

- [ ] **Step 2: Run them, verify they fail.** Run: `mix test test/cinder/subtitles_test.exs`. Expected: FAIL (module undefined).

- [ ] **Step 3: Implement.** Create `lib/cinder/subtitles.ex`:

```elixir
defmodule Cinder.Subtitles do
  @moduledoc """
  Fetches subtitle sidecars for imported files, in the household's configured languages.

  Best-effort: `fetch_missing/2` always returns `:ok`; failures are logged, never raised, so a
  subtitle miss can't affect the video import. Idempotent: a language whose sidecar already exists
  is skipped (no search, no download, no wasted quota). The "which languages / which candidate"
  policy lives here; the network lives in `Cinder.Subtitles.Provider`.
  """

  require Logger

  @doc "Configured subtitle languages (downcased). `[]` — feature off — when the setting is blank."
  @spec wanted_languages() :: [String.t()]
  def wanted_languages do
    provider_config()
    |> Keyword.get(:languages, "")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The sidecar path for `dest_path` in `lang`: the video's extension replaced by `.<lang>.srt`."
  @spec sidecar_path(String.t(), String.t()) :: String.t()
  def sidecar_path(dest_path, lang) do
    dir = Path.dirname(dest_path)
    base = Path.basename(dest_path, Path.extname(dest_path))
    Path.join(dir, "#{base}.#{lang}.srt")
  end

  @doc """
  For each wanted language whose sidecar is absent, search the provider, pick the best candidate,
  download it, and write the sidecar. `criteria_base` carries `:imdb_id`/`:tmdb_id`
  (+ `:season`/`:episode` for TV); `:languages` is filled in per language. Always `:ok`.
  """
  @spec fetch_missing(map(), String.t()) :: :ok
  def fetch_missing(criteria_base, dest_path) do
    for lang <- wanted_languages(), sidecar_missing?(dest_path, lang) do
      fetch_one(criteria_base, lang, dest_path)
    end

    :ok
  end

  defp fetch_one(criteria_base, lang, dest_path) do
    criteria = Map.put(criteria_base, :languages, [lang])

    with {:ok, results} <- provider().search(criteria),
         %{file_id: file_id} <- best(results, lang),
         {:ok, content} <- provider().download(file_id),
         :ok <- fs().write(sidecar_path(dest_path, lang), content) do
      Logger.info("wrote #{lang} subtitle for #{dest_path}")
    else
      nil -> :ok
      other -> Logger.info("no #{lang} subtitle for #{dest_path}: #{inspect(other)}")
    end
  rescue
    e -> Logger.warning("subtitle fetch crashed for #{dest_path} (#{lang}): #{inspect(e)}")
  catch
    kind, value -> Logger.warning("subtitle fetch #{kind} for #{dest_path}: #{inspect(value)}")
  end

  # Best candidate: exact language, not hearing-impaired, not machine-translated, most downloads.
  defp best(results, lang) do
    results
    |> Enum.filter(fn r ->
      String.downcase(r.language || "") == lang and not r.hearing_impaired and not r.ai_translated and
        not is_nil(r.file_id)
    end)
    |> Enum.max_by(& &1.downloads, fn -> nil end)
  end

  defp sidecar_missing?(dest_path, lang) do
    match?({:error, _}, fs().lstat(sidecar_path(dest_path, lang)))
  end

  defp provider, do: Application.fetch_env!(:cinder, :subtitles_provider)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  defp provider_config,
    do: Application.get_env(:cinder, Application.get_env(:cinder, :subtitles_provider), [])
end
```

- [ ] **Step 4: Run tests, verify they pass.** Run: `mix test test/cinder/subtitles_test.exs`. Expected: PASS (5 tests).

- [ ] **Step 5: Commit.**

```bash
git add lib/cinder/subtitles.ex test/cinder/subtitles_test.exs
git commit -m "feat(subtitles): context — pick-best, sidecar naming, best-effort fetch"
```

---

## Task 5: Best-effort import-time hooks in `Cinder.Library`

Fire `fetch_missing` after a file is placed, wrapped exactly like `scan/2` — never affecting the import result.

**Files:**
- Modify: `lib/cinder/library.ex` (`import_movie/2` tail, `do_import_episodes/3` success branch, new private `fetch_subtitles/2` + criteria builders)
- Test: `test/cinder/library_test.exs` (add cases; or the existing import test file)

**Interfaces:**
- Consumes: `Cinder.Subtitles.fetch_missing/2`.
- Produces: no public signature change — `import_movie/2` still returns `{:ok, dest, quality}`.

- [ ] **Step 1: Write the failing test.** Add to the library import test file (find it: `grep -rl "import_movie" test/`). Add a case proving best-effort + criteria, using the `Subtitles.ProviderMock`:

```elixir
  test "import_movie fetches subtitles best-effort and still succeeds when the provider errors" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    on_exit(fn -> Application.delete_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles) end)

    # (existing FilesystemMock stubs that make a movie import succeed go here, plus:)
    Cinder.Library.FilesystemMock
    |> stub(:lstat, fn _ -> {:error, :enoent} end)  # sidecar missing (keep existing lstat expectations consistent)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: _, languages: ["en"]} -> {:error, :down} end)

    movie = movie_ready_to_import()  # existing helper: a :downloaded movie with file_path + imdb_id
    assert {:ok, _dest, _quality} = Cinder.Library.import_movie(movie)
  end
```

Note: this test shares the file's existing Mox setup. If the existing `import_movie` tests set precise `lstat` expectations, thread the sidecar-`lstat` in without breaking them (a `stub` for the sidecar path, `expect` for the import paths). Keep the assertion minimal — the point is `{:ok, ...}` despite a provider error.

- [ ] **Step 2: Run it, verify it fails.** Run: `mix test <that file> -k "best-effort"`. Expected: FAIL (subtitles not called / criteria absent) — or a Mox "unexpected call" if hooks aren't wired yet.

- [ ] **Step 3: Implement the movie hook.** In `lib/cinder/library.ex`, change the `import_movie/2` success tail:

```elixir
         end) do
      scan(:movies, dest)
      fetch_subtitles(movie_criteria(movie), dest)
      {:ok, dest, quality}
    end
```

Add the alias at the top (`alias Cinder.Subtitles` — or fully-qualify) and these privates near `scan/2`:

```elixir
  # Best-effort, exactly like scan/2: a subtitle failure (return, raise, or exit deep in the HTTP
  # stack) must never turn a correctly-placed file into :import_failed.
  defp fetch_subtitles(criteria, dest) do
    Cinder.Subtitles.fetch_missing(criteria, dest)
  rescue
    e -> Logger.warning("subtitle fetch failed after importing #{dest}: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("subtitle fetch failed after importing #{dest}: #{inspect({kind, value})}")
  end

  defp movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id}),
    do: %{imdb_id: imdb_id, tmdb_id: tmdb_id}
```

- [ ] **Step 4: Implement the episode hook.** In `do_import_episodes/3`, in the `{:ok, imported}` branch (after `scan(:tv, content_path)`), add a fetch per imported episode file. Since `imported` is `[{episode_id, dest_path, quality}]` and the criteria needs the series `tmdb_id` + season/episode, build criteria from the `episodes` list keyed by id:

```elixir
        {:ok, imported} ->
          log_unmatched(unmatched)
          scan(:tv, content_path)
          fetch_episode_subtitles(imported, episodes)
          {:ok, imported, unmatched}
```

Add the private (episodes are preloaded `season: :series`):

```elixir
  defp fetch_episode_subtitles(imported, episodes) do
    by_id = Map.new(episodes, &{&1.id, &1})

    for {ep_id, dest, _q} <- imported, ep = by_id[ep_id], not is_nil(ep) do
      fetch_subtitles(episode_criteria(ep), dest)
    end
  end

  defp episode_criteria(%Episode{episode_number: number, season: %{season_number: season, series: %Series{tmdb_id: tmdb_id}}}),
    do: %{tmdb_id: tmdb_id, season: season, episode: number}
```

- [ ] **Step 5: Run the test, verify it passes.** Run: `mix test <that file>`. Expected: PASS. Then run the whole library suite to confirm no existing import test regressed: `mix test test/cinder/library_test.exs`.

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/library.ex test/cinder/library_test.exs
git commit -m "feat(subtitles): best-effort subtitle fetch on movie + episode import"
```

---

## Task 6: Settings fields, Test button, Health, gettext

Make the 3 credentials + language list editable in `/settings`, with a Test button.

**Files:**
- Modify: `lib/cinder/settings.ex`, `lib/cinder_web/settings_labels.ex`, `lib/cinder_web/components/settings_components.ex`, `lib/cinder/health.ex`, `config/runtime.exs`, `test/cinder/settings_test.exs`, `priv/gettext/fr/LC_MESSAGES/default.po`
- Test: `test/cinder/health_test.exs` (add a `:subtitles` case if the file exists; else fold into settings_test)

**Interfaces:**
- Consumes: the registry `apply_config_fields/1` overlay (module-backed creds ride it automatically).
- Produces: settings keys `opensubtitles_api_key`, `opensubtitles_username`, `opensubtitles_password`, `subtitle_languages`; `Health.check_service(:subtitles)`.

- [ ] **Step 1: Registry group + fields.** In `lib/cinder/settings.ex`, add `subtitles: "Subtitles"` to `@groups` (before `notifications:`), and append to `@base_config_fields`:

```elixir
    %{key: "opensubtitles_api_key", module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :api_key, secret: true, group: :subtitles,
      label: "OpenSubtitles API key", placeholder: ""},
    %{key: "opensubtitles_username", module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :username, secret: true, group: :subtitles,
      label: "OpenSubtitles username", placeholder: ""},
    %{key: "opensubtitles_password", module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :password, secret: true, group: :subtitles,
      label: "OpenSubtitles password", placeholder: ""},
    %{key: "subtitle_languages", module: Cinder.Subtitles.Provider.OpenSubtitles,
      field: :languages, secret: false, group: :subtitles,
      label: "Subtitle languages (comma-separated, e.g. en,fr)", placeholder: "en,fr"},
```

(No new `apply_*` function: `apply_config_fields/1` groups every `@base_config_fields` entry by `module` and overlays it. `username`/`password`/`api_key` are secret → Cloak-encrypted; `languages` is plaintext.)

- [ ] **Step 2: Labels.** In `lib/cinder_web/settings_labels.ex`, add to the `known/0` list:

```elixir
      gettext_noop("Subtitles"),
      gettext_noop("OpenSubtitles API key"),
      gettext_noop("OpenSubtitles username"),
      gettext_noop("OpenSubtitles password"),
      gettext_noop("Subtitle languages (comma-separated, e.g. en,fr)"),
```

- [ ] **Step 3: Test button.** In `lib/cinder_web/components/settings_components.ex`, add a clause to each mapping:

```elixir
  def services_for(:subtitles), do: [{"subtitles", "OpenSubtitles"}]
```
```elixir
  def decode_service("subtitles"), do: :subtitles
```

(Place each new clause before the catch-all `services_for(_group)` / `decode_service(service)` clause.)

- [ ] **Step 4: Health.** In `lib/cinder/health.ex`, add a `check_service` clause and include a guarded row in `check_all`:

```elixir
  def check_service(:subtitles) do
    case Application.get_env(:cinder, Application.get_env(:cinder, :subtitles_provider), [])[:api_key] do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      _ -> run(Application.fetch_env!(:cinder, :subtitles_provider))
    end
  end
```

```elixir
  # in check_all/0, append the subtitles row only when configured (off-by-default → no red noise):
  def check_all do
    [indexer_check()] ++ download_checks() ++ [media_server_check()] ++ library_checks() ++
      subtitles_check()
  end

  defp subtitles_check do
    case check_service(:subtitles) do
      {:error, :not_configured} -> []
      status -> [%{label: "Subtitles (OpenSubtitles)", status: status}]
    end
  end
```

- [ ] **Step 5: `@env_keys`.** In `test/cinder/settings_test.exs`, add to `@env_keys`:

```elixir
    Cinder.Subtitles.Provider.OpenSubtitles,
```

- [ ] **Step 6: Env bootstrap (optional but consistent).** In `config/runtime.exs`, mirror the Prowlarr block:

```elixir
if api_key = System.get_env("OPENSUBTITLES_API_KEY") do
  config :cinder, Cinder.Subtitles.Provider.OpenSubtitles,
    api_key: api_key,
    username: System.get_env("OPENSUBTITLES_USERNAME"),
    password: System.get_env("OPENSUBTITLES_PASSWORD"),
    languages: System.get_env("SUBTITLE_LANGUAGES")
end
```

- [ ] **Step 7: Verify settings + health.** Run: `mix test test/cinder/settings_test.exs test/cinder/health_test.exs`. Expected: PASS (the settings test's env snapshot now covers the new module key). Add a health test case if the file exists:

```elixir
  test "check_service(:subtitles) is :not_configured with no api key" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
    on_exit(fn -> Application.delete_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles) end)
    assert {:error, :not_configured} = Cinder.Health.check_service(:subtitles)
  end
```

- [ ] **Step 8: gettext extract + translate.** Run: `mix gettext.extract --merge`. Then in `priv/gettext/fr/LC_MESSAGES/default.po` fill the new `msgstr`s:

```po
msgid "Subtitles"
msgstr "Sous-titres"

msgid "OpenSubtitles API key"
msgstr "Clé API OpenSubtitles"

msgid "OpenSubtitles username"
msgstr "Nom d'utilisateur OpenSubtitles"

msgid "OpenSubtitles password"
msgstr "Mot de passe OpenSubtitles"

msgid "Subtitle languages (comma-separated, e.g. en,fr)"
msgstr "Langues des sous-titres (séparées par des virgules, ex. en,fr)"
```

- [ ] **Step 9: Full green.** Run: `mix test`. Expected: PASS (includes `no_hardcoded_strings_test` and `--check-formatted`; `mix format` first if needed).

- [ ] **Step 10: Commit.**

```bash
git add lib/cinder/settings.ex lib/cinder_web/settings_labels.ex lib/cinder_web/components/settings_components.ex lib/cinder/health.ex config/runtime.exs test/cinder/settings_test.exs test/cinder/health_test.exs priv/gettext/fr/LC_MESSAGES/default.po
git commit -m "feat(subtitles): settings fields, Test connection, health, i18n"
```

---

## Task 7: Catalog list helpers for the sweep

Two indexed reads the sweep needs. No schema change.

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Produces: `list_available_movies_with_file() :: [Movie.t()]`, `list_episodes_with_file() :: [Episode.t()]` (preloaded `season: :series`).

- [ ] **Step 1: Write the failing tests.** Add to `test/cinder/catalog_test.exs`:

```elixir
  test "list_available_movies_with_file/0 returns only :available movies with a file_path" do
    m1 = insert_movie!(status: :available, file_path: "/x/a.mkv")
    _m2 = insert_movie!(status: :available, file_path: nil)
    _m3 = insert_movie!(status: :requested, file_path: "/x/c.mkv")
    ids = Cinder.Catalog.list_available_movies_with_file() |> Enum.map(& &1.id)
    assert ids == [m1.id]
  end

  test "list_episodes_with_file/0 returns episodes with a file_path, season+series preloaded" do
    ep = insert_episode!(file_path: "/x/e.mkv")  # existing helper builds series→season→episode
    _no = insert_episode!(file_path: nil)
    assert [got] = Cinder.Catalog.list_episodes_with_file()
    assert got.id == ep.id
    assert %Cinder.Catalog.Series{} = got.season.series
  end
```

(Use whatever movie/episode insert helpers the test file already defines; match their names.)

- [ ] **Step 2: Run them, verify they fail.** Run: `mix test test/cinder/catalog_test.exs -k "with_file"`. Expected: FAIL (undefined).

- [ ] **Step 3: Implement.** In `lib/cinder/catalog.ex`, near `list_by_status/1`:

```elixir
  @doc "Available movies that have an imported file (subtitle-fetch candidates)."
  def list_available_movies_with_file do
    Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
  end

  @doc "Episodes with an imported file, season+series preloaded (subtitle-fetch candidates)."
  def list_episodes_with_file do
    Repo.all(from e in Episode, where: not is_nil(e.file_path), preload: [season: :series])
  end
```

- [ ] **Step 4: Run tests, verify they pass.** Run: `mix test test/cinder/catalog_test.exs -k "with_file"`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_test.exs
git commit -m "feat(subtitles): Catalog list helpers for the sweep"
```

---

## Task 8: `Cinder.Subtitles.Sweeper` GenServer

Periodic backfill: for every imported item, fetch any missing wanted-language sidecar. Mirrors `Cinder.Catalog.Refresher`.

**Files:**
- Create: `lib/cinder/subtitles/sweeper.ex`
- Modify: `lib/cinder/application.ex` (supervise it, `:start_poller`-gated)
- Test: `test/cinder/subtitles/sweeper_test.exs`

**Interfaces:**
- Consumes: `Catalog.list_available_movies_with_file/0`, `Catalog.list_episodes_with_file/0`, `Cinder.Subtitles.fetch_missing/2`, movie/episode criteria (rebuild locally — the same shapes Task 5 uses).
- Produces: `Cinder.Subtitles.Sweeper.poll/1` (synchronous one-pass, for tests).

- [ ] **Step 1: Write the failing tests.** Create `test/cinder/subtitles/sweeper_test.exs`:

```elixir
defmodule Cinder.Subtitles.SweeperTest do
  use Cinder.DataCase, async: false   # touches Application env + DB; matches Refresher test style

  import Mox

  alias Cinder.Subtitles.Sweeper

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    on_exit(fn -> Application.delete_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles) end)
    :ok
  end

  test "poll/1 fetches a missing sidecar for an available movie" do
    _m = insert_movie!(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", languages: ["en"]} ->
      {:ok, [%{file_id: 7, language: "en", downloads: 1, hearing_impaired: false, ai_translated: false}]}
    end)
    |> expect(:download, fn 7 -> {:ok, "SRT"} end)

    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 skips an item whose sidecar already exists (no provider call)" do
    _m = insert_movie!(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:ok, %File.Stat{}} end)

    # No ProviderMock expectations => verify_on_exit! fails if search/download is called.
    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 is a no-op when no languages are configured" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    _m = insert_movie!(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)
    # No FilesystemMock/ProviderMock expectations at all.
    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end
end
```

- [ ] **Step 2: Run them, verify they fail.** Run: `mix test test/cinder/subtitles/sweeper_test.exs`. Expected: FAIL (module undefined).

- [ ] **Step 3: Implement.** Create `lib/cinder/subtitles/sweeper.ex`:

```elixir
defmodule Cinder.Subtitles.Sweeper do
  @moduledoc """
  Periodic subtitle backfill. Each tick, for every imported movie/episode, fetches any missing
  wanted-language sidecar via `Cinder.Subtitles.fetch_missing/2`. Holds no state — re-derives its
  work from the DB + filesystem, so it recovers cleanly after a crash and catches subtitles
  uploaded after a release landed. Mirrors `Cinder.Catalog.Refresher`: self-rescheduling, 12h
  default, `:start_poller`-gated. A blank `subtitle_languages` setting makes each pass a no-op.

  The interval is module config (no string→int seam in `Cinder.Settings`):
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`. `ponytail:` no give-up marker — a
  still-missing sub re-searches each tick; failed searches don't consume the daily download quota.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Subtitles

  @default_interval :timer.hours(12)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one sweep synchronously (tests). The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll()
    {:reply, :ok, state}
  end

  defp do_poll do
    if Subtitles.wanted_languages() == [] do
      :ok
    else
      for movie <- Catalog.list_available_movies_with_file() do
        isolate("movie #{movie.id}", fn -> Subtitles.fetch_missing(movie_criteria(movie), movie.file_path) end)
      end

      for ep <- Catalog.list_episodes_with_file() do
        isolate("episode #{ep.id}", fn -> Subtitles.fetch_missing(episode_criteria(ep), ep.file_path) end)
      end

      :ok
    end
  end

  defp movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id}),
    do: %{imdb_id: imdb_id, tmdb_id: tmdb_id}

  defp episode_criteria(%Episode{episode_number: number, season: %{season_number: season, series: %Series{tmdb_id: tmdb_id}}}),
    do: %{tmdb_id: tmdb_id, season: season, episode: number}

  # fetch_missing/2 is already best-effort, but a DB/preload surprise shouldn't sink the whole tick.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("sweeper skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("sweeper skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:interval, @default_interval)
  end
end
```

- [ ] **Step 4: Supervise it.** In `lib/cinder/application.ex`, inside the `if Application.get_env(:cinder, :start_poller, true) do` block (where the pollers/Refresher are listed), add `Cinder.Subtitles.Sweeper` to the children list (after `Cinder.Catalog.Refresher`).

- [ ] **Step 5: Run tests, verify they pass.** Run: `mix test test/cinder/subtitles/sweeper_test.exs`. Expected: PASS (3 tests). If `insert_movie!`/`insert_episode!` helpers aren't in scope for a `DataCase`, use the factory the other catalog tests use (match the existing style in `test/cinder/catalog_test.exs`).

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/subtitles/sweeper.ex lib/cinder/application.ex test/cinder/subtitles/sweeper_test.exs
git commit -m "feat(subtitles): periodic Sweeper backfilling missing sidecars"
```

---

## Task 9: Docs

Revise the operating guide (it currently says Cinder does NOT fetch subtitles) and the changelog.

**Files:**
- Modify: `docs/operating.md`, `CHANGELOG.md`

- [ ] **Step 1: Rewrite the Subtitles section.** In `docs/operating.md`, replace the "Subtitles" section body: Cinder now fetches `.srt` sidecars from OpenSubtitles at import + on a 12h sweep, opt-in by setting `subtitle_languages` + OpenSubtitles credentials in `/settings`; blank languages = off; best-effort (a miss never fails an import); id-based match (note the sync-drift ceiling); 20/day free download quota. Keep the "media-server plugin is the zero-config alternative" and the "why not Bazarr" paragraphs as the alternative for households that don't want to configure this.

- [ ] **Step 2: Changelog.** In `CHANGELOG.md` under `[Unreleased]`, add:

```markdown
### Added
- **Subtitles.** Optional OpenSubtitles.com integration fetches `.srt` sidecars for imported
  movies and episodes in configured languages, at import time and via a 12h backfill sweep.
  Opt-in: set `Subtitle languages` + OpenSubtitles credentials in Settings. Best-effort — never
  blocks an import.
```

- [ ] **Step 3: Full green + format.** Run: `mix format && mix test`. Expected: PASS.

- [ ] **Step 4: Commit.**

```bash
git add docs/operating.md CHANGELOG.md
git commit -m "docs(subtitles): operating guide + changelog for the subtitle engine"
```

---

## Self-Review notes (coverage of the spec)

- Behaviour + impl + mock → Tasks 2, 3. Context pick-best/sidecar/idempotent → Task 4. Two triggers → Task 5 (import) + Task 8 (sweep). Filesystem-derived "needs subs" (no schema) → Tasks 7 + 8. Config (4 fields, secrets, no env vars required) → Task 6. Health → Task 6. `write/2` seam → Task 1. Best-effort discipline → Tasks 4, 5, 8 (rescue+catch, always `:ok`). Ceilings (id-based, global list, one provider, no give-up marker) → encoded in moduledocs + `ponytail:` comments.
- **Type consistency:** criteria maps use `:imdb_id/:tmdb_id/:season/:episode/:languages` and result maps `:file_id/:language/:downloads/:hearing_impaired/:ai_translated` uniformly across Provider (Task 2), OpenSubtitles (Task 3), context (Task 4), and Sweeper (Task 8). `fetch_missing/2` always returns `:ok`. `sidecar_path/2` stable across context + tests.
- **Known follow-up (not a blocker):** `subtitle_languages` lives under the OpenSubtitles module config (rides `apply_config_fields`, zero new machinery); if a second provider is ever added, promote it to a provider-agnostic flat key then. Documented as a ceiling.
