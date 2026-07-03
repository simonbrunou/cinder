defmodule Cinder.Download.Client.Sabnzbd do
  @moduledoc """
  Real `Cinder.Download.Client` impl, backed by `Req`, against SABnzbd's JSON API
  (a single `GET /api?mode=…&apikey=…&output=json` endpoint).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Auth is just the API key as
  a query param — no stateful login.

  `add/1` uses `mode=addurl`: SABnzbd fetches the NZB itself (requires SABnzbd
  ≥ 0.8.0, where `addurl` returns a usable `nzo_id`). The `nzo_id` is the
  `download_id` the poller tracks; it lives in the **queue** while downloading and
  moves to **history** for post-processing/completion, so `status/1` reads queue
  first, then history — both scoped by `nzo_ids` so SABnzbd's default page limit
  can't hide the job.

  NOTE: SABnzbd must have "Pause on Duplicates" disabled — that mode re-keys the
  `nzo_id` after `addurl`, so the stored id would never reappear.

  Validated against a live SABnzbd only in Phase 5; the unit test is a shape
  sanity-check against `Req.Test`.
  """
  @behaviour Cinder.Download.Client

  @default_base_url "http://localhost:8080"

  @impl true
  def add(%{download_url: url}) when is_binary(url) do
    # retry: false — `addurl` is side-effecting (SABnzbd queues the NZB), but it's a GET, which
    # Req's default :safe_transient policy would retry up to 3× on a transient failure, re-queuing
    # the same download. Disable retry on the add path only (status/health stay idempotent-retryable).
    case get([mode: "addurl", name: url], retry: false) do
      # A returned job id is success; key on it rather than the `status` field,
      # whose type varies across SABnzbd versions (boolean true vs 1).
      {:ok, %{status: 200, body: %{"nzo_ids" => [id | _]}}} -> {:ok, id}
      {:ok, %{status: 200, body: %{"nzo_ids" => []}}} -> {:error, :add_rejected}
      {:ok, %{status: 200, body: %{"status" => false}}} -> {:error, :add_rejected}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  def add(%{download_url: _}), do: {:error, :unsupported_download_url}

  @impl true
  def status(nzo_id) do
    case queue_slot(nzo_id) do
      {:ok, nil} -> history_status(nzo_id)
      {:ok, slot} -> {:ok, classify_queue(slot)}
      other -> other
    end
  end

  # A queued slot is normally in flight, but a Paused or Failed slot won't progress
  # on its own — report it as :error so the poller bounds it to :import_failed rather
  # than polling a stalled job forever (e.g. SABnzbd's "Pause on Duplicates" mode,
  # which parks the job paused in the queue).
  defp classify_queue(%{"status" => status} = slot) when status in ["Paused", "Failed"],
    do: %{state: :error, progress: pct(slot["percentage"]), content_path: nil}

  defp classify_queue(slot), do: downloading(slot["percentage"])

  defp queue_slot(nzo_id) do
    case get(mode: "queue", nzo_ids: nzo_id) do
      {:ok, %{status: 200, body: body}} -> {:ok, find_slot(body, "queue", nzo_id)}
      other -> error(other)
    end
  end

  defp history_status(nzo_id) do
    case get(mode: "history", nzo_ids: nzo_id) do
      {:ok, %{status: 200, body: body}} ->
        case find_slot(body, "history", nzo_id) do
          nil -> {:error, :not_found}
          slot -> {:ok, classify_history(slot)}
        end

      other ->
        error(other)
    end
  end

  # A 200 whose `slots` are missing/empty/malformed means "not in this list" — so
  # queue falls through to history rather than erroring and stranding the poll.
  defp find_slot(%{} = body, key, nzo_id) do
    case body do
      %{^key => %{"slots" => slots}} when is_list(slots) ->
        Enum.find(slots, &(&1["nzo_id"] == nzo_id))

      _ ->
        nil
    end
  end

  defp find_slot(_body, _key, _nzo_id), do: nil

  defp downloading(percentage),
    do: %{state: :downloading, progress: pct(percentage), content_path: nil}

  defp classify_history(%{"status" => "Completed"} = slot),
    do: %{state: :completed, progress: 1.0, content_path: slot["storage"]}

  defp classify_history(%{"status" => "Failed"}),
    do: %{state: :error, progress: 1.0, content_path: nil}

  # Extracting / Repairing / Verifying / Moving / … — still in flight.
  defp classify_history(_slot),
    do: %{state: :downloading, progress: 1.0, content_path: nil}

  # SABnzbd reports queue percentage as a string ("42"); coerce before dividing.
  defp pct(p) when is_binary(p) do
    case Float.parse(p) do
      {f, _} -> f / 100
      :error -> 0.0
    end
  end

  defp pct(p) when is_number(p), do: p / 100
  defp pct(_), do: 0.0

  @impl true
  def remove(nzo_id, opts \\ []) do
    del = if Keyword.get(opts, :delete_files, true), do: "1", else: "0"

    # A queued job is deleted via mode=queue; a finished/post-processing job lives
    # in history and needs mode=history. SABnzbd reports a no-match delete as
    # status=false (not an error), so a false from the queue delete falls through
    # to a history delete; a false from *both* means the id is gone already —
    # which is success for an idempotent remove (unknown id -> :ok).
    case delete_in("queue", nzo_id, del) do
      :ok -> :ok
      :not_deleted -> delete_in_history(nzo_id, del)
      {:error, _} = err -> err
    end
  end

  defp delete_in_history(nzo_id, del) do
    case delete_in("history", nzo_id, del) do
      :ok -> :ok
      :not_deleted -> :ok
      {:error, _} = err -> err
    end
  end

  defp delete_in(mode, nzo_id, del) do
    case get(mode: mode, name: "delete", value: nzo_id, del_files: del) do
      {:ok, %{status: 200, body: %{"status" => false}}} -> :not_deleted
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  @impl true
  # mode=queue requires the API key (unlike mode=version, which SABnzbd serves
  # unauthenticated), so a wrong key surfaces as unhealthy. SABnzbd reports a bad
  # key as HTTP 200 with `{"status": false}`, so that body must be caught too.
  def health do
    # Bounded probe: no retry, short receive AND connect timeouts, so a down/
    # blackholed SABnzbd can't hang the settings "Test connection" for minutes.
    probe = [retry: false, receive_timeout: 3_000, connect_options: [timeout: 3_000]]

    case get([mode: "queue"], probe) do
      {:ok, %{status: 200, body: %{"status" => false}}} -> {:error, :bad_api_key}
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  defp get(params, extra \\ []) do
    config = config()

    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(extra)
    |> Req.new()
    |> Req.get(url: "/api", params: query(config, params))
  end

  defp query(config, params),
    do: Keyword.merge([apikey: Keyword.get(config, :api_key), output: "json"], params)

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp error({:ok, %{status: status}}), do: {:error, {:sabnzbd_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
