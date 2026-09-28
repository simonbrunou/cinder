# A4 Anime Specials and Release Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make explicitly monitored Anime story specials and recaps acquirable, persist global and per-title Anime release preferences, wait safely for preferred groups, and reject only confirmed hard-policy mismatches before any library staging while preserving Standard behavior.

**Architecture:** Extend the existing movie and TV paths rather than adding an anime pipeline. `Cinder.Settings` supplies typed Anime defaults, `Cinder.Acquisition.AnimePreferences` resolves them with nullable title overrides, the A2 selectors consume the resolved policy, and the download reservation freezes only its hard verification subset. `Cinder.Library.PolicyVerifier` checks each unique story source through the existing MediaInfo behaviour before creating an `ImportStage`; confirmed mismatch reuses the exact-release blocklist and durable cleanup fences, while an unavailable probe uses bounded retry and a durable TV hold.

**Tech Stack:** Elixir, Phoenix 1.8 LiveView, Ecto with SQLite, ExUnit/Mox, Jason fixtures, the existing `Cinder.Settings`, `Cinder.Acquisition.Anime`, `Cinder.Download.Intent`, `Cinder.Library.MediaInfo`, `ImportStage`, and the repository's `mix test` quality alias.

## Global Constraints

- Work only on roadmap phase A4. Do not add provider discovery, automatic special monitoring, calendar UX, fuzzy group aliases, preference learning, a general policy engine, a MediaInfo health page, live dogfood, or A5 operator documentation.
- Preserve Standard-profile movie and TV search, scoring, language filtering, MediaInfo fail-open behavior, retry semantics, and import paths. Every Anime-specific branch must be gated by the effective profile or a non-nil frozen policy snapshot.
- Auto remains Standard. Stored Anime overrides survive profile changes but stay dormant while the title is Standard.
- `nil` title overrides inherit; an explicit empty list disables the inherited list. Normalize language/group lists on write, trim them, compare groups case-insensitively, and deduplicate in first-seen order.
- Keep `preferred_language` as the dub target. `:dub` and `:dual` are invalid with `original`/`any`; `:original` with missing original metadata creates no hard audio requirement. `:require` embedded subtitles is invalid with no effective subtitle language.
- A release-name omission is never proof that an audio or subtitle stream is absent. Reject before download only on a high-confidence contradictory claim; unknown traits remain eligible for MediaInfo verification.
- Preferred-group waiting requires a valid `published_at`; an undated non-preferred result is manual-only. Waiting never increments attempts or parks a target.
- Freeze hard requirements at reservation. A later settings or title edit must not alter an in-flight movie, intent, or grab. Standard rows keep `release_policy_snapshot` nil.
- Verify before any `ImportStage` write or destination filesystem mutation. Probe each unique story source once; positively ignored extras and sidecar subtitles never satisfy an embedded-stream requirement.
- A confirmed mismatch blocklists only the exact release title, preserves attempt counters, requeues only the owned targets, and commits its durable cleanup fence atomically with the Catalog state change. Group-wide blocking is forbidden.
- A missing MediaInfo implementation, probe error, or unprobeable stream metadata is not a mismatch. Preserve the download, retry to the existing bound, then use `:import_failed` for movies or `:verification_blocked` for TV without blocklisting.
- Every database write goes through Catalog or Settings. Filesystem work stays in Library/Download after commit. Tests never call a real indexer, download client, MediaInfo process, filesystem, or media server.
- Every production behavior change follows red-green-refactor: run the named focused test and observe the specified failure before implementation.
- Add no dependency and no abstraction beyond the two focused modules named in the approved design.
- Run `mix format` before every commit. Run `graphify update .` after all code changes. `mix test` is the final source of truth.

---

### Task 1: Persist typed title overrides and implement the pure policy resolver

**Files:**
- Create via generator: `priv/repo/migrations/*_add_anime_preferences_and_policy_snapshots.exs`
- Create: `lib/cinder/acquisition/anime_preferences.ex`
- Modify: `lib/cinder/acquisition/language.ex`
- Modify: `lib/cinder/catalog/movie.ex`
- Modify: `lib/cinder/catalog/series.ex`
- Modify: `lib/cinder/catalog/grab.ex`
- Modify: `lib/cinder/download/intent.ex`
- Create: `test/cinder/acquisition/anime_preferences_test.exs`
- Modify: `test/cinder/catalog/movie_test.exs`
- Modify: `test/cinder/catalog_tv_pipeline_test.exs`

**Interfaces:**
- Adds nullable `audio_mode`, `subtitle_languages`, `embedded_subtitle_mode`, `preferred_release_groups`, `blocked_release_groups`, and `group_fallback_delay` fields to Movie and Series.
- Adds nullable `release_policy_snapshot` documents to Movie, Intent, and Grab; later tasks activate their writers.
- Produces `AnimePreferences.resolve(title, defaults)` and `AnimePreferences.snapshot(policy, release)` as pure functions.
- Keeps general, refresh, metadata, and admin changesets unable to cast Anime preferences.

- [ ] **Step 1: Generate the migration and write failing schema/resolver tests**

Run:

```bash
mix ecto.gen.migration add_anime_preferences_and_policy_snapshots
```

In `anime_preferences_test.exs`, cover inheritance, explicit empty lists, modes, normalization, and invalid combinations:

```elixir
alias Cinder.Acquisition.AnimePreferences
alias Cinder.Catalog.Series

@defaults %{
  audio_mode: :original,
  subtitle_languages: ["fr", "en"],
  embedded_subtitle_mode: :prefer,
  preferred_groups: ["SubsPlease"],
  blocked_groups: ["BadGroup"],
  group_fallback_delay: 86_400
}

test "nil inherits and explicit empty lists disable inherited lists" do
  title = %Series{original_language: "ja", preferred_language: "fr"}

  assert {:ok, inherited} = AnimePreferences.resolve(title, @defaults)
  assert inherited.required_audio_languages == ["ja"]
  assert inherited.subtitle_languages == ["fr", "en"]
  assert inherited.preferred_groups == ["subsplease"]
  assert inherited.provenance.preferred_groups == :inherited

  title = %{title | subtitle_languages: [], preferred_release_groups: []}
  assert {:ok, explicit} = AnimePreferences.resolve(title, @defaults)
  assert explicit.subtitle_languages == []
  assert explicit.preferred_groups == []
  assert explicit.provenance.subtitle_languages == :overridden
end

test "audio modes produce ordered hard requirements" do
  base = %Series{original_language: "jpn", preferred_language: "fra"}

  assert {:ok, %{required_audio_languages: ["ja"]}} =
           AnimePreferences.resolve(%{base | audio_mode: :original}, @defaults)

  assert {:ok, %{required_audio_languages: ["fr"]}} =
           AnimePreferences.resolve(%{base | audio_mode: :dub}, @defaults)

  assert {:ok, %{required_audio_languages: ["ja", "fr"]}} =
           AnimePreferences.resolve(%{base | audio_mode: :dual}, @defaults)

  assert {:ok, %{required_audio_languages: []}} =
           AnimePreferences.resolve(%{base | audio_mode: :any}, @defaults)
end

test "invalid dub target and empty required subtitle list are rejected" do
  assert {:error, :dub_language_required} =
           AnimePreferences.resolve(
             %Series{audio_mode: :dub, preferred_language: "original"},
             @defaults
           )

  assert {:error, :subtitle_language_required} =
           AnimePreferences.resolve(
             %Series{embedded_subtitle_mode: :require, subtitle_languages: []},
             @defaults
           )
end
```

Add schema changeset tests that prove the six fields are accepted only by `anime_preferences_changeset/2`, negative seconds are rejected, and provider/admin refresh leaves stored choices untouched. Add a migration smoke assertion that Movie, Intent, and Grab expose `release_policy_snapshot` while Standard inserts default it to nil.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/acquisition/anime_preferences_test.exs test/cinder/catalog/movie_test.exs test/cinder/catalog_tv_pipeline_test.exs
```

Expected: compilation fails because `AnimePreferences`, the preference fields, and `release_policy_snapshot` do not exist.

- [ ] **Step 3: Add only the approved columns**

Use one migration so policy storage and preference storage arrive atomically:

```elixir
def change do
  alter table(:movies) do
    add :audio_mode, :string
    add :subtitle_languages, {:array, :string}
    add :embedded_subtitle_mode, :string
    add :preferred_release_groups, {:array, :string}
    add :blocked_release_groups, {:array, :string}
    add :group_fallback_delay, :integer
  end

  alter table(:series) do
    add :audio_mode, :string
    add :subtitle_languages, {:array, :string}
    add :embedded_subtitle_mode, :string
    add :preferred_release_groups, {:array, :string}
    add :blocked_release_groups, {:array, :string}
    add :group_fallback_delay, :integer
  end

  alter table(:movies), do: add(:release_policy_snapshot, :map)
  alter table(:download_intents), do: add(:release_policy_snapshot, :map)
  alter table(:grabs), do: add(:release_policy_snapshot, :map)
end
```

Add identical preference fields to Movie and Series schemas:

```elixir
field :audio_mode, Ecto.Enum, values: [:original, :dub, :dual, :any]
field :subtitle_languages, {:array, :string}
field :embedded_subtitle_mode, Ecto.Enum, values: [:allow, :prefer, :require]
field :preferred_release_groups, {:array, :string}
field :blocked_release_groups, {:array, :string}
field :group_fallback_delay, :integer
```

Add `field :release_policy_snapshot, :map` to Movie, Intent, and Grab, but do not add it to the broad `changeset/2` functions. Task 6 gives it narrow reservation writers.

- [ ] **Step 4: Implement one shared preference changeset contract**

In each title schema expose only this focused writer:

```elixir
@anime_preference_fields [
  :audio_mode,
  :subtitle_languages,
  :embedded_subtitle_mode,
  :preferred_release_groups,
  :blocked_release_groups,
  :group_fallback_delay
]

def anime_preferences_changeset(title, attrs) do
  title
  |> cast(attrs, @anime_preference_fields)
  |> validate_number(:group_fallback_delay, greater_than_or_equal_to: 0)
  |> update_change(:subtitle_languages, &AnimePreferences.normalize_languages/1)
  |> update_change(:preferred_release_groups, &AnimePreferences.normalize_groups/1)
  |> update_change(:blocked_release_groups, &AnimePreferences.normalize_groups/1)
