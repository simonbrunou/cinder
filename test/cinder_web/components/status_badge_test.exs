defmodule CinderWeb.StatusBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.CoreComponents

  defp badge(assigns), do: render_component(&CoreComponents.status_badge/1, assigns)

  test "renders every movie pipeline status with an icon and text label" do
    for status <- [
          :requested,
          :searching,
          :downloading,
          :downloaded,
          :available,
          :upgrading,
          :no_match,
          :search_failed,
          :import_failed,
          :cancelled
        ] do
      html = badge(%{kind: :movie, status: status})
      # icon+text, never colour alone: a heroicon span is present
      assert html =~ "hero-"
    end
  end

  describe "a download paused by its client" do
    @paused_at ~U[2026-11-23 10:00:00Z]

    test "says so in its label, icon and progress bar, with the progress kept" do
      for {kind, status} <- [{:movie, :downloading}, {:movie, :upgrading}, {:grab, :downloading}] do
        html = badge(%{kind: kind, status: status, progress: 0.42, paused_at: @paused_at})

        assert html =~ "Paused by download client"
        assert html =~ "hero-pause-circle"
        assert html =~ ~r/<progress[^>]*aria-label="Paused by download client"/
        assert html =~ "progress-warning"
        assert html =~ "42%"
        refute html =~ "Downloading"
      end
    end

    test "hands the Kindle hook the warning color and the paused label" do
      html = badge(%{id: "b", kind: :movie, status: :downloading, paused_at: @paused_at})

      assert html =~ ~s(data-kindle="badge-warning|Paused by download client")
    end

    test "colors and labels a bar with no progress value" do
      html = badge(%{kind: :movie, status: :downloading, progress: nil, paused_at: @paused_at})

      assert html =~ ~r/<progress[^>]*progress-warning[^>]*aria-label="Paused by download client"/
      refute html =~ ~r/<progress[^>]*value=/
    end

    test "shows no speed or time left, even from a stale estimate" do
      html =
        badge(%{
          kind: :movie,
          status: :downloading,
          progress: 0.0,
          speed: 1_500_000,
          eta: 90,
          paused_at: @paused_at
        })

      refute html =~ "MB/s"
      refute html =~ "remaining"
    end

    test "a stale mark does not relabel a download that moved on" do
      for {kind, status, label} <- [
            {:movie, :downloaded, "Importing"},
            {:movie, :searching, "Searching"},
            {:grab, :downloaded, "Importing"}
          ] do
        html = badge(%{kind: kind, status: status, paused_at: @paused_at})

        assert html =~ label
        refute html =~ "Paused by download client"
      end
    end

    test "no mark keeps the downloading label" do
      html = badge(%{kind: :movie, status: :downloading, progress: 0.42, paused_at: nil})

      assert html =~ "Downloading"
      assert html =~ "progress-info"
      refute html =~ "Paused by download client"
    end
  end

  test "operation badges render progress while request badges stay compact" do
    html =
      badge(%{
        kind: :movie,
        status: :downloading,
        progress: 0.42,
        speed: 1_500_000,
        eta: 90
      })

    assert html =~ "<progress"
    assert html =~ ~r/<progress[^>]*aria-label="Downloading"/
    assert html =~ "42%"
    assert html =~ "1.5 MB/s"
    assert html =~ "1m 30s remaining"

    assert badge(%{kind: :movie, status: :searching}) =~ "aria-label=\"Searching\""
    assert badge(%{kind: :movie, status: :downloaded}) =~ "Importing"
    assert badge(%{kind: :grab, status: :downloaded}) =~ "Importing"

    request = badge(%{kind: :request, status: :pending})
    assert request =~ "badge"
    refute request =~ "<progress"
  end

  test "covers request, episode, grab and health kinds with icon+text" do
    cases = [
      {%{kind: :request, status: :pending}, "Pending"},
      {%{kind: :request, status: :available}, "Available"},
      {%{kind: :request, status: :up_to_date_airing}, "Up to date, airing"},
      {%{kind: :episode, status: :wanted}, "Wanted"},
      {%{kind: :episode, status: :upcoming}, "Upcoming"},
      {%{kind: :grab, status: :downloading}, "Downloading"},
      {%{kind: :grab, status: :downloaded}, "Importing"},
      {%{kind: :health, status: :ok}, "OK"}
    ]

    for {assigns, label} <- cases do
      html = badge(assigns)
      assert html =~ label
      assert html =~ "hero-"
    end
  end

  test "a grab needing verification and a movie held mid-verification share the same treatment" do
    for assigns <- [
          %{kind: :grab, status: :verification_blocked},
          %{kind: :movie, status: :verification_hold}
        ] do
      html = badge(assigns)
      assert html =~ "Needs verification"
      assert html =~ "badge-warning"
      assert html =~ "hero-exclamation-triangle"
    end
  end

  test "a health error renders Unreachable, error colour, and a human reason as a title" do
    html = badge(%{kind: :health, status: {:error, :timeout}})
    assert html =~ "Unreachable"
    assert html =~ "badge-error"
    assert html =~ ~s(title=)
    assert html =~ "Timed out"
  end

  test "a health warning renders a warning without calling the service unreachable" do
    html =
      badge(%{
        kind: :health,
        status: {:warning, {:sabnzbd_config, [{:folder_max_length, 60}]}}
      })

    assert html =~ "Warning"
    assert html =~ "badge-warning"
    assert html =~ "Folder name limit is 60"
    refute html =~ "Unreachable"
  end

  test "health_reason unwraps wrapped error shapes into human strings" do
    f = &CinderWeb.CoreComponents.health_reason/1
    assert f.(%Req.TransportError{reason: :econnrefused}) == "Connection refused"
    assert f.(:not_configured) == "Not configured"
    assert f.({:status, 401}) == "Authentication failed"
    assert f.(%CaseClauseError{term: nil}) == "Check failed"

    assert f.({:path_mapping_local_prefix_unreadable, "/missing"}) ==
             "Local path prefix is not an existing readable directory: /missing"
  end

  test "the :upgrading badge uses progress-info and the arrow-up-circle icon" do
    html = badge(%{kind: :movie, status: :upgrading})
    assert html =~ "Upgrading"
    assert html =~ "progress-info"
    assert html =~ "hero-arrow-up-circle"
  end

  describe "the :indexer kind (#1660)" do
    @at ~U[2026-11-26 12:00:00Z]

    # Each red state `IndexerState.needs_admin?/1` names, `{:usable, at}`, the badge's own
    # `:disabled` clause, the waits, the usable states that carry a definition code (#1668), which
    # read yellow, and a state no code names.
    test "words and colours each state with an icon, an unknown one in yellow" do
      cases = [
        {{:usable, @at}, "OK", "badge-success", "hero-check-circle"},
        {:disabled, "Disabled", "badge-ghost", "hero-pause-circle"},
        {:undecryptable, "Needs attention", "badge-error", "hero-exclamation-circle"},
        {{:not_supported, :flaresolverr}, "Needs attention", "badge-error", "hero-"},
        {{:credentials_rejected, nil}, "Needs attention", "badge-error", "hero-"},
        {{:definition_no_longer_loads, :parse_error}, "Needs attention", "badge-error", "hero-"},
        {:never_checked, "Warning", "badge-warning", "hero-exclamation-triangle"},
        {{:limit_backoff, @at}, "Warning", "badge-warning", "hero-"},
        {{:failure_backoff, @at, :timeout, 1}, "Warning", "badge-warning", "hero-"},
        {{:retry_due, @at, :limit, 0}, "Warning", "badge-warning", "hero-"},
        {{:definition_update_held, :fails, @at}, "Warning", "badge-warning", "hero-"},
        {{:removed_upstream, @at}, "Warning", "badge-warning", "hero-"},
        {{:replaced_by, "Other", @at}, "Warning", "badge-warning", "hero-"},
        {{:some_new_state, @at}, "Warning", "badge-warning", "hero-"}
      ]

      for {state, label, colour, icon} <- cases do
        html = badge(%{kind: :indexer, status: state})
        assert html =~ label, inspect(state)
        assert html =~ colour, inspect(state)
        assert html =~ icon, inspect(state)
      end
    end

    test "Health.native_indexer_level/1, which the dashboard's per-indexer rows read, gives the same levels" do
      for {state, level} <- [
            {{:usable, @at}, :ok},
            {:undecryptable, :error},
            {{:credentials_rejected, {:code, 100}}, :error},
            {{:not_supported, :cardigann}, :error},
            {{:definition_no_longer_loads, :parse_error}, :error},
            {{:definition_update_held, :fails, @at}, :warning},
            {{:removed_upstream, @at}, :warning},
            {{:replaced_by, "Other", @at}, :warning},
            {:never_checked, :warning},
            {{:limit_backoff, @at}, :warning},
            {:some_new_state, :warning}
          ] do
        assert Cinder.Health.native_indexer_level(state) == level, inspect(state)
      end
    end
  end

  test "an unmapped status falls back to a neutral badge instead of raising" do
    html = badge(%{kind: :movie, status: :some_new_state})
    assert html =~ "badge-neutral"
    assert html =~ "Some new state"
  end
end
