defmodule Cinder.ConfigCase do
  @moduledoc """
  Helper for tests that temporarily override configuration and restore it on exit: a `:cinder`
  application-env key, and the media-server choice (the stored type row, `PLEX_URL`, the
  overlay's bootstrap impl).

  Test functions within a module run sequentially (ExUnit only parallelizes across
  async modules), so an override scoped to the test that owns the config key can't
  race another test.
  """

  @doc """
  Merges `overrides` onto the current `Application.get_env(:cinder, key)` and
  restores the original value when the test exits.
  """
  def put_config(key, overrides) do
    original = Application.get_env(:cinder, key)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cinder, key, original) end)
    Application.put_env(:cinder, key, Keyword.merge(original, overrides))
  end

  @doc """
  Sets `key` to `value` and restores the original value when the test exits, deleting the key
  when it was unset. For a value that is not a keyword list to merge into.
  """
  def put_env(key, value) do
    original = Application.fetch_env(:cinder, key)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, original} -> Application.put_env(:cinder, key, original)
        :error -> Application.delete_env(:cinder, key)
      end
    end)

    Application.put_env(:cinder, key, value)
  end

  @doc "Runs `put_env/2` for each key and value in the keyword list `pairs`."
  def put_env(pairs) when is_list(pairs),
    do: Enum.each(pairs, fn {key, value} -> put_env(key, value) end)

  @doc """
  Stores `type` as the `media_server_type` row and returns it, for the readers of the stored type
  (`Cinder.Settings.media_server_type/0`, the web link). A raw row, not `Cinder.Settings.put/2`:
  put reloads the overlay, which swaps the global `:media_server` impl off the Mox mock for the
  rest of the run.
  """
  def store_media_server_type(type) do
    Cinder.Repo.insert!(%Cinder.Settings.Setting{
      key: "media_server_type",
      value: type,
      is_secret: false
    })
  end

  @doc """
  Stores the Plex type row and sets `url` as the Plex web URL, restored on exit:
  `Cinder.Settings.media_server_web_link/0` reads both.
  """
  def put_media_server_web_url(url) do
    module = Cinder.Library.MediaServer.Plex
    previous = Application.get_env(:cinder, module, [])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cinder, module, previous) end)

    store_media_server_type("plex")
    Application.put_env(:cinder, module, Keyword.put(previous, :web_url, url))
  end

  @doc """
  Sets `PLEX_URL`, or unsets it for `nil`, and restores the prior value on exit. The variable is
  process-global and picks Plex while no media server type is stored, so only an `async: false`
  module sets it.
  """
  def put_plex_url(url) do
    prior = System.get_env("PLEX_URL")
    ExUnit.Callbacks.on_exit(fn -> set_plex_url(prior) end)
    set_plex_url(url)
  end

  defp set_plex_url(nil), do: System.delete_env("PLEX_URL")
  defp set_plex_url(url), do: System.put_env("PLEX_URL", url)

  @doc """
  Makes `module` the media-server impl the env overlay captured at boot (`Overlay.base/1`), the
  one it keeps with no type stored and no `os_env` set, and restores the capture on exit. The
  suite captures the Mox mock, which names no server; prod captures config.exs's Jellyfin.
  """
  def put_media_server_bootstrap(module) do
    key = {Cinder.Settings, :base, :media_server}
    prior = :persistent_term.get(key, :__none__)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        :__none__ -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.put(key, module)
  end
end
