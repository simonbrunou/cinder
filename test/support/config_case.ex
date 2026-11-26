defmodule Cinder.ConfigCase do
  @moduledoc """
  Helper for tests that temporarily override configuration and restore it on exit: a `:cinder`
  application-env key, and the media-server choice (the stored type row, `PLEX_URL`, the
  overlay's bootstrap impl).

  Test functions within a module run sequentially (ExUnit only parallelizes across
  async modules), so an override scoped to the test that owns the config key can't
  race another test.
  """

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Settings.Overlay

  @doc """
  Merges `overrides` onto the current `Application.get_env(:cinder, key)` and
  restores the original value when the test exits. For `:anime_preferences` it raises on groups
  given otherwise than `Cinder.Settings` stores them (`stored_anime_groups!/2`).
  """
  def put_config(key, overrides) do
    if key == :anime_preferences,
      do: stored_anime_groups!(overrides, "put_config(:anime_preferences, ...)")

    original = Application.get_env(:cinder, key)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cinder, key, original) end)
    Application.put_env(:cinder, key, Keyword.merge(original, overrides))
  end

  @doc """
  Raises unless the `:preferred_groups` and `:blocked_groups` in `overrides` (a keyword list or
  a map) are as `Cinder.Settings` stores them: trimmed, downcased, no blank and no repeat
  (`AnimePreferences.normalize_groups/1`). The policy compares a release's normalized group
  with the groups as stored, so a test that sets "Trusted" matches no release and passes
  without testing the group rule (#839). `caller` names the helper in the message.
  """
  def stored_anime_groups!(overrides, caller) do
    for slot <- [:preferred_groups, :blocked_groups],
        {:ok, groups} <- [Access.fetch(overrides, slot)],
        groups != AnimePreferences.normalize_groups(groups) do
      raise ArgumentError,
            "#{caller}: #{slot}: #{inspect(groups)} is not as Cinder.Settings stores it; " <>
              "pass #{inspect(AnimePreferences.normalize_groups(groups))}"
    end

    :ok
  end

  @doc """
  Sets `key` to `value` and restores the original value when the test exits, deleting the key
  when it was unset. For a value that is not a keyword list to merge into.
  """
  def put_env(key, value) do
    restore_env_on_exit([key])
    Application.put_env(:cinder, key, value)
  end

  @doc "Runs `put_env/2` for each key and value in the keyword list `pairs`."
  def put_env(pairs) when is_list(pairs),
    do: Enum.each(pairs, fn {key, value} -> put_env(key, value) end)

  @doc """
  Reads each `:cinder` key in `keys` now and, when the test exits, gives it back that value,
  `nil` included, or deletes it when it was unset. For keys the test changes some other way: a
  settings save, `Application.delete_env/2`, a raw write inside the test.
  """
  def restore_env_on_exit(keys) when is_list(keys) do
    saved = Enum.map(keys, &{&1, Application.fetch_env(:cinder, &1)})

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:cinder, key, value)
        {key, :error} -> Application.delete_env(:cinder, key)
      end)
    end)

    :ok
  end

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
  def put_media_server_web_url(url), do: put_media_server_web_url("plex", url)

  @doc """
  Stores `type` as the `media_server_type` row and sets `url` as that option's web URL, restored
  on exit. `type` is an option's `value` in `Cinder.Settings.Registry.media_servers/0`.
  """
  def put_media_server_web_url(type, url) do
    %{module: module} = Enum.find(Cinder.Settings.Registry.media_servers(), &(&1.value == type))
    previous = Application.get_env(:cinder, module, [])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cinder, module, previous) end)

    store_media_server_type(type)
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

  @doc """
  Replaces the boot capture the env overlay keeps for `key` (`Cinder.Settings.Overlay.base/1`)
  with `fun` applied to it, and restores the capture on exit. Each settings save rebuilds the env
  from the stored rows, so a `put_config/2` made before a save is gone once it returns; a key with
  no row falls back to this capture only where its overlay writer reads it, as a module's config
  does (docs/agents/testing.md). On such a key this keeps the change through saves, except on
  `:indexer_source`, whose writer keeps a captured module only when no option lists it. The
  capture is process-global, so only an `async: false` module calls it.
  """
  def update_boot_capture(key, fun) when is_function(fun, 1) do
    pt_key = {Cinder.Settings, :base, key}
    prior = :persistent_term.get(pt_key, :__none__)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        :__none__ -> :persistent_term.erase(pt_key)
        value -> :persistent_term.put(pt_key, value)
      end
    end)

    :persistent_term.put(pt_key, fun.(Overlay.base(key)))
  end
end
