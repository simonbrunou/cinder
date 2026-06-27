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
          :no_match,
          :search_failed,
          :import_failed,
          :cancelled
        ] do
      html = badge(%{kind: :movie, status: status})
      assert html =~ "badge"
      # icon+text, never colour alone: a heroicon span is present
      assert html =~ "hero-"
    end
  end

  test "covers request, episode, grab and health kinds with icon+text" do
    cases = [
      {%{kind: :request, status: :pending}, "Pending"},
      {%{kind: :request, status: :available}, "Available"},
      {%{kind: :episode, status: :wanted}, "Wanted"},
      {%{kind: :episode, status: :upcoming}, "Upcoming"},
      {%{kind: :grab, status: :downloading}, "Downloading"},
      {%{kind: :grab, status: :downloaded}, "Downloaded"},
      {%{kind: :health, status: :ok}, "OK"}
    ]

    for {assigns, label} <- cases do
      html = badge(assigns)
      assert html =~ label
      assert html =~ "hero-"
    end
  end

  test "a health error renders Unreachable, error colour, and a human reason as a title" do
    html = badge(%{kind: :health, status: {:error, :timeout}})
    assert html =~ "Unreachable"
    assert html =~ "badge-error"
    assert html =~ ~s(title=)
    assert html =~ "Timed out"
  end

  test "health_reason unwraps wrapped error shapes into human strings" do
    f = &CinderWeb.CoreComponents.health_reason/1
    assert f.(%Req.TransportError{reason: :econnrefused}) == "Connection refused"
    assert f.(:not_configured) == "Not configured"
    assert f.({:status, 401}) == "Authentication failed"
    assert f.(%CaseClauseError{term: nil}) == "Check failed"
  end

  test "an unmapped status falls back to a neutral badge instead of raising" do
    html = badge(%{kind: :movie, status: :some_new_state})
    assert html =~ "badge-neutral"
    assert html =~ "Some new state"
  end
end
