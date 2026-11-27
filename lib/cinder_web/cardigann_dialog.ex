defmodule CinderWeb.CardigannDialog do
  @moduledoc """
  The state of the Cardigann form in the Add and Edit dialogs of `CinderWeb.IndexersComponent`
  (#1676, #1625 point 5), and its save through `Cinder.Indexers`.

  A Cardigann dialog is a map with `step: :form`, `type: :cardigann` and a `mode`: `:add` for a
  site picked from the add list, `:edit` for a Cardigann row. It holds:

  - `definition`, the file name the save sends, and `blob_sha`, the hash of the copy the form
    rendered, which the save carries so the store refuses it once the mirror or the pin holds
    another copy (#1620 point 4). `copy` is that loaded definition, whose `links`, settings and
    defaults the form renders. An edit whose running copy no longer parses has no `copy` and no
    hash (`broken?`): its form holds the name, priority and Enabled only.
  - `values`: the typed non-secret fields as strings, `"name"`, `"base_url"`, `"priority"`,
    `"enabled"`, plus `"settings"`, each checkbox and select value by setting name, and
    `"clear"`, each secret's Clear box by setting name. `change/2` and a refused `save/3` keep
    them, so a re-render shows them again. Setting names are definition text and stay strings.
  - `saved`, the setting names whose secret the indexer stores, or `:unreadable`, and `plain`,
    the names it stores as plain settings. A secret's value never enters the dialog: `save/3`
    reads the `secrets` param, keeps the keys the form renders, and hands them to the store.
    Each secret input's id, new on each open, lets the browser keep what it holds across
    patches (`phx-update="ignore"`).
  - `stored_base_url`, an edit's saved base URL, which the base URL select keeps as an option.
  - As `CinderWeb.IndexerDialog` has them: `id`, `lock_version` and `config_version` for an edit,
    `errors`, and the `stale?` and `deleted?` flags a refused save sets.
  """

  alias Cinder.Indexers
  alias Cinder.Indexers.{CardigannSettings, Definitions}
  alias CinderWeb.IndexerFormText

  @value_keys ~w(name base_url priority enabled)
  @secret_types ["text", "password"]
  @label_types ["info_useragent", "info_category_8000"]

  @doc """
  The Add dialog's form for the mirror's file `name`, whose copy `import_copy/1` read as
  `%{blob_sha:, definition:}`: the definition's name, its first link, every setting's default,
  priority 25 and enabled.
  """
  @spec add(String.t(), %{blob_sha: String.t(), definition: map()}) :: map()
  def add(name, %{blob_sha: blob_sha, definition: definition}) do
    {:ok, plain, _secrets} = CardigannSettings.create(definition, %{}, %{})

    form(:add, name, blob_sha, definition, %{
      "name" => definition.name,
      "base_url" => List.first(definition.links || []) || "",
      "priority" => "25",
      "enabled" => "true",
      "settings" => strings(plain)
    })
  end

  @doc """
  The Edit dialog's form for the Cardigann configured indexer `id`, on the copy it runs; a
  deleted one opens on the deleted line, and one whose running copy no longer parses opens with
  no copy.
  """
  @spec edit(pos_integer()) :: map()
  def edit(id) do
    case Indexers.fetch_for_edit(id) do
      {:ok, row, stored} ->
        {blob_sha, definition} = running_copy(row.id)

        dialog =
          :edit
          |> form(row.definition, blob_sha, definition, row_values(row, row.settings || %{}))
          |> opened(row, stored, Map.keys(row.settings || %{}))

        %{dialog | stored_base_url: row.base_url}

      {:error, :not_found} ->
        deleted()
    end
  end

  # The copy the indexer runs, or none when it no longer parses.
  defp running_copy(id) do
    case Definitions.running_copy(id) do
      {:ok, copy} -> {copy.blob_sha, copy.definition}
      {:error, _reason} -> {nil, nil}
    end
  end

  defp row_values(row, plain) do
    %{
      "name" => row.name,
      "base_url" => row.base_url,
      "priority" => Integer.to_string(row.priority),
      "enabled" => to_string(row.enabled),
      "settings" => strings(plain)
    }
  end

  defp opened(dialog, row, stored, plain_names) do
    %{
      dialog
      | id: row.id,
        lock_version: row.lock_version,
        config_version: row.config_version,
        saved: stored,
        plain: plain_names
    }
  end

  defp deleted, do: %{form(:edit, nil, nil, nil, %{}) | deleted?: true}

  defp form(mode, definition, blob_sha, copy, values) do
    %{
      step: :form,
      type: :cardigann,
      mode: mode,
      definition: definition,
      blob_sha: blob_sha,
      copy: copy,
      broken?: mode == :edit and copy == nil,
      values: Map.merge(%{"settings" => %{}, "clear" => %{}}, values),
      saved: [],
      plain: [],
      stored_base_url: nil,
      errors: %{},
      stale?: false,
      deleted?: false,
      id: nil,
      lock_version: nil,
      config_version: nil,
      secret_key: System.unique_integer([:positive])
    }
  end

  defp strings(plain), do: Map.new(plain, fn {name, value} -> {name, to_string(value)} end)

  @doc "Keeps the typed non-secret values of a `phx-change` event's `params`."
  @spec change(map(), map()) :: map()
  def change(dialog, params), do: %{dialog | values: typed(dialog, params)}

  # Only text values under the keys the form renders: a payload of any other shape changes
  # nothing.
  defp typed(dialog, params) do
    input = form_input(params, "indexer")
    values = dialog.values

    values =
      for {key, value} <- input, key in @value_keys, is_binary(value), into: values do
        {key, value}
      end

    settings =
      for {key, value} <- form_input(input, "settings"),
          key in names(dialog, :plain),
          is_binary(value),
          into: values["settings"],
          do: {key, value}

    clear =
      for name <- names(dialog, :secret),
          value = form_input(params, "secrets")["clear_" <> name],
          is_binary(value),
          into: values["clear"],
          do: {name, value}

    %{values | "settings" => settings, "clear" => clear}
  end

  defp form_input(params, key) do
    case params do
      %{^key => %{} = input} -> input
      _other -> %{}
    end
  end

  @doc """
  Saves the form with the typed values of `params` and its secret input: `{:ok, row}`, or
  `{:error, dialog}` holding the refusal and the typed values.
  """
  @spec save(map(), term(), map()) :: {:ok, map()} | {:error, map()}
  def save(dialog, actor, params) do
    dialog = %{dialog | values: typed(dialog, params)}
    attrs = attrs(dialog)
    secrets = if dialog.broken?, do: %{}, else: secrets(dialog, params)

    result =
      case dialog.mode do
        :add -> Indexers.create(actor, attrs, secrets)
        :edit -> Indexers.update(actor, dialog.id, dialog.lock_version, attrs, secrets)
      end

    case result do
      {:ok, row} ->
        {:ok, row}

      {:error, :not_found} ->
        {:error, %{dialog | deleted?: true, errors: %{}, values: %{}}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{
           dialog
           | stale?: IndexerFormText.stale?(changeset),
             errors: IndexerFormText.errors(changeset, :cardigann)
         }}
    end
  end

  # An edit whose running copy no longer parses sends the fields its form holds and no hash, so
  # the store checks nothing against a copy (`Cinder.Indexers.update/5`).
  defp attrs(%{broken?: true, values: values}), do: base_attrs(values)

  defp attrs(dialog) do
    attrs =
      dialog.values
      |> base_attrs()
      |> Map.merge(%{
        "base_url" => dialog.values["base_url"],
        "definition_blob_sha" => dialog.blob_sha,
        "settings" => Map.take(dialog.values["settings"], names(dialog, :plain))
      })

    case dialog.mode do
      :add -> Map.merge(attrs, %{"type" => "cardigann", "definition" => dialog.definition})
      :edit -> attrs
    end
  end

  defp base_attrs(values),
    do: %{
      "name" => values["name"],
      "priority" => values["priority"],
      "enabled" => values["enabled"] == "true"
    }

  # Each secret the form renders, as typed, and its Clear box; any other key or shape is left
  # out. A blank input keeps the stored secret, or stores the copy's default on a create.
  defp secrets(dialog, params) do
    allowed = Enum.flat_map(names(dialog, :secret), &[&1, "clear_" <> &1])

    for {key, value} <- form_input(params, "secrets"),
        key in allowed,
        is_binary(value),
        into: %{},
        do: {key, value}
  end

  @doc """
  Whether a save of this dialog that answered `row` starts a Test, `row` being enabled: after a
  create, and after an edit that raised `config_version`.
  """
  @spec test_on_save?(map(), map()) :: boolean()
  def test_on_save?(%{mode: :add}, _row), do: true
  def test_on_save?(%{config_version: opened}, row), do: row.config_version > opened

  @doc """
  What the form renders for each of the copy's settings, in file order: `{index, setting,
  control}`, `control` one of `:secret`, `:checkbox`, `:select`, `:plain_text` (a setting the
  indexer stores plain whose copy now types it as text), `:info`, `:label` and `:cookie_help`
  (an `info_cookie` setting, which no v11 definition labels, so the form words it itself). An
  `info_flaresolverr` setting, an `info` one with neither label nor text, an `info_*` label
  setting with no label, and a type the engine does not know render nothing; an empty or blank
  label or text counts as none (`text?/1`). A setting the indexer stores keeps the class it was
  saved under (`CardigannSettings`).
  """
  @spec controls(map()) :: [{non_neg_integer(), map(), atom()}]
  def controls(%{copy: nil}), do: []

  def controls(dialog) do
    for {setting, index} <- Enum.with_index(dialog.copy.settings || []),
        control = control(dialog, setting),
        control != nil,
        do: {index, setting, control}
  end

  defp control(_dialog, %{type: "info"} = setting),
    do: if(text?(setting.label) or text?(setting.default), do: :info)

  defp control(_dialog, %{type: "info_cookie"}), do: :cookie_help

  defp control(_dialog, %{type: type} = setting) when type in @label_types,
    do: if(text?(setting.label), do: :label)

  defp control(dialog, %{name: name, type: type}) do
    cond do
      name in dialog.plain -> plain_control(type)
      secret_name?(dialog, name) or type in @secret_types -> :secret
      true -> input_control(type)
    end
  end

  # A setting the indexer stores plain: a copy that now types it as text shows the stored text.
  defp plain_control(type) when type in @secret_types, do: :plain_text
  defp plain_control(type), do: input_control(type)

  defp input_control("checkbox"), do: :checkbox
  defp input_control("select"), do: :select
  defp input_control(_type), do: nil

  # A stored secret keeps its class whatever type the copy gives it, as the store reads it.
  defp secret_name?(%{mode: :edit, saved: names}, name) when is_list(names), do: name in names
  defp secret_name?(_dialog, _name), do: false

  defp names(dialog, :plain) do
    for {_index, %{name: name}, control} <- controls(dialog),
        control in [:checkbox, :select, :plain_text],
        do: name
  end

  defp names(dialog, :secret) do
    for {_index, %{name: name}, :secret} <- controls(dialog), do: name
  end

  @doc "Whether a setting's label or text has something to show: not nil and not blank."
  @spec text?(term()) :: boolean()
  def text?(text), do: is_binary(text) and String.trim(text) != ""

  @doc """
  The words a setting's control is labelled with: its label when that has text (`text?/1`),
  else its name, so an empty label still leaves the control a name (#1892).
  """
  @spec label(map()) :: String.t()
  def label(%{name: name} = setting),
    do: if(text?(Map.get(setting, :label)), do: setting.label, else: name)

  @doc """
  A select setting's options as `{text, key}`: each option's label when it has text
  (`text?/1`), else its key, so an empty label still leaves the option words.
  """
  @spec options(map()) :: [{String.t(), String.t()}]
  def options(setting) do
    for {key, label} <- Map.get(setting, :options) || [],
        do: {if(text?(label), do: label, else: key), key}
  end

  @doc """
  Whether the indexer stores a secret for the setting `name`. True for every secret when the
  stored secrets do not decrypt.
  """
  @spec saved?(map(), String.t()) :: boolean()
  def saved?(%{saved: :unreadable}, _name), do: true
  def saved?(%{saved: names}, name), do: name in names

  @doc "The id of the secret input of the setting at `index`, new on each open."
  @spec secret_id(map(), non_neg_integer()) :: String.t()
  def secret_id(dialog, index), do: "indexer-form-secret-#{index}-#{dialog.secret_key}"

  @doc """
  The base URL select's options: the copy's links, and first an edit's stored base URL when it
  is not one of them, so a save does not move it silently. A typed base URL is never an option:
  a refused one can carry a credential (#1697).
  """
  @spec base_url_options(map()) :: [String.t()]
  def base_url_options(%{copy: nil}), do: []

  def base_url_options(dialog) do
    links = dialog.copy.links || []
    stored = dialog.stored_base_url
    if stored in [nil, ""] or stored in links, do: links, else: [stored | links]
  end

  @doc "Each field a refusal moves focus to, in the form's order, with its input's id."
  @spec field_ids(map()) :: [{atom(), String.t()}]
  def field_ids(_dialog) do
    [
      name: "indexer-form-name",
      base_url: "indexer-form-base-url",
      priority: "indexer-form-priority",
      enabled: "indexer-form-enabled"
    ]
  end

  @doc """
  The form of the dialog's typed fields, as `indexer[...]` fields, each carrying the messages of
  its refusals (see `CinderWeb.IndexerDialog.to_form/1`). The settings render apart.
  """
  @spec to_form(map()) :: Phoenix.HTML.Form.t()
  def to_form(dialog) do
    errors =
      for {field, messages} <- dialog.errors,
          field != :form,
          message <- messages,
          do: {field, {message, []}}

    Phoenix.Component.to_form(Map.take(dialog.values, @value_keys), as: :indexer, errors: errors)
  end
end
