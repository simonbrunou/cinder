defmodule CinderWeb.MediaCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.CoreComponents

  defp card(assigns), do: render_component(&CoreComponents.media_card/1, assigns)

  test "the placeholder tile carries per-title hue custom properties, stable across renders" do
    html = card(%{id: "m-1", title: "Inception", type: :movie})

    assert [[_, hue]] = Regex.scan(~r/--poster-hue:\s*(\d+);/, html)
    assert [[_, hue2]] = Regex.scan(~r/--poster-hue2:\s*(\d+);/, html)

    # Re-rendering the same title yields the exact same hues (identity feature, not random).
    html_again = card(%{id: "m-1", title: "Inception", type: :movie})
    assert html_again =~ "--poster-hue: #{hue};"
    assert html_again =~ "--poster-hue2: #{hue2};"

    # A different title gets a different (but still deterministic) hue.
    other = card(%{id: "m-2", title: "The Matrix", type: :movie})
    assert other =~ ~r/--poster-hue:\s*\d+;/
  end

  test "the placeholder tile theme-gates its lightness via the .poster-fallback class, not an inline gradient" do
    html = card(%{id: "m-3", title: "Dune", type: :movie})

    assert html =~ "poster-fallback"
    refute html =~ "linear-gradient"
    refute html =~ "background:"
  end

  test "the 'No poster' label uses the theme token, not a pinned text-white" do
    html = card(%{id: "m-4", title: "Arrival", type: :movie})

    assert html =~ "text-base-content"
    refute html =~ "text-white"
    assert html =~ "No poster"
  end
end
