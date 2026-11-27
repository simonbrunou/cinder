defmodule Cinder.CaptureServerGuard do
  @moduledoc """
  Reports and undoes the removal of `ExUnit.CaptureServer`'s log handler during a test run
  (#1716).

  `ExUnit.CaptureServer.log/2` (Elixir 1.20.5) formats each log event in a task per formatter
  and waits on them with `Task.await_many/1`'s default 5000 ms. When a log call raises or exits
  in it, such as that wait timing out, `:logger` removes the handler (`logger_backend`'s
  `call_handlers/3`, OTP 29.1.2) and prints only
  `Logger - error: {removed_failing_handler,'Elixir.ExUnit.CaptureServer'}`. CaptureServer adds
  its handler only when its first log capture opens, and removes it when its last one closes.
  So until no capture is open at all, every `capture_log` reads `""`, while other async tests
  keep a capture open.

  `install/0`, which `test/test_helper.exs` calls, sets the module level of `:logger_backend` to
  `:debug`, so `logger_backend` logs its `removed_failing_handler` report, and adds this module
  as a `:logger` handler at level `:all`, which receives that report under the suite's primary
  level `:warning`. That module level also lets `logger_backend`'s two other debug reports,
  `remove_handler_failed` and `removed_failing_filter`, reach the handlers; `log/2` ignores them.
  On a report for the CaptureServer handler, `log/2`:

    * runs `:sys.replace_state/3` on CaptureServer, so its check and its add run inside that
      process, in order with its own `log_capture_on` and `log_capture_off` calls. While its state
      holds at least one open log capture, it calls `:logger.add_handler/3` with the id, module
      and config that CaptureServer's own add uses. With no capture open it adds nothing, since
      CaptureServer adds the handler when the next capture opens: a handler already there makes
      that add crash CaptureServer with `{:badmatch, {:error, {:already_exist, ...}}}`. When the
      state is not a map with a `log_captures` map, as it could be in a later Elixir, it adds
      nothing. It returns the state unchanged in every case.
    * writes one line to the `:standard_error` process that was registered at install. A
      `capture_io(:stderr, ...)` registers a `StringIO` under that name while it runs, so the
      line goes to the VM's stderr even then. A partition of a bare `mix test` sends its stderr
      to its log, which the run prints whether the partition passed or failed
      (`Cinder.TestPartitions`). That run prints the log of the fence run it starts first,
      `test-partitions/fences.log` beside the build folder, only when the fences fail, so a line from a green fence run stays in that file. The line
      names the removed handler, the log
      event's level, pid and call site (its `mfa`, `file` and `line` metadata, each when present),
      the reason OTP gives and what the guard did, and asks for a `needs-triage` issue that
      quotes it.

  The handler never raises and never logs: `:logger` removes a handler that raises.

  What it cannot see:

    * a removal caused by an event that `:logger` itself logs, such as another handler's
      removal report: `logger_server:do_internal_log/5` sends the report on such an event to
      `logger_simple_h`, not to the handlers;
    * a run that unsets the `:logger_backend` module level, such as one that calls
      `Logger.delete_all_module_levels/0`. Only `Cinder.CaptureServerGuardTest`'s `install/1`
      test unsets it, while it runs, and sets it back in `on_exit`;
    * the raw `Logger - error:` line, which `:logger` prints with `erlang:display/1`. It still
      prints, also in `Cinder.CaptureServerGuardTest`, which removes the handler on purpose, so
      search a run's output for this guard's own line, not for that one.
  """

  @id __MODULE__
  @server ExUnit.CaptureServer

  @doc """
  Sets the `:logger_backend` module level to `:debug` and adds this module as the `:logger`
  handler `#{inspect(@id)}` at level `:all`, writing to the pid registered as `:standard_error`
  now.
  """
  @spec install() :: :ok
  def install, do: install(Process.whereis(:standard_error))

  @doc """
  `install/0` with the pid to write to, which `install/0` looks up. Raises, and changes nothing,
  when that pid is `nil`.
  """
  @spec install(pid() | nil) :: :ok
  def install(nil), do: raise("no :standard_error process to write to")

  def install(device) when is_pid(device) do
    :ok = :logger.set_module_level(:logger_backend, :debug)

    :ok =
      :logger.add_handler(@id, __MODULE__, %{
        level: :all,
        config: %{device: device, server: @server, handler_id: @server, handler_module: @server}
      })
  end

  @doc """
  The `:logger` handler callback. Acts only on `logger_backend`'s `removed_failing_handler`
  report for the handler that `config`'s `:handler_id` names, and returns `:ok` on every event.
  """
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{msg: {:report, report}}, %{config: config}) when is_list(report) do
    if removal_of?(report, config.handler_id) do
      try do
        outcome = restore(config)
        IO.write(config.device, line(report, config, outcome))
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  def log(_event, _config), do: :ok

  defp removal_of?(report, handler_id) do
    List.keyfind(report, :logger, 0) == {:logger, :removed_failing_handler} and
      match?({:handler, {^handler_id, _module}}, List.keyfind(report, :handler, 0))
  end

  # The fun sends its outcome before `:sys` replies from the same process, so the outcome is in
  # this process's mailbox when `replace_state/3` returns. `:infinity` matches CaptureServer's own
  # calls, and a request that timed out here would still run in CaptureServer later.
  defp restore(%{server: server, handler_id: handler_id, handler_module: module}) do
    caller = self()
    tag = make_ref()

    :sys.replace_state(
      server,
      fn state ->
        send(caller, {tag, restore_in(state, handler_id, module)})
        state
      end,
      :infinity
    )

    receive do
      {^tag, outcome} -> outcome
    end
  catch
    kind, reason -> {:failed, kind, reason}
  end

  defp restore_in(%{log_captures: captures}, handler_id, module) when is_map(captures) do
    case map_size(captures) do
      0 -> :no_capture
      open -> {:added, open, :logger.add_handler(handler_id, module, %{})}
    end
  end

  defp restore_in(state, _handler_id, _module), do: {:unknown_state, shape(state)}

  defp shape(state) when is_map(state), do: "a map with keys #{brief(Map.keys(state))}"
  defp shape(state), do: brief(state)

  defp line(report, config, outcome) do
    {:handler, {handler_id, module}} = List.keyfind(report, :handler, 0)

    "mix test: :logger removed the log handler #{inspect(handler_id)} (module " <>
      "#{inspect(module)}) after it failed on #{event(report)}, with reason " <>
      "#{reason(report)}. #{outcome(outcome, config)} File a needs-triage issue that quotes " <>
      "this line (#1716).\n"
  end

  defp event(report) do
    case List.keyfind(report, :log_event, 0) do
      {:log_event, %{level: level, meta: meta}} when is_map(meta) ->
        "#{inspect(level)} event from #{pid(meta)} at #{call_site(meta)}"

      _ ->
        "an event the report does not include"
    end
  end

  defp pid(%{pid: pid}), do: inspect(pid)
  defp pid(_meta), do: "an unknown pid"

  defp call_site(meta) do
    case mfa(meta) ++ file(meta) ++ line_number(meta) do
      [] -> "an unknown call site"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp mfa(%{mfa: {m, f, a}}), do: [Exception.format_mfa(m, f, a)]
  defp mfa(_meta), do: []

  defp file(%{file: file}) when is_binary(file) or is_list(file), do: [List.to_string([file])]
  defp file(_meta), do: []

  defp line_number(%{line: line}), do: ["line #{inspect(line)}"]
  defp line_number(_meta), do: []

  defp reason(report) do
    case List.keyfind(report, :reason, 0) do
      {:reason, reason} -> brief(reason)
      nil -> "unknown"
    end
  end

  defp outcome({:added, open, :ok}, config) do
    "The guard added it back inside #{inspect(config.server)}, which held #{open} open log " <>
      "captures."
  end

  defp outcome({:added, open, result}, config) do
    "With #{open} open log captures, :logger.add_handler/3 inside #{inspect(config.server)} " <>
      "returned #{brief(result)}."
  end

  defp outcome(:no_capture, config) do
    "The guard added nothing: #{inspect(config.server)} held no open log capture, and it adds " <>
      "the handler itself when the next one opens."
  end

  defp outcome({:unknown_state, shape}, config) do
    "The guard added nothing: the state of #{inspect(config.server)} is not a map with a " <>
      "log_captures map, as in Elixir 1.20.5, but #{shape}."
  end

  defp outcome({:failed, kind, reason}, config) do
    "The guard added nothing: :sys.replace_state/3 on #{inspect(config.server)} failed with " <>
      "#{inspect(kind)} #{brief(reason)}."
  end

  defp brief(term), do: inspect(term, limit: 50, printable_limit: 1000)
end
