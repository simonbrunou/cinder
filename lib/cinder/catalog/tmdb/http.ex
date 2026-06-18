defmodule Cinder.Catalog.TMDB.HTTP do
  @moduledoc """
  Real `Cinder.Catalog.TMDB` impl, backed by `Req`.

  Reads `base_url`, `token` (v4 bearer) and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Returns normalized movie maps
  (`%{tmdb_id, title, year, poster_path}`); `imdb_id` enrichment arrives in Phase 2.
  """
  @behaviour Cinder.Catalog.TMDB

  @default_base_url "https://api.themoviedb.org"

  @impl true
  def search(query) do
    case request(url: "/3/search/movie", params: [query: query]) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  def get_movie(tmdb_id) do
    case request(url: "/3/movie/#{tmdb_id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, normalize(body)}
      other -> error(other)
    end
  end

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [base_url: Keyword.get(config, :base_url, @default_base_url)]
    |> auth(Keyword.get(config, :token))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.request()
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, token), do: Keyword.put(opts, :auth, {:bearer, token})

  defp error({:ok, %{status: status}}), do: {:error, {:tmdb_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp normalize(movie) do
    %{
      tmdb_id: movie["id"],
      title: movie["title"],
      year: year_from(movie["release_date"]),
      poster_path: movie["poster_path"]
    }
  end

  defp year_from(date) when is_binary(date) and date != "" do
    case Integer.parse(date) do
      {year, _rest} -> year
      :error -> nil
    end
  end

  defp year_from(_), do: nil
end
