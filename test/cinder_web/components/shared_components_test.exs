defmodule CinderWeb.SharedComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Phoenix.Component

  alias CinderWeb.CoreComponents

  describe "interactive target sizing" do
    test "compact buttons keep a 24px minimum target" do
      for size <- ["xs", "sm"] do
        html =
          render_component(&CoreComponents.button/1, %{
            size: size,
            inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Test" end}]
          })

        assert html =~ "min-h-6"
        assert html =~ "min-w-6"
      end
    end

    test "primary buttons and flash dismiss controls meet their target policy" do
      button =
        render_component(&CoreComponents.button/1, %{
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Save" end}]
        })

      flash =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Saved" end}]
        })

      assert button =~ "min-h-11"
      assert flash =~ "min-h-6"
      assert flash =~ "min-w-6"
    end
  end

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

  describe "empty_state/1" do
    test "default no-results state shows title, message and a neutral icon" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          title: "Nothing here yet",
          message: "Search above to add a movie.",
          icon: "hero-bookmark"
        })

      assert html =~ "Nothing here yet"
      assert html =~ "Search above to add a movie"
      assert html =~ "hero-bookmark"
      refute html =~ "text-error"
    end

    test "search-error variant is visually distinct (error icon + colour)" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          title: "Search failed",
          message: "TMDB didn't respond. Try again.",
          variant: "search-error"
        })

      assert html =~ "Search failed"
      assert html =~ "text-error"
      assert html =~ "hero-exclamation-triangle"
    end
  end
end
