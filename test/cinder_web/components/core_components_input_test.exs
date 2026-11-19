defmodule CinderWeb.CoreComponentsInputTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import CinderWeb.CoreComponents, only: [input: 1]

  # One `<.input>` call site per clause that wires the error node (`input_attrs/3`), so the
  # caller's extra attributes reach the component as `@rest`, as they do in a template.
  defp render(type, assigns) do
    assigns = Map.merge(%{described_by: nil, invalid: nil, errors: []}, assigns)

    html =
      case type do
        "text" ->
          ~H"""
          <.input
            id="f"
            name="f"
            value=""
            errors={@errors}
            aria-describedby={@described_by}
            aria-invalid={@invalid}
          />
          """

        "checkbox" ->
          ~H"""
          <.input
            type="checkbox"
            id="f"
            name="f"
            value={false}
            errors={@errors}
            aria-describedby={@described_by}
            aria-invalid={@invalid}
          />
          """

        "select" ->
          ~H"""
          <.input
            type="select"
            id="f"
            name="f"
            value="a"
            options={[{"A", "a"}]}
            errors={@errors}
            aria-describedby={@described_by}
            aria-invalid={@invalid}
          />
          """

        "textarea" ->
          ~H"""
          <.input
            type="textarea"
            id="f"
            name="f"
            value=""
            errors={@errors}
            aria-describedby={@described_by}
            aria-invalid={@invalid}
          />
          """
      end

    tag = html |> rendered_to_string() |> LazyHTML.from_fragment() |> LazyHTML.query("#f")
    1 = Enum.count(tag)

    %{
      invalid: List.first(LazyHTML.attribute(tag, "aria-invalid")),
      described_by: List.first(LazyHTML.attribute(tag, "aria-describedby"))
    }
  end

  @types ~w(text checkbox select textarea)

  test "a caller's aria-describedby comes first and keeps the error node after it" do
    for type <- @types do
      assert render(type, %{described_by: "hint"}) == %{invalid: nil, described_by: "hint"},
             type

      assert render(type, %{described_by: "hint", errors: ["bad"]}) ==
               %{invalid: "true", described_by: "hint f-error"},
             type
    end
  end

  test "with no caller description, errors alone set the error node, and no errors set nothing" do
    for type <- @types do
      assert render(type, %{}) == %{invalid: nil, described_by: nil}, type

      assert render(type, %{errors: ["bad"]}) == %{invalid: "true", described_by: "f-error"},
             type
    end
  end

  test "a caller's aria-invalid stays when the input has no errors" do
    for type <- @types do
      assert render(type, %{invalid: "true"}) == %{invalid: "true", described_by: nil}, type
    end
  end
end
