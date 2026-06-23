defmodule CinderWeb.StatusBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.CoreComponents

  test "renders a :cancelled movie status badge without raising (badge-error)" do
    html = render_component(&CoreComponents.movie_status_badge/1, %{status: :cancelled})
    assert html =~ "badge-error"
    assert html =~ "cancelled"
  end

  test "renders every movie status without raising FunctionClauseError" do
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
      assert render_component(&CoreComponents.movie_status_badge/1, %{status: status}) =~ "badge"
    end
  end
end
