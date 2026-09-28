# Operation Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Show live, accurate download percentage, speed, ETA, and named search/import phases for movie and TV operations wherever operation badges currently appear.

**Architecture:** The existing five-second pollers remain the only download-client callers. They normalize client metrics, persist only changed snapshots through guarded Catalog writers, and reuse existing PubSub flows. The shared status badge gains an accessible expanded operation branch; all other badges stay compact.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/SQLite, Req, Mox, ExUnit, daisyUI native progress elements.

## Global Constraints

- qBittorrent supplies per-download speed and ETA; SABnzbd supplies per-slot ETA only. Never show SABnzbd queue-wide speed as a grab speed.
- Movie writes go through guarded Catalog.transition/3; grab writes only land while content_path is nil.
- Clear metrics on a new movie download or upgrade, completion, retry/error, cancel, abort/revert, and terminal transition.
- Use no browser polling, cache, JavaScript, dependency, index, or new persistent upgrade state.
- Visible copy uses gettext. Render native progress with a visible label; never rely on colour alone.
- The final gate is mix test. Run graphify update . after modifying code.

---

## File structure

| File | Responsibility |
| --- | --- |
| priv/repo/migrations/20260710120000_add_download_progress_metrics.exs | Adds nullable metrics to movies and grabs. |
| lib/cinder/catalog/movie.ex and grab.ex | Schema fields plus movie transition reset rule. |
| lib/cinder/catalog.ex | Guarded metric writers and grab lifecycle clears. |
| lib/cinder/download/client.ex, client/qbittorrent.ex, client/sabnzbd.ex | Documents and normalizes progress, rate, and ETA. |
| lib/cinder/download/poller.ex and tv_poller.ex | Writes fresh metrics and clears stale observations. |
| lib/cinder_web/components/core_components.ex | Renders compact badges or expanded operation progress. |
| lib/cinder_web/live/movie_detail_live.ex, activity_live.ex, library_live.ex, dashboard_live.ex, my_requests_live.ex | Passes movie/grab metrics to the shared renderer. |
| test/cinder/catalog/movie_test.exs and catalog_admin_test.exs | Tests writers and reset paths. |
| test/cinder/download/client/qbittorrent_test.exs and client/sabnzbd_test.exs | Tests client normalization. |
| test/cinder/download/poller_test.exs and tv_poller_test.exs | Tests persisted polling and stale guards. |
| test/cinder_web/components/status_badge_test.exs | Tests determinate and indeterminate markup. |
| affected LiveView tests | Tests every operation-badge location. |

The normalized status map uses progress as a 0.0 to 1.0 float and optional speed/eta:

~~~elixir
%{
  state: :downloading | :completed | :error,
  progress: float() | nil,
  speed: non_neg_integer() | nil,
  eta: non_neg_integer() | nil,
  content_path: String.t() | nil
}
~~~

### Task 1: Persist metrics and add guarded Catalog writers

**Files:**

- Create: priv/repo/migrations/20260710120000_add_download_progress_metrics.exs
- Modify: lib/cinder/catalog/movie.ex
- Modify: lib/cinder/catalog/grab.ex
- Modify: lib/cinder/catalog.ex
- Test: test/cinder/catalog/movie_test.exs
- Test: test/cinder/catalog_admin_test.exs

**Interfaces:**

- Produces Catalog.update_movie_download_metrics/2 and Catalog.update_grab_download_metrics/2.
- Each accepts %{download_progress: float() | nil, download_speed: integer() | nil, download_eta: integer() | nil}.
- A changed movie update returns the existing guarded transition result. An equal snapshot returns {:ok, movie}. A race returns {:error, :stale_status} or {:error, :stale_grab}.

- [ ] **Step 1: Write failing data tests**

Add these tests before changing the schemas:

~~~elixir
test "transition clears metrics when it leaves downloading" do
  movie =
    movie_fixture(%{
      status: :downloading,
      download_progress: 0.42,
      download_speed: 1_500_000,
      download_eta: 90
    })

  assert {:ok, updated} = Catalog.transition(movie, %{status: :downloaded})
  assert %{download_progress: nil, download_speed: nil, download_eta: nil} = updated
end

test "changed movie metrics broadcast once and an equal snapshot is silent" do
  movie = movie_fixture(%{status: :downloading})
  Catalog.subscribe()
  metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}

  assert {:ok, updated} = Catalog.update_movie_download_metrics(movie, metrics)
  assert_receive {:movie_updated, ^updated}
  assert {:ok, ^updated} = Catalog.update_movie_download_metrics(updated, metrics)
  refute_receive {:movie_updated, _}
