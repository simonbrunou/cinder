defmodule CinderWeb.IndexerSourceFieldTest do
  # The Indexers group's source select of `SettingsComponents.service_fields/1` (#1662), rendered
  # alone: a host that passes no `indexer_source` gets no select, and a rejected value shows the
  # host's refusal text when it has one, else the shape's message.
  use Cinder.DataCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Cinder.Settings
  alias CinderWeb.SettingsComponents

  @source %{saved: "prowlarr", prowlarr_url?: false, error: nil}

  defp render_fields(assigns) do
    assigns = Map.merge(%{form: Settings.form_state(), health: %{}, indexers: []}, assigns)

    SettingsComponents
    |> Function.capture(:service_fields, 1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp query(doc, selector), do: LazyHTML.query(doc, selector)
  defp text(doc, selector), do: doc |> query(selector) |> LazyHTML.text() |> String.trim()

  defp rejected_form, do: Settings.form_state(%{"indexer_source" => "native"}, ["indexer_source"])

  test "renders no select when the host passes no indexer_source" do
    doc = render_fields(%{})

    # Positive control: the Indexers group renders.
    assert Enum.count(query(doc, "#settings-group-indexer")) == 1
    assert Enum.empty?(query(doc, "#indexer_source"))
  end

  test "renders the select first in the Indexers group when the host passes indexer_source" do
    doc = render_fields(%{indexer_source: @source})

    assert Enum.count(
             query(
               doc,
               "#settings-group-indexer > .collapse-content > :first-child #indexer_source"
             )
           ) == 1

    assert Enum.empty?(query(doc, "#indexer_source-error"))
  end

  test "a rejected value with the host's refusal shows that text in place of the shape's" do
    doc =
      render_fields(%{form: rejected_form(), indexer_source: %{@source | error: "Refused here."}})

    assert text(doc, "#indexer_source-error") == "Refused here."
    assert LazyHTML.attribute(query(doc, "#indexer_source"), "aria-invalid") == ["true"]
  end

  test "a rejected value with no refusal shows the shape's message" do
    doc = render_fields(%{form: rejected_form(), indexer_source: @source})

    assert text(doc, "#indexer_source-error") == "Choose a listed indexer source."
    assert LazyHTML.attribute(query(doc, "#indexer_source"), "aria-invalid") == ["true"]
  end
end
