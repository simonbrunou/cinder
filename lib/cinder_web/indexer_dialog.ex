defmodule CinderWeb.IndexerDialog do
  @moduledoc """
  The state of the Add and Edit dialogs' Newznab and Torznab form in `CinderWeb.IndexersComponent`
  (#1661), and its save through `Cinder.Indexers`.

  A form dialog is a map with `step: :form`, its `mode` (`:add` or `:edit`), the `type` step 1
  picked or the row holds, and `values`: the typed non-secret fields as strings, keyed
  `"name"`, `"base_url"`, `"api_path"`, `"additional_parameters"`, `"priority"`, `"enabled"`, and
  the Clear box's `"clear_api_key"`. `change/2` and a failed `save/3` keep the typed values in
  it, so a re-render, a Test's finish included, renders them again. The exception is a refused
  base URL, API path or additional parameters value, which can carry a credential (#1697): a
  failed `save/3` empties each one the store refused, so its input renders empty with its error.
  The save's reply empties that input in the browser also while it has focus, as after a submit
  with Enter from it (`.github/scripts/browser_lifecycle.py` case 14). A save of an indexer
  deleted in another tab keeps no typed value, since the deleted line replaces the form. The
  secret input's value is
  never kept: `save/3` reads it from the event's `secrets` param and hands it to the store, and
  the input's `secret_id`, new on each open, lets the browser keep what it holds across patches
  (`phx-update="ignore"`).

  An edit dialog also holds the `lock_version` and `config_version` the row had when it opened,
  `stored_secrets` (the secret field names it holds, or `:unreadable`), and the flags `stale?`
  and `deleted?` that a refused save sets. The type is never read from the form.
  """

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Indexers
  alias CinderWeb.IndexerFormText

  @value_keys ~w(name base_url api_path additional_parameters priority enabled)

  # The value key each refused store field empties.
  @refused_value_keys %{
    base_url: "base_url",
    api_path: "api_path",
    settings: "additional_parameters"
  }

  @doc "A new Add dialog's form for `type`: priority 25, enabled, API path `/api`."
  @spec add(atom()) :: map()
  def add(type) do
    form(:add, type, %{
      "name" => "",
      "base_url" => "",
      "api_path" => "/api",
      "additional_parameters" => "",
      "priority" => "25",
      "enabled" => "true"
    })
  end

  @doc """
  The Edit dialog's form for the configured indexer `id`, as the store holds it now; a deleted
  one opens on the deleted line.
  """
  @spec edit(pos_integer()) :: map()
  def edit(id) do
    case Indexers.fetch_for_edit(id) do
      {:ok, row, stored} ->
        :edit
        |> form(row.type, %{
          "name" => row.name,
          "base_url" => row.base_url,
          "api_path" => row.api_path || "",
          "additional_parameters" => Map.get(row.settings || %{}, "additional_parameters", ""),
          "priority" => Integer.to_string(row.priority),
          "enabled" => to_string(row.enabled)
        })
        |> Map.merge(%{
          id: row.id,
          lock_version: row.lock_version,
          config_version: row.config_version,
          stored_secrets: stored
        })

      {:error, :not_found} ->
        %{form(:edit, nil, %{}) | deleted?: true}
    end
  end

  defp form(mode, type, values) do
    %{
      step: :form,
      mode: mode,
      type: type,
      values: Map.put(values, "clear_api_key", "false"),
      errors: %{},
      stale?: false,
      deleted?: false,
      id: nil,
      lock_version: nil,
      config_version: nil,
      stored_secrets: [],
      secret_id: "indexer-form-api-key-#{System.unique_integer([:positive])}",
      prowlarr_url: Prowlarr.saved_base_url()
    }
  end

  @doc "Keeps the typed non-secret values of a `phx-change` event's `params`."
  @spec change(map(), map()) :: map()
  def change(dialog, params), do: %{dialog | values: typed(dialog.values, params)}

  # Only text values under the known keys: a payload of any other shape changes nothing.
  defp typed(values, params) do
    values =
      for {key, value} <- form_input(params, "indexer"),
          key in @value_keys,
          is_binary(value),
          into: values,
          do: {key, value}

    case form_input(params, "secrets") do
      %{"clear_api_key" => clear} when is_binary(clear) -> Map.put(values, "clear_api_key", clear)
      _other -> values
    end
  end

  defp form_input(params, key) do
    case params do
      %{^key => %{} = input} -> input
      _other -> %{}
    end
  end

  @doc """
  Saves the form with the typed values of `params` and its secret input: `{:ok, row}`, or
  `{:error, dialog}` holding the refusal and the typed values, each refused base URL, API path
  or additional parameters value emptied.
  """
  @spec save(map(), term(), map()) :: {:ok, map()} | {:error, map()}
  def save(dialog, actor, params) do
    dialog = change(dialog, params)
    attrs = attrs(dialog.type, dialog.values)
    secrets = secrets(params)

    result =
      case dialog.mode do
        :add ->
          Indexers.create(actor, Map.put(attrs, "type", Atom.to_string(dialog.type)), secrets)

        :edit ->
          Indexers.update(actor, dialog.id, dialog.lock_version, attrs, secrets)
      end

    case result do
      {:ok, row} ->
        {:ok, row}

      # The deleted line replaces the form, so no typed value is kept for it.
      {:error, :not_found} ->
        {:error, %{dialog | deleted?: true, errors: %{}, values: %{}}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{
           dialog
           | values: Map.merge(dialog.values, Map.new(refused_value_keys(changeset), &{&1, ""})),
             stale?: IndexerFormText.stale?(changeset),
             errors: IndexerFormText.errors(changeset, dialog.type)
         }}
    end
  end

  # The value keys of the refused fields, read from the store's errors: a Torznab settings
  # refusal, which the form shows above the fields, still empties its key.
  defp refused_value_keys(changeset) do
    changeset.errors
    |> Enum.flat_map(fn {field, _error} -> List.wrap(@refused_value_keys[field]) end)
    |> Enum.uniq()
  end

  @doc """
  Whether a save of this dialog that answered `row` starts a Test, `row` being enabled: after a
  create, and after an edit that raised `config_version` (a base URL, API path, settings or
  secret change).
  """
  @spec test_on_save?(map(), map()) :: boolean()
  def test_on_save?(%{mode: :add}, _row), do: true
  def test_on_save?(%{mode: :edit, config_version: opened}, row), do: row.config_version > opened

  # The Newznab form's blank additional parameters store no key, so an edit that leaves the field
  # blank changes no setting; the Torznab form sends no settings at all.
  defp attrs(type, values) do
    attrs = %{
      "name" => values["name"],
      "base_url" => values["base_url"],
      "api_path" => values["api_path"],
      "priority" => values["priority"],
      "enabled" => values["enabled"] == "true"
    }

    if type == :newznab,
      do: Map.put(attrs, "settings", settings(values["additional_parameters"] || "")),
      else: attrs
  end

  defp settings(parameters) do
    if String.trim(parameters) == "",
      do: %{},
      else: %{"additional_parameters" => parameters}
  end

  # The API key as typed, and the Clear box; any other key or shape is left out.
  defp secrets(params) do
    for {key, value} <- form_input(params, "secrets"),
        key in ["api_key", "clear_api_key"],
        is_binary(value),
        into: %{},
        do: {key, value}
  end

  @doc """
  The form of the dialog's typed values, as `indexer[...]` fields, each carrying the messages of
  its refusals. The messages are already translated (`CinderWeb.IndexerFormText`), so each goes
  out with no bindings, and `translate_error/1` of `CinderWeb.CoreComponents` answers it
  unchanged: no `errors` domain msgstr turns a translated message into another. The API key and
  a refusal shown above the fields are rendered apart.
  """
  @spec to_form(map()) :: Phoenix.HTML.Form.t()
  def to_form(dialog) do
    errors =
      for {field, messages} <- dialog.errors,
          field not in [:form, :api_key],
          message <- messages,
          do: {field, {message, []}}

    Phoenix.Component.to_form(Map.delete(dialog.values, "clear_api_key"),
      as: :indexer,
      errors: errors
    )
  end

  @doc "Whether the indexer holds a saved API key, or secrets that do not decrypt."
  @spec key_saved?(map()) :: boolean()
  def key_saved?(%{stored_secrets: :unreadable}), do: true
  def key_saved?(%{stored_secrets: names}), do: "api_key" in names

  @doc "Each field the form renders, in the form's order, with its input's id."
  @spec field_ids(map()) :: [{atom(), String.t()}]
  def field_ids(dialog) do
    [
      name: "indexer-form-name",
      base_url: "indexer-form-base-url",
      api_path: "indexer-form-api-path",
      api_key: dialog.secret_id,
      additional_parameters: "indexer-form-additional-parameters",
      priority: "indexer-form-priority",
      enabled: "indexer-form-enabled"
    ]
  end

  @doc "Whether the typed base URL and API path are searched through the saved Prowlarr URL."
  @spec through_prowlarr?(map()) :: boolean()
  def through_prowlarr?(dialog),
    do:
      Indexers.through_prowlarr?(
        dialog.values["base_url"],
        dialog.values["api_path"],
        dialog.prowlarr_url
      )
end
