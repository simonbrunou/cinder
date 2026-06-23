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
    with {:ok, bytes} <- fetch_torrent(url),
         {:ok, hash} <- Torrent.infohash(bytes),
         {:ok, %{status: 200, body: body}} <- upload_torrent(bytes) do
      if String.trim(to_string(body)) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      other -> error(other)
    end
  end

  defp fetch_torrent(url) do
    case Req.get(url,
           receive_timeout: 15_000,
           decode_body: false,
           retry: false,
           plug: fetch_plug()
         ) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> {:ok, bytes}
      {:ok, %{status: status}} -> {:error, {:torrent_fetch_status, status}}
      other -> error(other)
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
  def health do
    case action(fn req ->
           Req.get(req, url: "/api/v2/app/webapiVersion", receive_timeout: 3_000)
         end) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  # Logs in, then runs `fun` with a Req carrying the SID cookie + base_url.
  defp action(fun) do
    config = config()

    with {:ok, cookie} <- login(config) do
      config
      |> base()
      |> Keyword.put(:headers, [{"cookie", cookie}])
      |> Req.new()
      |> fun.()
    end
  end

  defp login(config) do
    resp =
      config
      |> base()
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
          nil -> {:error, :login_failed}
          cookie -> {:ok, cookie}
        end

      other ->
        error(other)
    end
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
      content_path: torrent["content_path"]
    }
  end

  defp classify(state, _progress) when state in @errored, do: :error
  defp classify(state, _progress) when state in @in_transit, do: :downloading
  defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
  # Catch-all so unlisted/future qBit states (forcedMetaDL, unknownState, …) are safe.
  defp classify(_state, _progress), do: :downloading

  defp base(config) do
    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp error({:ok, %{status: status}}), do: {:error, {:qbittorrent_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