end
```

Keep `changeset/2`, `refresh_changeset/2`, `metadata_changeset/2`, and `admin_changeset/2` unchanged. Do not validate inherited cross-field state in Ecto; `resolve/2` owns that after defaults are supplied, and Task 3 feeds its result back into the form.

- [ ] **Step 5: Implement the pure normalized resolver and snapshot builder**

Use a map contract, not a policy struct or protocol:

```elixir
def resolve(title, defaults) do
  audio_mode = inherited(title.audio_mode, defaults.audio_mode)
  subtitles = inherited_list(title.subtitle_languages, defaults.subtitle_languages)
  embedded = inherited(title.embedded_subtitle_mode, defaults.embedded_subtitle_mode)

  with {:ok, required_audio} <- required_audio(audio_mode, title),
       :ok <- validate_embedded(embedded, subtitles) do
    {:ok,
     %{
       required_audio_languages: required_audio,
       subtitle_languages: normalize_languages(subtitles),
       embedded_subtitle_mode: embedded,
       preferred_groups:
         inherited_list(title.preferred_release_groups, defaults.preferred_groups)
         |> normalize_groups(),
       blocked_groups:
         inherited_list(title.blocked_release_groups, defaults.blocked_groups)
         |> normalize_groups(),
       group_fallback_delay:
         inherited(title.group_fallback_delay, defaults.group_fallback_delay),
       provenance: provenance(title)
     }}
  end
end

def snapshot(policy, release) do
  %{
    "version" => 1,
    "required_audio_languages" => policy.required_audio_languages,
    "required_embedded_subtitle_languages" =>
      if(policy.embedded_subtitle_mode == :require,
        do: policy.subtitle_languages,
        else: []
      ),
    "release_group" => normalize_group(release.group),
    "release_title" => release.title
  }
end
```

Add `Cinder.Acquisition.Language.normalize/1` as a public registry-backed function, map ISO-639 aliases such as `jpn → ja` and `fra/fre → fr`, and implement ordered uniqueness without sorting. `:original` returns `[]` when `original_language` is missing; `:any` always returns `[]`; `:dub`/`:dual` return `{:error, :dub_language_required}` for `original` or `any` targets.

- [ ] **Step 6: Verify GREEN and migration reversibility**

Run:

```bash
mix format
MIX_ENV=test mix ecto.reset
mix test test/cinder/acquisition/anime_preferences_test.exs test/cinder/catalog/movie_test.exs test/cinder/catalog_tv_pipeline_test.exs
```

Expected: all focused tests pass; existing general changesets cannot erase the preference fields; a fresh test database migrates successfully.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/cinder/acquisition/anime_preferences.ex lib/cinder/acquisition/language.ex lib/cinder/catalog/movie.ex lib/cinder/catalog/series.ex lib/cinder/catalog/grab.ex lib/cinder/download/intent.ex test/cinder/acquisition/anime_preferences_test.exs test/cinder/catalog/movie_test.exs test/cinder/catalog_tv_pipeline_test.exs
git commit -m "feat: persist anime release preferences"
```

### Task 2: Add typed Anime defaults to Settings and the existing settings form

**Files:**
- Modify: `config/config.exs`
- Modify: `lib/cinder/settings.ex`
- Modify: `lib/cinder_web/components/settings_components.ex`
- Modify: `lib/cinder_web/live/settings_live.ex`
- Modify: `test/cinder/settings_test.exs`
- Modify: `test/cinder_web/live/settings_live_test.exs`
- Modify: `test/cinder_web/live/setup_live_test.exs`

**Interfaces:**
- Produces `Settings.anime_defaults/0` with seconds and normalized lists.
- Persists the five approved non-secret keys through the existing settings transaction and bootstrap overlay.
- Renders one `Anime releases` group on `/settings`; `/setup` does not gain an A4-only section.

- [ ] **Step 1: Write failing settings and LiveView tests**

Prove defaults, validation, DB overlay, clear-to-bootstrap, and display units:

```elixir
test "anime defaults are typed and DB rows overlay the bootstrap" do
  assert Settings.anime_defaults() == %{
           audio_mode: :original,
           subtitle_languages: [],
           embedded_subtitle_mode: :prefer,
           preferred_groups: [],
           blocked_groups: [],
           group_fallback_delay: 86_400
         }

  assert :ok =
           Settings.save_form(%{
             "anime_audio_mode" => "dual",
             "anime_embedded_subtitle_mode" => "require",
             "anime_preferred_groups" => " SubsPlease, Erai-Raws, subsplease ",
             "anime_blocked_groups" => "BadGroup",
             "anime_group_fallback_delay" => "12",
             "subtitle_languages" => "fr,en"
           })

  assert Settings.anime_defaults().audio_mode == :dual
  assert Settings.anime_defaults().preferred_groups == ["subsplease", "erai-raws"]
  assert Settings.anime_defaults().group_fallback_delay == 43_200
end

test "invalid enum, negative delay, and require without languages save nothing" do
  for params <- [
        valid_anime_params(%{"anime_audio_mode" => "surround"}),
        valid_anime_params(%{"anime_group_fallback_delay" => "-1"}),
        valid_anime_params(%{
          "anime_embedded_subtitle_mode" => "require",
          "subtitle_languages" => ""
        })
      ] do
    assert {:error, invalid} = Settings.save_form(params)
    assert invalid != []
  end
end
```

In `settings_live_test.exs`, assert `/settings` has `#anime-settings`, the select values and hours input survive validation errors, saving flashes success, secrets remain absent from rendered values, and `/setup` does not render `#anime-settings`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/settings_test.exs test/cinder_web/live/settings_live_test.exs test/cinder_web/live/setup_live_test.exs
```

Expected: `anime_defaults/0`, the five form keys, and the Anime group are absent.

- [ ] **Step 3: Seed the immutable bootstrap defaults**

In `config/config.exs` add one flat map:

```elixir
config :cinder, :anime_preferences,
  audio_mode: :original,
  embedded_subtitle_mode: :prefer,
  preferred_groups: [],
  blocked_groups: [],
  group_fallback_delay: 24 * 60 * 60
```

Do not duplicate `subtitle_languages`; `Settings.anime_defaults/0` reads the effective languages from the existing `OpenSubtitles` config after `apply_config_fields/1` runs.

- [ ] **Step 4: Extend the settings planner and overlay with five explicit keys**

Add registry metadata without pretending these values are service-module fields:

```elixir
@anime_fields [
  %{key: "anime_audio_mode", type: :select, options: ~w(original dub dual any)},
  %{
    key: "anime_embedded_subtitle_mode",
    type: :select,
    options: ~w(allow prefer require)
  },
  %{key: "anime_preferred_groups", type: :csv},
  %{key: "anime_blocked_groups", type: :csv},
  %{key: "anime_group_fallback_delay", type: :hours}
]

def anime_fields, do: @anime_fields
```

Include their keys in `form_state/0`, `form_state/2`, and `plan/1` using the existing non-secret `plan_flat/3` behavior. Add `invalid_anime_values/1` to the existing validation list. Validate the two enums exactly, accept only a non-negative integer hour value, and reject global `require` when the submitted effective `subtitle_languages` list is empty.

Apply the overlay after `apply_config_fields(rows)`:

```elixir
defp apply_anime_config(rows) do
  base = base(:anime_preferences)

  config = [
    audio_mode: anime_enum(rows, "anime_audio_mode", base[:audio_mode]),
    embedded_subtitle_mode:
      anime_enum(
        rows,
        "anime_embedded_subtitle_mode",
        base[:embedded_subtitle_mode]
      ),
    preferred_groups:
      anime_csv(rows, "anime_preferred_groups", base[:preferred_groups] || []),
    blocked_groups: anime_csv(rows, "anime_blocked_groups", base[:blocked_groups] || []),
    group_fallback_delay:
      anime_hours(rows, "anime_group_fallback_delay", base[:group_fallback_delay] || 86_400)
  ]

  Application.put_env(:cinder, :anime_preferences, config)
end

def anime_defaults do
  anime = Application.fetch_env!(:cinder, :anime_preferences)
  subtitle = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

  anime
  |> Map.new()
  |> Map.put(
    :subtitle_languages,
    subtitle |> Keyword.get(:languages, "") |> AnimePreferences.normalize_languages()
  )
end
```

Blank group text becomes `[]`, not nil, because the Anime default is an intentionally empty list. Blank delay clears the DB override and reverts to the 24-hour bootstrap. Preserve the existing one-time `base/1` semantics.

- [ ] **Step 5: Render the group with existing inputs**

In `settings_components.ex`, add an attr such as `attr :show_anime, :boolean, default: true`, render the section only for `/settings`, and pass `show_anime={false}` from setup:

```heex
<details :if={@show_anime} id="anime-settings" class="collapse collapse-arrow bg-base-200">
  <summary class="collapse-title font-semibold">Anime releases</summary>
  <div class="collapse-content grid gap-4 md:grid-cols-2">
    <.input
      field={@form[:anime_audio_mode]}
      type="select"
      label="Audio mode"
      options={[
        {"Use server default (Original)", ""},
        {"Original", "original"},
        {"Dub", "dub"},
        {"Dual audio", "dual"},
        {"Any", "any"}
      ]}
    />
    <.input
      field={@form[:anime_embedded_subtitle_mode]}
      type="select"
      label="Embedded subtitles"
      options={[
        {"Use server default (Prefer embedded)", ""},
        {"Allow", "allow"},
        {"Prefer embedded", "prefer"},
        {"Require embedded", "require"}
      ]}
    />
    <.input field={@form[:anime_preferred_groups]} label="Preferred groups" />
    <.input field={@form[:anime_blocked_groups]} label="Blocked groups" />
    <.input
      field={@form[:anime_group_fallback_delay]}
      type="number"
      min="0"
      label="Preferred-group fallback delay (hours)"
    />
  </div>
</details>
```

Use the existing invalid-key CSS/error plumbing; do not add another form or LiveView event. The blank select options and blank delay clear their DB rows, preserving Settings' clear-to-bootstrap contract instead of promoting bootstrap defaults into persistent overrides.

- [ ] **Step 6: Verify GREEN and bootstrap restoration**

Run:

```bash
mix format && mix test test/cinder/settings_test.exs test/cinder_web/live/settings_live_test.exs test/cinder_web/live/setup_live_test.exs
```

Expected: settings tests pass, clearing rows restores the original config snapshot, and the setup wizard is unchanged.

- [ ] **Step 7: Commit**

```bash
git add config/config.exs lib/cinder/settings.ex lib/cinder_web/components/settings_components.ex lib/cinder_web/live/settings_live.ex test/cinder/settings_test.exs test/cinder_web/live/settings_live_test.exs test/cinder_web/live/setup_live_test.exs
git commit -m "feat: configure anime release defaults"
```

### Task 3: Add compact per-title Anime preference forms

**Files:**
- Modify: `lib/cinder/acquisition/anime_preferences.ex`
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder_web/components/core_components.ex`
- Modify: `lib/cinder_web/live/movie_detail_live.ex`
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Modify: `test/cinder/acquisition/anime_preferences_test.exs`
- Modify: `test/cinder_web/live/movie_detail_live_test.exs`
- Modify: `test/cinder_web/live/series_detail_live_test.exs`