end
~~~

Also add tests that a new downloading/upgrading run clears old values, direct cancel and abort-upgrade clear them, a stale movie write returns stale_status, a grab metric write broadcasts the series, and a grab marked downloaded before a late write returns stale_grab.

- [ ] **Step 2: Run the tests and confirm the expected red state**

Run:

~~~bash
mix test test/cinder/catalog/movie_test.exs test/cinder/catalog_admin_test.exs
~~~

Expected: FAIL because the schema fields and Catalog metric writers do not exist.

- [ ] **Step 3: Add migration and schema fields**

Create this migration with no defaults or indexes:

~~~elixir
defmodule Cinder.Repo.Migrations.AddDownloadProgressMetrics do
  use Ecto.Migration

  def change do
    for table <- [:movies, :grabs] do
      alter table(table) do
        add :download_progress, :float
        add :download_speed, :integer
        add :download_eta, :integer
      end
    end
  end
end
~~~

Add the three fields to Movie.schema/1 and Grab.schema/1, and add them to Movie.transition_changeset/2 and Grab.changeset/2 casts. Make Movie.transition_changeset/2 call this private helper after cast:

~~~elixir
defp reset_download_metrics(changeset, previous_status) do
  status = get_field(changeset, :status)

  if status not in [:downloading, :upgrading] or status != previous_status do
    change(changeset, download_progress: nil, download_speed: nil, download_eta: nil)
  else
    changeset
  end
end
~~~

This preserves same-state metric writes, clears a new run, and also covers direct cancel/abort transactions because they already call this changeset.

- [ ] **Step 4: Add only the two required Catalog writers**

In Catalog, compare the complete metric tuple before writing:

~~~elixir
@download_metric_fields [:download_progress, :download_speed, :download_eta]

defp metric_changes(record, attrs) do
  attrs = Map.take(attrs, @download_metric_fields)
  if Map.take(record, @download_metric_fields) == attrs, do: %{}, else: attrs
end
~~~

For movies, call transition(movie, Map.put(changes, :status, movie.status), expect: movie.status) only if changes is non-empty. For grabs, use one Repo.update_all constrained by grab id and is_nil(content_path), setting updated_at: now(); broadcast the owning series only after one row changes. Return stale_grab on a zero-row update.

Make mark_grab_downloaded/2 set all three metrics to nil with content_path. Make increment_grab_attempts/1 set all three to nil in the same update, so retry/error cannot leave an old rate or ETA visible.

- [ ] **Step 5: Run the focused data tests and confirm green**

Run:

~~~bash
mix test test/cinder/catalog/movie_test.exs test/cinder/catalog_admin_test.exs
~~~

Expected: PASS, including equal snapshots that make no DB write/broadcast and late grab writes that cannot overwrite import state.

- [ ] **Step 6: Commit the data boundary**

~~~bash
git add priv/repo/migrations/20260710120000_add_download_progress_metrics.exs \
  lib/cinder/catalog/movie.ex lib/cinder/catalog/grab.ex lib/cinder/catalog.ex \
  test/cinder/catalog/movie_test.exs test/cinder/catalog_admin_test.exs
git commit -m "feat: persist download progress metrics"
~~~

### Task 2: Normalize qBittorrent and SABnzbd measurements

**Files:**

- Modify: lib/cinder/download/client.ex
- Modify: lib/cinder/download/client/qbittorrent.ex
- Modify: lib/cinder/download/client/sabnzbd.ex
- Test: test/cinder/download/client/qbittorrent_test.exs
- Test: test/cinder/download/client/sabnzbd_test.exs

**Interfaces:**

- Every normal client status has progress, speed, and eta keys; unavailable values are nil.
- qBittorrent maps dlspeed and valid eta. SABnzbd maps timeleft and always leaves speed nil.

- [ ] **Step 1: Write failing normalization tests**

Add exact response assertions:

~~~elixir
assert {:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: 90}} =
         QBittorrent.status("abc123")

assert {:ok, %{state: :downloading, progress: 0.42, speed: nil, eta: 90}} =
         Sabnzbd.status("nzo-1")
~~~

The qBittorrent fixture supplies dlspeed 1_500_000 and eta 90. A second fixture supplies eta 8_640_000 and asserts eta is nil. The SABnzbd queue slot supplies timeleft "0:01:30"; malformed "unknown" must assert eta nil.

- [ ] **Step 2: Run the client tests and confirm red**

