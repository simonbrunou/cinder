# Phase 5 — Wire the Loop + Status Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a `:requested` movie flow automatically through search → download → import → `:available` (no manual steps), add a live `/status` dashboard, and handle real release URLs (base32 magnets + `.torrent` files).

**Architecture:** Extend the existing supervised `Cinder.Download.Poller` (which re-derives all work from the DB each tick — the property that gives crash recovery) with a third sweep, `search_requested`, that runs `Cinder.Download.start/1` on `:requested`/`:searching` movies. Transient failures are backed-off and bounded-retried (parking `:search_failed`); permanent ones park immediately. A new `Cinder.Download.Torrent.infohash/1` lets the qBittorrent client compute the v1 infohash for `.torrent` URLs so status polling works.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Ecto + `ecto_sqlite3`, `Req`, ExUnit + `Mox`. daisyUI + Tailwind.

Council review: 2 rounds — sound to execute, all flaws fixed. (Round 1 caught: invalid `-k`
test flag, undefined test helpers `stub_login_and_add`/`stub_torrent_fetch_and_add`, the
`.torrent` fetch plug not wired in test config, and `:bad_torrent` not classified permanent —
all corrected. Residual: a non-200 qBittorrent *upload* response is labelled
`:torrent_fetch_status` — cosmetic, error still surfaces.)

## Global Constraints

- `mix test` (the alias) must stay green: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Run it at the end of every task.
- External services are reached only through behaviours, resolved at runtime via `Application.fetch_env!/2` / `Application.get_env/3` (never `compile_env!` — it breaks Mox under `--warnings-as-errors`). Tests never hit the network: TMDB/Indexer/Client/MediaServer/Filesystem are Mox mocks (`config/test.exs`).
- `mix format` before committing. Match surrounding code style and comment density.
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit.
- Status enum values (`Cinder.Catalog.Movie.@statuses`): `:requested, :searching, :downloading, :downloaded, :available, :no_match, :import_failed` — this plan adds `:search_failed`.
- `@max_attempts` (retry cap) is `10` in `Cinder.Download.Poller`.

---

### Task 1: Data layer — `search_attempts`, `:search_failed`, `Catalog.get_movie_by_id/1`

**Files:**
- Create: `priv/repo/migrations/<generated_ts>_add_search_attempts_to_movies.exs`
- Modify: `lib/cinder/catalog/movie.ex` (schema `@statuses` ~L14-22, `field`s ~L24-36, `transition_changeset/2` ~L46-51)
- Modify: `lib/cinder/catalog.ex` (add `get_movie_by_id/1`)
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Produces: `Cinder.Catalog.get_movie_by_id(id :: integer) :: %Movie{} | nil`; `Movie` has `:search_attempts` (integer, default 0); `:search_failed` is a valid status; `transition_changeset/2` casts `:search_attempts`.

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration add_search_attempts_to_movies`
This creates `priv/repo/migrations/<ts>_add_search_attempts_to_movies.exs`. Replace its body with:

```elixir
defmodule Cinder.Repo.Migrations.AddSearchAttemptsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :search_attempts, :integer, default: 0, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: migration applies cleanly (adds `search_attempts` to `movies`).

- [ ] **Step 3: Update the `Movie` schema and changeset**

In `lib/cinder/catalog/movie.ex`, add `:search_failed` to `@statuses`:

```elixir
  @statuses [
    :requested,
    :searching,
    :downloading,
    :downloaded,
    :available,
    :no_match,
    :search_failed,
    :import_failed
  ]
```

Add the field (after `:import_attempts`):

```elixir
    field :import_attempts, :integer, default: 0
    field :search_attempts, :integer, default: 0
```

Update `transition_changeset/2` (docstring + cast list):

```elixir
  @doc "Changeset for pipeline state transitions (status + optional download_id/imdb_id/file_path/attempt counters)."
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:status, :download_id, :imdb_id, :file_path, :import_attempts, :search_attempts])
    |> validate_required([:status])
  end
```

- [ ] **Step 4: Write the failing test**

In `test/cinder/catalog_test.exs`, add (inside the existing module):

```elixir
  describe "get_movie_by_id/1" do
    test "returns the movie by primary key, or nil" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7001, title: "M"})
      assert %Cinder.Catalog.Movie{id: id} = Catalog.get_movie_by_id(movie.id)
      assert id == movie.id
      assert Catalog.get_movie_by_id(-1) == nil
    end
  end

  describe "search_failed terminal + search_attempts" do
    test "transition can set :search_failed and persist search_attempts" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7002, title: "M"})
      {:ok, m} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
      assert m.search_attempts == 3
      {:ok, m} = Catalog.transition(m, %{status: :search_failed})
      assert m.status == :search_failed
    end
  end
```

(If `Catalog` and/or `Cinder.Catalog.Movie` aren't aliased in this test file, use the fully-qualified names as above or add aliases matching the file's existing style.)

- [ ] **Step 5: Run the test to verify it fails**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL — `Catalog.get_movie_by_id/1` undefined.

- [ ] **Step 6: Add `get_movie_by_id/1` to `Catalog`**

In `lib/cinder/catalog.ex`, add near `list_by_status/1`:

```elixir
  @doc "Fetches a watchlisted movie by primary key, or `nil`."
  def get_movie_by_id(id), do: Repo.get(Movie, id)
```

Also update the `transition/2` docstring to mention the new castable field (it currently lists `:download_id`, `:imdb_id`, `:file_path`):

```elixir
  `attrs` must set `:status`; it may also set `:download_id`, `:imdb_id`, `:file_path`,
  `:import_attempts`, and `:search_attempts`.
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/cinder/catalog_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add priv/repo/migrations lib/cinder/catalog/movie.ex lib/cinder/catalog.ex test/cinder/catalog_test.exs
git commit -m "Phase 5: add search_attempts, :search_failed status, Catalog.get_movie_by_id/1"
```

