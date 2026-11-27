defmodule CinderWeb.CardigannDialog do
  @moduledoc """
  The state of the Cardigann form in the Add, Edit and Switch dialogs of
  `CinderWeb.IndexersComponent` (#1676, #1625 point 5, #1907), and its save through
  `Cinder.Indexers`.

  A Cardigann dialog is a map with `step: :form`, `type: :cardigann` and a `mode`: `:add` for a
  site picked from the add list, `:edit` for a Cardigann row, `:switch` for Switch to %{name},
  which opens a row on the definition that replaces its own. It holds:

  - `definition`, the file name the save sends, and `blob_sha`, the hash of the copy the form
    rendered, which the save carries so the store refuses it once the mirror or the pin holds
    another copy (#1620 point 4). `copy` is that loaded definition, whose `links`, settings and
    defaults the form renders. An edit whose running copy no longer parses has no `copy` and no
    hash (`broken?`): its form holds the name, priority and Enabled only.
  - `values`: the typed non-secret fields as strings, `"name"`, `"base_url"`, `"priority"`,
    `"enabled"`, `"flaresolverr"` (the toggle, #1682), plus `"settings"`, each checkbox and
    select value by setting name, and
    `"clear"`, each secret's Clear box by setting name. `change/2` and a refused `save/3` keep
    them, so a re-render shows them again. Setting names are definition text and stay strings.
  - `saved`, the setting names whose secret the indexer stores, or `:unreadable`, and `plain`,
    the names it stores as plain settings. A secret's value never enters the dialog: `save/3`
    reads the `secrets` param, keeps the keys the form renders, and hands them to the store.
    Each secret input's id, new on each open, lets the browser keep what it holds across
    patches (`phx-update="ignore"`).
  - `stored_base_url`, an edit's saved base URL, which the base URL select keeps as an option.
  - For a Switch, `hosts`: the credential hosts the save would send credentials to that the
    indexer does not send them to today (`Cinder.Indexers.switch_hosts/4`), read from the
    `lock_version`, plain attrs and secret input the save sends, on open, after a refused save
    and on each change except one that `change/2` skips; or `{:error, reason}` when the input
    of that read would be refused. A skipped change can leave the list up for an input the save
    then refuses, which reads the list again. Each host
    a secret fills shows as its template, so a typed secret never enters the dialog. The form
    draws the list's digest (`shown_digest/1`) in a hidden input, the save sends the posted one,
    and the store refuses it when the list it reads then differs.
  - `flaresolverr_url?`, whether a FlareSolverr URL is saved, read on open, on each change and
    on each save, and `flaresolverr_url`, the URL typed in the field the form shows while the
    toggle is on and none is saved; it posts under `flaresolverr[url]`. A save with the toggle
    on and no URL saved saves the typed URL first (`Cinder.Indexers.FlareSolverrUrl.put/1`),
    then the indexer, and refuses a blank or invalid one under `:flaresolverr_url`.
  - As `CinderWeb.IndexerDialog` has them: `id`, `lock_version` and `config_version` for an edit
    or a Switch, `errors`, and the `stale?` and `deleted?` flags a refused save sets.
  """

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Indexers
  alias Cinder.Indexers.{CardigannSettings, Definitions, FlareSolverrUrl}
  alias CinderWeb.IndexerFormText

  @value_keys ~w(name base_url priority enabled flaresolverr)
  @hostless_targets [["indexer", "name"], ["indexer", "priority"], ["indexer", "enabled"]]
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
      "flaresolverr" => "false",
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

  @doc """
  The Switch dialog of the Cardigann configured indexer `id` (#1907; #1616 rule 7): its form on
  the mirror's copy of the file that replaces the indexer's own. The name, priority and Enabled
  carry over; a plain setting carries over by name when the new copy's setting of that name has
  its type and accepts its value, as the save will (`CardigannSettings.switch/5`); the base URL
  is the new copy's first link.
  `{:error, :not_replaced}` when the mirror names no replacement that loads, and the deleted
  line for a deleted indexer.
  """
  @spec switch(pos_integer()) :: map() | {:error, :not_replaced}
  def switch(id) do
    with {:ok, row, stored} <- Indexers.fetch_for_edit(id),
         {:replaced_by, name} <- Definitions.name_status(row.definition),
         {:in_mirror, %{definition: %{} = definition, result: :loads} = copy} <-
           Definitions.import_copy(name) do
      {:ok, plain, _secrets} =
        CardigannSettings.switch(definition, row.settings || %{}, %{}, %{}, %{})

      values = %{row_values(row, plain) | "base_url" => List.first(definition.links || []) || ""}

      :switch
      |> form(name, copy.blob_sha, definition, values)
      |> opened(row, stored, [])
      |> with_hosts(%{})
    else
      {:error, :not_found} -> deleted()
      _other -> {:error, :not_replaced}
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
      "flaresolverr" => to_string(row.flaresolverr),
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
      hosts: [],
      stored_base_url: nil,
      errors: %{},
      stale?: false,
      deleted?: false,
      id: nil,
      lock_version: nil,
      config_version: nil,
      secret_key: System.unique_integer([:positive]),
      flaresolverr_url?: FlareSolverrUrl.get() != nil,
      flaresolverr_url: ""
    }
  end

  defp strings(plain), do: Map.new(plain, fn {name, value} -> {name, to_string(value)} end)

  @doc """
  Keeps the typed non-secret values of a `phx-change` event's `params`, and for a Switch reads
  the new hosts again from the input the save would send. A change from the name, the priority
  or Enabled, which no host reads, skips that read while `hosts` is a list (an empty one
  included), so a refusal those fields cause shows only at the next other change or the
  refused save. While `hosts` holds a refusal, which those fields can lift, it reads again.
  """
  @spec change(map(), map()) :: map()
  def change(%{mode: :switch} = dialog, params) do
    dialog = changed(dialog, params)

    if params["_target"] in @hostless_targets and is_list(dialog.hosts),
      do: dialog,
      else: with_hosts(dialog, params)
  end

  def change(dialog, params), do: changed(dialog, params)

  # The typed values, the typed FlareSolverr URL, and whether a URL is saved now.
  defp changed(dialog, params) do
    %{
      dialog
      | values: typed(dialog, params),
        flaresolverr_url: typed_url(params),
        flaresolverr_url?: FlareSolverrUrl.get() != nil
    }
  end

  defp typed_url(%{"flaresolverr" => %{"url" => url}}) when is_binary(url), do: url
  defp typed_url(_params), do: ""

  # The hosts of the input `save/3` sends for these `params`, or the save's refusal of it.
  defp with_hosts(dialog, params) do
    case Indexers.switch_hosts(
           dialog.id,
           dialog.lock_version,
           attrs(dialog),
           secrets(dialog, params)
         ) do
      {:ok, hosts} -> %{dialog | hosts: hosts}
      {:error, reason} -> %{dialog | hosts: {:error, reason}}
    end
  end

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
    dialog = changed(dialog, params)

    case save_url(dialog) do
      :ok ->
        save_indexer(%{dialog | flaresolverr_url?: FlareSolverrUrl.get() != nil}, actor, params)

      {:error, reason} ->
        {:error,
         %{dialog | errors: %{flaresolverr_url: [IndexerFormText.flaresolverr_url(reason)]}}}
    end
  end

  # With the toggle on and no URL saved, the typed URL saves first (#1682), so the URL exists
  # before the indexer's Test runs, and stays saved when the store then refuses the indexer.
  defp save_url(
         %{broken?: false, values: %{"flaresolverr" => "true"}, flaresolverr_url?: false} = dialog
       ) do
    cond do
      String.trim(dialog.flaresolverr_url) == "" -> {:error, :blank}
      FlareSolverrUrl.put(dialog.flaresolverr_url) == :ok -> :ok
      true -> {:error, :invalid}
    end
  end

  defp save_url(_dialog), do: :ok

  defp save_indexer(dialog, actor, params) do
    attrs = dialog |> attrs() |> posted_digest(dialog, params)
    secrets = if dialog.broken?, do: %{}, else: secrets(dialog, params)

    result =
      case dialog.mode do
        :add -> Indexers.create(actor, attrs, secrets)
        _edit_or_switch -> Indexers.update(actor, dialog.id, dialog.lock_version, attrs, secrets)
      end

    case result do
      {:ok, row} ->
        {:ok, row}

      {:error, :not_found} ->
        {:error, %{dialog | deleted?: true, errors: %{}, values: %{}}}

      {:error, %Ecto.Changeset{} = changeset} ->
        dialog = %{
          dialog
          | stale?: IndexerFormText.stale?(changeset),
            errors: IndexerFormText.errors(changeset, :cardigann)
        }

        {:error, refused_hosts(dialog, params)}
    end
  end

  # A refused Switch reads its hosts again from the input it sent (#1890).
  defp refused_hosts(%{mode: :switch} = dialog, params), do: with_hosts(dialog, params)
  defp refused_hosts(dialog, _params), do: dialog

  # An edit whose running copy no longer parses sends the fields its form holds and no hash, so
  # the store checks nothing against a copy (`Cinder.Indexers.update/5`). Its form holds no
  # FlareSolverr toggle, so the stored one stays.
  defp attrs(%{broken?: true, values: values}),
    do: values |> base_attrs() |> Map.delete("flaresolverr")

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
      :add ->
        Map.merge(attrs, %{"type" => "cardigann", "definition" => dialog.definition})

      :switch ->
        Map.put(attrs, "definition", dialog.definition)

      :edit ->
        attrs
    end
  end

  # A Switch's save sends the digest the form drew (`switch_hosts_digest`), not the one of the
  # dialog's last list: a submit can leave the browser before the re-render of a change the
  # server already read, and the store then refuses the list the admin did not see.
  defp posted_digest(attrs, %{mode: :switch}, params) do
    digest = if is_binary(params["switch_hosts_digest"]), do: params["switch_hosts_digest"]
    Map.put(attrs, "switch_hosts_digest", digest)
  end

  defp posted_digest(attrs, _dialog, _params), do: attrs

  @doc """
  The digest of the Switch host list `hosts` the form draws, which its save sends; nil while it
  draws none, which the store refuses.
  """
  @spec shown_digest([Cinder.Indexers.Definitions.CredentialHosts.host()] | {:error, term()}) ::
          String.t() | nil
  def shown_digest(hosts) when is_list(hosts), do: Indexers.hosts_digest(hosts)
  def shown_digest(_refused), do: nil

  defp base_attrs(values),
    do: %{
      "name" => values["name"],
      "priority" => values["priority"],
      "enabled" => values["enabled"] == "true",
      "flaresolverr" => values["flaresolverr"] == "true"
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
  create, and after an edit or a Switch that raised `config_version`.
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
  Whether the indexer stores a secret for the setting `name`: a Switch carries a stored secret
  by name onto a secret setting of the new copy. True for every secret when the stored secrets
  do not decrypt.
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

  @doc """
  Whether the dialog's copy logs in through a `form` login that shows an image captcha (#1681),
  which the admin solves in the Edit dialog.
  """
  @spec captcha?(map()) :: boolean()
  def captcha?(%{copy: copy}), do: Cardigann.image_captcha?(copy)
  def captcha?(_dialog), do: false

  @doc "Each field a refusal moves focus to, in the form's order, with its input's id."
  @spec field_ids(map()) :: [{atom(), String.t()}]
  def field_ids(_dialog) do
    [
      name: "indexer-form-name",
      base_url: "indexer-form-base-url",
      flaresolverr_url: "indexer-form-flaresolverr-url",
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
