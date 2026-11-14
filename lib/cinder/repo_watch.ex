defmodule Cinder.RepoWatch do
  @moduledoc """
  Logs who holds SQLite's write lock, who waits for a pool connection, and when the node stalls
  (#1310). Every line starts with `db watch:`, so `grep 'db watch:'` lists them all. A hold or
  stall line logged at time T with a duration D covers T - D to T; a queue line says what else
  its D leaves out.

  - `db watch: hold <D> ms, <outcome> (begin wait <ms> ms, in SQL <ms> ms, <commit|rollback>
    <ms> ms) by <opener> in <process>`: a transaction that held the write lock for the hold
    threshold or longer. The hold runs from BEGIN's return, when `default_transaction_mode:
    :immediate` has taken the lock, to COMMIT's or ROLLBACK's return. `begin wait` is BEGIN's own
    time, the wait for another holder, and is not part of the hold. `in SQL` sums the statements
    run inside; the rest of the hold is Elixir code, the COMMIT, or a stall. The outcome is
    `committed`, `commit failed`, `rolled back` or `rollback failed`. A nested transaction emits
    no events of its own, so only the outermost logs. A failed BEGIN is a waiter and logs no hold.
    A transaction whose process is killed before COMMIT or ROLLBACK emits no end event, so it
    logs nothing. When the pool disconnects a transaction's connection on its `:timeout`, SQLite
    frees the lock then, but the line, `rollback failed`, comes only when the transaction's
    process reaches its ROLLBACK, so D can run past the lock.
  - `db watch: hold <D> ms, statement <KEYWORD> [on <table>] by <opener> in <process>`: a
    statement outside any transaction whose query time reached the hold threshold. That time
    includes the statement's own wait for the lock, so such a line can name a waiter too.
  - `db watch: queue <D> ms, then <KEYWORD> <Q> ms, by <opener> in <process>`: a checkout that
    waited the queue threshold or longer for a pool connection, a failed one included. The wait
    rides on the event of the first call after the checkout, a BEGIN or a statement, which logs
    only once that call has run for Q ms, its own wait for the lock included. So a queue line
    logged at T covers T - Q - D to T - Q. No event inside `Repo.checkout/2` carries its wait,
    so it logs none.
  - `db watch: stall, tick <D> ms late`, from `Cinder.RepoWatch.Stall`.

  The opener is a frame of the stack Ecto captures at the Repo call, which `stacktrace: true` in
  `config/config.exs` turns on: the first `Cinder.` or `CinderWeb.` frame other than the repo
  and `Cinder.GuardedWrite`, which only wrap the call, else the first frame outside them, Ecto
  and DBConnection. A function that calls the Repo as its last expression leaves no frame
  of its own, so the line names its caller. Raw SQL (`Repo.query/3`) carries no stack and prints
  `unknown`. The process is its registered name, else its `$initial_call`, else its initial call,
  then its pid.

  No line holds a bound parameter, a row value or the SQL text: a statement line names only the
  statement's first keyword and its table.

  Each threshold is 1 s unless `config :cinder, Cinder.RepoWatch` sets `hold_ms`, `queue_ms` or
  `stall_ms`. `Cinder.Application` attaches the handler before `Cinder.Repo` starts, and starts
  the ticker, unless `:start_repo_watch` is false. The test env sets it false: a hold of over a
  second on a loaded runner would fail a test that refuses warnings. A watch test attaches its own
  handler through `attach/1`.
  """

  require Logger

  alias Cinder.RepoWatch.{Hold, Thresholds}

  @prefix "db watch:"
  @event [:cinder, :repo, :query]
  @wrappers [Cinder.GuardedWrite]

  # The handler's config, which `:telemetry` passes to each call of `handle_event/4`.
  @enforce_keys [:hold_ms, :queue_ms, :clock]
  defstruct @enforce_keys

  @doc "The fixed prefix every line starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The clock every hold and stall is measured on: monotonic time in milliseconds."
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc "The hold, queue and stall thresholds in ms: 1 s each unless app config sets them."
  @spec thresholds() :: Thresholds.t()
  def thresholds, do: Thresholds.read()

  @doc false
  # A child of Cinder.Supervisor that attaches the handler and starts no process.
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc false
  def start_link(opts) do
    attach(opts)
    :ignore
  end

  @doc """
  Attaches the handler to `Cinder.Repo`'s query event. Options, for tests: `:handler_id`
  (default `Cinder.RepoWatch`), `:event`, `:clock` (a 0-arity function returning milliseconds,
  default `monotonic_ms/0`), and `:hold_ms` and `:queue_ms`, which override `thresholds/0`.
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    defaults = thresholds()

    config = %__MODULE__{
      hold_ms: Keyword.get(opts, :hold_ms, defaults.hold),
      queue_ms: Keyword.get(opts, :queue_ms, defaults.queue),
      clock: Keyword.get(opts, :clock, &__MODULE__.monotonic_ms/0)
    }

    :telemetry.attach(
      Keyword.get(opts, :handler_id, __MODULE__),
      Keyword.get(opts, :event, @event),
      &__MODULE__.handle_event/4,
      config
    )
  end

  @doc """
  The telemetry handler. `:telemetry` detaches a handler that raises, for good, so this one
  catches anything its own code raises and logs one `db watch:` error line instead.
  """
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(_event, measurements, metadata, config) do
    queue(measurements, metadata, config)
    observe(metadata[:query], measurements, metadata, config)
    :ok
  catch
    kind, reason ->
      reason = Exception.normalize(kind, reason, __STACKTRACE__)
      Logger.error("#{@prefix} handler failed with #{kind} #{describe(reason)}")
      :ok
  end

  defp queue(measurements, metadata, config) do
    case measurements[:queue_time] do
      native when is_integer(native) ->
        waited = ms(native)

        if waited >= config.queue_ms do
          Logger.warning(
            "#{@prefix} queue #{waited} ms, then #{keyword(metadata[:query])} " <>
              "#{ms(measurements[:query_time])} ms, by #{opener(metadata)} in #{process()}"
          )
        end

      _ ->
        :ok
    end
  end

  defp observe("begin", measurements, %{result: {:ok, _}} = metadata, config) do
    open = %Hold{start: now(config), begin: ms(measurements[:query_time])}
    Process.put(key(metadata), open)
  end

  defp observe("begin", _measurements, _metadata, _config), do: :ok

  defp observe(query, measurements, metadata, config) when query in ["commit", "rollback"] do
    case Process.delete(key(metadata)) do
      nil -> :ok
      open -> finish(open, query, measurements, metadata, config)
    end
  end

  defp observe(query, measurements, metadata, config) when is_binary(query) do
    if metadata.repo.in_transaction?() do
      add_sql(measurements, metadata)
    else
      statement(query, measurements, metadata, config)
    end
  end

  defp observe(_query, _measurements, _metadata, _config), do: :ok

  defp finish(open, query, measurements, metadata, config) do
    held = now(config) - open.start

    if held >= config.hold_ms do
      Logger.warning(
        "#{@prefix} hold #{held} ms, #{outcome(query, metadata[:result])} " <>
          "(begin wait #{open.begin} ms, in SQL #{open.sql} ms, " <>
          "#{query} #{ms(measurements[:query_time])} ms) " <>
          "by #{opener(metadata)} in #{process()}"
      )
    end
  end

  defp add_sql(measurements, metadata) do
    case Process.get(key(metadata)) do
      %Hold{sql: sql} = open ->
        Process.put(key(metadata), %Hold{open | sql: sql + ms(measurements[:query_time])})

      nil ->
        :ok
    end
  end

  defp statement(query, measurements, metadata, config) do
    took = ms(measurements[:query_time])

    if took >= config.hold_ms do
      Logger.warning(
        "#{@prefix} hold #{took} ms, statement #{keyword(query)}#{table(metadata[:source])} " <>
          "by #{opener(metadata)} in #{process()}"
      )
    end
  end

  defp outcome("commit", {:ok, _}), do: "committed"
  defp outcome("commit", _result), do: "commit failed"
  defp outcome("rollback", {:ok, _}), do: "rolled back"
  defp outcome("rollback", _result), do: "rollback failed"

  defp keyword(query) when is_binary(query) do
    case Regex.run(~r/^\s*([A-Za-z]+)/, query) do
      [_, word] -> String.upcase(word)
      nil -> "?"
    end
  end

  defp keyword(_query), do: "?"

  defp table(source) when is_binary(source), do: " on #{source}"
  defp table(_source), do: ""

  defp opener(%{stacktrace: [_ | _] = stack} = metadata) do
    wrappers = [metadata[:repo] | @wrappers]
    frames = Enum.reject(stack, &library_frame?(&1, wrappers))

    case Enum.find(frames, &cinder_frame?/1) || List.first(frames) do
      nil -> "unknown"
      frame -> format_frame(frame)
    end
  end

  defp opener(_metadata), do: "unknown"

  defp library_frame?({module, _fun, _arity, _location}, wrappers) when is_atom(module) do
    module in wrappers or
      String.starts_with?(Atom.to_string(module), ["Elixir.Ecto.", "Elixir.DBConnection"])
  end

  defp library_frame?(_frame, _wrappers), do: true

  defp cinder_frame?({module, _fun, _arity, _location}) do
    String.starts_with?(Atom.to_string(module), ["Elixir.Cinder.", "Elixir.CinderWeb."])
  end

  # A frame captured from an exception can carry the call's arguments instead of its arity, so
  # only their count is printed.
  defp format_frame({module, fun, args, location}) do
    arity = if is_list(args), do: length(args), else: args
    mfa = Exception.format_mfa(module, fun, arity)

    case {location[:file], location[:line]} do
      {file, line} when not is_nil(file) and is_integer(line) -> "#{mfa} (#{file}:#{line})"
      _ -> mfa
    end
  end

  defp process do
    pid = self()

    label =
      case Process.info(pid, :registered_name) do
        {:registered_name, name} when is_atom(name) -> inspect(name)
        _ -> initial_call(pid)
      end

    "#{label} #{inspect(pid)}"
  end

  defp initial_call(pid) do
    case Process.get(:"$initial_call") || Process.info(pid, :initial_call) do
      {module, fun, arity} -> Exception.format_mfa(module, fun, arity)
      {:initial_call, {module, fun, arity}} -> Exception.format_mfa(module, fun, arity)
      _ -> "unnamed"
    end
  end

  # Only the exception's module: its message or a raw reason can hold the event's metadata.
  defp describe(%{__struct__: struct}), do: inspect(struct)
  defp describe(_reason), do: "a non-exception value"

  defp key(metadata), do: {__MODULE__, metadata[:repo]}

  defp now(%{clock: clock}), do: clock.()

  defp ms(native) when is_integer(native),
    do: System.convert_time_unit(native, :native, :millisecond)

  defp ms(_native), do: 0
end
