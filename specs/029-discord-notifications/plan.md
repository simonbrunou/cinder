# Discord Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Cinder's six pipeline events to a Discord channel as rich embeds via a webhook, configured in-app at `/settings`, opt-in per install.

**Architecture:** A new `Cinder.Notifier.Discord` module implements the existing `Cinder.Notifier` behaviour. It delegates the log line to `Cinder.Notifier.Log`, then POSTs a Discord embed via `Req` when a webhook URL is configured. The webhook URL is a `Cinder.Settings` registry entry (Cloak-encrypted secret) that overlays `Application.get_env(:cinder, Cinder.Notifier.Discord)[:webhook_url]`. The config default `:notifier` flips from `Log` to `Discord` — behaviourally identical to today until a webhook is set.

**Tech Stack:** Elixir 1.20 / OTP 29, `Req` 0.6.1 (already a dep), `Req.Test` stubs, ExUnit, `Cinder.Settings` + Cloak, gettext, daisyUI settings UI.

## Global Constraints

- `mix test` (the alias: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `ecto.create/migrate`, then the suite) must be fully green. This is the definition of done.
- **The `mix test` alias format/credo/compile-gates the WHOLE project on every invocation** — including `mix test <file>`. So: (a) run `mix format` before any `mix test`; (b) a mid-edit unformatted file anywhere aborts the run at the format gate, not at the test. Keep the diff formatted.
- **No new dependency** (`Req` is already present) and **no new service env var** — the webhook is an in-app `Cinder.Settings` registry entry, per the project convention.
- The Discord notifier is reached only through the `Cinder.Notifier` behaviour; it must never raise out of `notify/1`, **and** it must not block the (synchronous) call sites — every request carries a bounded `receive_timeout`.
- Secret settings are encrypted at rest via the `secret: true` registry flag (compile-time `@secret_keys`); never echo a secret back.
- **Any new `Cinder.Settings` domain label must be registered in `CinderWeb.SettingsLabels.known/0`** (`gettext_noop/1`) AND get a French translation, or `no_hardcoded_strings_test` / `translations_complete_test` fail. Run `mix gettext.extract --merge` **last**, after all lib edits (msgid line-refs drift and fail `--check-up-to-date` otherwise — project convention).
- Embed colors, verbatim: green `0x2ECC71` (approved/available), red `0xE74C3C` (failures).
- Test stub name: `Cinder.DiscordStub`; test webhook URL: `"https://discord.test/hook"`.
- Do NOT add a per-file license/SPDX header — sibling files in these directories carry none.

---

### Task 1: `Cinder.Notifier.Discord` module

Self-contained transport, tested in isolation against a `Req.Test` stub with plain-map events (no DB). The config default is **not** flipped in this task, so existing behaviour is untouched until Task 2.

**Files:**
- Create: `lib/cinder/notifier/discord.ex`
- Create: `test/cinder/notifier/discord_test.exs`
- Modify: `config/test.exs` (add the Discord stub config block after the SABnzbd block, ~line 94)

**Interfaces:**
- Consumes: `Cinder.Notifier` behaviour (`@callback notify(event) :: :ok`); `Cinder.Notifier.Log.notify/1` (delegated log line).
- Produces:
  - `Cinder.Notifier.Discord.notify/1` — `@impl` behaviour callback, returns `:ok`.
  - `Cinder.Notifier.Discord.health/0` :: `:ok | {:error, term()}` — GETs the webhook to validate it **without posting**; `{:error, :not_configured}` when no webhook. Consumed by `Cinder.Health.check_service(:discord)` in Task 2.
- Event shapes (from the pipeline): `{:request_approved, request}`, `{:movie_available, movie}`, `{:movie_failed, movie, reason}`, `{:movie_upgrade_failed, movie, reason}`, `{:episodes_available, episodes}`, `{:grab_failed, grab, reason}`. Structs are accessed by dot only, so plain maps satisfy them in tests.

- [ ] **Step 1: Add the Discord stub config to `config/test.exs`**

Add after the SABnzbd `req_options` block (~line 94):

```elixir
# Discord notifier: a stub webhook so Cinder.Notifier.Discord can exercise the real HTTP
# path (POST embeds, GET health) in tests without hitting the network.
config :cinder, Cinder.Notifier.Discord,
  webhook_url: "https://discord.test/hook",
  req_options: [plug: {Req.Test, Cinder.DiscordStub}, retry: false]
```