**Interfaces:**
- Produces `Catalog.set_anime_preferences/2` for Movie and Series, with one broadcast after a successful write.
- Produces pure `AnimePreferences.override_attrs/1` and `AnimePreferences.form_state/2` helpers shared by both title LiveViews.
- Renders controls only when the selected/effective profile is Anime and preserves stored values while Standard.

- [ ] **Step 1: Write failing pure, Catalog, and LiveView tests**

Test the nil-versus-empty contract explicitly:

```elixir
test "override attrs distinguish inherit from an explicit blank list" do
  assert {:ok, %{subtitle_languages: nil}} =
           AnimePreferences.override_attrs(%{
             "subtitle_languages_mode" => "inherit",
             "subtitle_languages" => "fr,en"
           })

  assert {:ok, %{subtitle_languages: []}} =
           AnimePreferences.override_attrs(%{
             "subtitle_languages_mode" => "override",
             "subtitle_languages" => ""
           })
end
```

For both detail LiveViews, assert:

```elixir
view
|> form("#anime-preferences-form", anime_preferences: %{
  "audio_mode" => "dual",
  "embedded_subtitle_mode" => "require",
  "subtitle_languages_mode" => "override",
  "subtitle_languages" => "fr",
  "preferred_release_groups_mode" => "override",
  "preferred_release_groups" => "SubsPlease, subsplease",
  "blocked_release_groups_mode" => "override",
  "blocked_release_groups" => "BadGroup",
  "group_fallback_delay_mode" => "override",
  "group_fallback_delay_hours" => "6"
})
|> render_submit()

fresh = Catalog.get_series!(series.id)
assert fresh.audio_mode == :dual
assert fresh.subtitle_languages == ["fr"]
assert fresh.preferred_release_groups == ["subsplease"]
assert fresh.group_fallback_delay == 21_600
```

Also prove invalid dub/dual target, negative delay, and require-with-empty-effective-list render inline errors and persist nothing; Standard pages do not render `#anime-preferences-form`; switching Standard then back to Anime reveals the previous override values.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/acquisition/anime_preferences_test.exs test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/series_detail_live_test.exs
```

Expected: the shared form helpers, Catalog writers, and form markup are missing.

- [ ] **Step 3: Parse title form values without losing inheritance semantics**

Keep form conversion pure and bounded:

```elixir
def override_attrs(params) do
  with {:ok, delay} <- delay_override(params) do
    {:ok,
     %{
       audio_mode: enum_override(params["audio_mode"], @audio_modes),
       embedded_subtitle_mode:
         enum_override(params["embedded_subtitle_mode"], @embedded_modes),
       subtitle_languages:
         list_override(params, "subtitle_languages", &normalize_languages/1),
       preferred_release_groups:
         list_override(params, "preferred_release_groups", &normalize_groups/1),
       blocked_release_groups:
         list_override(params, "blocked_release_groups", &normalize_groups/1),
       group_fallback_delay: delay
     }}
  end
end

defp list_override(params, field, normalize) do
  if params[field <> "_mode"] == "override",
    do: params[field] |> split_csv() |> normalize.(),
    else: nil
end
```

`group_fallback_delay_hours` converts to integer seconds only in override mode; blank or negative override returns `{:error, :invalid_group_fallback_delay}`. Enum value `"inherit"` maps to nil; unknown enum text is an error, never an atom conversion.

- [ ] **Step 4: Add the two narrow Catalog writers**

Use two explicit public clauses over one private implementation:

```elixir
def set_anime_preferences(%Movie{} = movie, params) do
  persist_anime_preferences(
    movie,
    params,
    &Movie.anime_preferences_changeset/2,
    &broadcast({:movie_updated, &1})
  )
end

def set_anime_preferences(%Series{} = series, params) do
  persist_anime_preferences(
    series,
    params,
    &Series.anime_preferences_changeset/2,
    &broadcast_series(&1.id)
  )
end

defp persist_anime_preferences(title, params, changeset_fun, publish) do
  defaults = Settings.anime_defaults()

  with {:ok, attrs} <- AnimePreferences.override_attrs(params),
       changeset = changeset_fun.(title, attrs),
       {:ok, changeset} <- AnimePreferences.validate_effective(changeset, defaults),
       {:ok, updated} <- Repo.update(changeset) do
    publish.(updated)
    {:ok, updated}
  end
end
```

`AnimePreferences.validate_effective/2` calls `Ecto.Changeset.apply_changes/1`, resolves the candidate, and converts resolver errors into field-specific changeset errors, so LiveViews receive one ordinary changeset contract. Broadcast `{:movie_updated, movie}` or `{:series_updated, series.id}` exactly once after commit.

- [ ] **Step 5: Reuse one core component from both detail pages**

Add one function component to the existing `core_components.ex`; do not create a component file:

```heex
<.anime_preferences_form
  :if={@profile_summary.effective == :anime or @profile_summary.selected == :anime}
  form={@anime_preferences_form}
  effective={@anime_policy}
/>
```

The component uses select option `Use Anime default` for enums. Each list and delay has a mode select (`Use Anime default` / `Override`) plus its value input; this is what makes an explicit blank distinguishable from inherit. Render effective inherited values as help text, including:

- `Original audio cannot be verified because the original language is unknown` when applicable;
- `Blank override disables the global list` for the three list fields; and
- the effective fallback delay in hours.

Handle a single `save_anime_preferences` event in each existing LiveView, then reload the title and effective policy. Do not add a route, modal, hook, or client-side state.

- [ ] **Step 6: Verify GREEN and profile dormancy**

Run:

```bash
mix format && mix test test/cinder/acquisition/anime_preferences_test.exs test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/series_detail_live_test.exs
```

Expected: both forms share identical semantics, invalid combinations remain in the form, Standard pages stay behaviorally unchanged, and stored overrides reappear after switching back to Anime.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/acquisition/anime_preferences.ex lib/cinder/catalog.ex lib/cinder_web/components/core_components.ex lib/cinder_web/live/movie_detail_live.ex lib/cinder_web/live/series_detail_live.ex test/cinder/acquisition/anime_preferences_test.exs test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/series_detail_live_test.exs
git commit -m "feat: edit per-title anime preferences"
```

### Task 4: Make only explicitly monitored Anime story specials wanted

**Files:**
- Create: `test/support/fixtures/anime/specials-v1.json`
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/catalog/episode.ex`
- Modify: `lib/cinder/catalog/season.ex`
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Modify: `test/cinder/catalog_tv_pipeline_test.exs`
- Modify: `test/cinder_web/live/series_detail_live_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`

**Interfaces:**
- Extends the existing wanted predicate with an Anime-only classified-special branch.
- Sets newly provider-classified `story_special`, `recap`, and `extra` rows unmonitored at insert time.
- Preserves monitoring on existing rows during refresh and on manual classification edits.

- [ ] **Step 1: Write failing wanted-set and refresh tests**

Create this versioned input matrix in `specials-v1.json`, then load it from `catalog_tv_pipeline_test.exs`:

```json
{
  "version": 1,
  "cases": [
    {"id": "story-special", "profile": "anime", "season": 0, "episode": 1, "classification": "story_special", "monitored": true, "aired": true, "wanted": true},
    {"id": "episode-zero", "profile": "anime", "season": 0, "episode": 0, "classification": "story_special", "monitored": true, "aired": true, "wanted": true},
    {"id": "recap", "profile": "anime", "season": 0, "episode": 2, "classification": "recap", "monitored": true, "aired": true, "wanted": true},
    {"id": "unmonitored-special", "profile": "anime", "season": 0, "episode": 3, "classification": "story_special", "monitored": false, "aired": true, "wanted": false},
    {"id": "extra", "profile": "anime", "season": 0, "episode": 4, "classification": "extra", "monitored": true, "aired": true, "wanted": false},
    {"id": "standard-special", "profile": "standard", "season": 0, "episode": 5, "classification": "story_special", "monitored": true, "aired": true, "wanted": false},
    {"id": "unaired-special", "profile": "anime", "season": 0, "episode": 6, "classification": "story_special", "monitored": true, "aired": false, "wanted": false},
    {"id": "regular", "profile": "anime", "season": 1, "episode": 1, "classification": "regular", "monitored": true, "aired": true, "wanted": true}
  ]
}
```

Drive it without duplicating expected values in Elixir:

```elixir
for case_data <- anime_fixture!("specials-v1.json")["cases"] do
  episode = episode_from_special_case!(case_data)
  assert (episode.id in wanted_ids()) == case_data["wanted"], case_data["id"]
end
```

Add cases for unaired, owned, imported, and search-exhausted episodes. The first three must stay out of `Catalog.wanted_episodes/0`; the existing TV-poller attempt-cap filter must skip the fourth without changing the Standard query split.

Add provider lifecycle assertions:

```elixir
test "new provider-classified specials default unmonitored and refresh preserves an operator toggle" do
  series = add_anime_series_with_tmdb_specials!()
  special = episode_by_tmdb_id(series, 7001)
  refute special.monitored
  assert special.classification == :story_special
  assert special.classification_source == "tmdb"

  assert {:ok, _} = Catalog.set_episode_monitored(special, true)
  assert {:ok, _} = Catalog.refresh_series(series)
  assert Repo.reload!(special).monitored
end
```

In the LiveView test, prove Search appears for an aired, monitored Anime story special (including episode zero), but never for an extra or Standard Season 00 row.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/catalog_tv_pipeline_test.exs test/cinder_web/live/series_detail_live_test.exs test/cinder/download/tv_poller_test.exs
```

Expected: Season 00 remains excluded wholesale, new specials inherit the season monitor flag, and the detail-page action does not mirror the new rule.

- [ ] **Step 3: Classify before inserting new provider episodes**

Extend only `Episode.nested_changeset/2` and `Episode.refresh_changeset/2` to cast the already-existing classification fields. In the initial nested tree, compute provider classification once:

```elixir
defp provider_episode_attrs(ep, season_number, strategy, today) do
  {classification, label} = Identity.classify_tmdb_episode(season_number, ep.title)

  ep
  |> Map.put(:classification, classification)
  |> Map.put(:classification_source, "tmdb")
  |> Map.put(:classification_label, label)
  |> Map.put(
    :monitored,
    classification == :regular and monitored?(strategy, ep.air_date, today)
  )
end
```

Use that helper from `series_attrs/5`. During refresh, pass the full `%Season{}` to `insert_episode/2`, classify the fetched row, and set:

