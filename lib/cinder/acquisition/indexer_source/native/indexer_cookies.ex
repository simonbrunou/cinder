defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCookies do
  @moduledoc """
  The cookie table (#1680; #1620 points 4, 6, 9 and 11): one row per Cardigann configured
  indexer, holding the cookie jar of its last login
  (`Cinder.Acquisition.Indexer.Cardigann.Jar`). It is runtime state of
  `Cinder.Acquisition.IndexerSource.Native`, written only here; `Cinder.Indexers` never writes
  it, and deleting the configured indexer deletes its row (`ON DELETE CASCADE`).

  A row holds:

  - the jar as one ciphertext through `Cinder.SecretCodec`, whose plaintext names its scope
    (`"indexer_cookies"`) and the indexer's id, so a row copied to another indexer reads as
    unreadable;
  - the `credentials_version` the login ran under;
  - `logged_in_at`, the login's time, and `expires_at`, `lifetime_days/0` days after it, as
    Prowlarr keeps a login's cookies (`DateTime.Now.AddDays(30)`, `b0b5774`).

  `read/2` answers `:miss`, a cache miss that the health state does not count, for no row, an
  expired row, a row that does not decrypt, and a row under an older `credentials_version` than
  the indexer's, which it deletes. `store_login/3` writes a login's jar and refuses a login that
  started under another `credentials_version` than the configured indexer holds now, such as a
  login that finishes after an edit. `update/3` writes the jar a later answer changed, keeping
  `logged_in_at` and `expires_at`, and refuses when another login replaced the row meanwhile.

  An `Exqlite.Error`, as a write lock held past the busy timeout raises, answers `:not_written`
  from a write and `:miss` from `read/2`, and logs the indexer id and the error's module only.
  The two writes run with `log: false`, as `Cinder.Indexers` writes its ciphertext, so a debug
  log never holds the row's ciphertext.
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo
  alias Cinder.SecretCodec

  @scope "indexer_cookies"
  @lifetime_days 30

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "native_indexer_cookies" do
    field :ciphertext, :string, redact: true
    field :credentials_version, :integer
    field :logged_in_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end

  @typedoc "A stored session: its jar and the time of the login that made it."
  @type session :: %{jar: Jar.t(), logged_in_at: DateTime.t()}

  @doc "How long a login's cookies are used, in days: 30."
  @spec lifetime_days() :: pos_integer()
  def lifetime_days, do: @lifetime_days

  @doc "The stored session of `indexer` at `now`, or `:miss`; see the moduledoc."
  @spec read(ConfiguredIndexer.t(), DateTime.t()) :: {:ok, session()} | :miss
  def read(%ConfiguredIndexer{id: id} = indexer, %DateTime{} = now) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        :miss

      %__MODULE__{credentials_version: version} when version < indexer.credentials_version ->
        Repo.delete_all(
          from(c in __MODULE__,
            where: c.configured_indexer_id == ^id and c.credentials_version == ^version
          )
        )

        :miss

      %__MODULE__{} = row ->
        usable(row, indexer, now)
    end
  rescue
    error in Exqlite.Error -> not_written(id, error, :miss)
  end

  defp usable(row, indexer, now) do
    with true <- row.credentials_version == indexer.credentials_version,
         true <- DateTime.compare(row.expires_at, now) == :gt,
         {:ok, jar} <- open(row) do
      {:ok, %{jar: jar, logged_in_at: row.logged_in_at}}
    else
      _expired_unreadable_or_newer -> :miss
    end
  end

  defp open(%__MODULE__{configured_indexer_id: id, ciphertext: ciphertext}) do
    with {:ok, json} <- SecretCodec.decode(ciphertext),
         {:ok, %{"scope" => @scope, "id" => ^id, "jar" => entries} = envelope}
         when map_size(envelope) == 3 <- Jason.decode(json) do
      Jar.from_list(entries)
    else
      _unreadable -> :error
    end
  end

  defp seal(id, jar),
    do:
      SecretCodec.encode(
        Jason.encode!(%{"scope" => @scope, "id" => id, "jar" => Jar.to_list(jar)})
      )

  @doc """
  Stores `jar`, the cookies of a login of `indexer` at `now`, under the `credentials_version`
  `indexer` carries, with `expires_at` `lifetime_days/0` days after `now`. Answers `:written`,
  `:refused` when the configured indexer is gone or holds another `credentials_version` now, or
  `:not_written` on an `Exqlite.Error`.
  """
  @spec store_login(ConfiguredIndexer.t(), Jar.t(), DateTime.t()) ::
          :written | :refused | :not_written
  def store_login(%ConfiguredIndexer{id: id} = indexer, %Jar{} = jar, %DateTime{} = now)
      when is_integer(id) do
    now = usec(now)

    transact(id, fn ->
      if current_version(id) == indexer.credentials_version do
        row = %{
          configured_indexer_id: id,
          ciphertext: seal(id, jar),
          credentials_version: indexer.credentials_version,
          logged_in_at: now,
          expires_at: DateTime.add(now, @lifetime_days * 86_400, :second)
        }

        Repo.insert_all(__MODULE__, [row],
          on_conflict:
            {:replace, [:ciphertext, :credentials_version, :logged_in_at, :expires_at]},
          conflict_target: :configured_indexer_id,
          log: false
        )

        :written
      else
        :refused
      end
    end)
  end

  @doc """
  Stores `jar`, the session `session` read for `indexer` with the cookies a later answer set,
  keeping its `logged_in_at` and `expires_at`. Answers `:written`, `:refused` when the row is gone,
  another login replaced it (its `logged_in_at` moved) or the configured indexer holds another
  `credentials_version`, or `:not_written` on an `Exqlite.Error`.
  """
  @spec update(ConfiguredIndexer.t(), DateTime.t(), Jar.t()) :: :written | :refused | :not_written
  def update(%ConfiguredIndexer{id: id} = indexer, %DateTime{} = logged_in_at, %Jar{} = jar)
      when is_integer(id) do
    logged_in_at = usec(logged_in_at)

    transact(id, fn ->
      {count, _} =
        Repo.update_all(
          from(c in __MODULE__,
            where:
              c.configured_indexer_id == ^id and c.logged_in_at == ^logged_in_at and
                c.credentials_version == ^indexer.credentials_version
          ),
          [set: [ciphertext: seal(id, jar)]],
          log: false
        )

      if count == 1 and current_version(id) == indexer.credentials_version,
        do: :written,
        else: Repo.rollback(:refused)
    end)
  end

  defp transact(id, fun) do
    case Repo.transact(fn -> {:ok, fun.()} end) do
      {:ok, result} -> result
      {:error, :refused} -> :refused
    end
  rescue
    error in Exqlite.Error -> not_written(id, error, :not_written)
  end

  defp not_written(id, error, answer) do
    Logger.warning(
      "native indexer cookies of indexer #{id} not read or written: #{inspect(error.__struct__)}"
    )

    answer
  end

  # A time at microsecond precision, as the `:utc_datetime_usec` columns take it: Native's clock
  # can answer whole seconds.
  defp usec(%DateTime{microsecond: {value, _precision}} = time),
    do: %{DateTime.truncate(time, :microsecond) | microsecond: {value, 6}}

  defp current_version(id),
    do: Repo.one(from(c in ConfiguredIndexer, where: c.id == ^id, select: c.credentials_version))
end