~~~bash
mix test test/cinder/download/client/qbittorrent_test.exs test/cinder/download/client/sabnzbd_test.exs
~~~

Expected: FAIL because both normalizers omit speed and eta.

- [ ] **Step 3: Implement defensive normalization**

Document optional speed/eta in Cinder.Download.Client status/1 documentation.

In qBittorrent, add these helpers and include their results in normalize/1:

~~~elixir
defp metric(value) when is_integer(value) and value >= 0, do: value
defp metric(_value), do: nil

defp eta(value) when is_integer(value) and value in 0..8_639_999, do: value
defp eta(_value), do: nil
~~~

Return speed: metric(torrent["dlspeed"]) and eta: eta(torrent["eta"]). Preserve existing state classification; do not treat a 100-percent moving torrent as complete.

In SABnzbd, keep speed nil and parse only a valid H:MM:SS timeleft:

~~~elixir
defp eta(timeleft) when is_binary(timeleft) do
  with [hours, minutes, seconds] <- String.split(String.trim(timeleft), ":"),
       {hours, ""} <- Integer.parse(hours),
       {minutes, ""} <- Integer.parse(minutes),
       {seconds, ""} <- Integer.parse(seconds),
       true <- hours >= 0 and minutes in 0..59 and seconds in 0..59 do
    hours * 3600 + minutes * 60 + seconds
  else
    _ -> nil
  end
end

defp eta(_timeleft), do: nil
~~~

Queued maps pass eta(slot["timeleft"]); completed/history maps use speed: nil, eta: nil.

- [ ] **Step 4: Run client tests and confirm green**

~~~bash
mix test test/cinder/download/client/qbittorrent_test.exs test/cinder/download/client/sabnzbd_test.exs
~~~

Expected: PASS, including sentinel omission and nil SABnzbd per-grab speed.

- [ ] **Step 5: Commit client normalization**

~~~bash
git add lib/cinder/download/client.ex lib/cinder/download/client/qbittorrent.ex \
  lib/cinder/download/client/sabnzbd.ex test/cinder/download/client/qbittorrent_test.exs \
  test/cinder/download/client/sabnzbd_test.exs
git commit -m "feat: normalize download speed and eta"
~~~

### Task 3: Publish movie and upgrade progress from the poller

**Files:**

- Modify: lib/cinder/download/poller.ex
- Test: test/cinder/download/poller_test.exs

**Interfaces:**

- Consumes Catalog.update_movie_download_metrics/2.
- Produces fresh metrics for downloading and upgrading movies; a client error clears metrics but retains existing retry semantics.

- [ ] **Step 1: Write failing poller tests**

Create a downloading movie and stub status with:

~~~elixir
{:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: 90}}
~~~

After Poller.poll/0, assert the reloaded movie and movie_updated message carry the tuple. Poll the same map again and assert no second message. Add an upgrading fixture, a transient {:error, :timeout} fixture that clears prior values without changing status, and a completed fixture proving :downloaded has nil metrics before import.

- [ ] **Step 2: Run the movie poller suite and confirm red**

~~~bash
mix test test/cinder/download/poller_test.exs
~~~

Expected: FAIL because the current in-flight catch-all makes no write.

- [ ] **Step 3: Persist only fresh downloading maps**

Place this clause before each existing catch-all in advance_with/2 and advance_upgrade_with/2:

~~~elixir
{:ok, %{state: :downloading} = status} ->
  Catalog.update_movie_download_metrics(movie, %{
    download_progress: Map.get(status, :progress),
    download_speed: Map.get(status, :speed),
    download_eta: Map.get(status, :eta)
  })
~~~

For a non-not-found client error, call the same writer with all three fields nil. In retry_or_fail/4 and retry_or_revert/2, add the nil tuple to the same-status transition attributes; client-reported error must not retain an old rate/ETA. Let the Task 1 transition reset handle completion, park, and revert.

- [ ] **Step 4: Run movie poller suite and confirm green**

~~~bash
mix test test/cinder/download/poller_test.exs
~~~

Expected: PASS for changed, equal, cleared-on-error, completed, and upgrade snapshots.

- [ ] **Step 5: Commit movie poll progress**

~~~bash
git add lib/cinder/download/poller.ex test/cinder/download/poller_test.exs
git commit -m "feat: publish movie download progress"
~~~

### Task 4: Publish guarded TV grab progress

**Files:**

- Modify: lib/cinder/download/tv_poller.ex
- Test: test/cinder/download/tv_poller_test.exs

**Interfaces:**

