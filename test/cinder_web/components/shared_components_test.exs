defmodule CinderWeb.SharedComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Phoenix.Component

  alias CinderWeb.CoreComponents

  describe "confirm_action/1" do
    defp confirm(assigns) do
      render_component(
        fn assigns ->
          ~H"""
          <CoreComponents.confirm_action
            id={@id}
            on_confirm={@on_confirm}
            on_cancel={@on_cancel}
            value={@value}
            confirm_label={@confirm_label}
          >
            <:caveat>{@caveat}</:caveat>
          </CoreComponents.confirm_action>
          """
        end,
        assigns
      )
    end

    test "renders an alert with caveat, confirm and cancel wired to the given events" do
      html =
        confirm(%{
          id: "confirm-delete-7",
          on_confirm: "confirm_delete",
          on_cancel: "dismiss_confirm",
          value: 7,
          confirm_label: "Delete",
          caveat: "Delete this movie's record? (Library files are left on disk.)"
        })

      assert html =~ ~s(role="alert")
      assert html =~ "Library files are left on disk"
      assert html =~ ~s(phx-click="confirm_delete")
      assert html =~ ~s(phx-value-id="7")
      assert html =~ ~s(phx-click="dismiss_confirm")
      assert html =~ "Delete"
      assert html =~ "Cancel"
    end
  end
end
