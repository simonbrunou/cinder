defmodule Cinder.Library.MigrationSource.Readarr do
  @moduledoc """
  Bookshelf's Readarr v3-compatible `/api/v1`, currently `pennydreadful/bookshelf:hardcover`.

  Named `Readarr` for the wire protocol it speaks (matching how `Radarr`/`Sonarr` are named for
  theirs), not for the Bookshelf fork that happens to serve it — the deployment's own
  `/api/v1/system/status` self-reports `"appName": "Readarr"`.

  Reads `base_url`, `api_key`, optional path prefixes, and `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime.
  """
  @behaviour Cinder.Library.MigrationSource

  alias Cinder.Download.PathMapping
  alias Cinder.HTTPPolicy
  alias Cinder.Util

  @max_response_bytes 8 * 1024 * 1024

  @impl true
  def snapshot do
    with {:ok, config} <- configured(),
         :ok <- mapping_health(config),
         {:ok, %{status: 200, body: authors}} when is_list(authors) <-
           request(config, url: "/api/v1/author"),
         {:ok, %{status: 200, body: books}} when is_list(books) <-
           request(config, url: "/api/v1/book"),
         {:ok, %{status: 200, body: editions}} when is_list(editions) <-
           request(config, url: "/api/v1/edition"),
         {:ok, %{status: 200, body: files}} when is_list(files) <-
           request(config, url: "/api/v1/bookfile"),
         {:ok, %{status: 200, body: profiles}} when is_list(profiles) <-
           request(config, url: "/api/v1/qualityprofile"),
         {:ok, %{status: 200, body: roots}} when is_list(roots) <-
           request(config, url: "/api/v1/rootfolder"),
         {:ok, %{status: 200, body: naming}} when is_map(naming) <-
           request(config, url: "/api/v1/config/naming"),
         {:ok, normalized_authors} <- normalize_authors(authors),
         {:ok, normalized_works} <- normalize_works(books),
         {:ok, normalized_editions} <- normalize_editions(editions),
         {:ok, normalized_files} <- normalize_files(files, config) do
      {:ok,
       %{
         movies: [],
         series: [],
         episodes: [],
         authors: normalized_authors,
         works: normalized_works,
         editions: normalized_editions,
         files: normalized_files,
         profiles: normalize_profiles(profiles),
         roots: normalize_roots(roots, naming)
       }}
    else
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      {:ok, %{status: status}} -> {:error, {:readarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def health do
    with {:ok, config} <- configured(),
         {:ok, %{status: 200, body: status}} <-
           request(config,
             url: "/api/v1/system/status",
             receive_timeout: 3_000,
             connect_options: [timeout: 3_000]
           ),
         :ok <- validate_status_shape(status),
         :ok <- mapping_health(config) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:readarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  # Validates the observed `system/status` shape (a non-blank `appName`/`version`/`branch`)
  # rather than hard-coding this deployment's current values, so a Bookshelf upgrade that
  # reshapes the response fails the health check loudly instead of silently misreading it.
  defp validate_status_shape(%{"appName" => app, "version" => version, "branch" => branch})
       when is_binary(app) and is_binary(branch) do
    if Util.present?(app) and Util.present?(branch) and version_shaped?(version),
      do: :ok,
      else: {:error, :unexpected_response}
  end

  defp validate_status_shape(_status), do: {:error, :unexpected_response}

  defp version_shaped?(version) when is_binary(version),
    do: Util.present?(version) and Regex.match?(~r/^\d+(\.\d+)*$/, version)

  defp version_shaped?(_version), do: false

  defp normalize_authors(authors) do
    Enum.reduce_while(authors, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_author(raw) do
        {:ok, author} -> {:cont, {:ok, [author | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_author(%{"id" => provider_id, "authorName" => name} = raw)
       when is_integer(provider_id) and provider_id > 0 and is_binary(name) do
    {:ok,
     %{
       provider_id: provider_id,
       name: name,
       foreign_id: Util.trim_to_nil(raw["foreignAuthorId"]),
       monitored: raw["monitored"] == true,
       monitor_new_items: Util.trim_to_nil(raw["monitorNewItems"])
     }}
  end

  defp normalize_author(_raw), do: {:error, :unexpected_response}

  defp normalize_works(books) do
    Enum.reduce_while(books, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_work(raw) do
        {:ok, work} -> {:cont, {:ok, [work | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_work(%{"id" => provider_id, "authorId" => author_id, "title" => title} = raw)
       when is_integer(provider_id) and provider_id > 0 and is_integer(author_id) and
              author_id > 0 and is_binary(title) do
    {:ok,
     %{
       provider_id: provider_id,
       author_id: author_id,
       title: title,
       foreign_id: Util.trim_to_nil(raw["foreignBookId"]),
       monitored: raw["monitored"] == true
     }}
  end

  defp normalize_work(_raw), do: {:error, :unexpected_response}

  defp normalize_editions(editions) do
    Enum.reduce_while(editions, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_edition(raw) do
        {:ok, edition} -> {:cont, {:ok, [edition | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_edition(%{"id" => provider_id, "bookId" => work_id} = raw)
       when is_integer(provider_id) and provider_id > 0 and is_integer(work_id) and work_id > 0 do
    {:ok,
     %{
       provider_id: provider_id,
       work_id: work_id,
       isbn13: Util.trim_to_nil(raw["isbn13"]),
       asin: Util.trim_to_nil(raw["asin"]),
       monitored: raw["monitored"] == true
     }}
  end

  defp normalize_edition(_raw), do: {:error, :unexpected_response}

  defp normalize_files(files, config) do
    Enum.reduce_while(files, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_file(raw, config) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq_by(& &1.provider_id)}
      error -> error
    end
  end

  defp normalize_file(
         %{"id" => provider_id, "bookId" => work_id, "path" => path, "size" => size} = raw,
         config
       )
       when is_integer(provider_id) and provider_id > 0 and is_integer(work_id) and
              work_id > 0 and is_binary(path) and is_integer(size) and size >= 0 do
    {:ok,
     %{
       provider_id: provider_id,
       kind: :book,
       path: translate(path, config),
       size: size,
       work_id: work_id,
       format: quality_format(raw)
     }}
  end

  defp normalize_file(_raw, _config), do: {:error, :unexpected_response}

  defp quality_format(%{"quality" => %{"quality" => %{"name" => name}}}) when is_binary(name),
    do: String.downcase(name)

  defp quality_format(_raw), do: nil

  # Unlike the author/work/edition/file normalizers above — which halt the whole snapshot on a
  # malformed row because they carry catalog identity — profiles/roots are read-only, informational
  # (§B6b.1) and never matched against. A row that doesn't fit the expected shape is filtered out
  # rather than failing the entire snapshot over data nothing acts on yet.
  defp normalize_profiles(profiles) do
    for %{"id" => provider_id, "name" => name} <- profiles,
        is_integer(provider_id) and provider_id > 0 and is_binary(name) do
      %{provider_id: provider_id, name: name}
    end
  end

  defp normalize_roots(roots, naming) do
    rename_books = naming["renameBooks"] == true
    standard_book_format = Util.trim_to_nil(naming["standardBookFormat"])

    for %{"id" => provider_id, "path" => path} <- roots,
        is_integer(provider_id) and provider_id > 0 and is_binary(path) do
      %{
        provider_id: provider_id,
        path: path,
        rename_books: rename_books,
        standard_book_format: standard_book_format
      }
    end
  end

  defp translate(path, config) do
    PathMapping.translate(path, config[:remote_path_prefix], config[:local_path_prefix])
  end

  defp mapping_health(config) do
    PathMapping.validate_local_prefix(
      config[:remote_path_prefix],
      config[:local_path_prefix]
    )
  end

  defp configured do
    config = Application.get_env(:cinder, __MODULE__, [])

    if Util.trim_to_nil(config[:base_url]) && Util.trim_to_nil(config[:api_key]),
      do: {:ok, config},
      else: {:error, :not_configured}
  end

  defp request(config, opts) do
    [
      base_url: config[:base_url],
      headers: [{"x-api-key", config[:api_key]}],
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end
end