- Consumes Catalog.update_grab_download_metrics/2.
- Produces series broadcasts that cause Activity to reload fresh grab measurements; a grab completed/deleted during the client call cannot be overwritten.

- [ ] **Step 1: Write failing TV poller tests**

Create a grab and return:

~~~elixir
{:ok, %{state: :downloading, progress: 0.42, speed: nil, eta: 90}}
~~~

Assert the reloaded grab contains the tuple. A second equal poll must not change updated_at. Add a completion test that confirms mark_grab_downloaded/2 clears metrics, and call update_grab_download_metrics/2 after marking the same stale grab downloaded to assert stale_grab.

- [ ] **Step 2: Run the TV poller suite and confirm red**

~~~bash
mix test test/cinder/download/tv_poller_test.exs
~~~

Expected: FAIL because still-downloading TV statuses are ignored.

- [ ] **Step 3: Add the downloading and stale-observation branches**

Add this branch before the catch-all in TvPoller.advance_with/2:

~~~elixir
{:ok, %{state: :downloading} = status} ->
  Catalog.update_grab_download_metrics(grab, %{
    download_progress: Map.get(status, :progress),
    download_speed: Map.get(status, :speed),
    download_eta: Map.get(status, :eta)
  })
~~~

For a client error other than not_found, send an all-nil tuple to the writer. Keep state:error and not_found on retry_or_park/2; Task 1 makes increment_grab_attempts/1 clear old values. Do not alter the current completion/import ordering.

- [ ] **Step 4: Run TV poller suite and confirm green**

~~~bash
mix test test/cinder/download/tv_poller_test.exs
~~~

Expected: PASS, including silent equal polls and no late completion overwrite.

- [ ] **Step 5: Commit TV poll progress**

~~~bash
git add lib/cinder/download/tv_poller.ex test/cinder/download/tv_poller_test.exs
git commit -m "feat: publish tv download progress"
~~~

### Task 5: Render operation progress everywhere the operation badge exists

**Files:**

- Modify: lib/cinder_web/components/core_components.ex
- Modify: lib/cinder_web/live/movie_detail_live.ex
- Modify: lib/cinder_web/live/activity_live.ex
- Modify: lib/cinder_web/live/library_live.ex
- Modify: lib/cinder_web/live/dashboard_live.ex
- Modify: lib/cinder_web/live/my_requests_live.ex
- Test: test/cinder_web/components/status_badge_test.exs
- Test: test/cinder_web/live/movie_detail_live_test.exs
- Test: test/cinder_web/live/activity_live_test.exs
- Test: test/cinder_web/live/library_live_test.exs
- Test: test/cinder_web/live/dashboard_live_test.exs
- Test: test/cinder_web/live/my_requests_live_test.exs

**Interfaces:**

- status_badge/1 accepts optional progress, speed, and eta assigns.
- My Requests holds movies_by_tmdb as %{tmdb_id => movie}; Catalog.movie_status_map/0 remains untouched for Discover.

- [ ] **Step 1: Write failing rendering tests**

Add these component assertions:

~~~elixir
html =
  badge(%{
    kind: :movie,
    status: :downloading,
    progress: 0.42,
    speed: 1_500_000,
    eta: 90
  })

assert html =~ "<progress"
assert html =~ "42%"
assert html =~ "1.5 MB/s"
assert html =~ "1m 30s remaining"
assert badge(%{kind: :movie, status: :downloaded}) =~ "Importing"
assert badge(%{kind: :grab, status: :downloaded}) =~ "Importing"
~~~

Also assert a request badge remains compact. In each affected LiveView test, create a movie/grab with progress 0.42, speed 1_500_000, eta 90 and assert its page contains 42%. Activity covers both movie and TV grab. My Requests creates a request and matching movie with the same TMDB id, then asserts both the request badge and operation progress render.

- [ ] **Step 2: Run UI tests and confirm red**

~~~bash
mix test test/cinder_web/components/status_badge_test.exs \
  test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/activity_live_test.exs \
  test/cinder_web/live/library_live_test.exs test/cinder_web/live/dashboard_live_test.exs \
  test/cinder_web/live/my_requests_live_test.exs
~~~

Expected: FAIL because status_badge has no metrics and My Requests only stores a status atom.

- [ ] **Step 3: Add an accessible expanded status branch**

Declare optional assigns:

~~~elixir
attr :progress, :float, default: nil
attr :speed, :integer, default: nil
attr :eta, :integer, default: nil
~~~

