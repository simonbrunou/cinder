defmodule CinderWeb.ProwlarrImportText do
  @moduledoc """
  Words the codes of `Cinder.Indexers.ProwlarrImport` for the Import from Prowlarr dialog
  (#1674): the errors of `preview/0` and `commit/3`, what each preview row becomes and why, the
  settings it does not carry, the errors a refused commit gives a row, and the report's lines
  (docs/agents/architecture.md "Translation stays in the web layer").
  """
  use Gettext, backend: CinderWeb.Gettext

  alias Cinder.Indexers.ProwlarrImport.Row
  alias CinderWeb.{IndexerFormText, IndexerStateText}

  @doc "The text of an error tag of `preview/0` or `commit/3`."
  @spec error(term()) :: String.t()
  def error(:not_configured), do: gettext("Save Prowlarr's URL and API key first.")
  def error(:timeout), do: gettext("Couldn't reach Prowlarr. Try again.")
  def error(:transport), do: gettext("Couldn't reach Prowlarr. Try again.")

  def error({:http_status, 401}),
    do: gettext("Prowlarr refused the API key. Check it in the Indexers group.")

  def error({:http_status, _status}), do: unreadable()
  def error(:too_large), do: unreadable()
  def error(:invalid_json), do: unreadable()
  def error(:unexpected_response), do: unreadable()

  def error(:import_running),
    do: gettext("Another import is running. Try again when it ends.")

  def error(:nothing_ticked), do: gettext("Tick at least one indexer to import.")

  def error(:audit_refused),
    do: gettext("The import could not be saved, so nothing was imported. Try again.")

  def error(:changed), do: gettext("Prowlarr or a definition changed: check the preview again.")

  # A tag the import may add later: a crash would log the event's params, typed keys included.
  def error(_tag), do: gettext("The import failed. Try again.")

  defp unreadable, do: gettext("Prowlarr gave an answer Cinder can't read.")

  @doc "What the row becomes, or why it is not imported."
  @spec becomes(Row.t()) :: String.t()
  def becomes(%Row{state: :direct, type: type}),
    do: gettext("%{kind}, searched by Cinder", kind: kind(type))

  def becomes(%Row{state: :via_prowlarr, type: type}),
    do: gettext("%{kind}, searched through Prowlarr", kind: kind(type))

  def becomes(%Row{state: :held}),
    do: gettext("Not imported: indexer definitions not loaded yet")

  def becomes(%Row{state: :already_imported}), do: gettext("Already imported")
  def becomes(%Row{state: :refused}), do: gettext("Can't be imported")

  defp kind(:newznab), do: "Newznab"
  defp kind(:torznab), do: "Torznab"
  defp kind(:cardigann), do: "Cardigann"

  @doc "Each reason of a through-Prowlarr or refused row, in order."
  @spec reasons(Row.t()) :: [String.t()]
  def reasons(%Row{state: state} = row) when state in [:via_prowlarr, :refused],
    do: Enum.map(row.reasons, &reason(&1, row))

  def reasons(_row), do: []

  defp reason(:implementation, row),
    do:
      gettext("Cinder can't search a %{implementation} indexer itself.",
        implementation: row.implementation
      )

  defp reason(:http_proxy, _row), do: gettext("It goes through an HTTP proxy in Prowlarr.")
  defp reason(:socks_proxy, _row), do: gettext("It goes through a SOCKS proxy in Prowlarr.")

  defp reason(:flaresolverr, _row),
    do: gettext("It goes through FlareSolverr in Prowlarr, which Cinder uses for Cardigann only.")

  defp reason(:other_proxy, _row),
    do: gettext("It goes through a proxy in Prowlarr that Cinder doesn't know.")

  defp reason(:global_proxy, _row), do: gettext("Prowlarr's global proxy is on.")

  defp reason(:additional_parameters, _row),
    do: gettext("It has additional parameters, which Cinder keeps for Newznab only.")

  defp reason(:protocol_unknown, _row),
    do: gettext("Prowlarr doesn't say whether it is a Usenet or a torrent indexer.")

  # A Cardigann row's reasons (#1675). A setting's label comes from the definition: it is text,
  # never translated.
  defp reason(:definition_not_available, _row),
    do: gettext("Definition not available: add it through Prowlarr")

  defp reason({:not_supported, feature}, _row),
    do: gettext("Not supported: %{feature}", feature: IndexerStateText.feature(feature))

  defp reason(:needs_newer_cinder, _row), do: gettext("Needs a newer Cinder")

  defp reason(:base_url_not_in_links, _row),
    do: gettext("Base URL is not one of the definition's links")

  defp reason({:select_no_default, label}, _row) when is_binary(label),
    do: gettext("%{setting} has no default value", setting: label)

  defp reason({field, validation}, _row) when is_atom(field), do: field_refusal(field, validation)
  defp reason(_reason, _row), do: gettext("Cinder can't import this indexer as it is set up.")

  # A refused setting, under its field's name, in the words of the indexer form.
  defp field_refusal(field, validation) do
    message = IndexerFormText.refusal(field, validation)

    case field_label(field) do
      nil -> message
      label -> gettext("%{field}: %{message}", field: label, message: message)
    end
  end

  defp field_label(:base_url), do: gettext("Base URL")
  defp field_label(:api_path), do: gettext("API path")
  defp field_label(:settings), do: gettext("Additional parameters")
  defp field_label(:priority), do: gettext("Priority")
  defp field_label(_field), do: nil

  @doc "The line naming the Prowlarr settings the row has that the import does not carry, or nil."
  @spec not_carried(Row.t()) :: String.t() | nil
  def not_carried(%Row{not_carried: []}), do: nil

  def not_carried(%Row{not_carried: notes}),
    do: gettext("Not carried: %{settings}.", settings: Enum.map_join(notes, ", ", &setting/1))

  defp setting(:query_limit), do: gettext("query limit")
  defp setting(:grab_limit), do: gettext("grab limit")
  defp setting(:query_timeout), do: gettext("query timeout")
  defp setting(:app_profile), do: gettext("app profile")
  defp setting(:seed_settings), do: gettext("seed settings")

  @doc """
  The lines naming what a direct Cardigann row, or the indexer the import created from it, took
  in Prowlarr's place: each select that took its default.
  """
  @spec notes(%{notes: list()}) :: [String.t()]
  def notes(%{notes: notes}) do
    for {:took_default, label} <- notes,
        do: gettext("%{setting} took its default value", setting: label)
  end

  @doc "The text of an error code a refused commit gave a row."
  @spec row_error(term()) :: String.t()
  def row_error(:not_importable), do: gettext("This indexer can't be imported.")

  def row_error(:via_prowlarr_not_chosen),
    do: gettext("Tick Add it through Prowlarr to import this indexer.")

  def row_error(:via_prowlarr_not_offered),
    do: gettext("This indexer is imported directly, not through Prowlarr.")

  def row_error(:name_required), do: gettext("Enter a name.")
  def row_error(:name_taken), do: gettext("Another indexer already has this name.")
  def row_error(:name_conflict), do: gettext("Another indexer already has this name.")
  def row_error(:name_duplicate), do: gettext("Another ticked indexer has this name.")
  def row_error(:secret_invalid), do: gettext("Enter the API key as plain text.")
  def row_error(:settings_invalid), do: gettext("Enter each setting as plain text.")
  def row_error(:already_imported), do: gettext("This indexer was imported meanwhile.")
  def row_error(:link_conflict), do: gettext("This indexer was imported meanwhile.")

  # The create checks a Cardigann row's pinned copy again inside its transaction.
  def row_error({:definition, _validation}), do: error(:changed)
  def row_error({field, validation}) when is_atom(field), do: field_refusal(field, validation)
  def row_error(_code), do: gettext("This indexer can't be imported.")

  @doc "The report's line for one indexer the import created."
  @spec created(map()) :: String.t()
  def created(%{name: name, notes: notes}) do
    cond do
      :created_disabled_no_key in notes ->
        gettext("%{name}: API key not entered: created disabled", name: name)

      labels = Enum.find_value(notes, &secrets_not_entered/1) ->
        gettext("%{name}: %{settings} not entered: created disabled",
          name: name,
          settings: Enum.join(labels, ", ")
        )

      true ->
        gettext("%{name}: created", name: name)
    end
  end

  defp secrets_not_entered({:secrets_not_entered, labels}), do: labels
  defp secrets_not_entered(_note), do: nil

  @doc """
  The report's line on the Tests the import started: one sentence for all the enabled indexers it
  created when each one's Test started, the names of those whose Test started when only some
  did, and nil when none did.
  """
  @spec testing(map()) :: String.t() | nil
  def testing(%{tests_started: []}), do: nil

  def testing(%{created: created, tests_started: started}) do
    enabled = for row <- created, row.enabled, do: row.id

    if Enum.all?(enabled, &(&1 in started)) do
      gettext("Cinder is testing each enabled indexer it created.")
    else
      names = for row <- created, row.id in started, do: row.name
      gettext("Cinder is testing %{names}.", names: Enum.join(names, ", "))
    end
  end

  @doc "The report's line for one indexer the preview showed as already imported."
  @spec skipped(String.t()) :: String.t()
  def skipped(name), do: gettext("%{name}: already imported, skipped", name: name)
end
