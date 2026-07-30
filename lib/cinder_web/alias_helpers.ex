defmodule CinderWeb.AliasHelpers do
  @moduledoc """
  The manual title-alias CRUD shared verbatim by the movie and series detail
  LiveViews (#211): the `save_alias` / `edit_alias` / `cancel_alias_edit` /
  `delete_alias` event bodies plus the alias form and kind-label plumbing.
  Every function takes the owning struct (`%Movie{}` or `%Series{}`); the
  event helpers return the `{:noreply, socket}` the view's `handle_event/3`
  hands back unchanged. `refresh` is the view's own `refresh_identity/2`, so
  a successful write re-renders through the view's normal reload path.
  """
  use Gettext, backend: CinderWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Cinder.Catalog

  def save_alias(socket, owner, params, refresh) do
    result =
      case params["id"] do
        id when id in [nil, ""] -> Catalog.save_manual_alias(owner, params)
        id -> update_current_alias(owner, parse_alias_id(id), params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:alias_form, alias_form())
         |> refresh.(owner)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:alias_form, alias_form(params))
         |> put_flash(:error, gettext("Couldn't save the alias."))}

      _ ->
        {:noreply, socket}
    end
  end

  def edit_alias(socket, owner, id) do
    with id when not is_nil(id) <- parse_alias_id(id),
         alias_record when not is_nil(alias_record) <- current_manual_alias(owner, id) do
      {:noreply, assign(socket, :alias_form, alias_form(alias_record))}
    else
      _ -> {:noreply, socket}
    end
  end

  def cancel_alias_edit(socket), do: {:noreply, assign(socket, :alias_form, alias_form())}

  def delete_alias(socket, owner, id, refresh) do
    with id when not is_nil(id) <- parse_alias_id(id),
         alias_record when not is_nil(alias_record) <- current_manual_alias(owner, id),
         {:ok, _} <- Catalog.delete_manual_alias(owner, alias_record.id) do
      {:noreply, refresh.(socket, owner)}
    else
      _ -> {:noreply, socket}
    end
  end

  def alias_form(params \\ %{})

  def alias_form(%Cinder.Catalog.TitleAlias{} = alias_record) do
    alias_form(%{
      "id" => alias_record.id,
      "title" => alias_record.title,
      "kind" => alias_record.kind,
      "country_code" => alias_record.country_code,
      "language_code" => alias_record.language_code
    })
  end

  def alias_form(params) do
    defaults = %{
      "id" => "",
      "title" => "",
      "kind" => "alternative",
      "country_code" => "",
      "language_code" => ""
    }

    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)
    to_form(Map.merge(defaults, params), as: :alias)
  end

  def alias_kind_options do
    [
      {gettext("Alternative"), "alternative"},
      {gettext("Native"), "native"},
      {gettext("Romaji"), "romaji"},
      {gettext("Licensed"), "licensed"},
      {gettext("Scene"), "scene"}
    ]
  end

  def alias_kind_label(:alternative), do: gettext("Alternative")
  def alias_kind_label(:native), do: gettext("Native")
  def alias_kind_label(:romaji), do: gettext("Romaji")
  def alias_kind_label(:licensed), do: gettext("Licensed")
  def alias_kind_label(:scene), do: gettext("Scene")

  defp update_current_alias(owner, id, params) do
    case current_manual_alias(owner, id) do
      nil -> {:error, :not_manual_alias}
      alias_record -> Catalog.update_manual_alias(owner, alias_record.id, params)
    end
  end

  defp current_manual_alias(owner, id) do
    Enum.find(Catalog.list_title_aliases(owner), &(&1.id == id and &1.precedence == :manual))
  end

  defp parse_alias_id(id) when is_integer(id), do: id

  defp parse_alias_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_alias_id(_id), do: nil
end
