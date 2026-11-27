defmodule CinderWeb.IndexerFormText do
  @moduledoc """
  Words the refusals of `Cinder.Indexers`' changeset for the Newznab, Torznab and Cardigann forms
  of the indexers dialogs (#1661, #1676). The store tags each refusal with a `validation:` code
  (`Cinder.Indexers.ConfiguredIndexer`); this module picks the form field it shows under and
  its translated message (docs/agents/architecture.md "Translation stays in the web layer").

  `errors/2` answers `%{field => [message]}`. The fields are the form's: `:name`, `:base_url`,
  `:api_path`, `:additional_parameters`, `:priority`, `:enabled` and `:api_key`. A refusal on a
  field the form does not render goes under `:form`, shown above the fields: so does a
  `settings` refusal in the Torznab form, which has no additional parameters field, and each
  `definition`, `settings` and `secrets` refusal in the Cardigann form (#1676), whose settings
  come from the site's definition and which has its own words for them. The stale
  save's `lock_version` error is left out: the dialog says it in its own line.
  """
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [translate_error: 1]

  alias Cinder.Settings.Shape
  alias CinderWeb.DomainLabels

  @form_fields [:name, :base_url, :api_path, :priority, :enabled]

  @doc "The changeset's refusals by form field, for a form of `type`, each list in order."
  @spec errors(Ecto.Changeset.t(), atom()) :: %{atom() => [String.t()]}
  def errors(%Ecto.Changeset{errors: errors}, type) do
    errors
    |> Enum.reject(&stale_error?/1)
    |> Enum.map(fn {field, {_message, opts} = error} ->
      {form_field(field, type), message({field, opts[:validation]}, error, type)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {field, messages} -> {field, Enum.uniq(messages)} end)
  end

  @doc """
  The refusal of the Cardigann form's FlareSolverr URL field (#1682): `:blank` with the toggle on
  and no URL saved, `:invalid` for a URL `Cinder.Indexers.FlareSolverrUrl.put/1` refuses.
  """
  @spec flaresolverr_url(:blank | :invalid) :: String.t()
  def flaresolverr_url(:blank), do: gettext("Enter FlareSolverr's URL, or turn FlareSolverr off.")

  def flaresolverr_url(:invalid),
    do: DomainLabels.t(Shape.message(:service_url))

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
  defp form_field(:secrets, :cardigann), do: :form
  defp form_field(:secrets, _type), do: :api_key
  defp form_field(field, _type) when field in @form_fields, do: field
  defp form_field(_field, _type), do: :form

  defp message(field_validation, error, :cardigann),
    do: cardigann_message(field_validation) || message(field_validation, error)

  defp message(field_validation, error, _type), do: message(field_validation, error)

  # The Cardigann form's own refusals (#1676): its settings and secrets come from the site's
  # definition, and the form carries the hash of the copy it rendered.
  # The mirror or the pin no longer holds the copy the form rendered (#1620 point 4).
  defp cardigann_message({:definition, validation})
       when validation in [:definition_changed, :definition_not_in_mirror],
       do:
         gettext(
           "This site's definition changed while the form was open: close it and open it again."
         )

  # A Switch's host list changed between the form's last read and the save (#1907).
  defp cardigann_message({:definition, :switch_hosts_changed}),
    do:
      gettext(
        "The hosts this Switch would send the indexer's credentials to changed: check the list again, then save."
      )

  defp cardigann_message({:definition, :definition_fails}),
    do: gettext("This site's definition no longer loads, so Cinder can't check these settings.")

  defp cardigann_message({:definition, :fixed_at_create}),
    do: gettext("An indexer keeps its site, unless the mirror replaces that site's definition.")

  defp cardigann_message({_base_url, :base_url_links}),
    do: gettext("Pick one of the site's addresses.")

  defp cardigann_message({field, :settings_keys}) when field in [:settings, :secrets],
    do:
      gettext(
        "A setting is not one the site's definition declares: close the form and open it again."
      )

  defp cardigann_message({field, validation})
       when field in [:settings, :secrets] and validation in [:settings_values, :select_option],
       do: gettext("A setting's value is not one the site's definition accepts.")

  defp cardigann_message({:secrets, :secret_fields}),
    do:
      gettext(
        "A secret is not one the site's definition declares: close the form and open it again."
      )

  defp cardigann_message({:secrets, :secrets_unreadable}),
    do:
      gettext(
        "The saved secrets can't be decrypted: type each one again, or tick its Clear box, before you save."
      )

  defp cardigann_message(_field_validation), do: nil

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
