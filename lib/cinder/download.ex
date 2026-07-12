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
  alias Cinder.Download.{Intent, IntentEpisode}

  @retry_base_seconds 5
  @retry_max_seconds 300
  @permanent_submission_errors [:unsupported_download_url, :bad_torrent, :invalid_intent_release]

  @doc "Reserves a durable downloader operation before any external side effect."
  def reserve_intent(%{release: %Release{download_url: url} = release} = attrs)
      when is_binary(url) do
    intent_attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: Map.fetch!(attrs, :kind),
      target_id: Map.fetch!(attrs, :target_id),
      episode_ids: Map.get(attrs, :episode_ids, []),
      protocol: Map.fetch!(attrs, :protocol),
      release: %{
        "title" => release.title,
        "download_url_ciphertext" => url |> Vault.encrypt!() |> Base.encode64()
      },
      status: :reserved
    }

    Repo.transaction(fn -> insert_reserved_intent(intent_attrs) end)
    |> normalize_reservation()
  rescue
    Ecto.ConstraintError -> {:error, :download_intent_busy}
  end

  def reserve_intent(%{release: %Release{}}), do: {:error, :unsupported_download_url}

  defp insert_reserved_intent(attrs) do
    case %Intent{} |> Intent.changeset(attrs) |> Repo.insert() do
      {:ok, intent} ->
        Enum.each(intent.episode_ids, &insert_episode_reservation(intent.id, &1))
        intent

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_episode_reservation(intent_id, episode_id) do
    case %IntentEpisode{}
         |> IntentEpisode.changeset(%{intent_id: intent_id, episode_id: episode_id})
         |> Repo.insert() do
      {:ok, _reservation} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp normalize_reservation({:ok, intent}), do: {:ok, intent}

  defp normalize_reservation({:error, %Ecto.Changeset{} = changeset}) do
    if changeset.errors == [], do: {:error, changeset}, else: {:error, :download_intent_busy}
  end

  @doc "Durably submits a movie release and attaches the remote ID to the movie."
  def grab_movie(%Movie{} = movie, %Release{} = release) do
    case Repo.get_by(Intent, kind: :movie, target_id: movie.id) do
      nil -> reserve_and_reconcile(:movie, movie.id, [], release)
      %Intent{status: :cleanup_pending} -> {:error, :download_intent_busy}
      intent -> reconcile_matching_intent(intent, release, [])
    end
  end

  @doc "Durably submits a TV release and creates its guarded episode grab."
  def grab_episodes(%Release{} = release, episode_ids) when episode_ids != [] do
    case overlapping_episode_intent(episode_ids) do
      nil ->
        kind = if length(episode_ids) == 1, do: :episode, else: :season_pack
        reserve_and_reconcile(kind, hd(episode_ids), episode_ids, release)

      %Intent{status: :cleanup_pending} ->
        {:error, :download_intent_busy}

      intent ->
        reconcile_matching_intent(intent, release, episode_ids)
    end
  end

  defp reconcile_matching_intent(intent, release, episode_ids) do
    if same_release?(intent, release) and same_episode_assignment?(intent, episode_ids),
      do: reconcile_intent(intent),
      else: {:error, :download_intent_busy}
  end

  defp same_release?(intent, release) do
    intent.protocol == release.protocol and intent.release["title"] == release.title and
      decrypt_download_url(intent.release) == {:ok, release.download_url}
  end

  defp same_episode_assignment?(%Intent{kind: :movie}, []), do: true
  defp same_episode_assignment?(intent, ids), do: Enum.sort(intent.episode_ids) == Enum.sort(ids)

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
    Repo.one(
      from i in Intent,
        join: r in IntentEpisode,
        on: r.intent_id == i.id,
        where: r.episode_id in ^episode_ids,
        limit: 1
    )
  end

  @doc "Finds or submits the reserved remote job, then records its normal downloader ID."
  def submit_intent(%Intent{} = intent), do: with_intent_lock(intent, &do_submit_intent/1)

  defp do_submit_intent(%Intent{status: :submitted, remote_id: id} = intent)
       when is_binary(id),
       do: {:ok, intent}

  defp do_submit_intent(%Intent{status: :cleanup_pending}),
    do: {:error, :cleanup_pending}

  defp do_submit_intent(%Intent{} = intent) do
    if retry_due?(intent), do: submit_due_intent(intent), else: {:error, :intent_backoff}
  end

  defp submit_due_intent(intent) do
    case configured_client(intent.protocol) do
      {:ok, client} -> submit_with_client(intent, client)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp submit_with_client(intent, client) do
    case client.find_by_operation_key(intent.operation_key) do
      {:ok, remote_id} -> store_remote_id(intent, remote_id)
      :not_found -> add_reserved_release(intent, client)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  @doc "Attaches a durable intent's remote ID to its movie/grab owner and removes the intent."
  def reconcile_intent(%Intent{} = intent), do: with_intent_lock(intent, &do_reconcile_intent/1)

  defp do_reconcile_intent(%Intent{status: :cleanup_pending} = intent), do: do_cleanup(intent)

  defp do_reconcile_intent(%Intent{remote_id: nil} = intent) do
    with {:ok, submitted} <- do_submit_intent(intent), do: do_reconcile_intent(submitted)
  end

  defp do_reconcile_intent(%Intent{kind: :movie} = intent), do: reconcile_movie(intent)
  defp do_reconcile_intent(%Intent{} = intent), do: reconcile_episodes(intent)

  defp with_intent_lock(intent, fun) do
    :global.trans({{__MODULE__, intent.id}, self()}, fn ->
      case Repo.get(Intent, intent.id) do
        nil -> {:error, :intent_completed}
        fresh -> fun.(fresh)
      end
    end)
  end

  @doc false
  def reconcile_pending_intents(kinds) when is_list(kinds) do
    intents = Repo.all(from i in Intent, where: i.kind in ^kinds, order_by: [asc: i.id])
    Enum.each(intents, &reconcile_intent/1)
    :ok
  end

  @doc false
  def pending_episode_ids do
    Repo.all(from r in IntentEpisode, select: r.episode_id) |> MapSet.new()
  end

  @doc false
  def cancel_movie_intents(movie_id),
    do: cancel_intents(from i in Intent, where: i.kind == :movie and i.target_id == ^movie_id)

  @doc false
  def cancel_episode_intents(episode_ids) do
    from(i in Intent,
      join: r in IntentEpisode,
      on: r.intent_id == i.id,
      where: r.episode_id in ^episode_ids,
      distinct: true
    )
    |> cancel_intents()
  end

  defp cancel_intents(query) do
    query |> Repo.all() |> Enum.each(&cancel_intent/1)
    :ok
  end

  defp cancel_intent(intent) do
    with_intent_lock(intent, fn fresh ->
      case fresh
           |> Intent.changeset(%{
             status: :cleanup_pending,
             attempt_count: 0,
             next_attempt_at: nil,
             last_error: nil
           })
           |> Repo.update() do
        {:ok, cleanup} -> do_cleanup(cleanup)
        {:error, changeset} -> {:error, changeset}
      end
    end)
  end

  defp do_cleanup(intent) do
    if retry_due?(intent), do: cleanup_due_intent(intent), else: {:error, :intent_backoff}
  end

  defp cleanup_due_intent(intent) do
    case configured_client(intent.protocol) do
      {:ok, client} -> cleanup_with_client(intent, client)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp cleanup_with_client(%Intent{remote_id: id} = intent, client) when is_binary(id),
    do: remove_for_cleanup(intent, client, id)

  defp cleanup_with_client(intent, client), do: find_for_cleanup(intent, client)

  defp find_for_cleanup(intent, client) do
    case client.find_by_operation_key(intent.operation_key) do
      :not_found -> complete_intent(intent, :absent)
      {:ok, remote_id} -> persist_then_remove(intent, client, remote_id)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp persist_then_remove(intent, client, remote_id) do
    case store_cleanup_remote_id(intent, remote_id) do
      {:ok, updated} -> remove_for_cleanup(updated, client, remote_id)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp remove_for_cleanup(intent, client, remote_id) do
    case strict_remove(client, remote_id) do
      :ok -> complete_intent(intent, :removed)
      {:error, reason} -> schedule_retry(intent, reason)
    end
  end

  defp strict_remove(client, remote_id) do
    client.remove(remote_id, delete_files: true)
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp add_reserved_release(intent, client) do
    case decrypt_download_url(intent.release) do
      {:ok, download_url} -> add_decrypted_release(intent, client, download_url)
      {:error, reason} -> abandon_reserved(intent, reason)
    end
  end

  defp add_decrypted_release(intent, client, download_url) do
    release = %Release{
      title: intent.release["title"],
      download_url: download_url,
      protocol: intent.protocol
    }

    case client.add(release, operation_key: intent.operation_key) do
      {:ok, remote_id} ->
        store_remote_id(intent, remote_id)

      {:error, reason} when reason in @permanent_submission_errors ->
        abandon_reserved(intent, reason)

      {:error, reason} ->
        schedule_retry(intent, reason)
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

  defp store_remote_id(intent, remote_id) do
    intent
    |> Intent.changeset(%{
      status: :submitted,
      remote_id: remote_id,
      attempt_count: 0,
      next_attempt_at: nil,
      last_error: nil
    })
    |> Repo.update()
  end

  defp store_cleanup_remote_id(intent, remote_id) do
    intent |> Intent.changeset(%{remote_id: remote_id}) |> Repo.update()
  end

  defp schedule_retry(intent, reason) do
    attempt = (intent.attempt_count || 0) + 1
    delay = min(@retry_base_seconds * Integer.pow(2, min(attempt - 1, 6)), @retry_max_seconds)

    intent
    |> Intent.changeset(%{
      attempt_count: attempt,
      next_attempt_at: DateTime.utc_now(:second) |> DateTime.add(delay, :second),
      last_error: retry_error(reason)
    })
    |> Repo.update()

    {:error, reason}
  end

  defp retry_error(reason) when is_atom(reason), do: inspect(reason)

  defp retry_error({tag, value}) when is_atom(tag) and (is_atom(value) or is_integer(value)),
    do: inspect({tag, value})

  # Downloader errors can contain response bodies, request URLs, or exception
  # structs. Keep only the stable error class for those shapes.
  defp retry_error({tag, _value}) when is_atom(tag), do: inspect(tag)

  defp retry_error(_reason), do: "client_error"

  defp retry_due?(%Intent{next_attempt_at: nil}), do: true

  defp retry_due?(%Intent{next_attempt_at: next}),
    do: DateTime.compare(next, DateTime.utc_now()) in [:lt, :eq]

  defp abandon_reserved(intent, reason) do
    delete_intent(intent)
    {:error, reason}
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
        cleanup_failed_ownership(intent, :stale_entry)

      _ ->
        cleanup_failed_ownership(intent, :stale_target)
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
      {:error, _} -> cleanup_failed_ownership(intent, :stale_target)
    end
  rescue
    Ecto.StaleEntryError -> cleanup_failed_ownership(intent, :stale_entry)
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
          {:error, _} -> cleanup_failed_ownership(intent, :no_episodes_linked)
        end
    end
  rescue
    error -> cleanup_failed_ownership(intent, error)
  catch
    kind, value -> cleanup_failed_ownership(intent, {kind, value})
  end

  defp cleanup_failed_ownership(intent, reason) do
    case intent
         |> Intent.changeset(%{status: :cleanup_pending, next_attempt_at: nil})
         |> Repo.update() do
      {:ok, cleanup} ->
        do_cleanup(cleanup)
        {:error, reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp complete_intent(intent, owner) do
    delete_intent(intent)
    {:ok, owner}
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
