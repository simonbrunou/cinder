defmodule Cinder.Notifier.Discord do
  @moduledoc """
  Discord-webhook notifier. Delegates the log line to `Cinder.Notifier.Log`, then — when a
  webhook URL is configured — posts embeds for availability and failures. Best-effort: a failed
  post is logged and swallowed so a Discord outage never touches the pipeline, and the request
  carries a bounded `receive_timeout` so a hung webhook can't stall synchronous poller call sites.
  `Cinder.Notifier.notify/1` catches raises on top of this.

  The webhook URL is a `Cinder.Settings` registry entry, overlaid onto
  `Application.get_env(:cinder, __MODULE__)[:webhook_url]`.

  ponytail: single transport that also logs — not a multi-transport fan-out registry
  (roadmap-parked). Upgrade path is a real dispatcher behind the same `notify/1` seam.
  """
  @behaviour Cinder.Notifier
  alias Cinder.Catalog.Episode
  alias Cinder.HTTPPolicy
  alias Cinder.Notifier.Log
  alias Cinder.Util
  require Logger

  @green 0x2ECC71
  @red 0xE74C3C
  @image_base "https://image.tmdb.org/t/p/w342"
  @maintenance_names %{
    movie_pipeline: "Movie pipeline",
    tv_pipeline: "TV pipeline",
    series_refresh: "Monitored series refresh",
    subtitle_backfill: "Subtitle backfill",
    scan_movies: "Movie library scan",
    scan_tv: "TV library scan"
  }

  # Bounded so a hung/dead webhook can't stall the synchronous notify/1 call sites (poller ticks,
  # the admin Approve handler). Bounds both connect (Mint's default is ~30s) and the response
  # wait — 3s each, matching the other service probes (Prowlarr/TMDB/Jellyfin/…) and the ~3s
  # assumption behind settings_live's synchronous Test button. retry: false stops a Test-button
  # GET retrying a bad webhook.
  @default_req_options [receive_timeout: 3_000, connect_options: [timeout: 3_000], retry: false]
  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def notify(event) do
    Log.notify(event)

    with url when is_binary(url) <- webhook_url(),
         embed when is_map(embed) <- embed(event) do
      post(url, embed)
    end

    :ok
  end

  @doc """
  Validates the configured webhook for the `/settings` Test button via a GET (Discord's
  "Get Webhook with Token" endpoint — checks the webhook without posting a message).
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    case webhook_url() do
      nil -> {:error, :not_configured}
      url -> request(:get, url) |> classify()
    end
  end

  # --- embeds (one per event; nil for anything unknown so notify/1 skips the post) ---

  defp embed({:movie_available, movie}),
    do:
      with_poster(
        %{title: "🎬 Now available", description: title_year(movie), color: @green},
        movie.poster_path
      )

  defp embed({:movie_failed, movie, reason}), do: failure_embed("Movie failed", movie, reason)

  defp embed({:movie_upgrade_failed, movie, reason}),
    do: failure_embed("Upgrade failed", movie, reason)

  defp embed({:season_available, season}),
    do:
      with_poster(
        %{
          title: "📺 Season now available",
          description: "#{season.title} — Season #{season.season_number}",
          color: @green
        },
        season.poster_path
      )

  defp embed({:grab_failed, grab, reason}),
    do: %{title: "TV grab ##{grab.id} failed", description: inspect(reason), color: @red}

  defp embed({:episodes_search_exhausted, episodes}) do
    {summary, poster} = episodes_summary(episodes)

    with_poster(
      %{
        title: "Episode search exhausted",
        description: "#{summary} — giving up until a manual Search",
        color: @red
      },
      poster
    )
  end

  defp embed({:maintenance_completed, key}),
    do: %{title: "Maintenance completed", description: maintenance_name(key), color: @green}

  defp embed({:maintenance_failed, key, reason}),
    do: %{
      title: "Maintenance failed",
      description: "#{maintenance_name(key)} — #{inspect(reason)}",
      color: @red
    }

  defp embed(_other), do: nil

  # --- helpers ---

  defp maintenance_name(key), do: Map.get(@maintenance_names, key, inspect(key))

  defp failure_embed(title, movie, reason) do
    with_poster(
      %{title: title, description: "#{title_year(movie)} — #{inspect(reason)}", color: @red},
      movie.poster_path
    )
  end

  defp title_year(%{title: title, year: year}) when not is_nil(year), do: "#{title} (#{year})"
  defp title_year(%{title: title}), do: title

  # A blank poster_path (nil or "") yields no thumbnail: an empty string would otherwise build a
  # bare base URL with no image path and render as a broken thumbnail in Discord.
  defp with_poster(embed, path) when is_binary(path) and path != "",
    do: Map.put(embed, :thumbnail, %{url: @image_base <> path})

  defp with_poster(embed, _path), do: embed

  defp episodes_summary([%{season: %{series: series}} | _] = episodes) do
    codes =
      Enum.map_join(episodes, ", ", fn ep ->
        Episode.code(ep.season.season_number, ep.episode_number)
      end)

    {"#{series.title} — #{codes}", series.poster_path}
  end

  defp episodes_summary(episodes), do: {"#{length(episodes)} episode(s)", nil}

  defp webhook_url do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:webhook_url)
    |> Util.blank_to_nil()
  end

  # Matches the repo's Req idiom (jellyfin.ex): a base req from config's req_options merged onto the
  # bounded defaults, then Req.post / Req.get with the full webhook url. req_options carries the
  # test plug (+ retry: false) in :test and is empty in prod.
  defp base_req do
    req_options = :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    @default_req_options
    |> Keyword.merge(req_options)
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp post(url, embed) do
    request(:post, url, json: %{embeds: [embed]})
    |> classify()
    |> log_if_error()
  end

  defp request(method, url, options \\ []) do
    base_req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp classify({:error, reason}), do: {:error, reason}

  defp log_if_error(:ok), do: :ok

  defp log_if_error({:error, reason} = error) do
    Logger.warning("Discord notify failed: #{HTTPPolicy.sanitize_log(reason)}")
    error
  end
end