```elixir
monitored: season.monitored and classification == :regular
```

Matched rows continue through `sync_tmdb_classifications/2`, which changes classification evidence only and never casts `monitored`. Manual classification continues to use `provider_classification_changeset/2` and therefore also preserves monitoring.

- [ ] **Step 4: Extend the wanted predicate with one explicit OR branch**

Keep the common monitored/file/grab/air-date predicates shared:

```elixir
defp wanted_episodes_query do
  today = Date.utc_today()

  from e in Episode,
    join: s in assoc(e, :season),
    join: series in assoc(s, :series),
    where:
      e.monitored == true and is_nil(e.file_path) and is_nil(e.grab_id) and
        not is_nil(e.air_date) and e.air_date <= ^today,
    where:
      (s.season_number > 0 and e.episode_number > 0) or
        (series.media_profile == :anime and
           e.classification in [:story_special, :recap])
end
```

This deliberately does not require a positive Season 00 episode number. It also does not treat all Season 00 rows as wanted: `extra`, unmonitored, Standard, and unknown/non-stored classifications stay out. Auto is Standard by A1, so the SQL enum comparison is the effective-profile gate.

Leave the current search-attempt cap/backoff in `TVPoller` rather than duplicating it in SQL; add the focused poller assertion that a capped special is skipped.

- [ ] **Step 5: Make detail actions call the same eligibility rule**

Extract a pure Catalog predicate used by both the query semantics and the view:

```elixir
def episode_searchable?(%Episode{} = episode, profile, today \\ Date.utc_today()) do
  common? =
    episode.monitored and is_nil(episode.file_path) and is_nil(episode.grab_id) and
      not is_nil(episode.air_date) and Date.compare(episode.air_date, today) != :gt

  regular? = episode.season.season_number > 0 and episode.episode_number > 0
  special? = profile.effective == :anime and episode.classification in [:story_special, :recap]

  common? and (regular? or special?)
end
```

Use it for per-episode Search rendering and event authorization. Do not show a button and then reject it server-side; re-read the episode in `search_episode_now/1` as today so a stale click remains safe.

- [ ] **Step 6: Verify GREEN and Standard regression**

Run:

```bash
mix format && mix test test/cinder/catalog_tv_pipeline_test.exs test/cinder_web/live/series_detail_live_test.exs test/cinder/download/tv_poller_test.exs
```

Expected: monitored Anime story specials/recaps enter the same stable-ID grouping as regular episodes; extras and Standard Season 00 stay excluded; refresh never reverses a manual monitor decision.

- [ ] **Step 7: Commit**

```bash
git add test/support/fixtures/anime/specials-v1.json lib/cinder/catalog.ex lib/cinder/catalog/episode.ex lib/cinder/catalog/season.ex lib/cinder_web/live/series_detail_live.ex test/cinder/catalog_tv_pipeline_test.exs test/cinder_web/live/series_detail_live_test.exs test/cinder/download/tv_poller_test.exs
git commit -m "feat: acquire monitored anime specials"
```

### Task 5: Apply Anime group, audio, subtitle, and waiting policy during selection

**Files:**
- Create: `test/support/fixtures/anime/preferences-v1.json`
- Modify: `lib/cinder/acquisition/parser.ex`
- Modify: `lib/cinder/acquisition/release.ex`
- Modify: `lib/cinder/acquisition/anime_preferences.ex`
- Modify: `lib/cinder/acquisition/anime.ex`
- Modify: `lib/cinder/acquisition.ex`
- Modify: `lib/cinder/acquisition/scorer.ex`
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/download.ex`
- Modify: `lib/cinder/download/tv_poller.ex`
- Modify: `lib/cinder_web/components/manual_search_component.ex`
- Modify: `test/cinder/acquisition/parser_test.exs`
- Modify: `test/cinder/acquisition/anime_selection_test.exs`
- Modify: `test/cinder/catalog_series_test.exs`
- Modify: `test/cinder/download/poller_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`
- Modify: `test/cinder_web/components/manual_search_component_test.exs`

**Interfaces:**
- Adds conservative parsed claims to Release: `audio_languages`, `audio_claim_complete?`, `embedded_subtitle_languages`, and `embedded_subtitle_claim` (`:present | :absent | :unknown`).
- Produces `AnimePreferences.release_allowed?/2`, `rank_key/2`, and `selection_opts/1`.
- Feeds one resolved policy per Anime title to movie auto-search, TV auto-search, and manual verdict annotation.

- [ ] **Step 1: Add a versioned fixture and failing parser/selection tests**

The new fixture must include movie and episode candidates for these exact boundaries:

```json
{
  "version": 1,
  "cases": [
    {
      "id": "episode-preferred",
      "kind": "episode",
      "title": "[SubsPlease] Frieren - 29 [1080p] [JA Audio] [FR Subs]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "SubsPlease", "audio": ["ja"], "audio_complete": true, "subtitles": ["fr"], "subtitle_claim": "present"}
    },
    {
      "id": "episode-fallback",
      "kind": "episode",
      "title": "[Erai-raws] Frieren - 29 [1080p] [JA Audio] [FR Subs]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "Erai-raws", "audio": ["ja"], "audio_complete": true, "subtitles": ["fr"], "subtitle_claim": "present"}
    },
    {
      "id": "movie-preferred",
      "kind": "movie",
      "title": "[SubsPlease] Suzume 2022 [1080p] [JA Audio] [FR Subs]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "SubsPlease", "audio": ["ja"], "audio_complete": true, "subtitles": ["fr"], "subtitle_claim": "present"}
    },
    {
      "id": "blocked",
      "kind": "episode",
      "title": "[BadGroup] Frieren - 29 [1080p]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "BadGroup", "audio": [], "audio_complete": false, "subtitles": [], "subtitle_claim": "unknown"}
    },
    {
      "id": "dub-only",
      "kind": "episode",
      "title": "[Group] Frieren - 29 [1080p] [FR Audio]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "Group", "audio": ["fr"], "audio_complete": true, "subtitles": [], "subtitle_claim": "unknown"}
    },
    {
      "id": "dual",
      "kind": "episode",
      "title": "[Group] Frieren - 29 [1080p] [JA+FR Audio]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "Group", "audio": ["ja", "fr"], "audio_complete": true, "subtitles": [], "subtitle_claim": "unknown"}
    },
    {
      "id": "embedded-fr",
      "kind": "episode",
      "title": "[Group] Frieren - 29 [1080p] [FR Subs]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "Group", "audio": [], "audio_complete": false, "subtitles": ["fr"], "subtitle_claim": "present"}
    },
    {
      "id": "raw",
      "kind": "episode",
      "title": "[Group] Frieren - 29 [1080p] [RAW]",
      "published_at": "2026-07-13T12:00:00Z",
      "expected": {"group": "Group", "audio": [], "audio_complete": false, "subtitles": [], "subtitle_claim": "absent"}
    },
    {
      "id": "unknown-undated",
      "kind": "episode",
      "title": "[Mystery] Frieren - 29 [1080p]",
      "published_at": null,
      "expected": {"group": "Mystery", "audio": [], "audio_complete": false, "subtitles": [], "subtitle_claim": "unknown"}
    }
  ]
}
```

Keep expected parsed traits and publication timestamps in the fixture rather than inferring them in test helpers. Add tests for:

- blocked groups removed before stable-ID cover;
- one release may cover a regular episode and a monitored story-special stable ID together, with both exact IDs frozen in the mapping snapshot;
- a complete FR-only audio claim rejected for required JA, while an unknown claim survives;
- RAW rejected only when embedded subtitles are required;
- preferred group wins soft ranking when quality constraints tie;
- non-preferred candidates wait until the exact `published_at + delay` boundary;
- missing/invalid publication time is omitted from automatic selection but still appears in manual results;
- an Anime manual TV result carries a version-2 mapping snapshot over exact stable IDs, including an episode-zero special, while an unmarked Anime manual release is rejected before client I/O;
- waiting reports only uncovered episode IDs and never increments movie/episode attempts; and
- Standard selection order remains the existing resolution → source → size order.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/acquisition/parser_test.exs test/cinder/acquisition/anime_selection_test.exs test/cinder/catalog_series_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/components/manual_search_component_test.exs
```

Expected: Release has no claim fields, selectors do not receive persisted policy, and blocked/soft trait cases fail.

- [ ] **Step 3: Parse only positive, high-confidence claims**

Append these fields to the existing `Release.defstruct/1` list:

```elixir
:audio_languages,
:audio_claim_complete?,
:embedded_subtitle_languages,
:embedded_subtitle_claim,
:release_policy_snapshot
```

Add these entries to the map returned by `Parser.parse/1`:

```elixir
audio_languages: declared_audio_languages(title),
audio_claim_complete?: complete_audio_claim?(title),
embedded_subtitle_languages: declared_subtitle_languages(title),
embedded_subtitle_claim: embedded_subtitle_claim(title)
```

Rules:

- preserve the existing trailing `-Group` parser and fall back to the leading anime `[Group]` token, bounded to one line and non-empty, so manual Anime results carry the same group evidence as automatic `AnimeParser` results;
- `[JA Audio]`, `[FR Audio]`, and `[JA+FR Audio]` are complete declarations after language normalization.
- A bare `Dual Audio` or `MULTI` without named languages is unknown, not contradictory.
- `VOSTFR`, `[FR Subs]`, and `[French Subtitles]` are positive embedded claims.
- a bounded standalone `RAW` token is an explicit absent-subtitle claim.
- no token, an unrecognized token, or a title word collision is `:unknown`.

Keep the existing singular `release.language` output for Standard compatibility. The new claim fields supplement it; they do not replace `Language.filter/3`.

- [ ] **Step 4: Implement Anime-only hard filtering and soft ordering**

In `AnimePreferences`:

```elixir
def release_allowed?(release, policy) do
  not group_blocked?(release.group, policy.blocked_groups) and
    not contradictory_audio?(release, policy.required_audio_languages) and
    not contradictory_subtitles?(release, policy)
end

defp contradictory_audio?(%{audio_claim_complete?: true} = release, required)
     when required != [] do
  not Enum.all?(required, &Language.audio_satisfies?(&1, release.audio_languages || []))
end

defp contradictory_audio?(_release, _required), do: false

defp contradictory_subtitles?(release, %{embedded_subtitle_mode: :require} = policy) do
  release.embedded_subtitle_claim == :absent or
    (release.embedded_subtitle_claim == :present and
       release.embedded_subtitle_languages != [] and
       not Enum.any?(policy.subtitle_languages, fn wanted ->
         Language.audio_satisfies?(wanted, release.embedded_subtitle_languages)
       end))
end

defp contradictory_subtitles?(_release, _policy), do: false
```