---

### Task 2: `Download.start/1` contract shift (transient vs permanent imdb resolution)

**Files:**
- Modify: `lib/cinder/download.ex` (`start/1` ~L20-32, `ensure_imdb_id/1` ~L34-43, moduledoc)
- Test: `test/cinder/download_test.exs` (update one test, add one)

**Interfaces:**
- Produces: `Cinder.Download.start/1` returns `{:ok, %Movie{}}` (status `:downloading` or `:no_match`) | `{:error, :no_imdb_id}` (movie still `:requested`) | `{:error, :tmdb_unavailable}` (movie still `:requested`) | `{:error, term}` (indexer/client error; movie left `:searching`). It no longer parks `:no_match` itself for the no-imdb case — the Poller's `search_one` (Task 7) owns that.

- [ ] **Step 1: Update the regressing test and add the transient-TMDB test**

In `test/cinder/download_test.exs`, replace the test at ~L70-75 ("parks the movie at :no_match when the imdb_id can't be resolved") with:

```elixir
  test "returns {:error, :no_imdb_id} and leaves the movie :requested when imdb is genuinely missing" do
    movie = requested(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:ok, %{imdb_id: nil}} end)

    assert {:error, :no_imdb_id} = Download.start(movie)
    assert %Movie{status: :requested} = Repo.get!(Movie, movie.id)
  end

  test "returns {:error, :tmdb_unavailable} on a transient TMDB error, movie stays :requested" do
    movie = requested(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, {:tmdb_status, 503}} end)

    assert {:error, :tmdb_unavailable} = Download.start(movie)
    assert %Movie{status: :requested} = Repo.get!(Movie, movie.id)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/download_test.exs`
Expected: FAIL — `start/1` currently returns `{:ok, %Movie{status: :no_match}}` for the no-imdb case, and collapses the transient error to the same.

- [ ] **Step 3: Implement the contract shift**

In `lib/cinder/download.ex`, change the `else` of `start/1`:

```elixir
  def start(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
      case Acquisition.best_release(imdb_id) do
        {:ok, release} -> add_to_client(movie, release)
        :no_match -> Catalog.transition(movie, %{status: :no_match})
        {:error, _} = err -> err
      end
    else
      :no_imdb_id -> {:error, :no_imdb_id}
      {:error, _} = err -> err
    end
  end
```

Split `ensure_imdb_id/1`'s catch-all so a transient TMDB error is distinguishable from a genuinely-missing id:

```elixir
  defp ensure_imdb_id(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id) and imdb_id != "" do
    {:ok, imdb_id}
  end

  defp ensure_imdb_id(%Movie{tmdb_id: tmdb_id}) do
    case Catalog.get_movie(tmdb_id) do
      {:ok, %{imdb_id: imdb_id}} when is_binary(imdb_id) and imdb_id != "" -> {:ok, imdb_id}
      {:ok, _} -> :no_imdb_id
      {:error, _} -> {:error, :tmdb_unavailable}
    end
  end
```

