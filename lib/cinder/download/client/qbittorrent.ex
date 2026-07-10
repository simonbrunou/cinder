defmodule Cinder.Download.Client.QBittorrent do
  @moduledoc """
  Real `Cinder.Download.Client` impl, backed by `Req`, against qBittorrent's
  Web API v2.

  Reads `base_url`, `username`, `password` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. The auth flow is stateful:
  each call logs in (`POST /api/v2/auth/login`), threads the returned session
  cookie (`SID` on <= 4.x, `QBT_SID_<port>` on >= 5.x) into the action request,
  then performs it.

  Validated against a live qBittorrent only in Phase 5; the unit test is a shape
  sanity-check against `Req.Test`.
  """
  @behaviour Cinder.Download.Client

  alias Cinder.Download.Torrent

  @default_base_url "http://localhost:8080"

  # qBit upload-phase / post-download states all mean "download finished, at rest".
  @completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP)
  # Finished downloading but relocating the file — not at rest, path not yet final.
  @in_transit ~w(moving)
  @errored ~w(error missingFiles)

  @max_redirects 5

  @impl true
  def add(%{download_url: "magnet:" <> _ = magnet}) do
    with {:ok, hash} <- btih(magnet),
         {:ok, %{status: 200, body: body}} <-
           action(fn req ->
             Req.post(req, url: "/api/v2/torrents/add", form_multipart: [urls: magnet])
           end) do
      # ponytail: magnet-only hash extraction; base32 btih and .torrent-URL→hash
      # (info-by-name lookup) are Phase-5 live concerns.
      if String.trim(body) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      :error -> {:error, :unsupported_download_url}
      other -> error(other)
    end
  end

  def add(%{download_url: "http://" <> _ = url}), do: add_torrent_url(url)
  def add(%{download_url: "https://" <> _ = url}), do: add_torrent_url(url)

  def add(%{download_url: _}), do: {:error, :unsupported_download_url}

  # Fetch the .torrent, compute its infohash (so status/1 can poll it), then
  # upload the bytes to qBittorrent. decode_body: false keeps the bytes raw so
  # the infohash is over the exact on-the-wire content.
  defp add_torrent_url(url) do
    case fetch_torrent(url, @max_redirects) do
      {:ok, bytes} -> add_torrent_bytes(bytes)
      # Magnet-only indexers answer their proxied downloadUrl with a 3xx to a
      # magnet: URI — route it through the magnet add path.
      {:magnet, magnet} -> add(%{download_url: magnet})
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_torrent_bytes(bytes) do
    with {:ok, hash} <- Torrent.infohash(bytes),
         {:ok, %{status: 200, body: body}} <- upload_torrent(bytes) do
      if String.trim(to_string(body)) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      other -> error(other)
    end
  end

  # Redirects are followed manually (redirect: false): Req's own redirect step
  # merges the Location URI without a scheme check, so a 3xx to a magnet: URI
  # makes Finch raise ArgumentError instead of returning {:error, _}.
  defp fetch_torrent(_url, 0), do: {:error, :too_many_redirects}

  defp fetch_torrent(url, hops) do
    case Req.get(url,
           receive_timeout: 15_000,
           decode_body: false,
           retry: false,
           redirect: false,
           plug: fetch_plug()
         ) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) ->
        {:ok, bytes}

      {:ok, %{status: status} = resp} when status in [301, 302, 303, 307, 308] ->
        case Req.Response.get_header(resp, "location") do
          ["magnet:" <> _ = magnet | _] -> {:magnet, magnet}
          [location | _] -> follow_redirect(url, location, hops)
          [] -> {:error, {:torrent_fetch_status, status}}
        end

      {:ok, %{status: status}} ->
        {:error, {:torrent_fetch_status, status}}

      other ->
        error(other)
    end
  end

  defp follow_redirect(url, location, hops) do
    next = url |> URI.merge(location) |> URI.to_string()

    if String.starts_with?(next, ["http://", "https://"]) do
      fetch_torrent(next, hops - 1)
    else
      {:error, :unsupported_download_url}
    end
  end

  defp upload_torrent(bytes) do
    action(fn req ->
      Req.post(req,
        url: "/api/v2/torrents/add",
        form_multipart: [
          torrents: {bytes, filename: "t.torrent", content_type: "application/x-bittorrent"}
        ]
      )
    end)
  end

  # In prod, no plug (real HTTP). In test, config can inject a Req.Test plug.
  defp fetch_plug, do: Keyword.get(config(), :fetch_plug)

  @impl true
  def status(hash) do
    case action(fn req -> Req.get(req, url: "/api/v2/torrents/info", params: [hashes: hash]) end) do
      {:ok, %{status: 200, body: [torrent | _]}} -> {:ok, normalize(torrent)}
      {:ok, %{status: 200, body: []}} -> {:error, :not_found}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  @impl true
  def remove(hash, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, true)

    case action(fn req ->
           Req.post(req,
             url: "/api/v2/torrents/delete",
             form: [hashes: hash, deleteFiles: to_string(delete_files)]
           )
         end) do
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

    case action(fn req -> Req.get(req, url: "/api/v2/app/webapiVersion") end, probe) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  # Logs in, then runs `fun` with a Req carrying the SID cookie + base_url.
  # `overrides` (e.g. health's short timeouts) apply to the login call too.
  defp action(fun, overrides \\ []) do
    config = config()

    with {:ok, cookie} <- login(config, overrides) do
      config
      |> base()
      |> Keyword.merge(overrides)
      |> Keyword.put(:headers, [{"cookie", cookie}])
      |> Req.new()
      |> fun.()
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
      |> Req.post(
        url: "/api/v2/auth/login",
        form: [username: Keyword.get(config, :username), password: Keyword.get(config, :password)]
      )

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
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp error({:ok, %{status: status}}), do: {:error, {:qbittorrent_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