Use case-insensitive exact group comparison. `rank_key/2` returns this lower-is-better tuple:

```elixir
{
  if(policy.preferred_groups == [] or preferred_group?(release, policy), do: 0, else: 1),
  if(policy.required_audio_languages == [] or explicit_audio_match?(release, policy),
    do: 0,
    else: 1
  ),
  if(policy.embedded_subtitle_mode == :allow or policy.subtitle_languages == [] or
       explicit_subtitle_match?(release, policy),
    do: 0,
    else: 1
  )
}
```

Contradictory complete claims have already been filtered. Unknown claims receive penalty 1, so a positive match wins a tie; the existing resolution/source/size key decides ties between equally unknown candidates.

In `Scorer`, prepend that key only when `opts[:anime_policy]` exists:

```elixir
def rank_key(%Release{} = release, opts \\ []) do
  {_min, _max, preferred, sources, _blocklist} = rules(opts)
  {anime_rank_key(release, opts), sort_key(release, preferred, sources)}
end

defp anime_rank_key(release, opts) do
  case Keyword.get(opts, :anime_policy) do
    nil -> {0, 0, 0}
    policy -> AnimePreferences.rank_key(release, policy)
  end
end
```

Use `rank_key/2` from both single-release selection and the stable-ID greedy tie break. Express greedy selection as `Enum.min_by(scored, fn {release, coverage} -> {-MapSet.size(coverage), rank_key(release, opts)} end)` so greater coverage still dominates and Standard ordering remains identical.

- [ ] **Step 5: Feed policy into the existing Anime selector and waiting seam**

At the top of `Anime.select_movie/2` and `Anime.select_episodes/4`, remove candidates failing `release_allowed?/2` before preferred-group timing or stable-ID cover. Read groups and delay from `opts[:anime_policy]`; delete no legacy options until all A2 tests pass:

```elixir
def selection_opts(policy) do
  [
    anime_policy: policy,
    preferred_groups: policy.preferred_groups,
    fallback_delay: policy.group_fallback_delay
  ]
end
```

Retain the existing `fallback_entry/4` nil/invalid-time clause that returns `[]`; this is the manual-only behavior. Keep `{:waiting_for_preferred_group, %{retry_at: ...}}` unchanged so the movie and TV pollers can preserve their current no-attempt branches.

- [ ] **Step 6: Resolve one policy per Anime title at all search entry points**

In movie `Download.start/1`:

```elixir
with {:ok, policy} <- AnimePreferences.resolve(movie, Settings.anime_defaults()) do
  opts = opts ++ AnimePreferences.selection_opts(policy)
  Acquisition.best_anime_movie(imdb_id, context, opts)
end
```

Add an explicit result clause after movie selection:

```elixir
{:waiting_for_preferred_group, %{retry_at: retry_at}} ->
  Logger.info("movie #{movie.id} waiting for preferred anime group until #{retry_at}")
  {:ok, movie}
```

The earlier guarded `:searching` transition updates the backoff timestamp; returning success prevents the movie poller from incrementing `search_attempts` while it periodically rechecks the boundary.

In `TVPoller`, resolve once per series group and append the same selection opts. Keep its existing waiting-ID exclusion. Add explicit `{:error, :invalid_anime_preferences}` clauses in both movie and TV pollers that log/hold without incrementing attempts, because an operator edit—not repeated searching—must repair the policy.

Add two manual-list entry points in `Acquisition`:

```elixir
def list_anime_movie_releases(imdb_id, context, opts) do
  with {:ok, releases, _failed?} <- Anime.search_movie(indexer(), imdb_id, context, opts) do
    {:ok, Anime.manual_movie_candidates(releases, opts) |> annotate(opts)}
  end
end

def list_anime_episode_releases(context, wanted_ids, opts) do
  with {:ok, releases, _failed?} <- Anime.search_episodes(indexer(), context, wanted_ids, opts) do
    {:ok, Anime.manual_episode_candidates(releases, context, wanted_ids, opts) |> annotate(opts)}
  end
end
```

`manual_episode_candidates/4` runs the same context parser and stable-ID resolver but does not apply preferred-group time eligibility or language/group hard filters; those become visible verdicts that the operator may override. For each resolved candidate, freeze its complete resolved-ID set into `build_mapping_snapshot/3` and set `release.mapping_snapshot`. An unresolved candidate is not grabbable because Cinder cannot assign it safely. `manual_movie_candidates/2` parses the leading group/traits but needs no mapping snapshot.

In `ManualSearchComponent`, branch on effective profile: Anime movies call `list_anime_movie_releases/3`; Anime TV computes the currently wanted IDs for the selected season and calls `list_anime_episode_releases/3`; Standard keeps the two existing list functions byte-for-byte. Append Anime policy only in the Anime branch. Show new verdict reasons (`blocked anime group`, `contradictory audio`, `contradictory subtitles`, `awaiting preferred group`, `publication time required`) while preserving manual override: only wrong protocol or unresolved stable IDs are ungrabbable.

In `Catalog.manual_grab_tv/3`, add an Anime clause before the Standard episode-number cover. Re-read the selected season's wanted IDs, require `release.mapping_snapshot` and non-empty `release.resolved_episode_ids`, require those IDs to be a subset of the current wanted IDs, and call `Download.grab_episodes/2` with those exact IDs. Return `{:error, :unsafe_anime_mapping}` before client I/O for an unmarked/stale candidate. Keep the current Standard clause unchanged. Task 6 additionally freezes the hard policy at the Download boundary.

- [ ] **Step 7: Verify GREEN, fixture integrity, and no-attempt waiting**

Run:

```bash
mix format
mix test test/cinder/acquisition/parser_test.exs test/cinder/acquisition/anime_selection_test.exs test/cinder/catalog_series_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/components/manual_search_component_test.exs
```

Expected: every fixture case passes for movies and stable episode IDs; waiting leaves counters unchanged; Standard parser/scorer regressions stay green.

- [ ] **Step 8: Commit**

```bash
git add test/support/fixtures/anime/preferences-v1.json lib/cinder/acquisition/parser.ex lib/cinder/acquisition/release.ex lib/cinder/acquisition/anime_preferences.ex lib/cinder/acquisition/anime.ex lib/cinder/acquisition.ex lib/cinder/acquisition/scorer.ex lib/cinder/catalog.ex lib/cinder/download.ex lib/cinder/download/tv_poller.ex lib/cinder_web/components/manual_search_component.ex test/cinder/acquisition/parser_test.exs test/cinder/acquisition/anime_selection_test.exs test/cinder/catalog_series_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/components/manual_search_component_test.exs
git commit -m "feat: apply anime acquisition preferences"
```

### Task 6: Freeze the hard release policy through durable reservation and restart

**Files:**
- Modify: `lib/cinder/acquisition/anime_preferences.ex`
- Modify: `lib/cinder/acquisition/anime.ex`
- Modify: `lib/cinder/acquisition/release.ex`
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/catalog/movie.ex`
- Modify: `lib/cinder/catalog/grab.ex`
- Modify: `lib/cinder/download.ex`
- Modify: `lib/cinder/download/intent.ex`
- Modify: `test/cinder/acquisition/anime_selection_test.exs`
- Modify: `test/cinder/download/intent_test.exs`
- Modify: `test/cinder/download/poller_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`

**Interfaces:**
- Marks an Anime Release with a validated version-1 policy snapshot at selection/manual-grab time.
- Reserves the snapshot in the same Intent transaction as target ownership.
- Copies it atomically to Movie or Grab during intent reconciliation.
- Clears it only when the reservation is rejected, cancelled, or requeued; a new reservation gets a new snapshot.

- [ ] **Step 1: Write failing producer, validator, atomicity, and restart tests**

Assert the exact bounded snapshot:

```elixir
assert release.release_policy_snapshot == %{
         "version" => 1,
         "required_audio_languages" => ["ja", "fr"],
         "required_embedded_subtitle_languages" => ["fr"],
         "release_group" => "subsplease",
         "release_title" => release.title
       }
```

Intent tests must independently reject unknown version, non-list languages, blank/non-string language entries, mismatched release title, a snapshot not equal to the selected Release marker, and mutation after insert. Add these transaction tests:

```elixir
test "episode reservation copies policy atomically through intent to grab" do
  {:ok, intent} = Download.reserve_intent(anime_intent_attrs(release, episode_ids))
  assert intent.release_policy_snapshot == release.release_policy_snapshot

  change_preferences_after_reservation!(series)
  restart_download_supervision!()

  assert {:ok, grab} = Download.reconcile_intent(Repo.reload!(intent))
  assert grab.release_policy_snapshot == release.release_policy_snapshot
  assert grab.release_policy_snapshot != current_policy_snapshot(series, release)
end

test "movie attach stores snapshot with remote ownership and rolls back both on stale status" do
  intent = submitted_movie_intent!(movie, release)
  assert {:ok, downloading} = Download.reconcile_intent(intent)
  assert downloading.release_policy_snapshot == release.release_policy_snapshot

  stale = submitted_movie_intent!(cancelled_movie, release)
  assert {:error, :intent_completed} = Download.reconcile_intent(stale)
  refute Repo.get!(Movie, cancelled_movie.id).release_policy_snapshot
end
```

Also prove Standard movie/TV rows and intents stay nil and a manual Anime grab receives a snapshot even though the manual search Release was not pre-marked by auto-selection.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs
```

Expected: snapshot storage exists from Task 1 but no producer, validator, reservation copy, or reconciliation copy is active.

- [ ] **Step 3: Mark automatic Anime selections with the exact policy they used**

When `Anime.select_movie/2` returns a release, and when `assignments/2` builds each episodic assignment, attach:

```elixir
snapshot = AnimePreferences.snapshot(opts[:anime_policy], release)
release = %{release | release_policy_snapshot: snapshot}
```

Build from the same `opts[:anime_policy]` that performed filtering/ranking; never re-read Settings inside `Anime`. Mapping and release policy snapshots remain separate documents.

- [ ] **Step 4: Close the manual-grab bypass at the Download boundary**

Before reservation, call one helper for both automatic and manual paths:

```elixir
defp ensure_policy_marker(%Release{} = release, title) do
  case Catalog.media_profile_summary(title).effective do
    :standard -> {:ok, %{release | release_policy_snapshot: nil}}
    :anime ->
      with {:ok, policy} <- AnimePreferences.resolve(title, Settings.anime_defaults()) do
        marked =
          case release.release_policy_snapshot do
            %{} -> release
            nil ->
              %{release | release_policy_snapshot: AnimePreferences.snapshot(policy, release)}
          end

        {:ok, marked}
      end
  end
end
```