Keep the existing compact span for non-operation states. For movie searching, movie/grab downloaded, movie downloading/upgrading, and grab downloading, render a flexible role=status wrapper. Use a labelled indeterminate progress element when progress is nil, and a determinate element when it is numeric:

~~~heex
<div class={["min-w-32 space-y-1", @class]} role="status">
  <div class="flex items-center gap-1 text-sm">
    <.icon name={@icon} class="size-4" />{@label}
  </div>
  <progress
    :if={is_number(@progress)}
    class="progress progress-info w-full"
    value={@progress * 100}
    max="100"
  >{round(@progress * 100)}%</progress>
  <progress :if={is_nil(@progress)} class="progress progress-info w-full" aria-label={@label} />
  <p :if={is_number(@progress)} class="text-xs tabular-nums">{round(@progress * 100)}%</p>
  <p :if={@speed || @eta} class="text-xs tabular-nums text-base-content/70">
    {[@speed && format_speed(@speed), @eta && format_eta(@eta)]
     |> Enum.reject(&is_nil/1)
     |> Enum.join(" · ")}
  </p>
</div>
~~~

Use gettext("Importing") for movie/grab downloaded and gettext("Searching") for searching. Add private formatters: speed formats one decimal MB/s; ETA produces "1m 30s remaining" below an hour and "1h 5m remaining" otherwise. Each returns nil for nil and the template separates only values that exist, so SABnzbd shows ETA without a fabricated speed.

- [ ] **Step 4: Pass persisted metrics to all real call sites**

At Movie Detail, Activity movie row, Library, Dashboard, and My Requests use:

~~~heex
<.status_badge
  kind={:movie}
  status={movie.status}
  progress={movie.download_progress}
  speed={movie.download_speed}
  eta={movie.download_eta}
/>
~~~

Use the same fields from g for Activity's grab badge. In My Requests load/1, replace the status-only assign with:

~~~elixir
movies_by_tmdb: Map.new(Catalog.list_movies(), &{&1.tmdb_id, &1})
~~~

Bind the second badge to movie = @movies_by_tmdb[r.target_id], retain the target_type == "movie" guard, and leave its request badge unchanged. Do not change Discover or movie_status_map/0.

- [ ] **Step 5: Extract strings and run UI tests**

~~~bash
mix gettext.extract
mix gettext.merge priv/gettext
mix test test/cinder_web/components/status_badge_test.exs \
  test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/activity_live_test.exs \
  test/cinder_web/live/library_live_test.exs test/cinder_web/live/dashboard_live_test.exs \
  test/cinder_web/live/my_requests_live_test.exs
~~~

Expected: PASS, with native determinate/indeterminate progress and all five movie locations plus Activity TV grab covered.

- [ ] **Step 6: Commit the rendering layer**

~~~bash
git add lib/cinder_web/components/core_components.ex \
  lib/cinder_web/live/movie_detail_live.ex lib/cinder_web/live/activity_live.ex \
  lib/cinder_web/live/library_live.ex lib/cinder_web/live/dashboard_live.ex \
  lib/cinder_web/live/my_requests_live.ex test/cinder_web/components/status_badge_test.exs \
  test/cinder_web/live/movie_detail_live_test.exs test/cinder_web/live/activity_live_test.exs \
  test/cinder_web/live/library_live_test.exs test/cinder_web/live/dashboard_live_test.exs \
  test/cinder_web/live/my_requests_live_test.exs priv/gettext
git commit -m "feat: show live operation progress"
~~~

### Task 6: Format, verify, and refresh Graphify

**Files:**

- Modify: graphify-out generated artifacts only if graphify update . changes them.

**Interfaces:**

- Consumes all implementation tasks.
- Produces a formatted, lint-clean, fully tested feature and current code graph.

- [ ] **Step 1: Format and inspect the complete diff**

~~~bash
mix format
git diff --check
git diff --stat
~~~

Expected: diff check is silent and the diff is limited to the planned migration, data flow, clients, pollers, UI, tests, Gettext output, and generated graph artifacts.

- [ ] **Step 2: Refresh the code graph**

~~~bash
graphify update .
~~~

Expected: successful completion; only generated graph artifacts change if relationships changed.

- [ ] **Step 3: Run the full project gate**

~~~bash
mix test
~~~

Expected: PASS for warnings-as-errors compilation, formatting, Credo strict, and all ExUnit tests.

- [ ] **Step 4: Commit generated graph artifacts only if present**

~~~bash
git add graphify-out
git diff --cached --quiet || git commit -m "chore: refresh code graph"
~~~