Update the moduledoc: change the last sentence from "Not auto-triggered yet — Phase 5 wires it." to "Auto-triggered by `Cinder.Download.Poller`'s search sweep." Also update the `start/1` `@doc` to describe the new return values (no-imdb and tmdb-unavailable now return `{:error, _}` and leave the movie `:requested`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/download_test.exs`
Expected: PASS (including the unchanged "parks at :no_match when no release survives scoring" and "leaves the movie :searching on add failure" tests).

- [ ] **Step 5: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download.ex test/cinder/download_test.exs
git commit -m "Phase 5: Download.start/1 distinguishes transient TMDB outage from missing imdb"
```

---

### Task 3: `Cinder.Download.Torrent.infohash/1` (bencode v1 infohash)

**Files:**
- Create: `lib/cinder/download/torrent.ex`
- Test: `test/cinder/download/torrent_test.exs`

**Interfaces:**
- Produces: `Cinder.Download.Torrent.infohash(bytes :: binary) :: {:ok, hex :: String.t()} | {:error, :bad_torrent}`. `hex` is lowercase 40-char hex = SHA-1 of the bencoded top-level `info` value, byte-for-byte.

- [ ] **Step 1: Write the failing test**

Create `test/cinder/download/torrent_test.exs`:

```elixir
defmodule Cinder.Download.TorrentTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Torrent

  # Minimal valid torrent: d 8:announce 11:http://x/an 4:info <infoval> e
  defp torrent(infoval), do: "d8:announce11:http://x/an4:info" <> infoval <> "e"

  test "computes SHA-1 of the original info value (not a re-encode)" do
    infoval = "d6:lengthi1024e4:name5:M.mkv12:piece lengthi16384ee"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "handles nested lists and dicts inside info" do
    infoval = "d5:filesld6:lengthi1e4:pathl1:aeee4:name1:xe"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "rejects non-bencode / HTML input" do
    assert {:error, :bad_torrent} = Torrent.infohash("<html>not found</html>")
    assert {:error, :bad_torrent} = Torrent.infohash("")
    # a dict with no info key
    assert {:error, :bad_torrent} = Torrent.infohash("d8:announce3:abce")
    # truncated
    assert {:error, :bad_torrent} = Torrent.infohash("d4:infod6:length")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/download/torrent_test.exs`
Expected: FAIL — module/function undefined.

- [ ] **Step 3: Implement the parser**

Create `lib/cinder/download/torrent.ex`:

```elixir
defmodule Cinder.Download.Torrent do
  @moduledoc """
  Computes a torrent's BitTorrent v1 infohash from its `.torrent` bytes.

  The v1 infohash is the SHA-1 of the bencoded `info` value **exactly as it
  appears in the file** (byte-for-byte, not a re-encode), so this is a minimal
  bencode value-walker that locates the byte span of the top-level `info` value
  and hashes that span. v2/hybrid (SHA-256) infohashes are out of scope.
  """

  @doc """
  Returns `{:ok, hex}` (lowercase 40-char hex) or `{:error, :bad_torrent}` for
  malformed / non-bencode input.
  """
  @spec infohash(binary) :: {:ok, String.t()} | {:error, :bad_torrent}
  def infohash(bin) when is_binary(bin) do
    case info_span(bin) do
      {:ok, {start, len}} ->
        digest = :crypto.hash(:sha, binary_part(bin, start, len))
        {:ok, Base.encode16(digest, case: :lower)}

      :error ->
        {:error, :bad_torrent}
    end
  rescue
    # :binary.at/2 raises on out-of-range, str-length parse can raise on
    # malformed input; treat any of it as a bad torrent rather than crashing.
    _ -> {:error, :bad_torrent}
  end

  # Top-level must be a dict; walk its key/value pairs for "info".
  defp info_span(<<?d, _::binary>> = bin), do: walk(bin, 1)
  defp info_span(_), do: :error

  defp walk(bin, off) do
    case :binary.at(bin, off) do
      ?e ->
        :error

      _ ->
        {klen, kstart} = str_len(bin, off, 0)
        key = binary_part(bin, kstart, klen)
        vstart = kstart + klen
        vend = skip(bin, vstart)
        if key == "info", do: {:ok, {vstart, vend - vstart}}, else: walk(bin, vend)
    end
  end

  # Offset just past the bencoded value starting at `off`.
  defp skip(bin, off) do
    case :binary.at(bin, off) do
      ?i -> find(bin, off + 1, ?e) + 1
      ?l -> skip_container(bin, off + 1)
      ?d -> skip_container(bin, off + 1)
      c when c in ?0..?9 -> {len, rest} = str_len(bin, off, 0); rest + len
    end
  end

  defp skip_container(bin, off) do
    case :binary.at(bin, off) do
      ?e -> off + 1
      _ -> skip_container(bin, skip(bin, off))
    end
  end

  # Parse a `<len>:` byte-string prefix → {len, offset_after_colon}.
  defp str_len(bin, off, acc) do
    case :binary.at(bin, off) do
      ?: -> {acc, off + 1}
      d when d in ?0..?9 -> str_len(bin, off + 1, acc * 10 + (d - ?0))
    end
  end

  defp find(bin, off, ch), do: if(:binary.at(bin, off) == ch, do: off, else: find(bin, off + 1, ch))
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder/download/torrent_test.exs`
Expected: PASS (all cases, no raise).

- [ ] **Step 5: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download/torrent.ex test/cinder/download/torrent_test.exs
git commit -m "Phase 5: Torrent.infohash/1 — bencode v1 infohash from .torrent bytes"
```

---

### Task 4: qBittorrent base32 magnets + client receive timeouts

**Files:**
- Modify: `lib/cinder/download/client/qbittorrent.ex` (`btih/1` ~L99-104, `base/1` ~L122-125)
- Modify: `lib/cinder/acquisition/indexer/prowlarr.ex` (`request/1` ~L32-41)
- Modify: `lib/cinder/catalog/tmdb/http.ex` (`request/1` ~L37-46)
- Test: `test/cinder/download/client/qbittorrent_test.exs`

**Interfaces:**
- Produces: `QBittorrent.add/1` accepts base32 magnets, returning `{:ok, lowercase_hex_hash}`. All three Req clients send `receive_timeout: 15_000` by default (overridable via config `req_options`).

- [ ] **Step 1: Write the failing test**

In `test/cinder/download/client/qbittorrent_test.exs`, add a base32 case using the file's
existing `stub_qbit/1` helper (it serves the login round-trip, then delegates the action to
the callback; the `QBittorrent` alias already exists in the file):

```elixir
  test "add/1 accepts a base32 magnet and returns its lowercase-hex infohash" do
    raw = :crypto.hash(:sha, "phase5")
    b32 = Base.encode32(raw, padding: false)
    expected = Base.encode16(raw, case: :lower)

    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/add"
      Req.Test.text(conn, "Ok.")
    end)

    assert {:ok, ^expected} =
             QBittorrent.add(%{download_url: "magnet:?xt=urn:btih:#{b32}&dn=x"})
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: FAIL — current `btih/1` only matches 40-char hex; a base32 magnet yields `{:error, :unsupported_download_url}`.

- [ ] **Step 3: Implement base32 in `btih/1`**

In `lib/cinder/download/client/qbittorrent.ex`, replace `btih/1` (~L99-104) with:

```elixir
  # Match the magnet verbatim (don't upcase the whole string — that breaks the
  # lowercase `xt=urn:btih:` literal); upcase only the captured base32 hash.
  @hex_btih ~r/xt=urn:btih:([a-fA-F0-9]{40})(?:&|$)/
  @b32_btih ~r/xt=urn:btih:([a-zA-Z2-7]{32})(?:&|$)/

  defp btih("magnet:" <> _ = magnet) do
    case Regex.run(@hex_btih, magnet) do
      [_, hex] ->
        {:ok, String.downcase(hex)}

      nil ->
        case Regex.run(@b32_btih, magnet) do
          [_, b32] ->
            case Base.decode32(String.upcase(b32), padding: false) do
              {:ok, raw} -> {:ok, Base.encode16(raw, case: :lower)}
              :error -> :error
            end

          nil ->
            :error
        end
    end
  end
```

- [ ] **Step 4: Add `receive_timeout` to the qBittorrent base options**