`grab_movie/2` already has its Movie. For `grab_episodes/2`, add `Catalog.get_single_series_for_episode_ids/1`, which verifies all IDs belong to exactly one Series and returns it; reject missing or mixed-series IDs before any client side effect. This query is also a defense for the existing reservation contract.

- [ ] **Step 5: Validate and reserve both immutable markers**

In `Download.reserve_intent/1`, require both markers to equal the explicit attrs:

```elixir
mapping = Map.get(attrs, :mapping_snapshot)
policy = Map.get(attrs, :release_policy_snapshot)

if mapping == release.mapping_snapshot and policy == release.release_policy_snapshot do
  reserve_marked_intent(attrs, release, url, mapping, policy)
else
  {:error, :invalid_release_evidence}
end
```

Cast `release_policy_snapshot` only in `Intent.reservation_changeset/2`, validate it with `AnimePreferences.valid_snapshot?/2`, and keep both mapping and policy immutable after insert. The validator requires exact `release_title`, version 1, normalized nonblank language lists, and optional normalized group; extra keys are rejected so mutable settings provenance cannot leak into the snapshot.

Pass the policy marker in `reserve_and_reconcile/4` for movie, episode, and pack kinds.

- [ ] **Step 6: Copy policy atomically to its durable owner**

Add `release_policy_snapshot` to `Grab.reservation_changeset/2` and to Movie's narrow pipeline transition cast. In `Catalog.create_grab_from_intent/1`, copy it in the same transaction that copies `mapping_snapshot`, links every authoritative episode, and deletes the Intent:

```elixir
attrs = %{
  download_id: fresh.remote_id,
  download_protocol: fresh.protocol,
  release_title: fresh.release["title"],
  mapping_snapshot: fresh.mapping_snapshot,
  release_policy_snapshot: fresh.release_policy_snapshot,
  mapping_status: :resolved
}
```

In movie intent reconciliation, include `release_policy_snapshot` in the same guarded transition that attaches `download_id`, protocol, release title, and `:downloading`/`:upgrading` state. Never write the Movie snapshot before remote ownership is durable.

Clear the Movie snapshot in retry/cancel/rejection attrs. Grab deletion naturally clears its snapshot; requeued episodes have no policy field. Existing cleanup carrier Intents may retain their historical snapshot until deletion, but no selection path reads a cleanup-pending Intent as current policy.

- [ ] **Step 7: Verify GREEN and crash recovery**

Run:

```bash
mix format && mix test test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs
```

Expected: policy survives settings changes and process restart, ownership/snapshot writes roll back together, manual Anime grabs cannot bypass freezing, and every Standard assertion remains nil.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/acquisition/anime_preferences.ex lib/cinder/acquisition/anime.ex lib/cinder/acquisition/release.ex lib/cinder/catalog.ex lib/cinder/catalog/movie.ex lib/cinder/catalog/grab.ex lib/cinder/download.ex lib/cinder/download/intent.ex test/cinder/acquisition/anime_selection_test.exs test/cinder/download/intent_test.exs test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs
git commit -m "feat: freeze anime release policy"
```

### Task 7: Verify frozen hard policy once per story source before staging

**Files:**
- Create: `lib/cinder/library/policy_verifier.ex`
- Modify: `lib/cinder/acquisition/language.ex`
- Modify: `lib/cinder/library/media_info.ex`
- Modify: `lib/cinder/library/media_info/ffprobe.ex`
- Modify: `lib/cinder/library.ex`
- Create: `test/cinder/library/policy_verifier_test.exs`
- Modify: `test/cinder/library_media_info_test.exs`
- Modify: `test/cinder/library/media_info/ffprobe_test.exs`
- Modify: `test/cinder/library/anime_preflight_test.exs`
- Modify: `test/cinder/library_test.exs`

**Interfaces:**
- Produces `PolicyVerifier.verify_sources(paths, snapshot, media_info_impl)` returning `{:ok, reports}`, `{:mismatch, evidence}`, or `{:unavailable, reason}`.
- Adds a detailed `probe_policy/1` MediaInfo callback with `audio_unknown?` and `subtitle_unknown?`; the existing `probe/1` contract and Standard callers remain unchanged.
- Makes Anime movie and assignment-based TV staging return tagged policy errors before any `ImportStage` or destination write.

- [ ] **Step 1: Write failing pure verifier and no-staging tests**

Cover each three-valued result:

```elixir
test "every required audio language and one desired embedded subtitle pass" do
  expect(MediaInfoMock, :probe_policy, fn "/downloads/a.mkv" ->
    {:ok,
     %{
       audio: ["ja", "fr"],
       subtitles: ["fr"],
       audio_unknown?: false,
       subtitle_unknown?: false
     }}
  end)

  assert {:ok, reports} =
           PolicyVerifier.verify_sources(["/downloads/a.mkv"], dual_required_snapshot(), MediaInfoMock)

  assert reports["/downloads/a.mkv"].audio == ["ja", "fr"]
end

