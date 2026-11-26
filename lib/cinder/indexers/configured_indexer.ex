defmodule Cinder.Indexers.ConfiguredIndexer do
  @moduledoc """
  What the admin saved for searching one indexer (GLOSSARY.md "Configured indexer"). Only
  `Cinder.Indexers` writes these rows; this module holds their shape and the write-path checks.

  Each refusal is a changeset error whose message Ecto already uses (`priv/gettext/errors.pot`),
  with a `validation:` tag naming the rule, such as `{"is invalid", [validation: :base_url_query]}`.
  A refused base URL, API path or settings value can carry a credential, such as
  `https://user:KEY@host` or `&apikey=KEY`, so `drop_refused/1` takes it out of the changeset
  (#1697).

  `secrets_ciphertext` holds the row's secrets (`Cinder.Indexers.Secrets`). The virtual `secrets`
  carries their plaintext on a read that asks for it, and `secrets_readable` says whether they
  decrypt. Both secret fields are redacted from `inspect/1`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types [:newznab, :torznab, :cardigann]

  # The settings keys each type stores as plain values.
  @settings_keys %{newznab: ["additional_parameters"], torznab: []}

  # The fields whose refused value `drop_refused/1` takes out of the changeset.
  @dropped_fields [:base_url, :api_path, :settings]

  # Parameter names a Newznab `additional_parameters` value may not carry: the key belongs in the
  # encrypted secrets, never in a plain setting.
  @credential_parameters ["apikey", "passkey"]

  schema "configured_indexers" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :definition, :string
    field :base_url, :string
    field :api_path, :string
    field :enabled, :boolean, default: true
    field :flaresolverr, :boolean, default: false
    field :settings, :map, default: %{}
    field :secrets_ciphertext, :string, redact: true
    field :priority, :integer, default: 25
    field :prowlarr_indexer_id, :integer
    field :lock_version, :integer, default: 1
    field :credentials_version, :integer, default: 1
    field :config_version, :integer, default: 1
    field :secrets, :map, virtual: true, redact: true
    field :secrets_readable, :boolean, virtual: true

    timestamps(type: :utc_datetime)
  end

  @create_fields [
    :name,
    :type,
    :definition,
    :base_url,
    :api_path,
    :enabled,
    :flaresolverr,
    :settings,
    :priority
  ]

  @doc "The secret field names a type stores in its ciphertext."
  @spec secret_fields(atom()) :: [String.t()]
  def secret_fields(type) when type in [:newznab, :torznab], do: ["api_key"]
  def secret_fields(_type), do: []

  @doc """
  A new row's changeset. A Cardigann row needs its definition file name; `Cinder.Indexers`
  checks its base URL and settings against the copy it pins.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(plain(attrs), @create_fields)
    |> validate()
  end

  @doc "An edit's changeset on `row`. The type and the definition stay as they were created."
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(plain(attrs), @create_fields)
    |> refuse_change(:type)
    |> refuse_change(:definition)
    |> validate()
  end

  @doc """
  Links a new row's changeset to the Prowlarr indexer `prowlarr_indexer_id`, the id Prowlarr's
  `/api/v1/indexer` and its search results give it. Only the Prowlarr import sets it
  (`Cinder.Indexers.create_imported/4`), and two rows never hold one id.
  """
  @spec link_changeset(Ecto.Changeset.t(), pos_integer()) :: Ecto.Changeset.t()
  def link_changeset(changeset, prowlarr_indexer_id) when is_integer(prowlarr_indexer_id) do
    changeset
    |> put_change(:prowlarr_indexer_id, prowlarr_indexer_id)
    |> unique_constraint(:prowlarr_indexer_id)
  end

  # Secret inputs travel apart from the plain attrs. A `secrets` key left among them would stay in
  # the changeset's params, which a form renders from.
  defp plain(attrs), do: Map.drop(attrs, ["secrets", :secrets])

  defp refuse_change(changeset, field) do
    if Map.has_key?(changeset.changes, field),
      do: add_error(changeset, field, "is invalid", validation: :fixed_at_create),
      else: changeset
  end

  defp validate(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type, :base_url, :enabled, :flaresolverr, :settings, :priority])
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 50)
    |> validate_change(:base_url, &base_url_errors/2)
    |> validate_api_type_fields()
    |> unique_constraint(:name)
    |> check_constraint(:priority, name: :configured_indexers_priority_range)
    |> drop_refused()
  end

  @doc """
  Takes the typed value of each of `base_url`, `api_path` and `settings` that carries an error,
  whatever rule refused it, out of `changeset`: the field has no change, and its param reads
  `""`, so a form of the changeset renders the input empty, never the stored value. The other
  fields keep their typed values, and every error stays.
  """
  @spec drop_refused(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def drop_refused(%Ecto.Changeset{} = changeset) do
    Enum.reduce(@dropped_fields, changeset, fn field, changeset ->
      if Keyword.has_key?(changeset.errors, field),
        do: drop_value(changeset, field),
        else: changeset
    end)
  end

  defp drop_value(changeset, field) do
    changeset = delete_change(changeset, field)
    %{changeset | params: Map.put(changeset.params || %{}, Atom.to_string(field), "")}
  end

  defp validate_api_type_fields(changeset) do
    case get_field(changeset, :type) do
      type when type in [:newznab, :torznab] ->
        changeset
        |> validate_required(:api_path)
        |> validate_change(:api_path, &api_path_errors/2)
        |> refuse_definition()
        |> validate_settings(type)

      :cardigann ->
        validate_required(changeset, :definition)

      _other ->
        changeset
    end
  end

  defp refuse_definition(changeset) do
    if get_field(changeset, :definition) == nil,
      do: changeset,
      else: add_error(changeset, :definition, "is invalid", validation: :definition_type)
  end

  defp validate_settings(changeset, type) do
    settings = get_field(changeset, :settings) || %{}

    case settings_refusal(settings, Map.fetch!(@settings_keys, type)) do
      nil -> changeset
      validation -> add_error(changeset, :settings, "is invalid", validation: validation)
    end
  end

  @doc """
  The `:settings` validation that a Newznab row's additional parameters `value` fails, or nil
  when it passes: `:settings_values`, `:parameter_format` or `:credential_parameter`. The
  Prowlarr import (#1673) runs it on a Torznab indexer's additional parameters, which Prowlarr
  adds to each search of that indexer.
  """
  @spec parameters_refusal(term()) :: atom() | nil
  def parameters_refusal(value),
    do: settings_refusal(%{"additional_parameters" => value}, ["additional_parameters"])

  defp settings_refusal(settings, allowed) do
    names = parameter_names(settings["additional_parameters"])

    cond do
      Enum.any?(Map.keys(settings), &(&1 not in allowed)) -> :settings_keys
      not Enum.all?(Map.values(settings), &text?/1) -> :settings_values
      :undecodable in names -> :parameter_format
      Enum.any?(names, &(&1 in @credential_parameters)) -> :credential_parameter
      true -> nil
    end
  end

  # UTF-8 text with no control character.
  defp text?(value), do: is_binary(value) and String.valid?(value) and not control?(value)

  defp control?(text), do: String.match?(text, ~r/[\x00-\x1F\x7F]/)

  # The parameter names of a Newznab additional parameters value such as "&cat=2000&apikey=x":
  # split on `&` and `;`, a leading `?` dropped, each name decoded as `URI.decode_www_form/1` reads
  # it, trimmed and downcased. So a percent-encoded, `+`-spaced or capitalised spelling of a
  # credential name reads as that name. A value with a `#`, or a name that decodes to anything but
  # text without control characters, gives `:undecodable`.
  # A value that is not text has no names here: the values check above refuses it first.
  defp parameter_names(value) when not is_binary(value), do: []

  defp parameter_names(value) do
    if String.contains?(value, "#"),
      do: [:undecodable],
      else: value |> String.split(["&", ";"]) |> Enum.map(&parameter_name/1)
  end

  defp parameter_name(pair) do
    [name | _value] = String.split(pair, "=", parts: 2)
    decoded = name |> String.trim_leading("?") |> URI.decode_www_form()

    if text?(decoded), do: decoded |> String.trim() |> String.downcase(), else: :undecodable
  end

  # http or https with a host and a port in range; no userinfo, query or fragment.
  defp base_url_errors(field, url) do
    case parse(url) do
      {:ok, %URI{scheme: scheme}} when scheme not in ["http", "https"] ->
        refusal(field, :base_url_scheme)

      {:ok, %URI{host: host}} when host in [nil, ""] ->
        refusal(field, :base_url_host)

      {:ok, %URI{port: port}} when port not in 1..65_535 ->
        refusal(field, :base_url_port)

      {:ok, %URI{userinfo: userinfo}} when userinfo != nil ->
        refusal(field, :base_url_userinfo)

      {:ok, %URI{query: query}} when query != nil ->
        refusal(field, :base_url_query)

      {:ok, %URI{fragment: fragment}} when fragment != nil ->
        refusal(field, :base_url_fragment)

      {:ok, %URI{}} ->
        []

      :error ->
        refusal(field, :base_url_format)
    end
  end

  # A plain path that starts with exactly one "/": `URI.merge/2` would send a request for
  # "//evil.example/api", key included, to that host.
  defp api_path_errors(field, "//" <> _authority), do: refusal(field, :api_path_authority)

  defp api_path_errors(field, path) do
    case parse(path) do
      {:ok,
       %URI{scheme: nil, host: nil, userinfo: nil, query: nil, fragment: nil, path: "/" <> _}} ->
        []

      {:ok, %URI{}} ->
        refusal(field, :api_path_plain)

      :error ->
        refusal(field, :api_path_format)
    end
  end

  defp refusal(field, validation), do: [{field, {"is invalid", validation: validation}}]

  # `URI.new/1` raises FunctionClauseError on a byte that is not valid UTF-8.
  defp parse(text) do
    with true <- String.valid?(text),
         {:ok, uri} <- URI.new(text) do
      {:ok, uri}
    else
      _ -> :error
    end
  end
end
