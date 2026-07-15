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

  SABnzbd requires `apikey` in the query string. Redirects and redirect logging are disabled so
  that protocol-required secret is never replayed to another origin or written to Cinder's logs.
  `addurl` remains a deputy boundary: Cinder validates the initial provider URL, but SABnzbd then
  performs its own DNS resolution and redirects outside this policy. Isolate SABnzbd's network and
  deny access to private control-plane/metadata destinations; migrating to `addfile` is a separate
  compatibility change.

  Validated against a live SABnzbd only in Phase 5; the unit test is a shape
  sanity-check against `Req.Test`.
  """
  @behaviour Cinder.Download.Client

  alias Cinder.HTTPPolicy

  @default_base_url "http://localhost:8080"
  @max_response_bytes 4 * 1024 * 1024
  # SABnzbd truncates job names at `max_foldername_length` (default 246) BYTES from the tail,
  # which would cut off the mandatory ".cinder-<key>" suffix find_by_operation_key/1 depends on.
  # 200 protects against that DEFAULT only. An operator-lowered value <= 200 still truncates the
  # tail, and that loss is unrecoverable: SABnzbd's queue/history search is a LIKE on the display
  # name, so a name that lost the key tail is never even returned for client-side matching.
  @max_nzbname_bytes 200

  def add(release), do: add(release, [])

  @impl true
  def add(%{download_url: url} = release, opts) when is_binary(url) do
    # retry: false — `addurl` is side-effecting (SABnzbd queues the NZB), but it's a GET, which
    # Req's default :safe_transient policy would retry up to 3× on a transient failure, re-queuing
    # the same download. Disable retry on the add path only (status/health stay idempotent-retryable).
    with {:ok, _uri} <- validate_url(url, Map.get(release, :download_url_origin)) do
      add_url(url, release, opts)
    end
  end

  def add(%{download_url: _}, _opts), do: {:error, :unsupported_download_url}

  defp add_url(url, release, opts) do
    params =
      case Keyword.get(opts, :operation_key) do
        key when is_binary(key) -> [mode: "addurl", name: url, nzbname: nzbname(release, key)]
        _ -> [mode: "addurl", name: url]
      end

    case get(params, retry: false) do
      # A returned job id is success; key on it rather than the `status` field,
      # whose type varies across SABnzbd versions (boolean true vs 1).
      {:ok, %{status: 200, body: %{"nzo_ids" => [id | _]}}} -> {:ok, id}
      {:ok, %{status: 200, body: %{"nzo_ids" => []}}} -> {:error, :add_rejected}
      {:ok, %{status: 200, body: %{"status" => false}}} -> {:error, :add_rejected}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  # Name the job after the release title (with the operation key as a suffix) so
  # SABnzbd's "deobfuscate final filenames" renames the video to a title-bearing
  # name instead of the bare `cinder-<key>` job name, which would erase every
  # episode marker the downstream parser depends on. The suffix stays mandatory:
  # it's what makes the job findable via find_by_operation_key/1, and it keeps a
  # legitimate re-grab of the same release from colliding on name alone.
  defp nzbname(release, key) do
    suffix = ".#{operation_name(key)}"

    # Behaviour-typed keys could someday exceed @max_nzbname_bytes on their own; don't go negative.
    budget = max(@max_nzbname_bytes - byte_size(suffix), 0)

    case release |> Map.get(:title) |> sanitize_title() do
      "" ->
        operation_name(key)

      title ->
        # Pre-bound before the byte-trim loop: every grapheme is >= 1 byte, so slicing to
        # `budget` graphemes upfront caps the loop below at `budget` iterations regardless of
        # the (indexer-controlled) original title length — an unbounded 210KB CJK title took
        # ~107s in that loop inside the poller GenServer without this.
        trimmed_title =
          title
          |> String.slice(0, budget)
          |> truncate_bytes(budget)
          |> String.replace(~r/[.\s]+$/, "")

        case trimmed_title do
          # A leading-dot job name is a hidden dir to SABnzbd; reachable via a single
          # >155-byte grapheme cluster that trims to nothing. Fall back to the bare key.
          "" -> operation_name(key)
          trimmed -> trimmed <> suffix
        end
    end
  end

  defp truncate_bytes("", _max_bytes), do: ""
  defp truncate_bytes(title, max_bytes) when byte_size(title) <= max_bytes, do: title

  defp truncate_bytes(title, max_bytes),
    do: title |> String.slice(0..-2//1) |> truncate_bytes(max_bytes)

  defp operation_name(key), do: "cinder-#{key}"

  @hostile_chars ~r/[\/\\:*?"<>|\x00-\x1f\x7f.{}=]+/

  # SABnzbd runs scan_password on the submitted nzbname BEFORE building the work name
  # (nzb/object.py:243→250): a `password=` substring truncates the stored name right there, and
  # an unanchored `{{` with a later `}}` truncates at the `{{` — neutralize `{`, `}`, `=` up
  # front so neither token form can survive. SABnzbd also NFC-normalizes the name before its own
  # byte-length truncation (filesystem.py:267→282), and NFC can EXPAND bytes (e.g. U+0958:
  # 3→6 bytes), so our byte cap must count post-NFC bytes too — normalize first, same as SABnzbd.
  defp sanitize_title(title) when is_binary(title) do
    case :unicode.characters_to_nfc_binary(title) do
      normalized when is_binary(normalized) ->
        normalized
        |> String.replace(@hostile_chars, ".")
        |> String.replace(~r/^[.\s]+|[.\s]+$/, "")

      _not_a_binary ->
        ""
    end
  end

  defp sanitize_title(_title), do: ""

  @impl true
  def find_by_operation_key(key) do
    name = operation_name(key)

    [
      named_slots("queue", name),
      named_slots("history", name, archive: 0),
      named_slots("history", name, archive: 1)
    ]
    |> unique_remote_id()
  end

  defp named_slots(mode, name, extra \\ []) do
    case get([mode: mode, search: name] ++ extra) do
      {:ok, %{status: 200, body: body}} -> {:ok, matching_named_slots(body, mode, name)}
      other -> error(other)
    end
  end

  # Matches one of three real SABnzbd name shapes for our "<title>.cinder-<key>" job name,
  # never a bare `contains?` on the key:
  #   1. suffix — "<title>.cinder-<key>" (or, for a legacy in-flight job, exactly
  #      "cinder-<key>");
  #   2. `nzb_name` in history keeps the .nzb extension SABnzbd stored it with —
  #      "<title>.cinder-<key>.nzb";
  #   3. a failed URL-fetch job (urlgrabber.py fail_to_history) is renamed to
  #      "<our nzbname> - <url>" — the key ends up mid-string, not at the tail. The
  #      arm requires the " - http" URL tail so only that rename shape matches.
  # An unanchored `contains?` on the bare key is deliberately rejected: a completed
  # download's own output file (e.g. "Title.cinder-op-123.mkv") can re-enter the indexer
  # as a future release's title, and a substring match would collide with that re-post.
  defp matching_named_slots(body, mode, name) do
    case body do
      %{^mode => %{"slots" => slots}} when is_list(slots) ->
        Enum.filter(slots, fn slot ->
          named?(slot["filename"], name) or named?(slot["name"], name) or
            named?(slot["nzb_name"], name)
        end)

      _ ->
        []
    end
  end

  defp named?(value, name) when is_binary(value) do
    String.ends_with?(value, name) or String.ends_with?(value, name <> ".nzb") or
      String.contains?(String.downcase(value, :ascii), String.downcase(name, :ascii) <> " - http")
  end

  defp named?(_value, _name), do: false

  defp unique_remote_id(results) do
    with {:ok, slots} <- collect_slots(results),
         {:ok, ids} <- collect_remote_ids(slots) do
      case Enum.uniq(ids) do
        [] -> :not_found
        [id] -> {:ok, id}
        [_ | _] -> {:error, :ambiguous_operation_key}
      end
    end
  end

  defp collect_slots(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, slots}, {:ok, acc} -> {:cont, {:ok, slots ++ acc}}
      error, _acc -> {:halt, error}
    end)
  end

  defp collect_remote_ids(slots) do
    Enum.reduce_while(slots, {:ok, []}, fn slot, {:ok, ids} ->
      case remote_id(slot) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        error -> {:halt, error}
      end
    end)
  end

  defp remote_id(%{"nzo_id" => id}) when is_binary(id), do: {:ok, id}
  defp remote_id(_slot), do: {:error, :unexpected_response}

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
    do: %{
      state: :error,
      progress: pct(slot["percentage"]),
      speed: nil,
      eta: eta(slot["timeleft"]),
      content_path: nil
    }

  defp classify_queue(slot), do: downloading(slot["percentage"], slot["timeleft"])

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

  defp downloading(percentage, timeleft),
    do: %{
      state: :downloading,
      progress: pct(percentage),
      speed: nil,
      eta: eta(timeleft),
      content_path: nil
    }

  defp classify_history(%{"status" => "Completed"} = slot),
    do: %{state: :completed, progress: 1.0, speed: nil, eta: nil, content_path: slot["storage"]}

  defp classify_history(%{"status" => "Failed"}),
    do: %{state: :error, progress: 1.0, speed: nil, eta: nil, content_path: nil}

  # Extracting / Repairing / Verifying / Moving / … — still in flight.
  defp classify_history(_slot),
    do: %{state: :downloading, progress: 1.0, speed: nil, eta: nil, content_path: nil}

  defp eta(timeleft) when is_binary(timeleft) do
    with [hours, minutes, seconds] <- String.split(String.trim(timeleft), ":"),
         {hours, ""} <- Integer.parse(hours),
         {minutes, ""} <- Integer.parse(minutes),
         {seconds, ""} <- Integer.parse(seconds),
         true <- hours >= 0 and minutes in 0..59 and seconds in 0..59 do
      hours * 3600 + minutes * 60 + seconds
    else
      _ -> nil
    end
  end

  defp eta(_timeleft), do: nil

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

    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(extra)
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> Req.merge(method: :get, url: "/api", params: query(config, params))
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp query(config, params),
    do: Keyword.merge([apikey: Keyword.get(config, :api_key), output: "json"], params)

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp validate_url(url, source_origin) do
    case Keyword.get(config(), :url_resolver) do
      resolver when is_function(resolver, 1) ->
        HTTPPolicy.validate_source_url(url, source_origin, resolver)

      nil ->
        HTTPPolicy.validate_source_url(url, source_origin)
    end
  end

  defp error({:ok, %{status: status}}), do: {:error, {:sabnzbd_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