In the same file, update `base/1` (~L122-125):

```elixir
  defp base(config) do
    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end
```

- [ ] **Step 5: Add `receive_timeout` to Prowlarr and TMDB**

In `lib/cinder/acquisition/indexer/prowlarr.ex`, in `request/1`, change the base list:

```elixir
    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
```

In `lib/cinder/catalog/tmdb/http.ex`, in `request/1`, change the base list:

```elixir
    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> auth(Keyword.get(config, :token))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs test/cinder/acquisition/indexer/prowlarr_test.exs test/cinder/catalog/tmdb/http_test.exs`
Expected: PASS — the new base32 test passes and the existing client tests are unaffected by the timeout (Req.Test ignores it).

- [ ] **Step 7: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download/client/qbittorrent.ex lib/cinder/acquisition/indexer/prowlarr.ex lib/cinder/catalog/tmdb/http.ex test/cinder/download/client/qbittorrent_test.exs
git commit -m "Phase 5: qBittorrent base32 magnets + 15s receive_timeout on all Req clients"
```

---

### Task 5: qBittorrent `.torrent` URL handoff (fetch + infohash + upload)

**Files:**
- Modify: `lib/cinder/download/client/qbittorrent.ex` (`add/1` clauses ~L24-40)
- Test: `test/cinder/download/client/qbittorrent_test.exs`

**Interfaces:**
- Consumes: `Cinder.Download.Torrent.infohash/1` (Task 3).
- Produces: `QBittorrent.add(%{download_url: "http(s)://…"})` fetches the `.torrent`, returns `{:ok, hex}` from `Torrent.infohash/1`; `{:error, :bad_torrent}` on non-torrent body; `{:error, {:torrent_fetch_status, n}}` / `{:error, reason}` on fetch failure; `{:error, :add_rejected}` if qBittorrent returns `"Fails."`.

- [ ] **Step 1: Wire the fetch plug in test config**

The external `.torrent` GET is a fresh `Req.get(url, plug: fetch_plug())` — separate from the
qBittorrent base-URL requests — so it needs its own test plug. In `config/test.exs`, add a
`fetch_plug` key to the QBittorrent block (reuse the same stub name as the API so one stub can
serve all three requests):

```elixir
config :cinder, Cinder.Download.Client.QBittorrent,
  base_url: "http://localhost:8080",
  username: "test",
  password: "test",
  fetch_plug: {Req.Test, Cinder.QBittorrentStub},
  req_options: [plug: {Req.Test, Cinder.QBittorrentStub}, retry: false]
```

- [ ] **Step 2: Write the failing tests (and fix the now-stale rejection test)**

In `test/cinder/download/client/qbittorrent_test.exs`, add a host-branching stub helper
(extends the existing `stub_qbit/1` pattern; the external tracker GET has `conn.host ==
"tracker.test"`, the qBittorrent calls have host `localhost`):

```elixir
  defp stub_torrent_flow(torrent_bytes) do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case {conn.host, conn.request_path} do
        {"tracker.test", _} ->
          Req.Test.text(conn, torrent_bytes)

        {_, "/api/v2/auth/login"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        {_, "/api/v2/torrents/add"} ->
          Req.Test.text(conn, "Ok.")
      end
    end)
  end
```

Add the two new tests:

```elixir
  test "add/1 fetches a .torrent URL, computes its infohash, and uploads it" do
    infoval = "d6:lengthi5e4:name5:M.mkv12:piece lengthi16384ee"
    torrent_bytes = "d8:announce11:http://x/an4:info" <> infoval <> "e"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)

    stub_torrent_flow(torrent_bytes)

    assert {:ok, ^expected} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/123.torrent"})
  end

  test "add/1 returns :bad_torrent when the URL returns a non-torrent body" do
    stub_torrent_flow("<html>nope</html>")

    assert {:error, :bad_torrent} =
             QBittorrent.add(%{download_url: "https://tracker.test/dl/x"})
  end
```

Now **update the existing test** "add/1 rejects a non-magnet download_url without calling
qBittorrent" (qbittorrent_test.exs ~L38-41): its URL `"http://prowlarr/file/1.torrent"` is no
longer rejected (HTTP URLs are now fetched). Change it to a genuinely unsupported value so it
still asserts the catch-all:

```elixir
  test "add/1 rejects an unsupported download_url scheme without calling qBittorrent" do
    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: "udp://tracker.test/announce"})

    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: nil})
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: FAIL — `add/1` currently returns `{:error, :unsupported_download_url}` for an HTTP URL.

- [ ] **Step 4: Implement the `.torrent` clauses**

In `lib/cinder/download/client/qbittorrent.ex`, keep the existing `add(%{download_url: "magnet:" <> _ ...})` clause, then add HTTP clauses **before** the catch-all, and a private helper:

```elixir
  def add(%{download_url: "http://" <> _ = url}), do: add_torrent_url(url)
  def add(%{download_url: "https://" <> _ = url}), do: add_torrent_url(url)

  def add(%{download_url: _}), do: {:error, :unsupported_download_url}
```

```elixir
  # Fetch the .torrent, compute its infohash (so status/1 can poll it), then
  # upload the bytes to qBittorrent. decode_body: false keeps the bytes raw so
  # the infohash is over the exact on-the-wire content.
  defp add_torrent_url(url) do
    with {:ok, %{status: 200, body: bytes}} when is_binary(bytes) <-
           Req.get(url, receive_timeout: 15_000, decode_body: false, plug: fetch_plug()),
         {:ok, hash} <- Cinder.Download.Torrent.infohash(bytes),
         {:ok, %{status: 200, body: body}} <-
           action(fn req ->
             Req.post(req,
               url: "/api/v2/torrents/add",
               form_multipart: [
                 torrents: {bytes, filename: "t.torrent", content_type: "application/x-bittorrent"}
               ]
             )
           end) do
      if String.trim(to_string(body)) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      {:error, :bad_torrent} = e -> e
      {:ok, %{status: status}} -> {:error, {:torrent_fetch_status, status}}
      other -> error(other)
    end
  end

  # In prod, no plug (real HTTP). In test, config can inject a Req.Test plug.
  defp fetch_plug, do: Keyword.get(config(), :fetch_plug)
```

