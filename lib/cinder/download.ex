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
  import Ecto.Query

  require Logger
  alias Cinder.{Acquisition, Catalog, Notifier, Repo, Vault}
  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.{Grab, Movie}
  alias Cinder.Download.Intent

  @doc "Reserves a durable downloader operation before any external side effect."
  def reserve_intent(%{release: %Release{} = release} = attrs) do
    intent_attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: Map.fetch!(attrs, :kind),
      target_id: Map.fetch!(attrs, :target_id),
      episode_ids: Map.get(attrs, :episode_ids, []),
      protocol: Map.fetch!(attrs, :protocol),
      release: %{
        "title" => release.title,
        "download_url_ciphertext" => release.download_url |> Vault.encrypt!() |> Base.encode64()
      },
      status: :reserved
    }

    %Intent{} |> Intent.changeset(intent_attrs) |> Repo.insert()
  end

  @doc "Durably submits a movie release and attaches the remote ID to the movie."
  def grab_movie(%Movie{} = movie, %Release{} = release) do
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil -> reserve_and_reconcile(:movie, movie.id, [], release)
      intent -> reconcile_intent(intent)
    end
  end

  @doc "Durably submits a TV release and creates its guarded episode grab."
  def grab_episodes(%Release{} = release, episode_ids) when episode_ids != [] do
    case overlapping_episode_intent(episode_ids) do
      nil ->
        kind = if length(episode_ids) == 1, do: :episode, else: :season_pack
        reserve_and_reconcile(kind, hd(episode_ids), episode_ids, release)

      intent ->
        reconcile_intent(intent)
    end
  end

  defp reserve_and_reconcile(kind, target_id, episode_ids, release) do
    with {:ok, intent} <-
           reserve_intent(%{
             kind: kind,
             target_id: target_id,
             episode_ids: episode_ids,
             protocol: release.protocol,
             release: release
           }) do
      reconcile_intent(intent)
    end
  end

  defp overlapping_episode_intent(episode_ids) do
    wanted = MapSet.new(episode_ids)

    Intent
    |> Repo.all()
    |> Enum.find(fn intent ->
      intent.kind in [:episode, :season_pack] and
        not MapSet.disjoint?(wanted, MapSet.new(intent.episode_ids))
    end)
  end

  @doc "Finds or submits the reserved remote job, then records its normal downloader ID."
  def submit_intent(%Intent{} = intent) do
    with {:ok, client} <- configured_client(intent.protocol) do
      case client.find_by_operation_key(intent.operation_key) do
        {:ok, remote_id} -> store_remote_id(intent, client, remote_id)
        :not_found -> add_reserved_release(intent, client)
        {:error, _} = error -> error
      end
    end
  end

  @doc "Attaches a durable intent's remote ID to its movie/grab owner and removes the intent."
  def reconcile_intent(%Intent{remote_id: nil} = intent) do
    with {:ok, submitted} <- submit_intent(intent), do: reconcile_intent(submitted)
  end

  def reconcile_intent(%Intent{kind: :movie} = intent), do: reconcile_movie(intent)

  def reconcile_intent(%Intent{} = intent), do: reconcile_episodes(intent)

  @doc false
  def reconcile_pending_intents(kinds) when is_list(kinds) do
    intents = Repo.all(from i in Intent, where: i.kind in ^kinds, order_by: [asc: i.id])
    Enum.each(intents, &reconcile_intent/1)
    :ok
  end

  @doc false
  def pending_episode_ids do
    Repo.all(from i in Intent, where: i.kind in [:episode, :season_pack], select: i.episode_ids)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc false
  def cancel_movie_intents(movie_id),
    do: cancel_intents(from i in Intent, where: i.kind == :movie and i.target_id == ^movie_id)

  @doc false
  def cancel_episode_intents(episode_ids) do
    wanted = MapSet.new(episode_ids)

    Intent
    |> Repo.all()
    |> Enum.filter(fn intent ->
      intent.kind in [:episode, :season_pack] and
        not MapSet.disjoint?(wanted, MapSet.new(intent.episode_ids))
    end)
    |> Enum.each(&cancel_intent/1)

    :ok
  end

  defp cancel_intents(query) do
    query |> Repo.all() |> Enum.each(&cancel_intent/1)
    :ok
  end

  defp cancel_intent(intent) do
    with {:ok, client} <- configured_client(intent.protocol) do
      case (intent.remote_id && {:ok, intent.remote_id}) ||
             client.find_by_operation_key(intent.operation_key) do
        {:ok, remote_id} -> best_effort_remove(client, remote_id)
        _ -> :ok
      end
    end

    delete_intent(intent)
  end

  defp add_reserved_release(intent, client) do
    with {:ok, download_url} <- decrypt_download_url(intent.release) do
      release = %Release{
        title: intent.release["title"],
        download_url: download_url,
        protocol: intent.protocol
      }

      case client.add(release, operation_key: intent.operation_key) do
        {:ok, remote_id} -> store_remote_id(intent, client, remote_id)
        {:error, _} = error -> error
      end
    end
  end

  defp decrypt_download_url(%{"download_url_ciphertext" => encoded}) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, url} when is_binary(url) <- Vault.decrypt(ciphertext) do
      {:ok, url}
    else
      _ -> {:error, :invalid_intent_release}
    end
  end

  defp decrypt_download_url(_release), do: {:error, :invalid_intent_release}

  defp store_remote_id(intent, client, remote_id) do
    intent
    |> Intent.changeset(%{status: :submitted, remote_id: remote_id})
    |> Repo.update()
  rescue
    Ecto.StaleEntryError ->
      best_effort_remove(client, remote_id)
      {:error, :stale_intent}
  end

  defp reconcile_movie(%Intent{remote_id: remote_id, target_id: movie_id} = intent) do
    case Repo.get(Movie, movie_id) do
      %Movie{download_id: ^remote_id} = movie ->
        complete_intent(intent, movie)

      %Movie{status: status} = movie when status in [:requested, :searching] ->
        attach_movie(intent, movie, %{status: :downloading})

      %Movie{status: status} = movie when status in [:no_match, :search_failed, :import_failed] ->
        attach_movie(intent, movie, %{status: :downloading, search_attempts: 0})

      %Movie{status: :available} = movie ->
        attach_movie(intent, movie, %{status: :upgrading})

      nil ->
        abandon_intent(intent, :stale_entry)

      _ ->
        abandon_intent(intent, :stale_target)
    end
  end

  defp attach_movie(intent, movie, attrs) do
    attrs =
      Map.merge(attrs, %{
        download_id: intent.remote_id,
        download_protocol: intent.protocol,
        release_title: intent.release["title"],
        import_attempts: 0
      })

    case Catalog.transition(movie, attrs, expect: movie.status) do
      {:ok, updated} -> complete_intent(intent, updated)
      {:error, _} -> abandon_intent(intent, :stale_target)
    end
  rescue
    Ecto.StaleEntryError -> abandon_intent(intent, :stale_entry)
  end

  defp reconcile_episodes(%Intent{remote_id: remote_id} = intent) do
    case Repo.get_by(Grab, download_id: remote_id, download_protocol: intent.protocol) do
      %Grab{} = grab ->
        complete_intent(intent, grab)

      nil ->
        case Catalog.create_grab(
               remote_id,
               intent.protocol,
               intent.episode_ids,
               intent.release["title"],
               reset_attempts: true
             ) do
          {:ok, grab} -> complete_intent(intent, grab)
          {:error, _} -> abandon_intent(intent, :no_episodes_linked)
        end
    end
  rescue
    error -> abandon_intent(intent, error)
  catch
    kind, value -> abandon_intent(intent, {kind, value})
  end

  defp complete_intent(intent, owner) do
    delete_intent(intent)
    {:ok, owner}
  end

  defp abandon_intent(intent, reason) do
    case configured_client(intent.protocol) do
      {:ok, client} -> best_effort_remove(client, intent.remote_id)
      {:error, _} -> :ok
    end

    delete_intent(intent)
    {:error, reason}
  end

  defp delete_intent(intent) do
    Repo.delete(intent, allow_stale: true)
    :ok
  end

  defp configured_client(protocol) do
    case client_for(protocol) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, :no_client}
    end
  end

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
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil -> do_start(movie)
      intent -> reconcile_intent(intent)
    end
  end

  defp do_start(movie) do
    # Every transition below is guarded on the status this unit read (expect:) so a
    # user cancel landing during the indexer/client I/O is never overwritten; a
    # {:error, :stale_status} skips the unit — the next tick re-derives.
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <-
           Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id},
             expect: movie.status
           ) do
      opts =
        [
          protocols: available_protocols(),
          preferred_language: movie.preferred_language,
          original_language: movie.original_language,
          release_blocklist: Catalog.blocked_release_titles(movie)
        ] ++ Acquisition.band_opts(:movies)

      case Acquisition.best_release(imdb_id, opts) do
        {:ok, release} ->
          add_to_client(movie, release)

        :no_match ->
          Catalog.transition(movie, %{status: :no_match}, expect: movie.status)

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
    with {:ok, parked} <-
           Catalog.transition(movie, %{status: :no_match}, expect: movie.status) do
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
    grab_movie(movie, release)
  end
end
