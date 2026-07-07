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
    [indexer_check()] ++
      download_checks() ++ [media_server_check()] ++ library_checks() ++ subtitles_check()
  end

  @doc """
  Checks a single service against its currently-applied config, returning
  `:ok | {:error, term()}`. Used by the settings "Test connection" buttons.
  `service` is `:tmdb | :indexer | :media_server | :discord | :subtitles | {:download, protocol}`.
  """
  def check_service(:tmdb), do: run(Application.fetch_env!(:cinder, :tmdb))
  def check_service(:indexer), do: run(Application.fetch_env!(:cinder, :indexer))
  def check_service(:media_server), do: run(Application.fetch_env!(:cinder, :media_server))
  def check_service(:discord), do: run(Cinder.Notifier.Discord)

  def check_service(:subtitles) do
    case Application.get_env(:cinder, Application.get_env(:cinder, :subtitles_provider), [])[
           :api_key
         ] do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      _ -> run(Application.fetch_env!(:cinder, :subtitles_provider))
    end
  end

  def check_service({:download, protocol}) do
    case Download.client_for(protocol) do
      {:ok, mod} -> run(mod)
      :error -> {:error, :not_configured}
    end
  end

  def check_service({:library, kind}) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      path -> library_writable(path)
    end
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

  # One row per library kind (Movies, TV, …); reuses the writable-path probe so a missing or
  # unwritable root shows red on /status — the visible signal that an import is holding.
  defp library_checks do
    for kind <- Cinder.Library.kinds() do
      %{label: "Library (#{kind})", status: check_service({:library, kind})}
    end
  end

  # Subtitles is off-by-default (no api_key ⇒ :not_configured) — omit the row entirely rather
  # than show red noise on an install that hasn't opted into the feature.
  defp subtitles_check do
    case check_service(:subtitles) do
      {:error, :not_configured} -> []
      status -> [%{label: "Subtitles (OpenSubtitles)", status: status}]
    end
  end

  defp check(label, mod), do: %{label: label, status: run(mod)}

  # Both probes run inside a LiveView async task, so a misbehaving impl must degrade to a
  # red row rather than take the whole panel down. `catch` covers exits/throws (e.g. a
  # pool-checkout timeout deep in the HTTP stack) that `rescue` would miss.
  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp run(mod) do
    safely(fn ->
      case mod.health() do
        :ok -> :ok
        {:error, _} = err -> err
      end
    end)
  end

  # The library import target isn't a behaviour with health/0; "reachable" means the
  # configured path is writable. mkdir_p on an existing dir is a no-op, so this is a
  # cheap probe through the same Filesystem behaviour the import uses (mockable in tests).
  defp library_writable(path) do
    safely(fn ->
      case Application.fetch_env!(:cinder, :filesystem).mkdir_p(path) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    end)
  end

  defp short(mod), do: mod |> Module.split() |> List.last()
end
