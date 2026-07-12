defmodule Cinder.Download.Client.QBittorrent do
  @moduledoc """
  Real `Cinder.Download.Client` impl, backed by `Req`, against qBittorrent's
  Web API v2.

  Reads `base_url`, `username`, `password` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. The auth flow is stateful:
  each call logs in (`POST /api/v2/auth/login`), threads the returned session
  cookie (`SID` on <= 4.x, `QBT_SID_<port>` on >= 5.x) into the action request,
  then performs it.

  Durable operation-key reconciliation requires qBittorrent Web API 2.8.3 or
  newer. Health checks and operation-key lookup reject older or malformed
  versions before relying on tag-filtered torrent listing.

  Validated against a live qBittorrent only in Phase 5; the unit test is a shape
  sanity-check against `Req.Test`.
  """
  @behaviour Cinder.Download.Client

  alias Cinder.Download.Torrent
  alias Cinder.HTTPPolicy

  @default_base_url "http://localhost:8080"

  # qBit upload-phase / post-download states all mean "download finished, at rest".
  @completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP)
  # Finished downloading but relocating the file — not at rest, path not yet final.
  @in_transit ~w(moving)
  @errored ~w(error missingFiles)

  @max_redirects 5
  @max_torrent_bytes 10 * 1024 * 1024
  @max_response_bytes 4 * 1024 * 1024
  @minimum_webapi_version "2.8.3"

  def add(release), do: add(release, [])

  @impl true
  def add(%{download_url: "magnet:" <> _ = magnet}, opts) do
    with {:ok, hash} <- btih(magnet),
         {:ok, %{status: 200, body: body}} <-
           action(
             method: :post,
             url: "/api/v2/torrents/add",
             form_multipart: [urls: magnet] ++ tag_part(opts)
           ) do
      # ponytail: magnet-only hash extraction; base32 btih and .torrent-URL→hash
      # (info-by-name lookup) are Phase-5 live concerns.
      if String.trim(body) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      :error -> {:error, :unsupported_download_url}
      other -> error(other)
    end
  end

  def add(%{download_url: "http://" <> _} = release, opts), do: add_torrent_url(release, opts)
  def add(%{download_url: "https://" <> _} = release, opts), do: add_torrent_url(release, opts)

  def add(%{download_url: _}, _opts), do: {:error, :unsupported_download_url}

  # Fetch the .torrent, compute its infohash (so status/1 can poll it), then
  # upload the bytes to qBittorrent. decode_body: false keeps the bytes raw so
  # the infohash is over the exact on-the-wire content.
  defp add_torrent_url(%{download_url: url} = release, opts) do
    source_origin = Map.get(release, :download_url_origin)

    case fetch_torrent(url, source_origin, @max_redirects) do
      {:ok, bytes} -> add_torrent_bytes(bytes, opts)
      # Magnet-only indexers answer their proxied downloadUrl with a 3xx to a
      # magnet: URI — route it through the magnet add path.
      {:magnet, magnet} -> add(%{download_url: magnet}, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_torrent_bytes(bytes, opts) do
    with {:ok, hash} <- Torrent.infohash(bytes),
         {:ok, %{status: 200, body: body}} <- upload_torrent(bytes, opts) do
      if String.trim(to_string(body)) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      other -> error(other)
    end
  end

  # Redirects are followed manually (redirect: false): Req's own redirect step
  # merges the Location URI without a scheme check, so a 3xx to a magnet: URI
  # makes Finch raise ArgumentError instead of returning {:error, _}.
  defp fetch_torrent(url, source_origin, hops) do
    with {:ok, uri} <- validate_url(url, source_origin) do
      trust =
        if HTTPPolicy.same_origin?(uri, source_origin),
          do: {:source, source_origin},
          else: :untrusted

      request_torrent(uri, trust, hops)
    end
  end

  defp request_torrent(uri, trust, hops) do
    request =
      Req.new(
        url: uri,
        receive_timeout: 15_000,
        pool_timeout: 5_000,
        connect_options: [timeout: 5_000],
        retry: false,
        redirect: false,
        plug: fetch_plug()
      )

    case HTTPPolicy.bounded_request(request, @max_torrent_bytes) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) ->
        {:ok, bytes}

      {:ok, %{status: status} = resp} when status in [301, 302, 303, 307, 308] ->
        case Req.Response.get_header(resp, "location") do
          ["magnet:" <> _ = magnet | _] -> {:magnet, magnet}
          [location | _] -> follow_redirect(uri, location, trust, hops)
          [] -> {:error, {:torrent_fetch_status, status}}
        end

      {:ok, %{status: status}} ->
        {:error, {:torrent_fetch_status, status}}

      other ->
        error(other)
    end
  end

  defp follow_redirect(_url, _location, _trust, 0), do: {:error, :too_many_redirects}

  defp follow_redirect(url, location, trust, hops) do
    case resolve_redirect(url, location, trust) do
      {:ok, next, next_trust} -> request_torrent(next, next_trust, hops - 1)
      {:error, :unsupported_scheme} -> {:error, :unsupported_download_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_torrent(bytes, opts) do
    action(
      method: :post,
      url: "/api/v2/torrents/add",
      form_multipart:
        [
          torrents: {bytes, filename: "t.torrent", content_type: "application/x-bittorrent"}
        ] ++ tag_part(opts)
    )
  end

  defp tag_part(opts) do
    case Keyword.get(opts, :operation_key) do
      key when is_binary(key) -> [tags: "cinder-#{key}"]
      _ -> []
    end
  end

  @impl true
  def find_by_operation_key(key) do
    tag = "cinder-#{key}"

    with :ok <- require_tag_filter_webapi() do
      case action(method: :get, url: "/api/v2/torrents/info", params: [tag: tag]) do
        {:ok, %{status: 200, body: torrents}} when is_list(torrents) ->
          torrents |> Enum.filter(&tagged?(&1, tag)) |> operation_hash()

        {:ok, %{status: 200}} ->
          {:error, :unexpected_response}

        other ->
          error(other)
      end
    end
  end

  defp tagged?(%{"tags" => tags}, wanted) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.member?(wanted)
  end

  defp tagged?(_torrent, _wanted), do: false

  defp operation_hash([]), do: :not_found
  defp operation_hash([%{"hash" => hash}]) when is_binary(hash), do: {:ok, hash}
  defp operation_hash([_ | _]), do: {:error, :ambiguous_operation_key}

  # In prod, no plug (real HTTP). In test, config can inject a Req.Test plug.
  defp fetch_plug, do: Keyword.get(config(), :fetch_plug)

  @impl true
  def status(hash) do
    case action(method: :get, url: "/api/v2/torrents/info", params: [hashes: hash]) do
      {:ok, %{status: 200, body: [torrent | _]}} -> {:ok, normalize(torrent)}
      {:ok, %{status: 200, body: []}} -> {:error, :not_found}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  @impl true
  def remove(hash, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, true)

    case action(
           method: :post,
           url: "/api/v2/torrents/delete",
           form: [hashes: hash, deleteFiles: to_string(delete_files)]
         ) do
      # qBittorrent answers /torrents/delete with 200 and an empty body whether or
      # not the hash was known — so it is idempotent for free (unknown hash → :ok).
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  @impl true
  def health do
    # Short bounds on both the login round-trip and the probe itself, so a
    # blackholed host can't hang the settings "Test connection" for minutes.
    # A health check is an explicit "probe NOW": drop any login cooldown first —
    # SettingsLive/SetupLive run this synchronously in the LiveView process, and a
    # cached failure there would show red for 10 minutes after the server recovered.
    Process.delete({__MODULE__, :login_cooldown})
    probe = [receive_timeout: 3_000, connect_options: [timeout: 3_000]]

    case action([method: :get, url: "/api/v2/app/webapiVersion"], probe) do
      {:ok, %{status: status, body: version}} when status in 200..299 -> validate_webapi(version)
      other -> error(other)
    end
  end

  defp require_tag_filter_webapi do
    case action(method: :get, url: "/api/v2/app/webapiVersion") do
      {:ok, %{status: status, body: version}} when status in 200..299 -> validate_webapi(version)
      other -> error(other)
    end
  end

  defp validate_webapi(version) when is_binary(version) do
    case Version.compare(version, @minimum_webapi_version) do
      order when order in [:eq, :gt] -> :ok
      _ -> {:error, {:unsupported_webapi_version, version}}
    end
  rescue
    Version.InvalidVersionError -> {:error, {:unsupported_webapi_version, version}}
  end

  defp validate_webapi(version), do: {:error, {:unsupported_webapi_version, to_string(version)}}

  # Logs in, then runs `fun` with a Req carrying the SID cookie + base_url.
  # `overrides` (e.g. health's short timeouts) apply to the login call too.
  defp action(options, overrides \\ []) do
    config = config()

    with {:ok, cookie} <- login(config, overrides) do
      config
      |> base()
      |> Keyword.merge(overrides)
      |> Keyword.put(:headers, [{"cookie", cookie}])
      |> Req.new()
      |> Req.merge(options)
      |> HTTPPolicy.bounded_request(@max_response_bytes)
    end
  end

  # A definitive auth failure (bad creds, or a 403 from an already-banned IP) is
  # remembered per process for @login_cooldown_ms: each poller is one long-lived
  # process, so one bad-creds tick makes ONE login attempt instead of one per
  # movie/grab — which would trip qBittorrent's consecutive-failure IP ban (default
  # 5 failures -> 1h ban) within a single tick. A Cinder-side config change (new
  # sig) retries immediately; health/0 clears the cooldown so a manual
  # "Test connection" always probes live, even in a long-lived LiveView process.
  @login_cooldown_ms 10 * 60_000

  defp login(config, overrides) do
    sig = :erlang.phash2({config[:base_url], config[:username], config[:password]})

    case Process.get({__MODULE__, :login_cooldown}) do
      {^sig, until} ->
        if System.monotonic_time(:millisecond) < until,
          do: {:error, :login_failed},
          else: attempt_login(config, overrides, sig)

      _ ->
        attempt_login(config, overrides, sig)
    end
  end

  defp attempt_login(config, overrides, sig) do
    resp =
      config
      |> base()
      |> Keyword.merge(overrides)
      |> Keyword.put(:headers, [{"referer", Keyword.get(config, :base_url, @default_base_url)}])
      |> Req.new()
      |> Req.merge(
        method: :post,
        url: "/api/v2/auth/login",
        form: [username: Keyword.get(config, :username), password: Keyword.get(config, :password)]
      )
      |> HTTPPolicy.bounded_request(@max_response_bytes)

    case resp do
      # qBittorrent answers a successful login with 200 ("Ok." on <= 4.x) or 204 No Content
      # (>= 5.x), in both cases setting the session cookie. A bad-credentials login is 200 with
      # body "Fails." and no cookie, so the missing cookie — not the status — signals failure.
      {:ok, %{status: status} = response} when status in 200..299 ->
        case session_cookie(response) do
          nil ->
            start_cooldown(sig)
            {:error, :login_failed}

          cookie ->
            Process.delete({__MODULE__, :login_cooldown})
            {:ok, cookie}
        end

      {:ok, %{status: 403}} ->
        start_cooldown(sig)
        {:error, {:qbittorrent_status, 403}}

      other ->
        error(other)
    end
  end

  defp start_cooldown(sig) do
    until = System.monotonic_time(:millisecond) + @login_cooldown_ms
    Process.put({__MODULE__, :login_cooldown}, {sig, until})
  end

  # qBittorrent names its session cookie `SID` (<= 4.x) or `QBT_SID_<port>` (>= 5.x). Capture
  # whichever it set as the raw `name=value` pair so it can be threaded back verbatim — sending
  # it under the wrong name drops the session on a 5.x server. nil => no session cookie (e.g. a
  # "Fails." bad-credentials response), which the caller treats as a login failure.
  defp session_cookie(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.find_value(fn cookie ->
      case Regex.run(~r/^(?:QBT_)?SID(?:_\d+)?=[^;]+/, cookie) do
        [pair] -> pair
        _ -> nil
      end
    end)
  end

  # Match the magnet verbatim (don't upcase the whole string — that breaks the
  # lowercase `xt=urn:btih:` literal); upcase only the captured base32 hash.
  @hex_btih ~r/xt=urn:btih:([a-fA-F0-9]{40})(?:&|$)/
  @b32_btih ~r/xt=urn:btih:([a-zA-Z2-7]{32})(?:&|$)/

  defp btih("magnet:" <> _ = magnet) do
    with nil <- Regex.run(@hex_btih, magnet),
         [_, b32] <- Regex.run(@b32_btih, magnet),
         {:ok, raw} <- Base.decode32(String.upcase(b32), padding: false) do
      {:ok, Base.encode16(raw, case: :lower)}
    else
      [_, hex] -> {:ok, String.downcase(hex)}
      _ -> :error
    end
  end

  defp normalize(torrent) do
    progress = torrent["progress"] || 0.0

    %{
      state: classify(torrent["state"], progress),
      progress: progress,
      speed: metric(torrent["dlspeed"]),
      eta: eta(torrent["eta"]),
      content_path: torrent["content_path"]
    }
  end

  defp metric(value) when is_integer(value) and value >= 0, do: value
  defp metric(_value), do: nil

  defp eta(value) when is_integer(value) and value in 0..8_639_999, do: value
  defp eta(_value), do: nil

  defp classify(state, _progress) when state in @errored, do: :error
  defp classify(state, _progress) when state in @in_transit, do: :downloading
  defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
  # Catch-all so unlisted/future qBit states (forcedMetaDL, unknownState, …) are safe.
  defp classify(_state, _progress), do: :downloading

  defp base(config) do
    # retry: false — the pollers carry their own bounded-retry budget; Req's default
    # 3-retry backoff on top of it only stretches a tick against a failing server.
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      redirect: false,
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp validate_url(url, source_origin) do
    case Keyword.get(config(), :url_resolver) do
      resolver when is_function(resolver, 1) ->
        HTTPPolicy.validate_source_url(url, source_origin, resolver)

      nil ->
        HTTPPolicy.validate_source_url(url, source_origin)
    end
  end

  defp resolve_redirect(current, location, {:source, source_origin}) do
    case HTTPPolicy.resolve_redirect(current, location, :same_origin) do
      {:ok, next} -> {:ok, next, {:source, source_origin}}
      {:error, :cross_origin_redirect} -> resolve_untrusted_redirect(current, location)
      error -> error
    end
  end

  defp resolve_redirect(current, location, :untrusted),
    do: resolve_untrusted_redirect(current, location)

  defp resolve_untrusted_redirect(current, location) do
    case Keyword.get(config(), :url_resolver) do
      resolver when is_function(resolver, 1) ->
        with {:ok, next} <- HTTPPolicy.resolve_redirect(current, location, resolver),
             do: {:ok, next, :untrusted}

      nil ->
        with {:ok, next} <- HTTPPolicy.resolve_redirect(current, location, :untrusted),
             do: {:ok, next, :untrusted}
    end
  end

  defp error({:ok, %{status: status}}), do: {:error, {:qbittorrent_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
