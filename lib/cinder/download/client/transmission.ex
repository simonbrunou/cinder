defmodule Cinder.Download.Client.Transmission do
  @moduledoc """
  `Cinder.Download.Client` implementation for Transmission 3+.

  Transmission's RPC endpoint uses HTTP Basic authentication and a CSRF session id. Cinder
  retries the initial 409 response once with the returned session id and marks every submitted
  torrent with a `cinder-<operation_key>` label for crash recovery and safe cleanup.
  """
  @behaviour Cinder.Download.Client

  alias Cinder.Download.Client.Fetch
  alias Cinder.Download.{PathMapping, Torrent}
  alias Cinder.HTTPPolicy

  @default_url "http://localhost:9091/transmission/rpc"
  @max_response_bytes 4 * 1024 * 1024
  @max_torrent_bytes 10 * 1024 * 1024
  @minimum_rpc_version 16
  @remote_path_prefix :transmission_remote_path_prefix
  @local_path_prefix :transmission_local_path_prefix
  @status_fields ~w(hashString status percentDone rateDownload eta peersSendingToUs error errorString downloadDir name)
  @managed_fields ~w(hashString labels status percentDone error uploadRatio secondsSeeding)

  def add(release), do: add(release, [])

  @impl true
  def add(%{download_url: "magnet:" <> _ = magnet}, opts),
    do: add_arguments(%{"filename" => sanitize_magnet(magnet)}, opts)

  def add(%{download_url: url} = release, opts) when is_binary(url) do
    fetch_opts = [
      max_bytes: @max_torrent_bytes,
      error_tag: :torrent_fetch_status,
      allow_magnet: true,
      receive_timeout: 90_000,
      plug: config()[:fetch_plug],
      resolver: config()[:url_resolver]
    ]

    case Fetch.bytes(url, Map.get(release, :download_url_origin), fetch_opts) do
      {:ok, bytes} -> add_torrent(bytes, opts)
      {:magnet, magnet} -> add(%{download_url: magnet}, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def add(%{download_url: _}, _opts), do: {:error, :unsupported_download_url}

  defp add_torrent(bytes, opts) do
    with {:ok, clean} <- Torrent.sanitize_embedded_urls(bytes, &keep_endpoint?/1) do
      add_arguments(%{"metainfo" => Base.encode64(clean)}, opts)
    end
  end

  defp add_arguments(arguments, opts) do
    with {:ok, response} <- rpc("torrent-add", arguments),
         {:ok, hash} <- added_hash(response),
         :ok <- tag(hash, Keyword.get(opts, :operation_key)) do
      {:ok, hash}
    end
  end

  defp added_hash(%{"torrent-added" => %{"hashString" => hash}}) when is_binary(hash),
    do: {:ok, hash}

  defp added_hash(%{"torrent-duplicate" => %{"hashString" => hash}}) when is_binary(hash),
    do: {:ok, hash}

  defp added_hash(_response), do: {:error, :unexpected_response}

  defp tag(_hash, key) when not is_binary(key), do: :ok

  defp tag(hash, key) do
    with {:ok, [torrent]} <- torrents(["labels"], [hash]),
         labels when is_list(labels) <- torrent["labels"],
         {:ok, _} <-
           rpc("torrent-set", %{
             "ids" => [hash],
             "labels" => Enum.uniq(["cinder-#{key}" | labels])
           }) do
      :ok
    else
      {:ok, _} -> {:error, :unexpected_response}
      {:error, _} = error -> error
      _ -> {:error, :unexpected_response}
    end
  end

  @impl true
  def find_by_operation_key(key) do
    wanted = "cinder-#{key}"

    with {:ok, torrents} <- torrents(["hashString", "labels"]) do
      matches =
        for %{"hashString" => hash, "labels" => labels} <- torrents,
            is_binary(hash) and is_list(labels) and wanted in labels,
            do: hash

      case matches do
        [] -> :not_found
        [hash] -> {:ok, hash}
        [_ | _] -> {:error, :ambiguous_operation_key}
      end
    end
  end

  @impl true
  def status(hash) do
    case torrents(@status_fields, [hash]) do
      {:ok, [torrent | _]} -> {:ok, normalize(torrent)}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @impl true
  def files(hash) do
    case torrents(["files"], [hash]) do
      {:ok, [%{"files" => files} | _]} when is_list(files) ->
        {:ok, for(%{"name" => name} <- files, is_binary(name), do: name)}

      {:ok, []} ->
        {:ok, []}

      {:ok, _} ->
        {:error, :unexpected_response}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def list_managed do
    with {:ok, torrents} <- torrents(@managed_fields) do
      {:ok, Enum.flat_map(torrents, &managed_entry/1)}
    end
  end

  defp managed_entry(%{"hashString" => hash, "labels" => labels} = torrent)
       when is_binary(hash) and is_list(labels) do
    case cinder_key(labels) do
      nil ->
        []

      key ->
        [
          %{
            id: hash,
            operation_key: key,
            state: classify(torrent),
            ratio: non_negative_number(torrent["uploadRatio"]),
            seeding_time: non_negative_integer(torrent["secondsSeeding"])
          }
        ]
    end
  end

  defp managed_entry(_torrent), do: []

  defp cinder_key(labels) do
    Enum.find_value(labels, fn
      "cinder-" <> key when key != "" -> key
      _label -> nil
    end)
  end

  @impl true
  def remove(hash, opts \\ []) do
    case rpc("torrent-remove", %{
           "ids" => [hash],
           "delete-local-data" => Keyword.get(opts, :delete_files, true)
         }) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def health do
    probe = [receive_timeout: 3_000, connect_options: [timeout: 3_000]]

    with {:ok, session} <- rpc("session-get", %{}, probe),
         :ok <- supported_rpc(session["rpc-version"]),
         do: mapping_health()
  end

  defp supported_rpc(version) when is_integer(version) and version >= @minimum_rpc_version,
    do: :ok

  defp supported_rpc(version), do: {:error, {:unsupported_transmission_rpc, version}}

  defp torrents(fields, ids \\ nil) do
    arguments = %{"fields" => fields}
    arguments = if is_list(ids), do: Map.put(arguments, "ids", ids), else: arguments

    case rpc("torrent-get", arguments) do
      {:ok, %{"torrents" => torrents}} when is_list(torrents) -> {:ok, torrents}
      {:ok, _} -> {:error, :unexpected_response}
      {:error, _} = error -> error
    end
  end

  defp normalize(torrent) do
    %{
      state: classify(torrent),
      progress: progress(torrent["percentDone"]),
      speed: non_negative_integer(torrent["rateDownload"]),
      eta: eta(torrent["eta"]),
      seeders: non_negative_integer(torrent["peersSendingToUs"]),
      reason: error_reason(torrent),
      content_path: content_path(torrent)
    }
  end

  defp classify(%{"error" => error}) when is_integer(error) and error != 0, do: :error

  defp classify(%{"status" => 0, "percentDone" => progress})
       when is_number(progress) and progress < 1,
       do: :error

  defp classify(%{"status" => status, "percentDone" => progress})
       when status in [0, 5, 6] and is_number(progress) and progress >= 1,
       do: :completed

  defp classify(_torrent), do: :downloading

  defp error_reason(%{"errorString" => reason}) when is_binary(reason) and reason != "",
    do: reason

  defp error_reason(%{"status" => 0, "percentDone" => progress})
       when is_number(progress) and progress < 1,
       do: "Stopped by the download client before completion."

  defp error_reason(_torrent), do: nil

  defp content_path(%{"downloadDir" => dir, "name" => name})
       when is_binary(dir) and is_binary(name) do
    PathMapping.translate(
      Path.join(dir, name),
      Application.get_env(:cinder, @remote_path_prefix),
      Application.get_env(:cinder, @local_path_prefix)
    )
  end

  defp content_path(_torrent), do: nil

  defp progress(value) when is_number(value), do: value / 1
  defp progress(_value), do: 0.0

  defp eta(value) when is_integer(value) and value >= 0, do: value
  defp eta(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp non_negative_number(value) when is_number(value) and value >= 0, do: value / 1
  defp non_negative_number(_value), do: nil

  defp mapping_health do
    PathMapping.validate_local_prefix(
      Application.get_env(:cinder, @remote_path_prefix),
      Application.get_env(:cinder, @local_path_prefix)
    )
  end

  defp rpc(method, arguments, overrides \\ []) do
    body = %{"method" => method, "arguments" => arguments}

    case request(body, overrides) do
      {:ok, %{status: 409} = response} -> retry_with_session(body, response, overrides)
      response -> rpc_response(response)
    end
  end

  defp retry_with_session(body, response, overrides) do
    case Req.Response.get_header(response, "x-transmission-session-id") do
      [session_id | _] ->
        body
        |> request(overrides, session_id)
        |> rpc_response()

      [] ->
        {:error, :missing_transmission_session_id}
    end
  end

  defp request(body, overrides, session_id \\ nil) do
    config = config()

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
    |> maybe_session(session_id)
    |> Req.new()
    |> Req.merge(method: :post, json: body)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp maybe_auth(options, config) do
    case Keyword.get(config, :username) do
      username when is_binary(username) and username != "" ->
        Keyword.put(options, :auth, {:basic, "#{username}:#{Keyword.get(config, :password, "")}"})

      _ ->
        options
    end
  end

  defp maybe_session(options, nil), do: options

  defp maybe_session(options, session_id),
    do: Keyword.put(options, :headers, [{"x-transmission-session-id", session_id}])

  defp rpc_response({:ok, %{status: 200, body: %{"result" => "success", "arguments" => args}}}),
    do: {:ok, args}

  defp rpc_response({:ok, %{status: 200, body: %{"result" => result}}}),
    do: {:error, {:transmission_rpc, result}}

  defp rpc_response({:ok, %{status: status}}), do: {:error, {:transmission_status, status}}
  defp rpc_response({:error, reason}), do: {:error, reason}

  defp sanitize_magnet(magnet) do
    case URI.new(magnet) do
      {:ok, %URI{query: query} = uri} when is_binary(query) ->
        clean =
          query
          |> URI.query_decoder()
          |> Enum.filter(fn
            {key, url} when key in ~w(tr ws as xs) -> keep_endpoint?(url)
            _pair -> true
          end)
          |> URI.encode_query()

        URI.to_string(%{uri | query: clean})

      _ ->
        magnet
    end
  rescue
    _ -> magnet
  end

  defp keep_endpoint?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" ->
        case config()[:url_resolver] do
          resolver when is_function(resolver, 1) ->
            HTTPPolicy.validate_untrusted_host(host, resolver) == :ok

          nil ->
            HTTPPolicy.validate_untrusted_host(host) == :ok
        end

      _ ->
        true
    end
  end

  defp keep_endpoint?(_url), do: true

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