Note: `Req.get/2` with `plug: nil` behaves as a normal request, so `fetch_plug/0` returning `nil` in prod is fine. `config/0` already exists in `qbittorrent.ex` (`Application.get_env(:cinder, __MODULE__, [])`) — reuse it. Keep the existing `error/1` helper.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: PASS (both new tests + the updated rejection test + all prior).

- [ ] **Step 6: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download/client/qbittorrent.ex test/cinder/download/client/qbittorrent_test.exs config/test.exs
git commit -m "Phase 5: qBittorrent handles .torrent URLs via self-computed infohash"
```

---

### Task 6: Generalize the Poller's `retry_or_fail` (refactor, behaviour-preserving)

**Files:**
- Modify: `lib/cinder/download/poller.ex` (`retry_or_fail/2` → `/4` ~L110-123; callers in `advance/1` ~L76 and `import_one/1` ~L103)

**Interfaces:**
- Produces: `retry_or_fail(movie, reason, attempts_field :: atom, terminal_status :: atom)` — increments `attempts_field`, parking at `terminal_status` once `>= @max_attempts`.

- [ ] **Step 1: Replace `retry_or_fail/2` with the parameterized `/4`**

In `lib/cinder/download/poller.ex`, replace the existing `retry_or_fail/2` with:

```elixir
  # Bounded retry: keep the movie where it is and try again next tick, but after
  # @max_attempts park it at `terminal_status` so a persistent failure surfaces a
  # terminal state instead of looping (and re-logging) forever.
  defp retry_or_fail(movie, reason, attempts_field, terminal_status) do
    attempts = (Map.get(movie, attempts_field) || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "movie #{movie.id} #{attempts_field} exhausted after #{attempts}: #{inspect(reason)}"
      )

      Catalog.transition(movie, %{status: terminal_status})
    else
      Logger.info(
        "movie #{movie.id} #{attempts_field} #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      # Dynamic key MUST come before keyword pairs in a map literal.
      Catalog.transition(movie, %{attempts_field => attempts, status: movie.status})
    end
  end
```

- [ ] **Step 2: Update the two existing callers**

In `advance/1`, change `retry_or_fail(movie, :no_content_path)` to:

```elixir
        retry_or_fail(movie, :no_content_path, :import_attempts, :import_failed)
```

In `import_one/1`, change `retry_or_fail(movie, reason)` to:

```elixir
        retry_or_fail(movie, reason, :import_attempts, :import_failed)
```

- [ ] **Step 3: Run the existing poller tests to verify no behaviour change**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: PASS — all existing import-retry/bound tests still green (this is a pure refactor).

- [ ] **Step 4: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download/poller.ex
git commit -m "Phase 5: generalize Poller.retry_or_fail to a counter-field + terminal-status helper"
```

---

### Task 7: Poller search sweep — auto-wire `:requested`, backoff, bounded retry

**Files:**
- Modify: `lib/cinder/download/poller.ex` (add `alias Cinder.Download`; `@search_retry_after`; `init/1`; `do_poll/0` → `do_poll/1`; `handle_info`/`handle_call`; `search_requested/1`, `search_one/1`, `search_due?/2`; moduledoc)
- Test: `test/cinder/download/poller_test.exs` (add tests; adjust the "full state machine" test)

**Interfaces:**
- Consumes: `Cinder.Download.start/1` (Task 2), `Cinder.Catalog.get_movie_by_id/1` (Task 1), `Cinder.Catalog.list_by_status/1`, `retry_or_fail/4` (Task 6).
- Produces: the Poller, on each tick, searches due `:requested`/`:searching` movies; `start_link` accepts `search_retry_after:` (seconds; default 60; tests pass `0`).

- [ ] **Step 1: Write the failing end-to-end auto-loop test**

In `test/cinder/download/poller_test.exs` (which already uses `setup :set_mox_global` and `async: false`), add:

```elixir
  test "auto-wires a :requested movie through to :available with no manual Download.start call" do
    {:ok, movie} =
      Catalog.add_to_watchlist(%{tmdb_id: 900, title: "Inception", imdb_id: "tt1375666"})

    assert movie.status == :requested

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok, [%{title: "Inception.2010.1080p.BluRay.x264-GRP", size: 8_000_000_000, download_url: "magnet:?x", seeders: 10}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-900"} end)

    stub(Cinder.Download.ClientMock, :status, fn "hash-900" ->
      {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
    end)

    stub_successful_import()

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    # search runs last in a tick: poll 1 → :downloading, poll 2 → :downloaded → :available
    assert :ok = Poller.poll()
    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/download/poller_test.exs` (the new "auto-wires…" test is the one in focus)
Expected: FAIL — the movie stays `:requested` (no search sweep yet).

- [ ] **Step 3: Implement the search sweep**

In `lib/cinder/download/poller.ex`:

Add the alias (near the existing aliases):

```elixir
  alias Cinder.Catalog
  alias Cinder.Download
  alias Cinder.Library
```

Add the default near `@max_attempts`:

```elixir
  @search_retry_after 60
```

Thread `search_retry_after` through state in `init/1`:

```elixir
  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
    {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
  end
```

Pass state into `do_poll` from both entry points:

```elixir
  @impl true
  def handle_info(:poll, state) do
    do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll(state)
    {:reply, :ok, state}
  end
```

Replace `do_poll/0` with `do_poll/1` (search runs **last** — see spec §3.1):

```elixir
  defp do_poll(state) do
    advance_downloading()
    import_downloaded()
    search_requested(state.search_retry_after)
    :ok
  end
```

Add the sweep + classifier + backoff gate (near `advance_downloading/0`):

```elixir
  defp search_requested(retry_after) do
    movies = Catalog.list_by_status(:requested) ++ Catalog.list_by_status(:searching)

    for movie <- movies, search_due?(movie, retry_after) do
      isolate(movie, &search_one/1)
    end
  end

  # Permanent search failures — retrying can't help, so park immediately (mirrors
  # @permanent_import_errors). :unsupported_download_url = unknown URL scheme;
  # :bad_torrent = the fetched .torrent was malformed/not bencode.
  @permanent_search_errors [:unsupported_download_url, :bad_torrent]

  defp search_one(movie) do
    case Download.start(movie) do
      {:ok, _movie} ->
        :ok

      {:error, :no_imdb_id} ->
        Catalog.transition(movie, %{status: :no_match})

      {:error, reason} when reason in @permanent_search_errors ->
        Logger.warning("movie #{movie.id} search failed permanently: #{inspect(reason)}")
        Catalog.transition(movie, %{status: :search_failed})

      {:error, reason} ->
        # Re-read so the counter write preserves start/1's current status
        # (e.g. :searching after an indexer/client failure) instead of the stale
        # struct's, which would revert :searching -> :requested.
        movie |> reread() |> retry_or_fail(reason, :search_attempts, :search_failed)
    end
  end

  defp reread(movie), do: Catalog.get_movie_by_id(movie.id) || movie

  # Fresh movies (search_attempts == 0) attempt immediately; failed ones back off
  # to once per `retry_after` seconds (external services — don't hammer). retry_after
  # 0 (test) makes everything due.
  defp search_due?(_movie, 0), do: true
  defp search_due?(%{search_attempts: 0}, _retry_after), do: true

  defp search_due?(movie, retry_after),
    do: DateTime.diff(DateTime.utc_now(), movie.updated_at) >= retry_after
```

Update the moduledoc to mention the search sweep (`:requested → :searching → :downloading`, backoff + bounded retry → `:search_failed`).

- [ ] **Step 4: Run the auto-loop test to verify it passes**

Run: `mix test test/cinder/download/poller_test.exs` (the new "auto-wires…" test is the one in focus)
Expected: PASS.

- [ ] **Step 5: Write the bounded-retry, backoff, and permanent-error tests**

Add to `test/cinder/download/poller_test.exs`:

```elixir
  test "a persistently transient search error parks :search_failed after max attempts" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 901, title: "M", imdb_id: "tt1"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1" -> {:error, :prowlarr_down} end)

    # search_retry_after: 0 → every poll is due
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    Enum.each(1..9, fn _ -> Poller.poll() end)
    refute Repo.get!(Movie, movie.id).status == :search_failed

    assert :ok = Poller.poll()
    assert %Movie{status: :search_failed} = Repo.get!(Movie, movie.id)
  end

  test "backoff: a just-failed movie is not re-attempted until retry_after elapses" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 902, title: "M", imdb_id: "tt2"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt2" -> {:error, :prowlarr_down} end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 60})

    # First poll: fresh (attempts 0) → attempted → search_attempts becomes 1.
    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).search_attempts == 1

    # Second poll immediately: not due (updated_at is ~now) → not attempted.
    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).search_attempts == 1

    # Back-date updated_at past the window → due again → attempted.
    past = DateTime.utc_now() |> DateTime.add(-61, :second) |> DateTime.truncate(:second)
    Repo.update_all(Movie, set: [updated_at: past])
    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).search_attempts == 2
  end

  test "unsupported download URL parks :search_failed immediately (no retry)" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 903, title: "M", imdb_id: "tt3"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt3" ->
      {:ok, [%{title: "M.1080p", size: 8_000_000_000, download_url: "magnet:?x", seeders: 5}]}
    end)
    stub(Cinder.Download.ClientMock, :add, fn _ -> {:error, :unsupported_download_url} end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    movie = Repo.get!(Movie, movie.id)
    assert movie.status == :search_failed
    assert movie.search_attempts == 0
  end

  test "genuinely-missing imdb parks :no_match; transient TMDB error retries" do
    {:ok, miss} = Catalog.add_to_watchlist(%{tmdb_id: 904, title: "M"})
    {:ok, flaky} = Catalog.add_to_watchlist(%{tmdb_id: 905, title: "N"})

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn
      904 -> {:ok, %{imdb_id: nil}}
      905 -> {:error, {:tmdb_status, 503}}
    end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    assert %Movie{status: :no_match} = Repo.get!(Movie, miss.id)
    assert %Movie{status: :requested, search_attempts: 1} = Repo.get!(Movie, flaky.id)
  end
```

- [ ] **Step 6: Adjust the existing "full state machine" test**

The test "drives a movie through the full state machine: requested -> downloaded" (poller_test.exs ~L74-106) calls `Download.start(movie)` manually. With the search sweep, that's now redundant. Either: (a) keep it as-is (it still passes — the movie reaches `:downloading` via the manual call, then `Poller.poll()` advances it; the sweep finds nothing new at `:downloading`), or (b) rename it to reflect it tests `Download.start/1` directly. Minimal change: leave it green; the new "auto-wires…" test is the trigger proof. Confirm it still passes in Step 7. (Do not remove the focused `Download.start/1` unit coverage in `download_test.exs`.)

- [ ] **Step 7: Run the poller tests to verify all pass**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: PASS (new tests + all existing, including crash-recovery and import bounds).

- [ ] **Step 8: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder/download/poller.ex test/cinder/download/poller_test.exs
git commit -m "Phase 5: Poller auto-searches :requested movies (backoff + bounded retry -> :search_failed)"
```

---

### Task 8: Shared `movie_status_badge/1` component

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `movie_status_badge/1` + `status_badge_class/1`)
- Modify: `lib/cinder_web/live/watchlist_live.ex` (use the shared badge at ~L122)
- Test: `test/cinder_web/live/watchlist_live_test.exs` (assert a colour class renders)

**Interfaces:**
- Produces: `<.movie_status_badge status={atom} />` — a daisyUI badge coloured by pipeline status. Available in all views via `CinderWeb` HTML helpers (core_components is imported there).

- [ ] **Step 1: Write the failing test**

In `test/cinder_web/live/watchlist_live_test.exs`, add a render assertion (adapt to the file's existing setup; a watchlisted movie is `:requested`, so its badge carries `badge-neutral`):

```elixir
  test "watchlist renders a colour-coded status badge", %{conn: conn} do
    {:ok, _movie} = Cinder.Catalog.add_to_watchlist(%{tmdb_id: 8100, title: "M"})
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "badge-neutral"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder_web/live/watchlist_live_test.exs` (the new "colour-coded…" test is the one in focus)
Expected: FAIL — current badge is `badge badge-soft badge-sm`, no status colour.

- [ ] **Step 3: Add the shared component**

In `lib/cinder_web/components/core_components.ex`, add:

```elixir
  @doc "A daisyUI badge for a movie's pipeline status, coloured by state."
  attr :status, :atom, required: true

  def movie_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_badge_class(@status)]}>{@status}</span>
    """
  end

  defp status_badge_class(:requested), do: "badge-neutral"
  defp status_badge_class(:searching), do: "badge-info"
  defp status_badge_class(:downloading), do: "badge-primary"
  defp status_badge_class(:downloaded), do: "badge-accent"
  defp status_badge_class(:available), do: "badge-success"
  defp status_badge_class(:no_match), do: "badge-warning"
  defp status_badge_class(:search_failed), do: "badge-error"
  defp status_badge_class(:import_failed), do: "badge-error"
```

- [ ] **Step 4: Use it in `WatchlistLive`**

In `lib/cinder_web/live/watchlist_live.ex`, replace the badge at ~L122:

```elixir
        <.movie_status_badge status={m.status} />
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/watchlist_live_test.exs`
Expected: PASS (the new assertion + all existing watchlist tests).

- [ ] **Step 6: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/watchlist_live_test.exs
git commit -m "Phase 5: shared movie_status_badge/1 component, used by the watchlist"
```

---

### Task 9: `StatusLive` dashboard at `/status`

**Files:**
- Create: `lib/cinder_web/live/status_live.ex`
- Modify: `lib/cinder_web/router.ex` (add the route)
- Modify: `lib/cinder_web/live/watchlist_live.ex` (nav link to `/status`)
- Test: `test/cinder_web/live/status_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.subscribe/0`, `Catalog.list_watchlist/0`, `{:movie_updated, %Movie{}}` broadcasts, `<.movie_status_badge/>` (Task 8).
- Produces: a LiveView at `/status` rendering a table of all movies with live status badges.

- [ ] **Step 1: Write the failing test**

Create `test/cinder_web/live/status_live_test.exs`:

```elixir
defmodule CinderWeb.StatusLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Catalog

  test "renders movies with status badges and live-updates on transition", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9100, title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/status")
    assert html =~ "Dune"
    assert html =~ "badge-neutral"

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-primary"
  end

  test "prepends a movie whose first transition arrives after mount", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/status")

    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9101, title: "Arrival"})
    {:ok, _} = Catalog.transition(movie, %{status: :searching})

    html = render(lv)
    assert html =~ "Arrival"
    assert html =~ "badge-info"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder_web/live/status_live_test.exs`
Expected: FAIL — no `/status` route / `StatusLive`.

- [ ] **Step 3: Create `StatusLive`**

Create `lib/cinder_web/live/status_live.ex`:

```elixir
defmodule CinderWeb.StatusLive do
  @moduledoc """
  Live status dashboard: every requested movie and its pipeline state, updated in
  real time via PubSub. Mounted at `/status`.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()
    {:ok, assign(socket, movies: Catalog.list_watchlist())}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    movies = socket.assigns.movies

    movies =
      if Enum.any?(movies, &(&1.id == movie.id)) do
        Enum.map(movies, fn m -> if m.id == movie.id, do: movie, else: m end)
      else
        [movie | movies]
      end

    {:noreply, assign(socket, movies: movies)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Status
        <:subtitle>Every requested movie and its live pipeline state.</:subtitle>
      </.header>

      <.link navigate={~p"/"} class="link mb-6 inline-block">← Search &amp; add</.link>

      <p :if={@movies == []} class="text-base-content/60">No movies yet.</p>

      <table :if={@movies != []} id="status-table" class="table">
        <thead>
          <tr><th>Title</th><th>Status</th></tr>
        </thead>
        <tbody>
          <tr :for={m <- @movies} id={"movie-#{m.id}"}>
            <td>
              {m.title}
              <span :if={m.year} class="text-base-content/60">({m.year})</span>
            </td>
            <td><.movie_status_badge status={m.status} /></td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
```

(The status board is a dense, scannable table — Title/Year + colour-coded badge. The spec
mentioned a poster thumbnail; it is **deliberately omitted** here to keep the board compact
and avoid duplicating `WatchlistLive`'s private `poster_url/1`. Add it later if wanted.)

- [ ] **Step 4: Add the route**

In `lib/cinder_web/router.ex`, in the `:browser`-scoped block that has `live "/", WatchlistLive`, add:

```elixir
      live "/status", StatusLive
```

- [ ] **Step 5: Add a nav link from the watchlist page**

In `lib/cinder_web/live/watchlist_live.ex`, add a link near the `<.header>` (inside the `Layouts.app`):

```elixir
      <.link navigate={~p"/status"} class="link mb-6 inline-block">Status dashboard →</.link>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/status_live_test.exs`
Expected: PASS (both render + live-update + prepend).

- [ ] **Step 7: Run the full suite and commit**

Run: `mix test`
Expected: green.

```bash
git add lib/cinder_web/live/status_live.ex lib/cinder_web/router.ex lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/status_live_test.exs
git commit -m "Phase 5: /status dashboard LiveView with live PubSub updates"
```

---

### Task 10: Live smoke-test documentation

**Files:**
- Create: `docs/phase-5-smoke-test.md`

**Interfaces:** none (documentation).

- [ ] **Step 1: Write the smoke-test doc**

Create `docs/phase-5-smoke-test.md`:

```markdown
# Phase 5 — Live smoke test

The mocked suite proves wiring and logic; only a live run proves your actual
Prowlarr/qBittorrent/Jellyfin return what Cinder expects. Run this when those
services are reachable.

## 1. Set credentials (read by `config/runtime.exs` in all envs)

    export TMDB_API_TOKEN=...            # TMDB v4 bearer token
    export QBITTORRENT_URL=http://localhost:8080
    export QBITTORRENT_USERNAME=...
    export QBITTORRENT_PASSWORD=...
    export JELLYFIN_URL=http://localhost:8096
    export JELLYFIN_API_KEY=...
    export LIBRARY_PATH=/path/to/jellyfin/movies   # MUST be the same filesystem as the qBittorrent download dir (hardlink)

Prowlarr is configured under `config :cinder, Cinder.Acquisition.Indexer.Prowlarr`
(`base_url`, `api_key`); add an env-var block to `config/runtime.exs` if you
haven't already (mirror the qBittorrent block).

## 2. Run

    mix phx.server

Open `/`, search a real movie, click Add. Open `/status` and watch it advance
`:requested → :searching → :downloading → :downloaded → :available`.

## 3. Known hazards / what each terminal state means

- **`:search_failed`** (red badge) — a release was found but couldn't be handed
  off, or transient search/handoff errors exhausted ~10 minutes of retries.
  Check the server log for the reason. Causes: a malformed/HTML "torrent"
  response, a BitTorrent v2-only (SHA-256) torrent (not handled — v1 only), or a
  persistent Prowlarr/qBittorrent outage. Distinct from `:no_match` on purpose.
- **`:no_match`** (yellow) — no acceptable release exists (scorer rejected all /
  zero results), or the movie has no IMDb id on TMDB. Passive; nothing to fix.
- **`:import_failed`** (red) — completed download had no usable video file, or
  import failed ~10 times. The hardlink requires `LIBRARY_PATH` to be on the same
  filesystem as the download dir; a cross-filesystem path fails every import.
- **Jellyfin scan is unvalidated against a real instance** — `MediaServer.Jellyfin.scan/0`
  (POST `/Library/Refresh`, `x-emby-token` header) is mock-tested only; the live
  run is its first real call. Adjust the endpoint/header if the scan doesn't fire.
- **Manually re-requesting a parked movie** keeps its `search_attempts`/`import_attempts`
  at the cap, so it re-parks on the first attempt — reset the counter in IEx
  (no retry UI yet).
```

- [ ] **Step 2: Verify the suite is still green and commit**

Run: `mix test`
Expected: green (no code change, but confirm).

```bash
git add docs/phase-5-smoke-test.md
git commit -m "Phase 5: live smoke-test checklist + terminal-state guide"
```

---

## Plan self-review

**Spec coverage:**
- Orchestration / extend Poller / search last → Task 7. ✓
- Backoff + bounded retry, `search_due?`, injectable interval → Task 7. ✓
- `:search_failed` terminal, `search_attempts`, migration, enum, cast → Task 1. ✓
- `ensure_imdb_id` transient/permanent split + `start/1` contract + test updates → Task 2. ✓
- `search_one` re-read (stale-write fix), `Catalog.get_movie_by_id/1` → Tasks 1 + 7. ✓
- base32 magnets → Task 4. ✓ `.torrent` via `Torrent.infohash/1` → Tasks 3 + 5. ✓
- `receive_timeout` on all three clients → Task 4. ✓
- Shared `movie_status_badge/1` → Task 8. ✓ `StatusLive` + route + nav → Task 9. ✓
- Smoke-test doc → Task 10. ✓
- Generalized `retry_or_fail` → Task 6. ✓

**Placeholder scan:** every code step contains complete code; the only "adapt to the file's existing setup" notes are for `Req.Test`/test-helper conventions whose exact local form must be read from the existing test file — the required behaviour and assertions are fully specified.

**Type consistency:** `Catalog.get_movie_by_id/1` (Task 1) is consumed by `search_one`'s `reread/1` (Task 7); `retry_or_fail/4` signature (Task 6) matches both call sites (Tasks 6, 7); `Torrent.infohash/1` return shape (Task 3) matches `add_torrent_url`'s `with` (Task 5); `:search_failed` (Task 1) is the terminal used in Task 7 and the badge in Task 8; `search_retry_after` option name is consistent across `init/1` and tests (Task 7).

**Ordering:** Tasks are in dependency order (1 data → 2 download → 3 torrent → 4/5 client → 6/7 poller → 8/9 web → 10 doc). Each ends green and committed.
