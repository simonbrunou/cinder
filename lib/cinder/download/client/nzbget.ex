defmodule Cinder.Download.Client.Nzbget do
  @moduledoc """
  `Cinder.Download.Client` implementation for NZBGet's JSON-RPC API.

  Cinder fetches NZB bytes through its own bounded SSRF policy, then submits them with a
  title-bearing `cinder-<operation_key>` filename. Queue and history records retain the NZBID,
  which is used as the stable download id through import and cleanup.
  """
  @behaviour Cinder.Download.Client

  alias Cinder.Download.Client.Fetch
  alias Cinder.Download.PathMapping
  alias Cinder.HTTPPolicy

  @default_url "http://localhost:6789/jsonrpc"
  @max_response_bytes 4 * 1024 * 1024
  @max_nzb_bytes 20 * 1024 * 1024
  @remote_path_prefix :nzbget_remote_path_prefix
  @local_path_prefix :nzbget_local_path_prefix
  @force_priority 900
  @operation_key_pattern ~r/cinder-([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})(?:\.nzb)?$/

  def add(release), do: add(release, [])

  @impl true
  def add(%{download_url: url} = release, opts) when is_binary(url) do
    fetch_opts = [
      max_bytes: @max_nzb_bytes,
      error_tag: :nzb_fetch_status,
      plug: config()[:fetch_plug],
      resolver: config()[:url_resolver]
    ]

    with {:ok, bytes} <- Fetch.bytes(url, Map.get(release, :download_url_origin), fetch_opts),
         {:ok, id} <- append(bytes, release, Keyword.get(opts, :operation_key)) do
      {:ok, to_string(id)}
    end
  end

  def add(%{download_url: _}, _opts), do: {:error, :unsupported_download_url}

  defp append(bytes, release, operation_key) do
    params = [
      nzb_name(release, operation_key),
      Base.encode64(bytes),
      "",
      0,
      false,
      false,
      "",
      0,
      "SCORE",
      false,
      []
    ]

    case rpc("append", params) do
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      {:ok, _} -> {:error, :add_rejected}
      {:error, _} = error -> error
    end
  end

  @impl true
  def find_by_operation_key(key) do
    wanted = "cinder-#{key}"

    with {:ok, queue} <- rpc_list("listgroups", [0]),
         {:ok, history} <- rpc_list("history", [false]) do
      ids =
        (queue ++ history)
        |> Enum.filter(&named?(&1, wanted))
        |> Enum.flat_map(&remote_id/1)
        |> Enum.uniq()

      case ids do
        [] -> :not_found
        [id] -> {:ok, id}
        [_ | _] -> {:error, :ambiguous_operation_key}
      end
    end
  end

  @impl true
  def status(id) do
    with {:ok, nzb_id} <- parse_id(id),
         {:ok, queue} <- rpc_list("listgroups", [0]) do
      case Enum.find(queue, &(&1["NZBID"] == nzb_id)) do
        nil -> history_status(nzb_id)
        item -> queue_status(item)
      end
    end
  end

  # A server-wide pause (`pausedownload`) leaves each waiting job at `QUEUED`, so only the
  # server's `DownloadPaused` tells it from a job about to start. NZBGet keeps downloading a job
  # of force priority (900) or above through that pause, so such a job keeps the stall clock. A
  # failed `status` call is a failed status, never a pause (#1602).
  defp queue_status(%{"Status" => "QUEUED"} = item) do
    with {:ok, paused?} <- download_paused() do
      {:ok, item |> classify_queue() |> server_pause(item, paused?)}
    end
  end

  defp queue_status(item), do: {:ok, classify_queue(item)}

  defp download_paused do
    case rpc("status", []) do
      {:ok, %{"DownloadPaused" => paused?}} when is_boolean(paused?) -> {:ok, paused?}
      {:ok, _} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  defp server_pause(report, %{"MaxPriority" => priority}, true)
       when is_integer(priority) and priority >= @force_priority,
       do: report

  defp server_pause(report, _item, true), do: Map.put(report, :client_paused, true)
  defp server_pause(report, _item, false), do: report

  defp history_status(nzb_id) do
    with {:ok, history} <- rpc_list("history", [false]) do
      case Enum.find(history, &(&1["NZBID"] == nzb_id)) do
        nil -> {:error, :not_found}
        item -> {:ok, classify_history(item)}
      end
    end
  end

  @impl true
  def files(id) do
    with {:ok, nzb_id} <- parse_id(id),
         {:ok, files} <- rpc_list("listfiles", [0, 0, nzb_id]) do
      {:ok, for(%{"Filename" => name} <- files, is_binary(name), do: name)}
    end
  end

  @impl true
  def list_managed do
    with {:ok, queue} <- rpc_list("listgroups", [0]),
         {:ok, history} <- rpc_list("history", [false]) do
      entries =
        Enum.flat_map(queue, fn item -> managed_entry(item, &classify_queue/1) end) ++
          Enum.flat_map(history, fn item -> managed_entry(item, &classify_history/1) end)

      {:ok, entries}
    end
  end

  defp managed_entry(item, classify) do
    with [id] <- remote_id(item),
         key when is_binary(key) <- operation_key(item) do
      entry = %{id: id, operation_key: key, state: classify.(item).state}

      # History items carry `HistoryTime` (Unix seconds); queue items have none.
      case item["HistoryTime"] do
        completed when is_integer(completed) -> [Map.put(entry, :completed_at, completed)]
        _ -> [entry]
      end
    else
      _ -> []
    end
  end

  @impl true
  def remove(id, _opts \\ []) do
    with {:ok, nzb_id} <- parse_id(id) do
      case rpc("editqueue", ["GroupFinalDelete", "", [nzb_id]]) do
        {:ok, true} -> :ok
        {:ok, false} -> remove_history(nzb_id)
        {:error, _} = error -> error
      end
    end
  end

  defp remove_history(nzb_id) do
    case rpc("editqueue", ["HistoryFinalDelete", "", [nzb_id]]) do
      {:ok, result} when result in [true, false] -> :ok
      {:ok, _} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  @impl true
  def health do
    probe = [receive_timeout: 3_000, connect_options: [timeout: 3_000]]

    case rpc("version", [], probe) do
      {:ok, version} when is_binary(version) -> mapping_health()
      {:ok, _version} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  # A `PAUSED` job is held on purpose while its health is at or above its critical health, as a
  # `GroupPause` leaves it, and it waits to be resumed (#1602). NZBGet's `HealthCheck=pause` also
  # pauses a job whose health fell below critical, a release missing too many articles to repair,
  # so a job below critical fails, whatever paused it. A job that does not report both its health
  # and critical health as integers fails as before.
  defp classify_queue(
         %{"Status" => "PAUSED", "Health" => health, "CriticalHealth" => critical} = item
       )
       when is_integer(health) and is_integer(critical) and health >= critical,
       do: item |> queue_report(:downloading) |> Map.put(:client_paused, true)

  defp classify_queue(
         %{"Status" => "PAUSED", "Health" => health, "CriticalHealth" => critical} = item
       )
       when is_integer(health) and is_integer(critical),
       do:
         item
         |> queue_report(:error)
         |> Map.put(
           :reason,
           "NZBGet's health check: health is below critical, too many articles are missing to repair the job."
         )

  defp classify_queue(%{"Status" => "PAUSED"} = item),
    do:
      item
      |> queue_report(:error)
      |> Map.put(:reason, "Paused by the download client; resume it in NZBGet, then retry.")

  defp classify_queue(item), do: queue_report(item, :downloading)

  defp queue_report(item, state),
    do: %{
      state: state,
      progress: queue_progress(item),
      speed: nil,
      eta: nil,
      content_path: nil
    }

  defp classify_history(%{"Status" => "SUCCESS/" <> _} = item),
    do: %{
      state: :completed,
      progress: 1.0,
      speed: nil,
      eta: nil,
      content_path: translated_path(item)
    }

  defp classify_history(item),
    do: %{
      state: :error,
      reason: history_reason(item["Status"]),
      progress: 1.0,
      speed: nil,
      eta: nil,
      content_path: nil
    }

  defp queue_progress(item) do
    total = bytes(item, "FileSize")
    remaining = bytes(item, "RemainingSize")

    if is_integer(total) and total > 0 and is_integer(remaining),
      do: max(min((total - remaining) / total, 1.0), 0.0),
      else: 0.0
  end

  defp bytes(item, prefix) do
    case {item["#{prefix}Hi"], item["#{prefix}Lo"]} do
      {high, low} when is_integer(high) and is_integer(low) -> high * 4_294_967_296 + low
      _ -> nil
    end
  end

  defp history_reason(status) when is_binary(status),
    do: "NZBGet reported #{String.downcase(status)}."

  defp history_reason(_status), do: "The download client reported the job failed."

  defp translated_path(item) do
    path = non_blank(item["FinalDir"]) || non_blank(item["DestDir"])

    PathMapping.translate(
      path,
      Application.get_env(:cinder, @remote_path_prefix),
      Application.get_env(:cinder, @local_path_prefix)
    )
  end

  defp non_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp non_blank(_value), do: nil

  defp rpc_list(method, params) do
    case rpc(method, params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  defp remote_id(%{"NZBID" => id}) when is_integer(id) and id > 0, do: [to_string(id)]
  defp remote_id(_item), do: []

  defp named?(item, wanted) do
    [item["NZBFilename"], item["NZBName"], item["Name"]]
    |> Enum.any?(fn
      value when is_binary(value) ->
        String.ends_with?(value, wanted) or String.ends_with?(value, wanted <> ".nzb")

      _ ->
        false
    end)
  end

  defp operation_key(item) do
    [item["NZBFilename"], item["NZBName"], item["Name"]]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        case Regex.run(@operation_key_pattern, value) do
          [_match, key] -> String.downcase(key)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  defp nzb_name(_release, key) when not is_binary(key), do: "cinder.nzb"

  defp nzb_name(release, key) do
    title =
      release
      |> Map.get(:title, "")
      |> to_string()
      |> String.slice(0, 120)
      |> String.replace(~r/[\x00-\x1f\\\/:*?"<>|{}=]+/, ".")
      |> String.trim(" .")

    prefix = if title == "", do: "download", else: title
    "#{prefix}.cinder-#{key}.nzb"
  end

  defp mapping_health do
    PathMapping.validate_local_prefix(
      Application.get_env(:cinder, @remote_path_prefix),
      Application.get_env(:cinder, @local_path_prefix)
    )
  end

  defp rpc(method, params, overrides \\ []) do
    request = %{"method" => method, "params" => params, "id" => 1}

    config()
    |> request_options(overrides)
    |> Req.new()
    |> Req.merge(method: :post, json: request)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> rpc_response()
  end

  defp request_options(config, overrides) do
    [
      url: Keyword.get(config, :base_url, @default_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      redirect: false
    ]
    |> maybe_auth(config)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(overrides)
  end

  defp maybe_auth(options, config) do
    case Keyword.get(config, :username) do
      username when is_binary(username) and username != "" ->
        Keyword.put(options, :auth, {:basic, "#{username}:#{Keyword.get(config, :password, "")}"})

      _ ->
        options
    end
  end

  defp rpc_response({:ok, %{status: 200, body: %{"error" => nil, "result" => result}}}),
    do: {:ok, result}

  defp rpc_response({:ok, %{status: 200, body: %{"error" => error}}}),
    do: {:error, {:nzbget_rpc, error}}

  defp rpc_response({:ok, %{status: status}}), do: {:error, {:nzbget_status, status}}
  defp rpc_response({:error, reason}), do: {:error, reason}

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
