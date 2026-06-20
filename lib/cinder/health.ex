defmodule Cinder.Health do
  @moduledoc """
  Reachability checks for the external services the pipeline depends on
  (indexer, download client(s), media server). Each check resolves the configured
  impl behind its behaviour and calls its `health/0`. The `/status` dashboard uses
  this to surface an unwired/unreachable dependency instead of leaving it to stall
  silently and only show up in the logs.
  """
  alias Cinder.Download

  @doc """
  Checks every configured external service. Returns a list of
  `%{label: String.t(), status: :ok | {:error, term()}}`, ordered
  indexer → download client(s) → media server.
  """
  def check_all do
    [indexer_check()] ++ download_checks() ++ [media_server_check()]
  end

  defp indexer_check do
    mod = Application.fetch_env!(:cinder, :indexer)
    check("Indexer (#{short(mod)})", mod)
  end

  defp media_server_check do
    mod = Application.fetch_env!(:cinder, :media_server)
    check("Media server (#{short(mod)})", mod)
  end

  # One row per configured protocol (sorted for a stable display order).
  defp download_checks do
    for protocol <- Enum.sort(Download.available_protocols()) do
      {:ok, mod} = Download.client_for(protocol)
      check("Download (#{protocol} · #{short(mod)})", mod)
    end
  end

  defp check(label, mod), do: %{label: label, status: run(mod)}

  # Runs inside a LiveView async task, so a raising/odd-returning impl must
  # degrade to a red row rather than take the whole panel down.
  defp run(mod) do
    case mod.health() do
      :ok -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp short(mod), do: mod |> Module.split() |> List.last()
end
