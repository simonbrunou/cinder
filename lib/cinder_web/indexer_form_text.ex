defmodule CinderWeb.IndexerFormText do
  @moduledoc """
  Words the refusals of `Cinder.Indexers`' changeset for the Newznab and Torznab form of the
  indexers dialogs (#1661). The store tags each refusal with a `validation:` code
  (`Cinder.Indexers.ConfiguredIndexer`); this module picks the form field it shows under and
  its translated message (docs/agents/architecture.md "Translation stays in the web layer").

  `errors/2` answers `%{field => [message]}`. The fields are the form's: `:name`, `:base_url`,
  `:api_path`, `:additional_parameters`, `:priority`, `:enabled` and `:api_key`. A refusal on a
  field the form does not render goes under `:form`, shown above the fields: so does a
  `settings` refusal in the Torznab form, which has no additional parameters field. The stale
  save's `lock_version` error is left out: the dialog says it in its own line.
  """
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [translate_error: 1]

  @form_fields [:name, :base_url, :api_path, :priority, :enabled]

  @doc "The changeset's refusals by form field, for a form of `type`, each list in order."
  @spec errors(Ecto.Changeset.t(), atom()) :: %{atom() => [String.t()]}
  def errors(%Ecto.Changeset{errors: errors}, type) do
    errors
    |> Enum.reject(&stale_error?/1)
    |> Enum.map(fn {field, {_message, opts} = error} ->
      {form_field(field, type), message({field, opts[:validation]}, error)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {field, messages} -> {field, Enum.uniq(messages)} end)
  end

  @doc "Whether the changeset is the store's stale-save refusal."
  @spec stale?(Ecto.Changeset.t()) :: boolean()
  def stale?(%Ecto.Changeset{errors: errors}), do: Enum.any?(errors, &stale_error?/1)

  @doc """
  The message of one refusal given as `{field, validation}` with no changeset, as the Prowlarr
  import's rows carry them (`CinderWeb.ProwlarrImportText`).
  """
  @spec refusal(atom(), atom() | nil) :: String.t()
  def refusal(field, validation),
    do: message({field, validation}, {"is invalid", [validation: validation]})

  defp stale_error?({field, {_message, opts}}),
    do: field == :lock_version and opts[:stale] == true

  defp form_field(:settings, :newznab), do: :additional_parameters
  defp form_field(:secrets, _type), do: :api_key
  defp form_field(field, _type) when field in @form_fields, do: field
  defp form_field(_field, _type), do: :form

  defp message({:name, :unique_name}, _error),
    do: gettext("Another indexer already has this name.")

  # Each base URL refusal's tag names its field, so these clauses match on the tag alone.
  defp message({_base_url, :base_url_scheme}, _error),
    do: gettext("Start the URL with http:// or https://.")

  defp message({_base_url, :base_url_host}, _error), do: gettext("Enter a URL with a host name.")
  defp message({_base_url, :base_url_port}, _error), do: gettext("Use a port from 1 to 65535.")

  defp message({_base_url, :base_url_userinfo}, _error),
    do: gettext("Remove the user name and password from the URL.")

  defp message({_base_url, :base_url_query}, _error),
    do: gettext("Remove the query, from the ? on, from the URL.")

  defp message({_base_url, :base_url_fragment}, _error),
    do: gettext("Remove the part from the # on from the URL.")

  defp message({_base_url, :base_url_format}, _error),
    do: gettext("Enter a valid URL, such as https://indexer.example.")

  defp message({:api_path, _validation}, _error),
    do: gettext("Enter a path that starts with a single /, such as /api.")

  defp message({:settings, :credential_parameter}, _error),
    do: gettext("Put the API key in the API key field, not in additional parameters.")

  defp message({:settings, _validation}, _error),
    do: gettext("Enter the parameters as &name=value pairs, such as &cat=2000.")

  defp message({:priority, _validation}, _error),
    do: gettext("Enter a whole number from 1 to 50.")

  defp message({:secrets, :secrets_unreadable}, _error),
    do:
      gettext(
        "The saved API key can't be decrypted: type it again, or tick Clear, before you save a key."
      )

  defp message({:secrets, _validation}, _error), do: gettext("Enter the API key as plain text.")
  defp message({field, :required}, error), do: required(field) || translate_error(error)
  defp message(_field_validation, error), do: translate_error(error)

  defp required(:name), do: gettext("Enter a name.")
  defp required(:base_url), do: gettext("Enter the indexer's URL.")
  defp required(_field), do: nil
end
