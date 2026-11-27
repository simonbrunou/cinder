defmodule Cinder.Acquisition.IndexerSource.Native.IndexerState do
  @moduledoc """
  Each configured indexer's condition, read from what Native recorded (#1657, #1619 points 13
  and 14): the one function the dashboard rows, the source's `health/0`, the gate, the indexers
  table (#1660) and the setup gate (#1663) read. No function here sends a request.

  ## The states

  `list/1` gives one entry per configured indexer, disabled ones and ones whose secrets do not
  decrypt included. The first rule that matches gives the state:

  1. `:disabled`: the admin turned it off.
  2. `:undecryptable`: its stored secrets do not decrypt.
  3. `{:not_supported, feature}`: its type has no adapter (`feature` is the type), or its
     FlareSolverr toggle is on (`:flaresolverr`), as `Native.not_supported/2` says.
  4. For a Cardigann indexer, from `Cinder.Indexers.Definitions.indexer_codes/0` (#1668):
     `{:not_supported, feature}` when its running copy reads not supported, `feature` being the
     copy's first code, and `{:definition_no_longer_loads, reason}` when its running copy fails
     to load on this build.
  5. `{:credentials_rejected, by}`: an answer rejected its credentials; `by` is `{:code, code}`,
     `{:http_status, 401}`, `{:login_rejected, method}` for a refused Cardigann login (#1680),
     `:captcha_required` for a Cardigann login that met its image captcha with no answer from
     the admin (#1681), or nil for a rejection with no code.
  6. `{:limit_backoff, until}`: a limit backoff runs until `until`.
  7. `{:failure_backoff, until, last_failure, failures_in_row}`: a failure backoff runs until
     `until`.
  8. `{:retry_due, ended_at, last_failure, failures_in_row}`: a backoff ended at `ended_at` with
     failures in a row still counted, or a limit ended at `ended_at` with no success after it
     (`failures_in_row` 0), so the next search asks it again. `last_failure` is `:limit` when a
     limit came after those failures.
  9. `{:usable, last_success_at}`: a success is recorded, no failure counts since it, and no
     limit came after it: the last outcome was a success. Rejected credentials count no
     failure, and a `config_version` rise clears the last success. A Cardigann indexer whose
     definition code is not red reads it here instead, with the same time, and stays usable,
     since it keeps searching on its running copy: `{:definition_update_held, reason,
     last_success_at}`, `{:removed_upstream, last_success_at}` or `{:replaced_by, name,
     last_success_at}`.
  10. `:never_checked`: no success since its last `config_version` rise, no failure in a row,
     and no limit.

  Rules 2 to 5 need the admin (`needs_admin?/1`), and rules 6 to 8 wait themselves out, so red
  wins over a wait and over a definition code that is not red.
  `last_failure` is a reason of `Cinder.Acquisition.IndexerSource.Report` with its code, such as
  `{:http_status, 410}`, `:timeout` or `:limit`.

  A running backoff is one whose until-time is after `now`, as `IndexerStatus.gate/2` reads it.
  """

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Indexers
  alias Cinder.Indexers.Definitions

  @type state ::
          :disabled
          | :undecryptable
          | {:not_supported, atom()}
          | {:credentials_rejected,
             {:code | :http_status, integer()}
             | {:login_rejected, :post | :get | :form | :cookie}
             | :captcha_required
             | nil}
          | {:limit_backoff, DateTime.t()}
          | {:failure_backoff, DateTime.t(), term(), pos_integer()}
          | {:retry_due, DateTime.t(), term(), non_neg_integer()}
          | {:definition_no_longer_loads, term()}
          | {:usable, DateTime.t()}
          | {:definition_update_held, term(), DateTime.t()}
          | {:removed_upstream, DateTime.t()}
          | {:replaced_by, String.t(), DateTime.t()}
          | :never_checked

  @type entry :: %{
          id: pos_integer(),
          name: String.t(),
          type: atom(),
          protocol: :usenet | :torrent,
          enabled: boolean(),
          state: state(),
          last_test: IndexerStatus.last_test() | nil
        }

  @doc """
  Every configured indexer by priority, then id, with its state at `now` (Native's clock by
  default) and its last Test. An entry is a plain map: it holds no URL and no secret.
  """
  @spec list(DateTime.t()) :: [entry()]
  def list(now \\ Native.now()) do
    indexers = Indexers.list()
    statuses = IndexerStatus.read(indexers)
    adapters = Application.fetch_env!(:cinder, :indexer_adapters)
    codes = definition_codes(indexers)

    Enum.map(indexers, fn indexer ->
      status = Map.fetch!(statuses, indexer.id)
      code = Map.get(codes, indexer.id)

      %{
        id: indexer.id,
        name: indexer.name,
        type: indexer.type,
        protocol: protocol(indexer.type),
        enabled: indexer.enabled,
        state: state(indexer, status, adapters, now, code),
        last_test: IndexerStatus.last_test(status)
      }
    end)
  end

  @doc """
  Whether `entry` is usable: enabled, supported, credentials not rejected, no backoff running,
  and a last outcome that was a success (rule 9 of the moduledoc, a definition code that is not
  red included).
  """
  @spec usable?(entry()) :: boolean()
  def usable?(%{state: state}), do: usable_state?(state)

  @doc """
  Whether `state` needs the admin: rules 2 to 5 of the moduledoc. On `Cinder.Health`'s row for
  an enabled indexer these states show red, `{:usable, _}` green, and every other state yellow,
  the usable states that carry a definition code included.
  """
  @spec needs_admin?(state()) :: boolean()
  def needs_admin?(:undecryptable), do: true

  def needs_admin?({tag, _detail})
      when tag in [:not_supported, :definition_no_longer_loads, :credentials_rejected],
      do: true

  def needs_admin?(_state), do: false

  defp usable_state?({:usable, _at}), do: true
  defp usable_state?({:definition_update_held, _reason, _at}), do: true
  defp usable_state?({:removed_upstream, _at}), do: true
  defp usable_state?({:replaced_by, _name, _at}), do: true
  defp usable_state?(_state), do: false

  @doc """
  The source's health for `entries`, which `list/1` judged at `now` (#1619 point 6, #1623
  point 9), what `Native.health/0` answers:

  - `{:error, :no_indexer_added}` with no entry, `{:error, :no_indexer_enabled}` with none
    enabled;
  - `:ok` when every enabled entry is usable;
  - otherwise `{:warning, reason}` when some enabled entry is usable, else `{:error, reason}`.
    `reason` is `{:native_indexers, listed, more, now}`: the first 5 enabled entries that are
    not usable, each `%{name: name, state: state}`, in `list/1` order, how many more there are,
    and the instant they were judged at, which their text counts its waits and dates from.
  """
  @spec health([entry()], DateTime.t()) :: :ok | {:warning, term()} | {:error, term()}
  def health([], _now), do: {:error, :no_indexer_added}

  def health(entries, now) do
    enabled = Enum.filter(entries, & &1.enabled)
    {usable, unusable} = Enum.split_with(enabled, &usable?/1)

    cond do
      enabled == [] -> {:error, :no_indexer_enabled}
      unusable == [] -> :ok
      usable == [] -> {:error, reason(unusable, now)}
      true -> {:warning, reason(unusable, now)}
    end
  end

  @listed 5

  defp reason(unusable, now) do
    listed = for entry <- Enum.take(unusable, @listed), do: Map.take(entry, [:name, :state])
    {:native_indexers, listed, max(length(unusable) - @listed, 0), now}
  end

  @doc """
  The gate (#1623 point 1): true when some enabled indexer is usable or in a running limit
  backoff. An ended limit fails it until the next answer, as an ended failure backoff does: a
  limit kept across an edit tells nothing about the new settings. A never-checked indexer does
  not pass, and with no enabled indexer the gate fails.
  """
  @spec passes_gate?(DateTime.t()) :: boolean()
  def passes_gate?(now \\ Native.now()), do: Enum.any?(list(now), &passes?/1)

  @doc """
  Whether `entry` alone passes the gate `passes_gate?/1` applies to the whole list: it is usable
  (`usable?/1`) or in a running limit backoff. A disabled entry never passes.
  """
  @spec passes?(entry()) :: boolean()
  def passes?(%{state: state}),
    do: usable_state?(state) or match?({:limit_backoff, _until}, state)

  defp protocol(:newznab), do: :usenet
  defp protocol(_torrent_type), do: :torrent

  # Only Cardigann rows have definition codes, so the query runs only when one is listed.
  defp definition_codes(indexers) do
    if Enum.any?(indexers, &(&1.type == :cardigann)),
      do: Definitions.indexer_codes(),
      else: %{}
  end

  defp state(%{enabled: false}, _status, _adapters, _now, _code), do: :disabled
  defp state(%{secrets_readable: false}, _status, _adapters, _now, _code), do: :undecryptable

  defp state(indexer, status, adapters, now, code) do
    case {Native.not_supported(indexer, adapters), code} do
      {nil, {:not_supported, feature}} -> {:not_supported, feature}
      {nil, {:no_longer_loads, reason}} -> {:definition_no_longer_loads, reason}
      {nil, code} -> status |> recorded_state(now) |> with_code(code)
      {feature, _code} -> {:not_supported, feature}
    end
  end

  # A definition code that is not red stands in for a usable state only.
  defp with_code({:usable, at}, {:held, reason}), do: {:definition_update_held, reason, at}
  defp with_code({:usable, at}, :removed_upstream), do: {:removed_upstream, at}
  defp with_code({:usable, at}, {:replaced_by, name}), do: {:replaced_by, name, at}
  defp with_code(state, _code), do: state

  defp recorded_state(%IndexerStatus{credentials_rejected: true} = status, _now),
    do: {:credentials_rejected, rejected_by(status)}

  defp recorded_state(status, now) do
    running? = status.backoff_until != nil and DateTime.compare(status.backoff_until, now) == :gt

    case {running?, status.backoff} do
      {true, :limit} ->
        {:limit_backoff, status.backoff_until}

      {true, :failure} ->
        {:failure_backoff, status.backoff_until, last_failure(status), status.failures_in_row}

      _settled ->
        settled_state(status)
    end
  end

  # The state of an indexer with no backoff running.
  defp settled_state(status) do
    cond do
      status.failures_in_row > 0 ->
        {:retry_due, status.backoff_until, last_failure(status), status.failures_in_row}

      # A limit that has ended stays the last outcome until a success comes after it (#1619
      # point 6: usable needs a last outcome that was a success).
      status.backoff == :limit and not success_after_limit?(status) ->
        {:retry_due, status.backoff_until, :limit, 0}

      status.last_success_at != nil ->
        {:usable, status.last_success_at}

      true ->
        :never_checked
    end
  end

  # A limit stamps itself as the last failure (`IndexerStatus.transition/3`), so a success after
  # it is one stamped later.
  defp success_after_limit?(%IndexerStatus{last_success_at: success, last_failure_at: limit}),
    do: success != nil and DateTime.compare(success, limit) == :gt

  defp rejected_by(%IndexerStatus{credentials_rejected_by: nil}), do: nil

  defp rejected_by(%IndexerStatus{credentials_rejected_by: :login_post}),
    do: {:login_rejected, :post}

  defp rejected_by(%IndexerStatus{credentials_rejected_by: :login_get}),
    do: {:login_rejected, :get}

  defp rejected_by(%IndexerStatus{credentials_rejected_by: :login_form}),
    do: {:login_rejected, :form}

  defp rejected_by(%IndexerStatus{credentials_rejected_by: :login_cookie}),
    do: {:login_rejected, :cookie}

  defp rejected_by(%IndexerStatus{credentials_rejected_by: :captcha}), do: :captcha_required

  defp rejected_by(%IndexerStatus{credentials_rejected_by: by, credentials_rejected_code: code}),
    do: {by, code}

  defp last_failure(%IndexerStatus{last_failure: tag, last_failure_code: nil}), do: tag
  defp last_failure(%IndexerStatus{last_failure: tag, last_failure_code: code}), do: {tag, code}
end
