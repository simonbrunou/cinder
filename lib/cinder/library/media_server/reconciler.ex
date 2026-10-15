defmodule Cinder.Library.MediaServer.Reconciler do
  @moduledoc """
  Periodically maps Cinder titles to media-server items by exact TMDB id, and stores the server's
  TV season inventory for the request page (`Cinder.Catalog.MediaServerSeasons`), so a season
  already on the server reads as available even for a show Cinder never added. Each provider callback
  returns either a complete bounded inventory or an error, so a failed/partial read never clears a
  previously reconciled id. `:start_poller`-gated with the other background workers.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.MediaServerSeasons
  alias Cinder.Library.MediaServer

  @default_interval :timer.minutes(15)
  use Cinder.Download.PollerSkeleton,
    log_prefix: "media-server reconciler",
    stateful: false,
    first_interval: :timer.minutes(1)

  defp do_poll do
    Enum.each(Cinder.Library.kinds(), fn kind ->
      isolate(to_string(kind), fn -> reconcile(kind) end)
    end)

    isolate("seasons", &reconcile_seasons/0)

    :ok
  end

  # An unconfigured server (or TV section) holds nothing. Keeping the last inventory there would
  # hide the Request button for seasons that no configured server has.
  defp reconcile_seasons do
    case MediaServer.impl().list_seasons() do
      {:ok, seasons} ->
        replace_seasons(seasons)

      {:error, reason} when reason in [:not_configured, {:plex_section_unset, :tv}] ->
        replace_seasons([])

      {:error, reason} ->
        log_failure(:seasons, reason)
    end
  end

  defp replace_seasons(seasons) do
    case MediaServerSeasons.replace(seasons) do
      {:ok, _} -> :ok
      {:error, reason} -> log_failure(:seasons, reason)
    end
  end

  defp reconcile(kind) do
    case MediaServer.impl().list_items(kind) do
      {:ok, items} ->
        case Catalog.reconcile_media_server_items(kind, items) do
          {:ok, _updated} -> :ok
          {:error, reason} -> log_failure(kind, reason)
        end

      {:error, reason} ->
        log_failure(kind, reason)
    end
  end

  defp log_failure(kind, reason) do
    Logger.warning("media-server reconciler: #{kind} inventory failed: #{inspect(reason)}")
    :ok
  end
end
