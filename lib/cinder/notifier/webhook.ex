defmodule Cinder.Notifier.Webhook do
  @moduledoc """
  Generic webhook notifier: when a URL is configured, POSTs every event as JSON. One transport
  covers the endpoints a homelab already runs — ntfy, Gotify, Apprise, n8n, Home Assistant, a
  Telegram/Slack relay — instead of a per-service agent each. There is deliberately no payload
  template: reshaping the body is what n8n/Apprise are for.

  Best-effort and registered in `Cinder.Notifier.Dispatcher` alongside `Log`, `Discord` and
  `Email`, so it inherits the dispatcher's isolation, supervised task and delivery timeout — a
  failed post is logged and swallowed, and the request carries a bounded `receive_timeout` so a
  hung endpoint can't stall a synchronous call site either.

  The URL and the optional `Authorization` header value are `Cinder.Settings` registry entries,
  overlaid onto `Application.get_env(:cinder, __MODULE__)`. A blank URL makes `notify/1` a no-op.
  """
  @behaviour Cinder.Notifier

  alias Cinder.HTTPPolicy
  alias Cinder.Util

  require Logger

  # Matches Discord's bounds: 3s connect + 3s response, no retry.
  @default_req_options [receive_timeout: 3_000, connect_options: [timeout: 3_000], retry: false]
  @max_response_bytes 4 * 1024 * 1024

  # The payload allowlist. Anything not named here stays out of the body, which keeps requester
  # emails and user free-text (an issue report's `detail`) off a third-party endpoint the same
  # way the Discord embeds do (#184).
  @subject_keys [:id, :title, :year, :season_number, :episode_number, :user_id, :category]

  @impl true
  def notify(event) do
    with url when is_binary(url) <- url(),
         payload when is_map(payload) <- payload(event) do
      post(url, payload)
    end

    :ok
  end

  # The typed event flattened to a stable shape: an `event` discriminator plus the subject's
  # identifying fields, and `reason` for the three-element (failure) events.
  defp payload({type, subject, reason}) when is_atom(type),
    do: Map.put(payload({type, subject}), :reason, reason(reason))

  defp payload({type, subject}) when is_atom(type),
    do: Map.put(fields(subject), :event, type)

  # An event of any other shape is a bug, not a payload: `nil` skips the post rather than
  # inspecting an unrecognised term onto a third-party endpoint. `Log` still records it.
  defp payload(_other), do: nil

  # `episodes_search_exhausted` carries a list; the episodes are preloaded through their season,
  # so the season number is lifted onto each one rather than left nested.
  defp fields(episodes) when is_list(episodes), do: %{episodes: Enum.map(episodes, &fields/1)}

  defp fields(%{season: %{season_number: number}} = episode),
    do: episode |> Map.take(@subject_keys) |> Map.put(:season_number, number)

  # The maintenance events' subject is the operation key, not a record.
  defp fields(key) when is_atom(key), do: %{name: key}
  defp fields(%{} = subject), do: Map.take(subject, @subject_keys)
  defp fields(other), do: %{summary: inspect(other)}

  # Atoms and strings encode as-is; a tuple/struct reason has no JSON form, so it is inspected.
  defp reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  defp post(url, payload) do
    base_req()
    |> Req.merge(method: :post, url: url, json: payload, headers: auth_headers())
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> classify()
    |> log_if_error()
  end

  # Matches the repo's Req idiom (discord.ex, jellyfin.ex): config's req_options merged onto the
  # bounded defaults. req_options carries the test plug in :test and is empty in prod.
  defp base_req do
    @default_req_options
    |> Keyword.merge(config(:req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp auth_headers do
    case Util.blank_to_nil(config(:auth_header)) do
      nil -> []
      value -> [{"authorization", value}]
    end
  end

  defp url, do: Util.blank_to_nil(config(:url))

  defp config(key, default \\ nil),
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp classify({:error, reason}), do: {:error, reason}

  defp log_if_error(:ok), do: :ok

  defp log_if_error({:error, reason} = error) do
    Logger.warning("Webhook notify failed: #{HTTPPolicy.sanitize_log(reason)}")
    error
  end
end