(Leave `config/test.exs` `notifier: Cinder.TestNotifier` unchanged — the suite keeps using the test notifier; this block only powers the Discord module's own unit test.)

- [ ] **Step 2: Write the failing test file**

Create `test/cinder/notifier/discord_test.exs`. `async: false` because two tests mutate the `:cinder` app env (unset-webhook cases) and restore it.

```elixir
defmodule Cinder.Notifier.DiscordTest do
  # async: false — the "webhook unset" tests mutate and restore app env.
  use ExUnit.Case, async: false

  alias Cinder.Notifier.Discord

  # Stub the webhook endpoint and forward the decoded POST body to the test process.
  defp expect_post do
    pid = self()

    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(pid, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)
  end

  defp movie, do: %{title: "Dune", year: 2021, poster_path: "/dune.jpg"}

  test "movie_available posts a green embed with poster thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:movie_available, movie()})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "🎬 Now available"
    assert embed["description"] == "Dune (2021)"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/dune.jpg"
  end

  test "movie_failed posts a red embed with the reason" do
    expect_post()
    assert :ok = Discord.notify({:movie_failed, movie(), :no_match})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Movie failed"
    assert embed["description"] =~ "Dune (2021)"
    assert embed["description"] =~ ":no_match"
    assert embed["color"] == 0xE74C3C
  end

  test "movie_upgrade_failed posts a red embed" do
    expect_post()
    assert :ok = Discord.notify({:movie_upgrade_failed, movie(), :revert})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Upgrade failed"
    assert embed["color"] == 0xE74C3C
  end

  test "request_approved posts a green embed with the request title and poster" do
    expect_post()
    request = %{title: "Arrival", poster_path: "/arr.jpg", user_id: 3}
    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Request approved"
    assert embed["description"] == "Arrival"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/arr.jpg"
  end

  test "episodes_available posts series title + episode codes with the series poster" do
    expect_post()

    episodes = [
      %{episode_number: 1, season: %{season_number: 2, series: %{title: "Severance", poster_path: "/sev.jpg"}}},
      %{episode_number: 2, season: %{season_number: 2, series: %{title: "Severance", poster_path: "/sev.jpg"}}}
    ]

    assert :ok = Discord.notify({:episodes_available, episodes})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "📺 Now available"
    assert embed["description"] == "Severance — S02E01, S02E02"
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/sev.jpg"
  end

  test "grab_failed posts a red embed with no thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:grab_failed, %{id: 7}, :timeout})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "TV grab #7 failed"
    assert embed["color"] == 0xE74C3C
    refute Map.has_key?(embed, "thumbnail")
  end

  test "an event with no poster_path omits the thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:movie_available, %{title: "Tenet", year: 2020, poster_path: nil}})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute Map.has_key?(embed, "thumbnail")
  end

  test "with no webhook configured it returns :ok and never posts" do
    original = Application.get_env(:cinder, Cinder.Notifier.Discord)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)
    Application.put_env(:cinder, Cinder.Notifier.Discord, [])

    Req.Test.stub(Cinder.DiscordStub, fn _ -> flunk("should not POST with no webhook") end)

    assert :ok = Discord.notify({:movie_available, movie()})
    refute_receive {:posted, _}
  end

  test "a non-2xx response is swallowed (returns :ok, no raise)" do
    Req.Test.stub(Cinder.DiscordStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert :ok = Discord.notify({:movie_available, movie()})
  end

  test "a transport error is swallowed (returns :ok, no raise)" do
    Req.Test.stub(Cinder.DiscordStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert :ok = Discord.notify({:movie_available, movie()})
  end

  test "health/0 GETs the webhook (no message posted) and returns :ok on 2xx" do
    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"id" => "1", "token" => "t"})
    end)

    assert :ok = Discord.health()
  end

  test "health/0 returns {:error, :not_configured} with no webhook" do
    original = Application.get_env(:cinder, Cinder.Notifier.Discord)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)
    Application.put_env(:cinder, Cinder.Notifier.Discord, [])

    assert {:error, :not_configured} = Discord.health()
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix format && mix test test/cinder/notifier/discord_test.exs`
Expected: the alias compile gate fails first (`Cinder.Notifier.Discord` undefined) — a valid red. (If you split the alias, the file itself fails with "function notify/1 is undefined".)

- [ ] **Step 4: Implement `lib/cinder/notifier/discord.ex`**

```elixir
defmodule Cinder.Notifier.Discord do
  @moduledoc """
  Discord-webhook notifier. Delegates the log line to `Cinder.Notifier.Log`, then — when a
  webhook URL is configured — posts a rich embed per pipeline event. Best-effort: a failed post
  is logged and swallowed so a Discord outage never touches the pipeline, and the request carries
  a bounded `receive_timeout` so a hung webhook can't stall the (synchronous) poller/approval call
  sites either. `Cinder.Notifier.notify/1` catches raises on top of this.

  The webhook URL is a `Cinder.Settings` registry entry, overlaid onto
  `Application.get_env(:cinder, __MODULE__)[:webhook_url]`.

  ponytail: single transport that also logs — not a multi-transport fan-out registry
  (roadmap-parked). Upgrade path is a real dispatcher behind the same `notify/1` seam.
  """
  @behaviour Cinder.Notifier
  require Logger

  @green 0x2ECC71
  @red 0xE74C3C
  @image_base "https://image.tmdb.org/t/p/w342"

  # Bounded so a hung/dead webhook can't stall the synchronous notify/1 call sites (poller ticks,
  # the admin Approve handler). retry: false stops a Test-button GET retrying a bad webhook.
  @default_req_options [receive_timeout: 5_000, retry: false]

  @impl true
  def notify(event) do
    Cinder.Notifier.Log.notify(event)

    with url when is_binary(url) <- webhook_url(),
         embed when is_map(embed) <- embed(event) do
      post(url, embed)
    end

    :ok
  end

  @doc """
  Validates the configured webhook for the `/settings` Test button via a GET (Discord's
  "Get Webhook with Token" endpoint — checks the webhook without posting a message).
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    case webhook_url() do
      nil -> {:error, :not_configured}
      url -> base_req() |> Req.get(url: url) |> classify()
    end
  end

  # --- embeds (one per event; nil for anything unknown so notify/1 skips the post) ---

  defp embed({:request_approved, request}),
    do:
      with_poster(
        %{title: "Request approved", description: request.title, color: @green},
        request.poster_path
      )

  defp embed({:movie_available, movie}),
    do:
      with_poster(
        %{title: "🎬 Now available", description: title_year(movie), color: @green},
        movie.poster_path
      )

  defp embed({:movie_failed, movie, reason}),
    do:
      with_poster(
        %{title: "Movie failed", description: "#{title_year(movie)} — #{inspect(reason)}", color: @red},
        movie.poster_path
      )

  defp embed({:movie_upgrade_failed, movie, reason}),
    do:
      with_poster(
        %{title: "Upgrade failed", description: "#{title_year(movie)} — #{inspect(reason)}", color: @red},
        movie.poster_path
      )

  defp embed({:episodes_available, episodes}) do
    {summary, poster} = episodes_summary(episodes)
    with_poster(%{title: "📺 Now available", description: summary, color: @green}, poster)
  end

  defp embed({:grab_failed, grab, reason}),
    do: %{title: "TV grab ##{grab.id} failed", description: inspect(reason), color: @red}

  defp embed(_other), do: nil

  # --- helpers ---

  defp title_year(%{title: title, year: year}) when not is_nil(year), do: "#{title} (#{year})"
  defp title_year(%{title: title}), do: title

  defp with_poster(embed, path) when is_binary(path),
    do: Map.put(embed, :thumbnail, %{url: @image_base <> path})

  defp with_poster(embed, _path), do: embed

  # ponytail: mirrors the S0xE0y formatting in Cinder.Notifier.Log (Discord additionally needs the
  # series poster, which Log's string-only helper doesn't return). Extract a shared helper only if
  # a third consumer appears. Returns {summary, poster_path | nil}.
  defp episodes_summary([%{season: %{series: series}} | _] = episodes) do
    codes =
      Enum.map_join(episodes, ", ", fn ep ->
        "S#{pad(ep.season.season_number)}E#{pad(ep.episode_number)}"
      end)

    {"#{series.title} — #{codes}", series.poster_path}
  end

  defp episodes_summary(episodes), do: {"#{length(episodes)} episode(s)", nil}

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp webhook_url do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:webhook_url)
    |> blank_to_nil()
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Matches the repo's Req idiom (jellyfin.ex): a base req from config's req_options merged onto the
  # bounded defaults, then Req.post / Req.get with the full webhook url. req_options carries the
  # test plug (+ retry: false) in :test and is empty in prod.
  defp base_req do
    req_options = :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
    @default_req_options |> Keyword.merge(req_options) |> Req.new()
  end

  defp post(url, embed) do
    base_req()
    |> Req.post(url: url, json: %{embeds: [embed]})
    |> classify()
    |> log_if_error()
  end

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp classify({:error, reason}), do: {:error, reason}

  defp log_if_error(:ok), do: :ok

  defp log_if_error({:error, reason} = error) do
    Logger.warning("Discord notify failed: #{inspect(reason)}")
    error
  end
end
```

Note: `notify/1` discards the `with` result and returns `:ok` — the failure is already handled by `log_if_error/1`. If `credo --strict` objects to the discarded `with` (low risk — the idiom mirrors `jellyfin.ex`'s pipe-into-`case`), rewrite as: `if is_binary(url = webhook_url()) and is_map(embed = embed(event)), do: post(url, embed)`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix format && mix test test/cinder/notifier/discord_test.exs`
Expected: PASS (all cases green).

- [ ] **Step 6: credo the new file**

Run: `mix credo --strict lib/cinder/notifier/discord.ex`
Expected: no issues. (If it flags the `with`, apply the rewrite from Step 4's note and re-run Step 5.)

- [ ] **Step 7: Commit**

```bash
git restore graphify-out/ 2>/dev/null
git add lib/cinder/notifier/discord.ex test/cinder/notifier/discord_test.exs config/test.exs
git commit -m "feat(notifier): Discord webhook transport (embeds for all six events)"
```

---

### Task 2: Wire Discord into settings, health, the /settings Test button, and the default

Makes the webhook configurable in `/settings` (encrypted, translated), testable via the Test button, and flips the default notifier to Discord (safe: delegates to Log, posts only when a webhook is set).

**Files:**
- Modify: `lib/cinder/settings.ex` — one `@base_config_fields` entry + a `@groups` entry.
- Modify: `lib/cinder_web/settings_labels.ex` — register the two new labels in `known/0`.
- Modify: `lib/cinder/health.ex` — add `check_service(:discord)`.
- Modify: `lib/cinder_web/components/settings_components.ex` — `services_for/1` + `decode_service/1` clauses.
- Modify: `lib/cinder/notifier.ex` — moduledoc default-impl mention (now Discord).
- Modify: `config/config.exs` — flip the default notifier (the `notifier:` line, ~60).
- Modify: `test/cinder/settings_test.exs` — overlay-encrypts-webhook test.
- Modify/Create: `test/cinder/health_test.exs` — `check_service(:discord)` test.
- Modify: `priv/gettext/default.pot` + `priv/gettext/fr/LC_MESSAGES/default.po` — via `mix gettext.extract --merge`, then fill FR.

**Interfaces:**
- Consumes: `Cinder.Notifier.Discord.health/0` (Task 1); `Cinder.Settings.put/2`; `Cinder.Health` private `run/1`.
- Produces: `Cinder.Health.check_service(:discord) :: :ok | {:error, term()}`; `CinderWeb.SettingsComponents.services_for(:notifications)`; `CinderWeb.SettingsComponents.decode_service("discord") :: :discord`; a `"discord_webhook_url"` settings key overlaying `Application.get_env(:cinder, Cinder.Notifier.Discord)[:webhook_url]`.

- [ ] **Step 1: Write the failing settings-overlay test**

In `test/cinder/settings_test.exs`, add (match the file's existing setup + `on_exit` env-restore convention used by sibling overlay tests):

```elixir
test "a stored discord_webhook_url overlays :cinder Discord config and is encrypted at rest" do
  original = Application.get_env(:cinder, Cinder.Notifier.Discord)
  on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)

  :ok = Cinder.Settings.put("discord_webhook_url", "https://discord.com/api/webhooks/1/abc")

  assert Application.get_env(:cinder, Cinder.Notifier.Discord)[:webhook_url] ==
           "https://discord.com/api/webhooks/1/abc"

  # Stored ciphertext is not the plaintext (secret: true → Cloak-encrypted).
  row = Cinder.Repo.get_by(Cinder.Settings.Setting, key: "discord_webhook_url")
  assert row.is_secret
  refute row.value == "https://discord.com/api/webhooks/1/abc"
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix format && mix test test/cinder/settings_test.exs`
Expected: the new test FAILS — no registry entry yet, so `[:webhook_url]` is nil.

- [ ] **Step 3: Add the settings registry entry + group (`lib/cinder/settings.ex`)**

Add the entry as the last element of the `@base_config_fields` list (after the `plex_token` map — insert a `,` after that map's closing `}` and then the new map):

```elixir
    %{
      key: "discord_webhook_url",
      module: Cinder.Notifier.Discord,
      field: :webhook_url,
      secret: true,
      group: :notifications,
      label: "Discord webhook URL",
      placeholder: "https://discord.com/api/webhooks/..."
    }
```

Add the group to the `@groups` list (append after the `releases:` entry — add a `,` after it):

```elixir
    releases: "Release size bands",
    notifications: "Notifications"
```

(`@secret_keys` is derived from `@base_config_fields` at compile time, so the new key is encrypted automatically, and `apply_config_fields/1` overlays it generically, preserving the test-config `req_options`.)

- [ ] **Step 4: Register the two labels for i18n (`lib/cinder_web/settings_labels.ex`)**

In `known/0`, add the group header alongside the other `Settings.groups/0` headers and the field label alongside the static config-field labels:

```elixir
      # group header — Settings.groups/0
      gettext_noop("Notifications"),
      # config-field label — Settings.config_fields/0
      gettext_noop("Discord webhook URL"),
```

- [ ] **Step 5: Run the settings test to verify it passes**

Run: `mix format && mix test test/cinder/settings_test.exs`
Expected: the overlay test PASSES. (`no_hardcoded_strings_test` also passes now that both labels are registered; `translations_complete_test` still fails until Step 11 — expected.)

- [ ] **Step 6: Write the failing health test**

In `test/cinder/health_test.exs` (create the module if absent; `async: false`), add:

```elixir
test "check_service(:discord) validates the webhook (GET) and returns :ok" do
  Req.Test.stub(Cinder.DiscordStub, fn conn -> Req.Test.json(conn, %{"id" => "1"}) end)
  assert :ok = Cinder.Health.check_service(:discord)
end
```

If creating the file, the module skeleton:

```elixir
defmodule Cinder.HealthTest do
  use ExUnit.Case, async: false

  # (test above)
end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `mix format && mix test test/cinder/health_test.exs`
Expected: FAIL — `check_service(:discord)` has no matching clause (FunctionClauseError).

- [ ] **Step 8: Add `check_service(:discord)` to `lib/cinder/health.ex`**

Add next to the other `check_service/1` clauses (after the `:media_server` clause, ~line 27):

```elixir
  def check_service(:discord), do: run(Cinder.Notifier.Discord)
```

(`run/1` already calls `mod.health()` inside `safely/1`, so an unset/failed webhook degrades to a red badge, never a crash.)

- [ ] **Step 9: Wire the /settings Test button (`lib/cinder_web/components/settings_components.ex`)**

Add a `services_for/1` clause (before `def services_for(_group), do: []`, ~line 200):

```elixir
  def services_for(:notifications), do: [{"discord", "Discord"}]
```

Add a `decode_service/1` string clause (among the explicit clauses, before the catch-all `def decode_service(service) do`, ~line 214):

```elixir
  def decode_service("discord"), do: :discord
```

- [ ] **Step 10: Update the seam moduledoc + flip the default**

In `lib/cinder/notifier.ex`, update the moduledoc line that reads `configured impl (default \`Cinder.Notifier.Log\`)` to:

```
configured impl (default `Cinder.Notifier.Discord`, which delegates to `Cinder.Notifier.Log`
and posts to Discord only when a webhook is configured).
```

In `config/config.exs`, change the `notifier:` line from `Cinder.Notifier.Log` to:

```elixir
config :cinder, notifier: Cinder.Notifier.Discord
```

(Test config keeps `Cinder.TestNotifier`; dev/prod now route through Discord, which delegates to Log and posts only when a webhook is configured — identical behaviour until then.)

- [ ] **Step 11: Extract + translate the new gettext strings (LAST lib edit)**

Run: `mix gettext.extract --merge`
This adds `"Notifications"` and `"Discord webhook URL"` to `priv/gettext/default.pot` and merges empty `msgstr` entries into each locale `.po`. Then fill the French translations in `priv/gettext/fr/LC_MESSAGES/default.po`:

```
msgid "Notifications"
msgstr "Notifications"

msgid "Discord webhook URL"
msgstr "URL du webhook Discord"
```

(Leave any other locale as generated. Do not hand-edit line refs — the extract manages them.)

- [ ] **Step 12: Run the full suite (the alias)**

Run: `mix format && mix test`
Expected: PASS — compile `--warnings-as-errors` clean, `format --check-formatted` clean, `credo --strict` no issues, whole suite green (incl. `no_hardcoded_strings_test`, `translations_complete_test`). If `translations_complete_test` still fails, a French `msgstr` is empty/fuzzy — fix it. (Ignore a lone unrelated `pool_size: 1` checkout-timeout flake on a rerun, per project memory.)

- [ ] **Step 13: Commit**

```bash
git restore graphify-out/ 2>/dev/null
git add lib/cinder/settings.ex lib/cinder_web/settings_labels.ex lib/cinder/health.ex \
  lib/cinder_web/components/settings_components.ex lib/cinder/notifier.ex config/config.exs \
  test/cinder/settings_test.exs test/cinder/health_test.exs \
  priv/gettext/default.pot priv/gettext/fr/LC_MESSAGES/default.po
git commit -m "feat(settings): configurable Discord webhook + Test button; default notifier → Discord"
```

---

## Self-Review

**Spec coverage:**
- New module `Cinder.Notifier.Discord` (notify/embed/health/webhook/base_req/post/classify) → Task 1. ✓
- All six events + colors + poster thumbnail + episode summary → Task 1 Step 4 + tests. ✓
- Best-effort/no-raise + bounded timeout → Task 1 (`@default_req_options`, `classify`, `log_if_error`) + tests. ✓
- GET-based (non-posting) health check → Task 1 `health/0` + its test. ✓
- Config flip default, no new env var → Task 2 Step 10; webhook via settings, not env. ✓
- Settings registry entry (secret, encrypted) + `:notifications` group → Task 2 Step 3. ✓
- i18n: label registration + gettext extract + FR → Task 2 Steps 4, 11. ✓
- `/settings` Test button (services_for/decode_service/Health.check_service) → Task 2 Steps 8, 9. ✓
- Seam moduledoc updated → Task 2 Step 10. ✓
- Tests for overlay-encryption + health → Task 2 Steps 1, 6. ✓
- ponytail simplification comments (module + episode-summary mirror) → Task 1 Step 4. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands. ✓

**Type consistency:** `health/0 :: :ok | {:error, term()}` defined in Task 1, consumed via `run/1` in Task 2. `classify/1`, `base_req/0`, `post/2`, `with_poster/2`, `episodes_summary/1`, `title_year/1` names consistent across steps. Settings key `"discord_webhook_url"`, module `Cinder.Notifier.Discord`, field `:webhook_url` consistent between Task 1 (config/test.exs), Task 2 (registry), and tests. Stub `Cinder.DiscordStub` consistent across config/test.exs and both test files. Labels `"Notifications"` / `"Discord webhook URL"` consistent between the registry entry (Step 3) and `known/0` (Step 4) and the FR `.po` (Step 11). ✓

**Council fixes folded in:**
- Blocker (testability): removed the invalid `mix test -k discord` flag → whole-file `mix test <file>`.
- Blocker (testability): added the i18n label/extract/FR step (Steps 4, 11) or `no_hardcoded_strings_test` + `translations_complete_test` fail.
- Major (testability): every verify step runs `mix format` first (the alias format-gates the whole project).
- Do-now (red-team): bounded `receive_timeout` (+ `retry: false`) so a hung webhook can't stall the synchronous poller/approval call sites.
- Do-now (red-team): GET-based `health/0` so the Test button doesn't spam the channel.
- Nit (architect): `notifier.ex` moduledoc updated for the new default (Step 10).
- Nit (architect/testability): `config.exs` `notifier:` line is ~60, not 61 — edit by the `notifier:` line, not the number.
- Parked (red-team, agreed): denial notifications (needs a new upstream event), rate-limit/429 backoff, SSRF host-allowlist (admin-trusted, no worse than existing service URLs), full async dispatch (bounded timeout suffices), sharing the episode-summary helper with `Log` (keep the small copy + sync comment — extracting grows this diff).
```
