defmodule Cinder.Acquisition.IndexerSource.Native.IndexerClearances do
  @moduledoc """
  The clearance table (#1682): one row per Cardigann configured indexer, holding the clearance
  of its last FlareSolverr solve (`Cinder.Acquisition.Indexer.Cardigann.FlareSolverr`), so later
  requests to the definition's hosts skip the challenge. It is runtime state of
  `Cinder.Acquisition.IndexerSource.Native`, written only here; `Cinder.Indexers` never writes
  it, and deleting the configured indexer deletes its row (`ON DELETE CASCADE`).

  The issue proposed joining the login cookie row of #1680
  (`Cinder.Acquisition.IndexerSource.Native.IndexerCookies`). That row is a login session: a
  definition with no login never reads it, a definition with one reads any row as logged in,
  and each login replaces its whole ciphertext. A table of its own keeps the two lifetimes
  apart under the same rules.

  A row holds:

  - the clearance as one ciphertext through `Cinder.SecretCodec`, whose plaintext names its
    scope (`"indexer_cookies"`), its kind (`"clearance"`) and the indexer's id, so a row copied
    to another indexer, or a cookie or captcha row's ciphertext, reads as unreadable;
  - the `config_version` the solve ran under: a base URL, settings, FlareSolverr toggle or
    secret change raises it (`Cinder.Indexers`), and a clearance of another version is not used;
  - `expires_at`, `lifetime_days/0` days after the solve, as a login's cookies are kept.

  `read/2` answers nil for no row, an expired row, a row that does not decrypt, and a row under
  another `config_version` than the indexer's; it deletes one under an older version. `store/3`
  writes a clearance and refuses one solved under another `config_version` than the configured
  indexer holds now, such as a solve that finishes after an edit.

  An `Exqlite.Error`, as a write lock held past the busy timeout raises, answers `:not_written`
  from `store/3` and nil from `read/2`, and logs the indexer id and the error's module only. The
  write runs with `log: false`, so a debug log never holds the row's ciphertext.
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Cinder.Acquisition.Indexer.Cardigann.{FlareSolverr, Jar}
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo
  alias Cinder.SecretCodec

  @scope "indexer_cookies"
  @kind "clearance"
  @lifetime_days 30

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "native_indexer_clearances" do
    field :ciphertext, :string, redact: true
    field :config_version, :integer
    field :expires_at, :utc_datetime_usec
  end

  @doc "How long a clearance is kept, in days: 30."
  @spec lifetime_days() :: pos_integer()
  def lifetime_days, do: @lifetime_days

  @doc "The stored clearance of `indexer` at `now`, or nil; see the moduledoc."
  @spec read(ConfiguredIndexer.t(), DateTime.t()) :: FlareSolverr.clearance() | nil
  def read(%ConfiguredIndexer{id: id} = indexer, %DateTime{} = now) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        nil

      %__MODULE__{config_version: version} when version < indexer.config_version ->
        Repo.delete_all(
          from(c in __MODULE__,
            where: c.configured_indexer_id == ^id and c.config_version == ^version
          )
        )

        nil

      %__MODULE__{} = row ->
        usable(row, indexer, now)
    end
  rescue
    error in Exqlite.Error -> failed(id, error, nil)
  end

  defp usable(row, indexer, now) do
    with true <- row.config_version == indexer.config_version,
         true <- DateTime.compare(row.expires_at, now) == :gt,
         {:ok, clearance} <- open(row) do
      clearance
    else
      _expired_unreadable_or_newer -> nil
    end
  end

  defp open(%__MODULE__{configured_indexer_id: id, ciphertext: ciphertext}) do
    with {:ok, json} <- SecretCodec.decode(ciphertext),
         {:ok,
          %{
            "scope" => @scope,
            "kind" => @kind,
            "id" => ^id,
            "user_agent" => user_agent,
            "cookies" => cookies
          } = envelope}
         when map_size(envelope) == 5 and is_binary(user_agent) and is_list(cookies) <-
           Jason.decode(json),
         {:ok, cookies} <- cookies(cookies) do
      {:ok, %{user_agent: user_agent, cookies: cookies}}
    else
      _unreadable -> :error
    end
  end

  defp cookies(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      [domain, name, value], {:ok, acc} when is_binary(domain) ->
        if Jar.cookie?(name, value),
          do: {:cont, {:ok, [{domain, name, value} | acc]}},
          else: {:halt, :error}

      _other, _acc ->
        {:halt, :error}
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end)
  end

  defp seal(id, %{user_agent: user_agent, cookies: cookies}) do
    SecretCodec.encode(
      Jason.encode!(%{
        "scope" => @scope,
        "kind" => @kind,
        "id" => id,
        "user_agent" => user_agent,
        "cookies" => for({domain, name, value} <- cookies, do: [domain, name, value])
      })
    )
  end

  @doc """
  Stores `clearance`, solved for `indexer` at `now`, under the `config_version` `indexer`
  carries, with `expires_at` `lifetime_days/0` days after `now`. Answers `:written`, `:refused`
  when the configured indexer is gone or holds another `config_version` now, or `:not_written`
  on an `Exqlite.Error`.
  """
  @spec store(ConfiguredIndexer.t(), FlareSolverr.clearance(), DateTime.t()) ::
          :written | :refused | :not_written
  def store(%ConfiguredIndexer{id: id} = indexer, clearance, %DateTime{} = now)
      when is_integer(id) do
    now = usec(now)

    transact(id, fn ->
      if current_version(id) == indexer.config_version do
        row = %{
          configured_indexer_id: id,
          ciphertext: seal(id, clearance),
          config_version: indexer.config_version,
          expires_at: DateTime.add(now, @lifetime_days * 86_400, :second)
        }

        Repo.insert_all(__MODULE__, [row],
          on_conflict: {:replace, [:ciphertext, :config_version, :expires_at]},
          conflict_target: :configured_indexer_id,
          log: false
        )

        :written
      else
        :refused
      end
    end)
  end

  defp transact(id, fun) do
    {:ok, result} = Repo.transact(fn -> {:ok, fun.()} end)
    result
  rescue
    error in Exqlite.Error -> failed(id, error, :not_written)
  end

  defp failed(id, error, answer) do
    Logger.warning(
      "native indexer clearance of indexer #{id} not read or written: " <>
        inspect(error.__struct__)
    )

    answer
  end

  # A time at microsecond precision, as the `:utc_datetime_usec` column takes it: Native's clock
  # can answer whole seconds.
  defp usec(%DateTime{microsecond: {value, _precision}} = time),
    do: %{DateTime.truncate(time, :microsecond) | microsecond: {value, 6}}

  defp current_version(id),
    do: Repo.one(from(c in ConfiguredIndexer, where: c.id == ^id, select: c.config_version))
end
