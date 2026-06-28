defmodule Cinder.Download do
  @moduledoc """
  Hands a `:requested` movie off to the download client: search for the best
  release and add it, advancing `:requested → :searching → :downloading` (or
  `:no_match`). The background `Cinder.Download.Poller` then tracks it to
  `:downloaded`.

  The client is reached only through the `Cinder.Download.Client` behaviour,
  resolved per-release-protocol from config (`config :cinder, :download_clients`,
  a `%{protocol => module}` map) so tests use Mox mocks and never hit the network.
  Auto-triggered by `Cinder.Download.Poller`'s search sweep.
  """
  require Logger
  alias Cinder.{Acquisition, Catalog, Notifier}
  alias Cinder.Catalog.Movie

  @doc """
  Hands `movie` off to the download client. Returns `{:ok, movie}` with the
  movie's new status (`:downloading` or `:no_match`), or `{:error, reason}`.

  Return values:
  - `{:ok, %Movie{status: :downloading}}` — release found and handed to client.
  - `{:ok, %Movie{status: :no_match}}` — indexer returned results but none survived scoring.
  - `{:error, :no_imdb_id}` — TMDB has no IMDb id for this movie; movie stays `:requested`.
  - `{:error, :tmdb_unavailable}` — transient TMDB error; movie stays `:requested`.
  - `{:error, reason}` — indexer or client error; movie left in `:searching`.
  """
  def start(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
      opts =
        [
          protocols: available_protocols(),
          preferred_language: movie.preferred_language,
          original_language: movie.original_language
        ] ++ Acquisition.band_opts(:movies)

      case Acquisition.best_release(imdb_id, opts) do
        {:ok, release} ->
          add_to_client(movie, release)

        :no_match ->
          Catalog.transition(movie, %{status: :no_match})

        :no_language_match ->
          park_no_language(movie)

        {:error, _} = err ->
          err
      end
    else
      :no_imdb_id -> {:error, :no_imdb_id}
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolves the download-client module for `protocol` (`:torrent | :usenet`).
  Returns `{:ok, module}` or `:error` when no client is configured for it. A
  `nil` protocol (a row from before download_protocol existed) resolves to
  `:torrent`.
  """
  def client_for(protocol) do
    :cinder
    |> Application.fetch_env!(:download_clients)
    |> Map.fetch(protocol || :torrent)
  end

  @doc "The protocols with a configured download client."
  def available_protocols do
    :cinder |> Application.fetch_env!(:download_clients) |> Map.keys()
  end

  @doc """
  After a successful import, removes the source download when the `move_on_import`
  setting is on. Usenet-only (an allowlist, so a nil/unknown protocol no-ops) and
  only when a download id is tracked — torrents are never auto-removed so seeding
  survives. Best-effort: a remove failure is logged, never propagated. Always `:ok`.
  """
  def remove_after_import(protocol, download_id) do
    move_on_import? = Application.get_env(:cinder, :move_on_import, false)

    if move_on_import? and protocol == :usenet and download_id not in [nil, ""] do
      case client_for(protocol) do
        {:ok, client} -> best_effort_remove(client, download_id)
        :error -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Removes a tracked client download best-effort: logs (and swallows) an `{:error,_}`
  return OR a raised/thrown client failure, always returning `:ok` so a misconfigured
  client can never block a delete/reap or unwind a poller. Shared by the delete/reap
  paths (`Cinder.Catalog`) and the post-import remove.
  """
  def best_effort_remove(client, id) do
    case client.remove(id, delete_files: true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("client remove failed for download #{inspect(id)}: #{inspect(reason)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning(
        "client remove raised for download #{inspect(id)}: #{inspect({kind, value})}"
      )

      :ok
  end

  defp park_no_language(movie) do
    with {:ok, parked} <- Catalog.transition(movie, %{status: :no_match}) do
      Notifier.notify({:movie_failed, parked, :no_language_match})
      {:ok, parked}
    end
  end

  defp ensure_imdb_id(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id) and imdb_id != "" do
    {:ok, imdb_id}
  end

  defp ensure_imdb_id(%Movie{tmdb_id: tmdb_id}) do
    case Catalog.get_movie(tmdb_id) do
      {:ok, %{imdb_id: imdb_id}} when is_binary(imdb_id) and imdb_id != "" -> {:ok, imdb_id}
      {:ok, _} -> :no_imdb_id
      {:error, _} -> {:error, :tmdb_unavailable}
    end
  end

  defp add_to_client(movie, release) do
    with {:ok, client} <- client_for(release.protocol),
         {:ok, download_id} <- client.add(release) do
      # download_id and download_protocol MUST be written in the same transition:
      # a torn write (id set, protocol nil) would route this download to :torrent.
      # release_title rides the same transition so the blocklist has the chosen
      # release's name if this download later parks terminally (crash-safe, no re-query).
      Catalog.transition(movie, %{
        status: :downloading,
        download_id: download_id,
        download_protocol: release.protocol,
        release_title: release.title
      })
    else
      # Unreachable post-filter (best_release only returns a configured protocol);
      # a fail-loud guard rather than a silent misroute.
      :error -> {:error, :no_client}
      {:error, _} = err -> err
    end
  end
end
