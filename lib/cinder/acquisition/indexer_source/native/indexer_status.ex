defmodule Cinder.Acquisition.IndexerSource.Native.IndexerStatus do
  @moduledoc """
  The status table (#1654): one row per configured indexer holding its backoff state, so a search
  skips an indexer that is backing off. It is runtime state of
  `Cinder.Acquisition.IndexerSource.Native`, written only here; `Cinder.Indexers` never writes
  it, and deleting the configured indexer deletes its row (`ON DELETE CASCADE`). A row holds
  closed tags, counts and times only, never a URL, a header or a body.

  ## What an answer does

  `transition/3` takes one answer: `:success`, `:test_success`, a class of
  `Cinder.Acquisition.Indexer.NewznabAnswer`, or a tag of `Cinder.Acquisition.Indexer.request/3`.
  The rules are #1619 points 1, 3 and 11 as #1636 point 2 amends them:

  - `:success`, a search answer that reads: the level steps down one (not below 0), a failure
    backoff ends, the failure count goes to 0 and the last success is `now`. A limit backoff
    stays until its until-time; one that has ended clears. Rejected credentials stay.
  - `:test_success`, a passing Test (#1657 is to record it): a success that also ends rejected
    credentials.
  - A failure (`{:http_status, status}`, `{:indexer_error, code}`, `:timeout`,
    `:connection_failed`, `:bad_response`, `:too_large`, `:challenge`): the level climbs one, up
    to 9, and a failure backoff runs for that step of the ladder, 1, 5, 15 and 30 min, then 1, 3,
    6, 12 and 24 h. The failure count rises by one and the failure is the last failure.
  - `:dns` and `:connection_refused`: a failure that climbs no higher than level 1. A level
    already above 1 stays, and the backoff runs 1 min.
  - `{:disabled_till, wait}`, Prowlarr's 429 for an indexer in its own backoff: a failure that
    climbs the ladder, whose backoff ends at `wait`, clamped between 1 min and 24 h after `now`,
    or at the ladder step when `wait` is nil. Its last failure is `{:http_status, 429}`, the
    reason the report carries.
  - `{:limit, wait}`: a limit backoff until `NewznabAnswer.limit_until/2` of `wait`. The level
    and the failure count stay; the limit is the last failure.
  - `{:rejected_credentials, by}`: credentials rejected by `by`, `{:code, code}` or
    `{:http_status, 401}`; `:rejected_credentials` and a grab's `:indexer_auth_failed` (#1659)
    reject them with no code. No backoff starts or ends; the level and the failure count stay;
    it is the last failure.
  - `:crashed`, a search process that died or raised (Native records it): a failure.
  - `{:query_error, code}` and `:deadline`: no change.

  A limit replaces any backoff that runs. A failure replaces a failure backoff. During a limit
  backoff that has not ended, a failure keeps the limit and its end, and still climbs the level
  and the failure count, so a success, a passing Test and a `config_version` rise leave the limit
  running. A row holds one until-time, so the failure's own step, or a disabled-till wait, is then
  not kept: once the limit ends the indexer is asked again. Unless a success or a
  `config_version` rise lowers the level first, its next failure backs off from the level it
  climbed to.

  ## Edits

  `reset/2` applies a `config_version` rise: the last success clears, the level and the failure
  count go to 0, a failure backoff ends and rejected credentials end. A limit backoff stays, and a
  disable or re-enable, which leaves `config_version`, changes nothing. `read/1` applies it, and
  the next write stores the reset row under the new version.

  ## Writes

  `record/3` writes the row only when the answer, or a `config_version` reset the row had not
  stored yet, changes a field other than the last success, or for a success when the stored last
  success is missing, 15 minutes old or more, or not newer than the stored last failure. So a
  clean search on a clean indexer usually writes nothing. It drops the answer of a request that
  started under another `config_version` than the configured indexer has now, and the answer for
  a deleted indexer.
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo

  # The failure ladder, in seconds, by level (#1619 point 3).
  @ladder [60, 5 * 60, 15 * 60, 30 * 60, 3_600, 3 * 3_600, 6 * 3_600, 12 * 3_600, 24 * 3_600]
  @top_level length(@ladder)
  @success_write_s 15 * 60

  # Every failure reason the report can carry, so each one stores as `last_failure`.
  @failure_tags Report.failure_atoms() ++ [:http_status, :indexer_error, :limit]

  @fields [
    :config_version,
    :backoff,
    :level,
    :backoff_until,
    :failures_in_row,
    :last_failure,
    :last_failure_code,
    :last_failure_at,
    :credentials_rejected,
    :credentials_rejected_by,
    :credentials_rejected_code,
    :last_success_at
  ]

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "native_indexer_status" do
    field :config_version, :integer
    field :backoff, Ecto.Enum, values: [:none, :failure, :limit], default: :none
    field :level, :integer, default: 0
    field :backoff_until, :utc_datetime
    field :failures_in_row, :integer, default: 0
    field :last_failure, Ecto.Enum, values: @failure_tags
    field :last_failure_code, :integer
    field :last_failure_at, :utc_datetime
    field :credentials_rejected, :boolean, default: false
    field :credentials_rejected_by, Ecto.Enum, values: [:code, :http_status]
    field :credentials_rejected_code, :integer
    field :last_success_at, :utc_datetime
  end

  @type t :: %__MODULE__{}
  @type answer :: :success | :test_success | NewznabAnswer.class() | atom()

  @doc "The status of an indexer no answer has reached yet, at `config_version`."
  @spec new(integer()) :: t()
  def new(config_version), do: %__MODULE__{config_version: config_version}

  @doc """
  The status of each of `indexers` by id, its row's or `new/1`'s, with `reset/2` applied for the
  indexer's `config_version`.
  """
  @spec read([ConfiguredIndexer.t()]) :: %{integer() => t()}
  def read(indexers) do
    ids = Enum.map(indexers, & &1.id)
    rows = Repo.all(from(s in __MODULE__, where: s.configured_indexer_id in ^ids))
    rows = Map.new(rows, &{&1.configured_indexer_id, &1})

    Map.new(indexers, fn indexer ->
      {indexer.id, indexer |> stored(Map.get(rows, indexer.id)) |> reset(indexer.config_version)}
    end)
  end

  @doc """
  What a search does with an indexer of `status` at `now`: `:ask`, `{:failed,
  :rejected_credentials}` while its credentials are rejected, or `{:skipped, {:backoff, until}}`
  while a backoff runs, `until` after `now`.
  """
  @spec gate(t(), DateTime.t()) :: :ask | Report.outcome()
  def gate(%__MODULE__{credentials_rejected: true}, _now), do: {:failed, :rejected_credentials}

  def gate(%__MODULE__{backoff: kind, backoff_until: %DateTime{} = until}, now)
      when kind in [:failure, :limit] do
    if DateTime.compare(until, now) == :gt, do: {:skipped, {:backoff, until}}, else: :ask
  end

  def gate(%__MODULE__{}, _now), do: :ask

  @doc "`status` after a `config_version` rise to `config_version`; see the moduledoc."
  @spec reset(t(), integer()) :: t()
  def reset(%__MODULE__{config_version: stored} = status, config_version)
      when config_version > stored do
    limit = if status.backoff == :limit, do: [], else: [backoff: :none, backoff_until: nil]

    struct!(
      status,
      [
        config_version: config_version,
        level: 0,
        failures_in_row: 0,
        last_success_at: nil
      ] ++ limit ++ credentials_accepted()
    )
  end

  def reset(%__MODULE__{} = status, _config_version), do: status

  @doc "`status` after `answer` at `now`; see the moduledoc."
  @spec transition(t(), answer(), DateTime.t()) :: t()
  def transition(%__MODULE__{} = status, answer, %DateTime{} = now),
    do: step(status, answer, DateTime.truncate(now, :second))

  defp step(status, {:query_error, _code}, _now), do: status
  defp step(status, :deadline, _now), do: status

  defp step(status, :success, now) do
    # A success ends a failure backoff, and clears a limit backoff only once it has ended.
    backoff =
      if status.backoff == :failure or not running?(status, now),
        do: [backoff: :none, backoff_until: nil],
        else: []

    struct!(
      status,
      [level: max(status.level - 1, 0), failures_in_row: 0, last_success_at: now] ++ backoff
    )
  end

  defp step(status, :test_success, now),
    do: status |> step(:success, now) |> struct!(credentials_accepted())

  defp step(status, {:limit, wait}, now) do
    status
    |> start_backoff(:limit, NewznabAnswer.limit_until(wait, now), now)
    |> last_failure(:limit, nil, now)
  end

  defp step(status, {:rejected_credentials, {by, code}}, now)
       when by in [:code, :http_status] and is_integer(code),
       do: reject(status, by, code, now)

  defp step(status, tag, now) when tag in [:rejected_credentials, :indexer_auth_failed],
    do: reject(status, nil, nil, now)

  defp step(status, {:disabled_till, wait}, now) do
    level = min(status.level + 1, @top_level)
    until = if wait, do: NewznabAnswer.limit_until(wait, now), else: ladder_until(level, now)
    failure(status, level, until, {:http_status, 429}, now)
  end

  defp step(status, tag, now) when tag in [:dns, :connection_refused] do
    level = max(status.level, 1)
    failure(status, level, DateTime.add(now, hd(@ladder), :second), tag, now)
  end

  defp step(status, reason, now) do
    unless Report.outcome?({:failed, reason}),
      do: raise(ArgumentError, "not an indexer answer: #{inspect(reason)}")

    level = min(status.level + 1, @top_level)
    failure(status, level, ladder_until(level, now), reason, now)
  end

  defp reject(status, by, code, now) do
    status
    |> struct!(
      credentials_rejected: true,
      credentials_rejected_by: by,
      credentials_rejected_code: code
    )
    |> last_failure(:rejected_credentials, nil, now)
  end

  defp failure(status, level, until, reason, now) do
    {tag, code} = tag_and_code(reason)

    status
    |> struct!(level: level, failures_in_row: status.failures_in_row + 1)
    |> start_backoff(:failure, until, now)
    |> last_failure(tag, code, now)
  end

  defp tag_and_code({tag, code}) when is_integer(code), do: {tag, code}
  defp tag_and_code(tag) when is_atom(tag), do: {tag, nil}

  defp ladder_until(level, now), do: DateTime.add(now, Enum.at(@ladder, level - 1), :second)

  # A failure during a limit that has not ended keeps the limit and its end.
  defp start_backoff(%__MODULE__{backoff: :limit} = status, :failure, until, now) do
    if running?(status, now),
      do: status,
      else: struct!(status, backoff: :failure, backoff_until: until)
  end

  defp start_backoff(status, kind, until, _now),
    do: struct!(status, backoff: kind, backoff_until: until)

  defp running?(%__MODULE__{backoff_until: %DateTime{} = until}, now),
    do: DateTime.compare(until, now) == :gt

  defp running?(%__MODULE__{}, _now), do: false

  defp last_failure(status, tag, code, now),
    do: struct!(status, last_failure: tag, last_failure_code: code, last_failure_at: now)

  defp credentials_accepted,
    do: [
      credentials_rejected: false,
      credentials_rejected_by: nil,
      credentials_rejected_code: nil
    ]

  @doc """
  Records `answer`, which a request to `indexer` got at `now`, and answers `:written`,
  `:unchanged` (no field to write; see the moduledoc) or `:dropped` (the indexer is gone, or its
  `config_version` is no longer the one `indexer` carries).

  An `Exqlite.Error`, as a write lock held past the busy timeout raises, answers `:not_written`
  and logs a warning naming the indexer id and the error's module only, so the search that made the
  request keeps its rows and its outcome.
  """
  @spec record(ConfiguredIndexer.t(), answer(), DateTime.t()) ::
          :written | :unchanged | :dropped | :not_written
  def record(%ConfiguredIndexer{id: id} = indexer, answer, %DateTime{} = now)
      when is_integer(id) do
    record_now(indexer, answer, DateTime.truncate(now, :second))
  rescue
    error in Exqlite.Error ->
      Logger.warning(
        "native indexer status of indexer #{id} not recorded: #{inspect(error.__struct__)}"
      )

      :not_written
  end

  defp record_now(indexer, answer, now) do
    # The common case, a clean success on a clean indexer, decides with no transaction.
    case outcome(indexer, answer, now) do
      {:write, _status} -> Repo.transact(fn -> {:ok, write(indexer, answer, now)} end)
      other -> other
    end
    |> case do
      {:ok, result} -> result
      result -> result
    end
  end

  defp write(indexer, answer, now) do
    case outcome(indexer, answer, now) do
      {:write, status} ->
        Repo.insert_all(__MODULE__, [Map.take(status, [:configured_indexer_id | @fields])],
          on_conflict: {:replace, @fields},
          conflict_target: :configured_indexer_id
        )

        :written

      other ->
        other
    end
  end

  defp outcome(%ConfiguredIndexer{id: id, config_version: started}, answer, now) do
    case current_version(id) do
      ^started ->
        stored = Repo.get(__MODULE__, id)

        status =
          %{configured_indexer_id: id, config_version: started}
          |> stored_or_new(stored)
          |> reset(started)

        changed = transition(status, answer, now)
        if write?(stored, changed), do: {:write, changed}, else: :unchanged

      _gone_or_edited ->
        :dropped
    end
  end

  defp current_version(id),
    do: Repo.one(from(c in ConfiguredIndexer, where: c.id == ^id, select: c.config_version))

  defp stored(indexer, row),
    do:
      stored_or_new(
        %{configured_indexer_id: indexer.id, config_version: indexer.config_version},
        row
      )

  defp stored_or_new(_key, %__MODULE__{} = row), do: row

  defp stored_or_new(%{configured_indexer_id: id, config_version: version}, nil),
    do: %{new(version) | configured_indexer_id: id}

  defp write?(nil, status), do: status != stored_or_new(status, nil)

  defp write?(%__MODULE__{} = stored, status) do
    cond do
      Map.take(stored, @fields -- [:last_success_at]) !=
          Map.take(status, @fields -- [:last_success_at]) ->
        true

      stored.last_success_at == status.last_success_at ->
        false

      true ->
        success_due?(stored, status.last_success_at)
    end
  end

  defp success_due?(%__MODULE__{last_success_at: nil}, _now), do: true

  defp success_due?(%__MODULE__{last_success_at: last} = stored, now) do
    DateTime.diff(now, last, :second) >= @success_write_s or
      (stored.last_failure_at != nil and DateTime.compare(stored.last_failure_at, last) != :lt)
  end
end
