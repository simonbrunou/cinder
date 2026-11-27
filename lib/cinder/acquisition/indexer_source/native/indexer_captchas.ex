defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCaptchas do
  @moduledoc """
  The captcha session table (#1681; #1620 points 6, 9 and 11): one row per Cardigann configured
  indexer, holding what a captcha load read from the site's login page, so the login that
  carries the admin's answer posts the form the image belongs to. It is runtime state of
  `Cinder.Acquisition.IndexerSource.Native`, written only here; `Cinder.Indexers` never writes
  it, and deleting the configured indexer deletes its row (`ON DELETE CASCADE`).

  A row holds one ciphertext through `Cinder.SecretCodec`, whose plaintext names its scope
  (`"indexer_cookies"`), its kind (`"captcha"`) and the indexer's id, so a row copied to another
  indexer, or a cookie row's ciphertext, reads as unreadable. Inside it:

  - the load's token, which the dialog that showed the image hands back with the answer, so an
    answer read off one load never posts another load's form;
  - the binding: the base URL the load ran under and the hash of the copy it read, since the
    form and its cookies belong to that page;
  - the landing page's cookie jar (`Cinder.Acquisition.Indexer.Cardigann.Jar`), the image's
    `Set-Cookie` from a credential host merged in, the landing page's URL, and the form the
    login posts as `Cinder.Acquisition.Indexer.Cardigann.Login` exports it: no setting value.

  `expires_at` is `lifetime_seconds/0` after the load, as Prowlarr keeps its landing page in a
  5-minute rolling cache (`Cardigann.cs` line 124, `b0b5774`). The row carries no credential, so
  no `credentials_version` guards it: one save can change the password and answer the captcha.

  `store/3` replaces the row and answers the new load's token. `take/4` answers the session once
  and deletes it; `live?/4` reads it with no write. `take/4` answers `:miss`, and `live?/4`
  false, for no row, an expired row, a row that does not decrypt or names another indexer,
  another load's token, or another binding; `take/4` deletes the row on each of those but
  another load's token, which leaves the newer load's session for its own answer.

  An `Exqlite.Error`, as a write lock held past the busy timeout raises, answers `:not_written`
  from a write, `:miss` from `take/4` and false from `live?/4`, and logs the indexer id and the
  error's module only. The write runs with `log: false`, so a debug log never holds the row's
  ciphertext.
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo
  alias Cinder.SecretCodec

  @scope "indexer_cookies"
  @kind "captcha"
  @lifetime_seconds 300
  @keys ~w(scope kind id token address blob_sha jar landing form)

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "native_indexer_captchas" do
    field :ciphertext, :string, redact: true
    field :expires_at, :utc_datetime_usec
  end

  @typedoc """
  The base URL (`address`) and the copy's hash a load ran under. The key is no `base_url`, since
  no request reads it (`test/code_health/service_base_url_fragment_test.exs`).
  """
  @type binding :: %{address: String.t(), blob_sha: String.t() | nil}

  @typedoc "A captcha session as a load stores it and a take answers it."
  @type session :: %{
          binding: binding(),
          jar: Jar.t(),
          landing: String.t(),
          form: map()
        }

  @doc "How long a captcha session lives after its load, in seconds: 300."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc """
  Stores `session` for the configured indexer `id`, loaded at `now`, in place of any row, and
  answers `{:ok, token}`; `:refused` when the configured indexer is gone, or `:not_written` on an
  `Exqlite.Error`.
  """
  @spec store(pos_integer(), session(), DateTime.t()) ::
          {:ok, String.t()} | :refused | :not_written
  def store(id, %{binding: binding, jar: %Jar{} = jar} = session, %DateTime{} = now)
      when is_integer(id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    envelope = %{
      "scope" => @scope,
      "kind" => @kind,
      "id" => id,
      "token" => token,
      "address" => binding.address,
      "blob_sha" => binding.blob_sha,
      "jar" => Jar.to_list(jar),
      "landing" => session.landing,
      "form" => session.form
    }

    row = %{
      configured_indexer_id: id,
      ciphertext: SecretCodec.encode(Jason.encode!(envelope)),
      expires_at: DateTime.add(usec(now), @lifetime_seconds, :second)
    }

    transact(id, fn ->
      if Repo.exists?(from(c in ConfiguredIndexer, where: c.id == ^id)) do
        Repo.insert_all(__MODULE__, [row],
          on_conflict: {:replace, [:ciphertext, :expires_at]},
          conflict_target: :configured_indexer_id,
          log: false
        )

        {:ok, token}
      else
        :refused
      end
    end)
  end

  @doc """
  The session of the configured indexer `id` that the load `token` stored under `binding`, read
  at `now` and deleted; see the moduledoc.
  """
  @spec take(pos_integer(), String.t(), binding(), DateTime.t()) :: {:ok, session()} | :miss
  def take(id, token, binding, %DateTime{} = now) when is_integer(id) do
    result =
      transact(id, fn ->
        case read(id, token, binding, now) do
          {:ok, session} -> delete_row(id, {:ok, session})
          :other_load -> :miss
          :miss -> delete_row(id, :miss)
        end
      end)

    if result == :not_written, do: :miss, else: result
  end

  @doc "Whether `take/4` would answer a session now; it writes nothing."
  @spec live?(pos_integer(), String.t(), binding(), DateTime.t()) :: boolean()
  def live?(id, token, binding, %DateTime{} = now) when is_integer(id) do
    match?({:ok, _session}, read(id, token, binding, now))
  rescue
    error in Exqlite.Error -> not_written(id, error, false)
  end

  @doc "Deletes the session of the configured indexer `id`, if any: `:ok`, or `:not_written`."
  @spec delete(pos_integer()) :: :ok | :not_written
  def delete(id) when is_integer(id), do: transact(id, fn -> delete_row(id, :ok) end)

  defp delete_row(id, answer) do
    Repo.delete_all(from(c in __MODULE__, where: c.configured_indexer_id == ^id))
    answer
  end

  defp read(id, token, binding, now) do
    case Repo.get(__MODULE__, id) do
      nil -> :miss
      row -> usable(row, token, binding, now)
    end
  end

  defp usable(row, token, binding, now) do
    with true <- DateTime.compare(row.expires_at, now) == :gt,
         {:ok, envelope} <- open(row) do
      cond do
        not is_binary(token) or envelope["token"] != token ->
          :other_load

        envelope["address"] != binding.address or envelope["blob_sha"] != binding.blob_sha ->
          :miss

        true ->
          session(envelope, binding)
      end
    else
      _expired_or_unreadable -> :miss
    end
  end

  defp open(%__MODULE__{configured_indexer_id: id, ciphertext: ciphertext}) do
    with {:ok, json} <- SecretCodec.decode(ciphertext),
         {:ok, %{"scope" => @scope, "kind" => @kind, "id" => ^id} = envelope} <-
           Jason.decode(json),
         true <- Enum.sort(Map.keys(envelope)) == Enum.sort(@keys) do
      {:ok, envelope}
    else
      _unreadable -> :error
    end
  end

  defp session(%{"jar" => entries, "landing" => landing, "form" => form}, binding)
       when is_binary(landing) and is_map(form) do
    case Jar.from_list(entries) do
      {:ok, jar} -> {:ok, %{binding: binding, jar: jar, landing: landing, form: form}}
      _unreadable -> :miss
    end
  end

  defp session(_envelope, _binding), do: :miss

  defp transact(id, fun) do
    case Repo.transact(fn -> {:ok, fun.()} end) do
      {:ok, result} -> result
    end
  rescue
    error in Exqlite.Error -> not_written(id, error, :not_written)
  end

  defp not_written(id, error, answer) do
    Logger.warning(
      "native indexer captcha of indexer #{id} not read or written: #{inspect(error.__struct__)}"
    )

    answer
  end

  # A time at microsecond precision, as the `:utc_datetime_usec` column takes it: Native's clock
  # can answer whole seconds.
  defp usec(%DateTime{microsecond: {value, _precision}} = time),
    do: %{DateTime.truncate(time, :microsecond) | microsecond: {value, 6}}
end
