defmodule Cinder.Library.MediaServer.Reconciler do
  @moduledoc """
  Periodically maps Cinder titles to media-server items by exact TMDB id. Each provider callback
  returns either a complete bounded inventory or an error, so a failed/partial read never clears a
  previously reconciled id. `:start_poller`-gated with the other background workers.
  """

  alias Cinder.Catalog
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

    :ok
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