test "known missing audio or embedded subtitles are confirmed mismatches" do
  assert {:mismatch, %{source: "a.mkv", missing_audio: ["fr"]}} =
           verify(%{audio: ["ja"], subtitles: ["fr"], audio_unknown?: false, subtitle_unknown?: false})

  assert {:mismatch, %{source: "a.mkv", missing_embedded_subtitles: ["fr"]}} =
           verify(%{audio: ["ja", "fr"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false})
end

test "probe failure or an unknown stream that could satisfy a missing language is unavailable" do
  assert {:unavailable, :media_info_not_configured} =
           PolicyVerifier.verify_sources(["a.mkv"], required_snapshot(), nil)

  assert {:unavailable, {:probe_failed, "a.mkv", :timeout}} =
           verify_result({:error, :timeout})

  assert {:unavailable, {:unprobeable_audio, "a.mkv"}} =
           verify(%{audio: ["ja"], subtitles: ["fr"], audio_unknown?: true, subtitle_unknown?: false})
end
```

Add a two-episode/one-file test expecting exactly one `probe/1` call. Add a multi-file test where the second story source fails and the whole grab fails. Add a preflight extra case proving a positively ignored NCOP source is never probed.

At the Library boundary, use the filesystem/import-stage mocks to assert both `{:release_policy_mismatch, evidence}` and `{:release_policy_unavailable, reason}` create zero `ImportStage` rows and perform no `mkdir_p`, link, copy, rename, or media-server refresh.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/library/policy_verifier_test.exs test/cinder/library_media_info_test.exs test/cinder/library/media_info/ffprobe_test.exs test/cinder/library/anime_preflight_test.exs test/cinder/library_test.exs
```

Expected: `PolicyVerifier` is absent, MediaInfo cannot distinguish unknown stream tags, and Library still performs the legacy mutable-language check.

- [ ] **Step 3: Preserve unknown-stream evidence in the MediaInfo contract**

Add a separate detailed behavior callback so the long-standing Standard callback does not change:

```elixir
@type probe_report :: %{
        required(:audio) => [String.t()],
        required(:subtitles) => [String.t()],
        required(:audio_unknown?) => boolean(),
        required(:subtitle_unknown?) => boolean()
      }

@callback probe_policy(path :: String.t()) :: {:ok, probe_report()} | {:error, term()}
```

Keep `probe/1` and `parse/1` returning exactly `%{audio: [...], subtitles: [...]}`. Add `Ffprobe.probe_policy/1` and `parse_policy/1`; the latter keeps every ffprobe row long enough to detect an untagged/`und` stream:

```elixir
%{
  audio: Enum.uniq(for {"audio", lang} <- rows, is_binary(lang), do: lang),
  subtitles: Enum.uniq(for {"subtitle", lang} <- rows, is_binary(lang), do: lang),
  audio_unknown?: Enum.any?(rows, &match?({"audio", nil}, &1)),
  subtitle_unknown?: Enum.any?(rows, &match?({"subtitle", nil}, &1))
}
```

`probe_policy/1` invokes ffprobe once and returns `parse_policy/1`; `probe/1` continues invoking it once and returns `parse/1`. The verifier's cached detailed report still supplies the same `audio`/`subtitles` keys to import metadata capture. Do not change existing Standard mocks or subtitle extraction callbacks.

- [ ] **Step 4: Add a conservative language status helper**

In `Language` expose a three-way helper while preserving `audio_satisfies?/2`:

```elixir
def stream_status(required, present, unknown?) do
  accepted = Map.get(@audio_codes, normalize(required), [])
  present = Enum.map(present, &String.downcase/1)

  cond do
    Enum.any?(present, &(&1 in accepted)) -> :satisfied
    unknown? or Enum.any?(present, &(&1 not in @known_audio_codes)) -> :unknown
    true -> :mismatch
  end
end
```

Policy verification uses this helper for every required audio language. The existing Standard boolean callers remain unchanged.

- [ ] **Step 5: Implement the small pure verifier loop**

The verifier must not know Movie, Grab, Repo, or filesystem APIs:

```elixir
def verify_sources(paths, snapshot, media_info) do
  paths = Enum.uniq(paths)

  if hard_requirements?(snapshot) do
    verify_all(paths, snapshot, media_info)
  else
    {:ok, %{}}
  end
end

defp verify_all(_paths, _snapshot, nil), do: {:unavailable, :media_info_not_configured}

defp verify_all(paths, snapshot, impl) do
  Enum.reduce_while(paths, {:ok, %{}}, fn source, {:ok, reports} ->
    case impl.probe_policy(source) do
      {:ok, report} ->
        case classify(source, report, snapshot) do
          :ok -> {:cont, {:ok, Map.put(reports, source, report)}}
          {:mismatch, evidence} -> {:halt, {:mismatch, evidence}}
          {:unavailable, reason} -> {:halt, {:unavailable, reason}}
        end

      {:error, reason} ->
        {:halt, {:unavailable, {:probe_failed, source, reason}}}
    end
  end)
end
```

For embedded subtitles, pass if any desired language is present; return unavailable if none is present but `subtitle_unknown?` is true; otherwise return confirmed mismatch. For audio, all required languages must be satisfied. Evidence contains relative/basename source identifiers for logging and tests, never policy provenance or secrets.

- [ ] **Step 6: Gate Movie staging and reuse the probe report**

In `Library.stage_movie/2`, route only snapshot-bearing Anime movies through the verifier after `resolve_source/1` and before `fs().lstat/1`, destination creation, or ImportStage. The with-chain becomes `root/1 → resolve_source/1 → verify_movie_policy/2 → lstat/1 → Parser.parse/1 → cached_or_capture_media/2 → build_dest/3 → safe_destination/2 → mkdir_p/1 → stage_place/8`. This fixes the exact position of the gate without adding another staging function.

Map verifier results to:

```elixir
{:mismatch, evidence} -> {:error, {:release_policy_mismatch, evidence}}
{:unavailable, reason} -> {:error, {:release_policy_unavailable, reason}}
```

When the Movie snapshot is nil, run the existing `verify_audio/2` and capture behavior byte-for-byte. When a hard-policy probe already ran, `capture_media` must consume the cached report instead of calling `probe/1` a second time.

- [ ] **Step 7: Gate only the authoritative Anime story sources**

In `stage_anime_episodes/2`, keep inventory revalidation first, then compute `to_import`, extract its unique source paths, verify them, and only then call `stage_anime_all`:

```elixir
with {:ok, current} <- inventory_anime_videos(grab.content_path),
     :ok <- same_inventory(current.files, preflight.decisions),
     :ok <- same_container_kind(current.folder?, preflight.folder?),
     {:ok, root} <- root(:tv),
     {:ok, to_import} <- anime_import_pairs(grab, preflight.assignments, current.folder?),
     {:ok, reports} <- verify_grab_policy(grab, to_import),
     do: stage_anime_all(to_import, root, episode_target(grab.episodes), current.folder?, reports)
```

`to_import` contains only assignments, so positive extras never reach the verifier. Thread cached reports into quality capture. Do not route the A3 Anime path through legacy `reject_wrong_audio/2`; its mutable series language and skip-as-unmatched semantics are replaced only when the frozen snapshot is present. Standard `stage_episodes/2` remains unchanged.

- [ ] **Step 8: Verify GREEN and the pre-stage boundary**

Run:

```bash
mix format && mix test test/cinder/library/policy_verifier_test.exs test/cinder/library_media_info_test.exs test/cinder/library/media_info/ffprobe_test.exs test/cinder/library/anime_preflight_test.exs test/cinder/library_test.exs
```

Expected: each story source is probed once, extras are ignored, mismatch/unavailable create no staging journal or filesystem write, and Standard MediaInfo behavior remains fail-open.

- [ ] **Step 9: Commit**

```bash
git add lib/cinder/library/policy_verifier.ex lib/cinder/acquisition/language.ex lib/cinder/library/media_info.ex lib/cinder/library/media_info/ffprobe.ex lib/cinder/library.ex test/cinder/library/policy_verifier_test.exs test/cinder/library_media_info_test.exs test/cinder/library/media_info/ffprobe_test.exs test/cinder/library/anime_preflight_test.exs test/cinder/library_test.exs
git commit -m "feat: verify frozen anime release policy"
```

### Task 8: Reject confirmed mismatches with exact blocklists and durable cleanup

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/download/poller.ex`
- Modify: `lib/cinder/download/tv_poller.ex`
- Modify: `test/cinder/download/poller_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`
- Create: `test/cinder/download/release_policy_cleanup_test.exs`

**Interfaces:**
- Produces `Catalog.reject_movie_release/2` and `Catalog.reject_grab_release/2` as guarded, atomic Catalog writers.
- Reuses `BlockedRelease`, `Download.fence_movie_cleanup/2`, `Download.fence_episode_cleanup/2`, and post-commit `Download.cleanup_intents/1`.
- Routes only tagged confirmed mismatch errors to rejection; every other import error retains its prior path.

- [ ] **Step 1: Write failing movie and TV rejection transaction tests**

For a normal downloaded Movie, assert:

```elixir
assert {:ok, requested} = Catalog.reject_movie_release(movie, evidence)
assert requested.status == :requested
assert requested.download_id == nil
assert requested.release_title == nil
assert requested.file_path == nil
assert requested.release_policy_snapshot == nil
assert requested.search_attempts == movie.search_attempts
assert requested.import_attempts == movie.import_attempts
assert Catalog.blocked_release_titles(requested) == [movie.release_title]
assert cleanup_pending_for?(movie.download_id)
refute Repo.exists?(ImportStage)
```

Add an upgrading Movie case: status returns to `:available`, the live library `file_path` and imported quality remain unchanged, only the rejected remote download is fenced, and the exact replacement title is blocked.

For TV, create one grab linked to two target episodes plus an unrelated episode:

```elixir
assert {:ok, _deleted} = Catalog.reject_grab_release(grab, evidence)
refute Repo.get(Grab, grab.id)
assert Repo.reload!(episode_a).grab_id == nil
assert Repo.reload!(episode_b).grab_id == nil
assert Repo.reload!(unrelated).grab_id == other_grab.id
assert Repo.reload!(episode_a).search_attempts == episode_a.search_attempts
assert Catalog.blocked_release_titles_for_series(series.id) == [grab.release_title]
assert cleanup_pending_for?(grab.download_id)
```

Prove a stale status, changed release title/snapshot, already-deleted grab, or ownership change rolls back the blocklist and cleanup fence. Simulate client removal failure and prove the committed cleanup Intent remains retryable.

At poller level, a mismatch must invoke these writers, create zero stage rows, never bump attempts, and select a sibling release from the same group on the next sweep.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder/download/release_policy_cleanup_test.exs
```

Expected: tagged mismatches flow into generic park/retry behavior and no atomic exact-rejection writer exists.

- [ ] **Step 3: Implement a strict blocklist insert for rejection transactions**

The existing public `block_release/2` is intentionally best-effort and therefore cannot prove atomic rejection. Add a private bang helper used only inside the new transactions:

```elixir
defp insert_blocked_release!(attrs) do
  %BlockedRelease{}
  |> BlockedRelease.changeset(attrs)
  |> Repo.insert!()
end
```

Do not change existing park callers to bang behavior.

- [ ] **Step 4: Implement guarded Movie rejection in one transaction**

Re-read and compare the expected row, then write block, cleanup fence, and state together:

```elixir
def reject_movie_release(%Movie{} = expected, evidence) do
  result =
    Repo.transaction(fn ->
      {claimed, _} =
        Repo.update_all(
          from(m in Movie,
            where:
              m.id == ^expected.id and m.status == ^expected.status and
                m.status in [:downloaded, :upgrading] and
                m.release_title == ^expected.release_title and
                m.release_policy_snapshot == ^expected.release_policy_snapshot and
                m.updated_at == ^expected.updated_at
          ),
          set: [updated_at: now()]
        )

      if claimed != 1, do: Repo.rollback(:stale_release)
      fresh = Repo.get!(Movie, expected.id)

      insert_blocked_release!(%{
        movie_id: fresh.id,
        release_title: fresh.release_title,
        reason: policy_reason(evidence)
      })

      intent_ids = Download.fence_movie_cleanup(fresh)
      target_status = if fresh.status == :upgrading, do: :available, else: :requested

      attrs = %{
        status: target_status,
        download_id: nil,
        download_protocol: nil,
        release_title: nil,
        release_policy_snapshot: nil
      }

      attrs = if fresh.status == :upgrading, do: attrs, else: Map.put(attrs, :file_path, nil)
      updated = fresh |> Movie.transition_changeset(attrs) |> Repo.update!()
      {updated, intent_ids}
    end)

  with {:ok, {updated, intent_ids}} <- result do
    Download.cleanup_intents(intent_ids)
    broadcast({:movie_updated, updated})
    {:ok, updated}
  end
end
```

Counters and imported quality are absent from attrs, so Ecto preserves them. Cleanup runs only after commit and remains durable on client failure. The method itself is the Catalog transition choke point; do not call public `transition/3` inside the outer transaction because it would broadcast before commit.

- [ ] **Step 5: Implement guarded Grab rejection in one transaction**

Capture authoritative ownership before delete:

```elixir
def reject_grab_release(%Grab{} = expected, evidence) do
  result =
    Repo.transaction(fn ->
      {claimed, _} =
        Repo.update_all(
          from(g in Grab,
            where:
              g.id == ^expected.id and g.mapping_status == :resolved and
                g.release_title == ^expected.release_title and
                g.release_policy_snapshot == ^expected.release_policy_snapshot and
                g.updated_at == ^expected.updated_at
          ),
          set: [updated_at: now()]
        )

      if claimed != 1, do: Repo.rollback(:stale_release)
      fresh = Repo.get!(Grab, expected.id)

      episode_ids = episode_ids_for_grab(fresh.id)
      series_id = series_id_for_grab(fresh.id)
      insert_blocked_release!(%{series_id: series_id, release_title: fresh.release_title, reason: policy_reason(evidence)})
      intent_ids = Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(fresh, episode_ids)])
      {:ok, deleted} = Repo.delete(fresh)
      {deleted, intent_ids, series_id}
    end)

  with {:ok, {deleted, intent_ids, series_id}} <- result do
    Download.cleanup_intents(intent_ids)
    broadcast_series(series_id)
    {:ok, deleted}
  end
end
```

The FK nilifies exactly this grab's links. Do not call `park_grab/1`, because it increments non-imported search attempts; do not create a mapping issue.

- [ ] **Step 6: Route only confirmed mismatch tags from both pollers**

Before generic permanent/transient cases:

```elixir
{:error, {:release_policy_mismatch, evidence}} ->
  Catalog.reject_movie_release(movie, evidence)
```

and:

```elixir
{:error, {:release_policy_mismatch, evidence}} ->
  Catalog.reject_grab_release(preflight.grab, evidence)
```

Apply the Movie clause to both normal import and upgrade replacement. A successful rejection is not an import failure notification; the exact target is immediately eligible for a fresh search. A stale rejection returns `:ok` to the poller and lets the next tick re-derive.

- [ ] **Step 7: Verify GREEN, exactness, and durable cleanup retry**

Run:

```bash
mix format && mix test test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder/download/release_policy_cleanup_test.exs
```

Expected: no mismatch creates an ImportStage or filesystem write; only the exact title/targets are affected; counters are preserved; cleanup fences survive client failure; group siblings remain eligible.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/catalog.ex lib/cinder/download/poller.ex lib/cinder/download/tv_poller.ex test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder/download/release_policy_cleanup_test.exs
git commit -m "feat: reject mismatched anime releases"
```

### Task 9: Preserve unverifiable downloads with bounded retry and a durable TV hold

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Modify: `lib/cinder/catalog/grab.ex`
- Modify: `lib/cinder/download/poller.ex`
- Modify: `lib/cinder/download/tv_poller.ex`
- Modify: `lib/cinder_web/live/activity_live.ex`
- Modify: `test/cinder/download/poller_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`
- Modify: `test/cinder_web/live/activity_live_test.exs`

**Interfaces:**
- Extends Grab `mapping_status` with `:verification_blocked` without adding another editor or issue document.
- Produces guarded `Catalog.hold_grab_verification/1` and `Catalog.retry_grab_verification/1`.
- Reuses existing Activity cancel for preserved content; adds only `Retry verification`.

- [ ] **Step 1: Write failing bounded retry, hold, retry, cancel, and Activity tests**

For movies, prove each unavailable result increments `import_attempts`, the tenth transitions to `:import_failed`, and all of these remain true:

```elixir
assert failed.file_path == downloaded.file_path
assert failed.download_id == downloaded.download_id
assert failed.release_policy_snapshot == downloaded.release_policy_snapshot
assert Catalog.blocked_release_titles(failed) == []
refute cleanup_pending_for?(failed.download_id)
refute Repo.exists?(ImportStage)
```

For TV, assert attempts 1–9 preserve `:resolved`; attempt 10 sets `:verification_blocked` and preserves the grab, content path, links, mapping evidence, policy snapshot, counters, and remote download. It must disappear from `list_grabs_downloaded/0` but remain in `list_grabs/0`.

Add guarded actions:

```elixir
assert {:ok, retried} = Catalog.retry_grab_verification(held)
assert retried.mapping_status == :resolved
assert retried.download_attempts == 0

assert {:error, :verification_not_held} = Catalog.retry_grab_verification(resolved_grab)
```

Activity tests assert `Needs verification`, `Retry verification`, and Cancel are present; the mapping editor link is absent; Retry performs no filesystem/MediaInfo/client call; Cancel uses the existing durable cleanup fence.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mix test test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/live/activity_live_test.exs
```

Expected: movie behavior may retry but TV eventually parks/deletes and requeues; the enum and Activity state do not exist.

- [ ] **Step 3: Add the durable enum state and prevent recovery-editor routing**

Extend only the Ecto enum:

```elixir
field :mapping_status, Ecto.Enum,
  values: [:resolved, :needs_mapping, :verification_blocked],
  default: :resolved
```

No migration is needed because the SQLite column is textual and has no restrictive CHECK. Tighten `Catalog.get_mapping_grab/1` to `mapping_status == :needs_mapping` so a hand-crafted recovery URL cannot open a verification-held grab in the mapping editor.

- [ ] **Step 4: Add guarded hold and retry Catalog writers**

Use conditional updates and broadcast only on a claimed row:

```elixir
def hold_grab_verification(%Grab{} = grab) do
  observed_attempts = grab.download_attempts || 0

  case Repo.update_all(
         from(g in Grab,
           where:
             g.id == ^grab.id and g.mapping_status == :resolved and
               g.download_attempts == ^observed_attempts and
               not is_nil(g.content_path),
           select: g
         ),
         set: [
           mapping_status: :verification_blocked,
           download_attempts: observed_attempts + 1,
           updated_at: now()
         ]
       ) do
    {1, [held]} -> broadcast_grab_and_ok(held)
    {0, _} -> {:error, :stale_grab}
  end
end

def retry_grab_verification(%Grab{} = grab) do
  case Repo.update_all(
         from(g in Grab,
           where: g.id == ^grab.id and g.mapping_status == :verification_blocked,
           select: g
         ),
         set: [mapping_status: :resolved, download_attempts: 0, updated_at: now()]
       ) do
    {1, [retried]} -> broadcast_grab_and_ok(retried)
    {0, _} -> {:error, :verification_not_held}
  end
end
```

`TVPoller` calls the hold only when `observed_attempts + 1 == @max_attempts`, so Catalog atomically records the tenth attempt without owning a duplicate retry bound. Do not alter mapping decisions/issues and do not invoke Library/Download from Retry.

- [ ] **Step 5: Route unavailable policy separately from generic TV parking**

In TV import handling:

```elixir
{:error, {:release_policy_unavailable, reason}} ->
  retry_or_hold_verification(preflight.grab, reason)
```

The helper increments attempts 1–9 with `Catalog.increment_grab_attempts/1`; at the existing tenth-attempt bound it calls `Catalog.hold_grab_verification/1`, not `park/2`. It never blocklists, deletes, cleans up, requeues, creates mapping evidence, or notifies `:grab_failed`.

Movies can use the existing generic `retry_or_fail/4`: the tagged unavailable tuple is absent from `@permanent_import_errors` and `@download_failure_errors`, so the tenth attempt reaches `:import_failed` without blocklist or cleanup. Add an explicit comment/test guarding that classification.

- [ ] **Step 6: Add the minimal Activity UX**

Render verification-held grabs with a distinct badge and two actions:

```heex
<span :if={grab.mapping_status == :verification_blocked} class="badge badge-warning">
  {gettext("Needs verification")}
</span>
<.button
  :if={grab.mapping_status == :verification_blocked}
  phx-click="retry_verification"
  phx-value-id={grab.id}
  size="xs"
>
  {gettext("Retry verification")}
</.button>
```

The handler parses the ID, re-reads with `Catalog.get_grab/1`, calls the guarded retry writer, flashes success/error, and reloads. Reuse the existing Cancel event unchanged. Never render `Fix mapping` for this state and do not add policy-edit fields.

- [ ] **Step 7: Verify GREEN and preserved-content semantics**

Run:

```bash
mix format && mix test test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/live/activity_live_test.exs
```

Expected: no unconfirmed outcome imports or blocklists; movies hold at `:import_failed`; TV holds visibly and idly; Retry resets only hold/counter; Cancel still commits durable cleanup.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/catalog.ex lib/cinder/catalog/grab.ex lib/cinder/download/poller.ex lib/cinder/download/tv_poller.ex lib/cinder_web/live/activity_live.ex test/cinder/download/poller_test.exs test/cinder/download/tv_poller_test.exs test/cinder_web/live/activity_live_test.exs
git commit -m "feat: hold unverifiable anime downloads"
```

### Task 10: Run the A4 phase gate, update the graph, and mark the roadmap boundary

**Files:**
- Modify only after all tests pass: `ROADMAP.md`
- Update generated graph artifacts through: `graphify update .`
- Review: `docs/superpowers/specs/2026-07-13-a4-anime-specials-preferences-design.md`
- Review: `docs/superpowers/plans/2026-07-13-a4-anime-specials-preferences.md`

**Interfaces:**
- Produces complete A4 test evidence and a current knowledge graph.
- Marks A4 complete only after the repository quality alias succeeds.
- Leaves A5 untouched.

- [ ] **Step 1: Run the focused A4 slice**

Run:

```bash
mix test \
  test/cinder/acquisition/anime_preferences_test.exs \
  test/cinder/acquisition/parser_test.exs \
  test/cinder/acquisition/anime_parser_test.exs \
  test/cinder/acquisition/anime_selection_test.exs \
  test/cinder/catalog_series_test.exs \
  test/cinder/catalog_tv_pipeline_test.exs \
  test/cinder/download/intent_test.exs \
  test/cinder/download/poller_test.exs \
  test/cinder/download/tv_poller_test.exs \
  test/cinder/download/release_policy_cleanup_test.exs \
  test/cinder/library/policy_verifier_test.exs \
  test/cinder/library_media_info_test.exs \
  test/cinder/library/media_info/ffprobe_test.exs \
  test/cinder/library/anime_preflight_test.exs \
  test/cinder/library_test.exs \
  test/cinder_web/live/settings_live_test.exs \
  test/cinder_web/live/setup_live_test.exs \
  test/cinder_web/live/movie_detail_live_test.exs \
  test/cinder_web/live/series_detail_live_test.exs \
  test/cinder_web/live/activity_live_test.exs \
  test/cinder_web/components/manual_search_component_test.exs
```

Expected: the complete preference/special/acquisition/snapshot/verification/rejection/hold slice passes with no network or real filesystem dependency.

- [ ] **Step 2: Run explicit Standard, A2, and A3 regressions**

Run:

```bash
mix test \
  test/cinder/acquisition/scorer_test.exs \
  test/cinder/catalog/grab_mapping_test.exs \
  test/cinder/catalog/anime_resolver_test.exs \
  test/cinder_web/live/grab_mapping_live_test.exs \
  test/cinder/subtitles_test.exs
```

Expected: Standard movie/TV scoring/import, A2 corpus/coverage, A3 mapping recovery, subtitle fallback, cleanup, and retry behavior remain green.

- [ ] **Step 3: Run the repository source of truth**

Run:

```bash
mix format
mix test
```

Expected: compile with warnings as errors, format check, `credo --strict`, and the full ExUnit suite all pass. Fix any failure before continuing; do not mark A4 from focused tests alone.

- [ ] **Step 4: Update and query the knowledge graph**

Run:

```bash
graphify update .
graphify query "How do Anime preferences flow from Settings and title overrides through release reservation to pre-import verification and rejection?"
```

Expected: the scoped graph includes `Settings`, `AnimePreferences`, `Anime`, `Intent`, `Grab`/Movie policy snapshots, `PolicyVerifier`, both pollers, and the Catalog cleanup writers. If graph generation changes tracked artifacts, include them in the phase-boundary commit.

- [ ] **Step 5: Review the final diff against every approved invariant**

Run:

```bash
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
git status --short
```

Confirm manually:

- Standard code paths have no new active defaults or snapshot documents.
- nil and explicit-empty overrides stay distinguishable through DB, resolver, and both forms.
- story specials/recaps require Anime plus explicit monitoring; extras never become targets.
- missing name traits remain eligible; only positive contradictions reject early.
- fallback waiting uses publication time and consumes no attempts.
- every automatic and manual Anime reservation freezes policy atomically.
- every unique authoritative source is probed once before staging; extras/sidecars cannot satisfy policy.
- confirmed mismatch blocks one exact title and durably requeues only owned targets without counter changes.
- unavailable evidence preserves content, blocklists nothing, and reaches the correct durable hold.
- verification-held grabs cannot open the mapping editor; Retry has no filesystem side effect.
- no TODO, generalized policy table, new route, new provider, or A5 behavior slipped into the diff.

- [ ] **Step 6: Mark A4 complete in ROADMAP only now**

Update the A4 checklist/status and its evidence note with the focused test command, full `mix test`, and graph update. Do not edit A5 completion state or claim live Jellyfin/Plex dogfood.

- [ ] **Step 7: Re-run the final gate after the roadmap edit**

Run:

```bash
mix format && mix test && git diff --check && git status --short
```

Expected: green source-of-truth alias, clean whitespace, and only intended uncommitted ROADMAP/graph artifacts.

- [ ] **Step 8: Commit the phase boundary**

```bash
git add ROADMAP.md graphify-out
git commit -m "docs: complete A4 anime preferences"
```

If `graphify-out` is ignored and has no tracked diff, stage only `ROADMAP.md`. Finish with:

```bash
git status --short --branch
git log --oneline --decorate -12
```

Expected: clean `codex/a4-anime-specials-preferences`, one commit per task boundary, and no A5 implementation.
