defmodule Cinder.Download do
  @moduledoc """
  Hands a `:requested` movie off to the download client: search for the best
  release and add it, advancing `:requested → :searching → :downloading` (or
  `:no_match`). The background `Cinder.Download.Poller` then tracks it to
  `:downloaded`.

  The client is reached only through the `Cinder.Download.Client` behaviour,
  resolved from config (`config :cinder, :download_client`) so tests use a Mox
  mock and never hit the network. Not auto-triggered yet — Phase 5 wires it.
  """
  alias Cinder.{Acquisition, Catalog}
  alias Cinder.Catalog.Movie

  @doc """
  Hands `movie` off to the download client. Returns `{:ok, movie}` with the
  movie's new status (`:downloading` or `:no_match`), or `{:error, reason}` when
  the indexer or the client errors (the movie is left in `:searching`).
  """
  def start(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
      case Acquisition.best_release(imdb_id) do
        {:ok, release} -> add_to_client(movie, release)
        :no_match -> Catalog.transition(movie, %{status: :no_match})
        {:error, _} = err -> err
      end
    else
      :no_imdb_id -> Catalog.transition(movie, %{status: :no_match})
      {:error, _} = err -> err
    end
  end

  defp ensure_imdb_id(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id) and imdb_id != "" do
    {:ok, imdb_id}
  end

  defp ensure_imdb_id(%Movie{tmdb_id: tmdb_id}) do
    case Catalog.get_movie(tmdb_id) do
      {:ok, %{imdb_id: imdb_id}} when is_binary(imdb_id) and imdb_id != "" -> {:ok, imdb_id}
      _ -> :no_imdb_id
    end
  end

  defp add_to_client(movie, release) do
    case client().add(release) do
      {:ok, download_id} ->
        Catalog.transition(movie, %{status: :downloading, download_id: download_id})

      {:error, _} = err ->
        err
    end
  end

  defp client, do: Application.fetch_env!(:cinder, :download_client)
end
