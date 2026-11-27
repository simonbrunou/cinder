defmodule Cinder.Indexers.Definitions.Hold do
  @moduledoc """
  The hold decision for one Cardigann configured indexer (#1668; #1616 rules 5 and 6, #1620
  points 3 and 10). Pure: `Cinder.Indexers.Definitions` reads the inputs inside its write
  transaction and writes the answer.

  `decide/1` takes the running copy, the mirror's copy for the indexer's file name (nil when the
  mirror holds none) with its load result, the folder above the engine that needs a newer Cinder
  (nil for none), the stored base URL and the stored values, or `:undecryptable`. It answers:

  - `:unchanged`: the mirror's copy differs from the running one and has no load result under
    the current fingerprint, so nothing is decided until one is stored;
  - `{:keep, newer}`: the running copy stays and no copy is held: the mirror holds no copy, or
    the same blob as the running one;
  - `{:apply, newer}`: the mirror's copy becomes the running copy and no copy is held;
  - `{:hold, reason}`: the running copy stays and the mirror's copy is held.

  `newer` is `{:needs_newer_cinder, version}` when a folder above the engine holds another copy
  of the name, else nil. It is the hold's reason when no copy is held.

  A copy other than the running one is held, first match in this order:

  1. `:undecryptable`: the stored secrets do not decrypt;
  2. `:fails`: it fails to load;
  3. `{:not_supported, feature}`: it reads not supported, `feature` its first code;
  4. for an indexer with credentials (`credentials?/2`) only: `:hosts`, its credential hosts
     (`Cinder.Indexers.Definitions.CredentialHosts.hosts/2`) are not a subset of the running
     copy's, or the running copy no longer parses; `:certificates`, its `certificates` differ
     as sets; `:removed_credential`, it no longer declares a setting that holds a credential;
     `:retyped_credential`, it declares one under another type;
  5. for any indexer whose running copy parses: `:retyped_credential` too, it declares again a
     setting the running copy does not declare, whose stored secret differs from the copy's
     default for it (`declares_again?/3`). A secret stays stored after an update that removes
     its setting applies or is accepted, and the running copy sends it nowhere until a copy
     declares it again.

  Any other copy applies, host moves included.
  """

  alias Cinder.Indexers.CardigannSettings
  alias Cinder.Indexers.Definitions.CredentialHosts

  @type definition :: {:ok, map()} | {:error, term()}
  @type result :: :loads | {:not_supported, [term()]} | {:fails, term()} | :unchecked
  @type settings :: %{plain: map(), secrets: map()} | :undecryptable
  @type input :: %{
          running: %{blob_sha: String.t(), definition: definition()},
          mirror: nil | %{blob_sha: String.t(), result: result(), definition: definition()},
          newer: pos_integer() | nil,
          stored_url: String.t() | nil,
          settings: settings()
        }
  @type newer :: {:needs_newer_cinder, pos_integer()} | nil
  @type reason ::
          :undecryptable
          | :fails
          | {:not_supported, term()}
          | :hosts
          | :certificates
          | :removed_credential
          | :retyped_credential
  @type outcome :: :unchanged | {:keep, newer()} | {:apply, newer()} | {:hold, reason()}

  @doc """
  The tag of each `reason`: `:not_supported` stands for `{:not_supported, feature}`, the others
  for themselves.
  """
  @spec reason_tags() :: [atom()]
  def reason_tags,
    do: [:undecryptable, :fails, :not_supported | credential_reasons()]

  @doc "The reasons an admin may Accept: the credential rules."
  @spec credential_reasons() :: [reason()]
  def credential_reasons, do: [:hosts, :certificates, :removed_credential, :retyped_credential]

  @doc "Decides one configured indexer's copies, as the moduledoc says."
  @spec decide(input()) :: outcome()
  def decide(%{running: running, mirror: mirror} = input) do
    newer = if input.newer, do: {:needs_newer_cinder, input.newer}

    cond do
      mirror == nil or mirror.blob_sha == running.blob_sha -> {:keep, newer}
      mirror.result == :unchecked -> :unchanged
      true -> candidate(input, newer)
    end
  end

  defp candidate(%{mirror: mirror} = input, newer) do
    case hold_reason(input, mirror) do
      nil -> {:apply, newer}
      reason -> {:hold, reason}
    end
  end

  defp hold_reason(%{settings: :undecryptable}, _mirror), do: :undecryptable
  defp hold_reason(_input, %{result: {:fails, _reason}}), do: :fails
  defp hold_reason(_input, %{definition: {:error, _reason}}), do: :fails

  defp hold_reason(_input, %{result: {:not_supported, [feature | _]}}),
    do: {:not_supported, feature}

  defp hold_reason(%{running: running, settings: settings} = input, %{definition: {:ok, new}}) do
    if credentials?(running.definition, settings),
      do:
        credential_reason(running.definition, new, input) ||
          declared_again(running, new, settings),
      else: declared_again(running, new, settings)
  end

  defp declared_again(%{definition: old}, new, settings),
    do: if(declares_again?(old, new, settings), do: :retyped_credential)

  @doc """
  Whether `new` declares again a setting the running copy `old` does not declare, whose stored
  secret differs from `new`'s default for it: false when `old` does not parse.
  """
  @spec declares_again?(definition(), map(), %{plain: map(), secrets: map()}) :: boolean()
  def declares_again?({:ok, old}, new, %{secrets: secrets}) do
    Enum.any?(secrets, fn {key, value} ->
      setting(old, key) == nil and setting(new, key) != nil and value != default(new, key)
    end)
  end

  def declares_again?({:error, _reason}, _new, _settings), do: false

  defp credential_reason({:error, _reason}, _new, _input), do: :hosts

  defp credential_reason({:ok, old}, new, input) do
    stored = %{stored_url: input.stored_url, settings: all_values(input.settings)}
    held = credential_keys(old, input.settings)

    cond do
      not MapSet.subset?(CredentialHosts.hosts(new, stored), CredentialHosts.hosts(old, stored)) ->
        :hosts

      MapSet.new(new.certificates || []) != MapSet.new(old.certificates || []) ->
        :certificates

      Enum.any?(held, &(setting(new, &1) == nil)) ->
        :removed_credential

      Enum.any?(held, &(setting(new, &1).type != setting(old, &1).type)) ->
        :retyped_credential

      true ->
        nil
    end
  end

  @doc """
  Whether an indexer has credentials (#1620 point 3): its secrets do not decrypt, or a stored
  secret value differs from the running copy's default for a setting the running copy declares,
  a missing default reading as empty text. A running copy that no longer parses counts any
  non-empty secret.
  """
  @spec credentials?(definition(), settings()) :: boolean()
  def credentials?(_definition, :undecryptable), do: true

  def credentials?({:error, _reason}, %{secrets: secrets}),
    do: Enum.any?(secrets, fn {_key, value} -> value not in [nil, ""] end)

  def credentials?({:ok, definition}, settings), do: credential_keys(definition, settings) != []

  # The stored secrets of declared settings that differ from the running copy's default.
  defp credential_keys(definition, %{secrets: secrets}) do
    for {key, value} <- secrets,
        setting(definition, key) != nil,
        value != default(definition, key),
        do: key
  end

  defp default(definition, key), do: CardigannSettings.default(definition, key)

  defp setting(definition, key), do: Enum.find(definition.settings || [], &(&1.name == key))

  defp all_values(%{plain: plain, secrets: secrets}), do: Map.merge(plain, secrets)
end
