defmodule Cinder.Health.Target do
  @moduledoc """
  One probe target: one thing Cinder can check on demand (an external service, a library root,
  a local tool). `Cinder.Health.targets/1` lists them; every surface that names a target (the
  `/settings` Test buttons, the `/setup` gate, the `/dashboard` rows) reads that one list.

  - `id`: the stable identity. It is the Test button's `phx-value-target`, the key of a
    LiveView's health map and the dashboard row's DOM id.
  - `group`: the `Cinder.Settings.Registry.groups/0` group whose Test button checks it.
  - `label`: an English msgid, the same on every surface; `CinderWeb.SettingsLabels.t/1`
    translates it.
  - `probe`: plain data naming what `Cinder.Health.check/1` calls, resolved at check time.
  - `setup`: `:required` (must be reachable to finish setup), `:any` (at least one target of
    its group must be) or `:optional`. `/setup` lists an `:any` group as one checklist row: `:ok`
    once one target is reachable, `{:error, :none_reachable}` once every checked target failed,
    and not checked yet otherwise.
  - `dashboard`: `:always`, `:configured` (no row while it is not configured) or `:never`.
  - `names_adapter`: `true` where the operator picks the adapter in `/settings` (the download
    clients, the media server), so the dashboard row names the wired one. Every other target has
    one adapter, which its label already names.
  """

  @enforce_keys [:id, :group, :label, :probe]
  defstruct [
    :id,
    :group,
    :label,
    :probe,
    setup: :optional,
    dashboard: :always,
    names_adapter: false
  ]

  @type probe ::
          {:env, atom()}
          | {:download, atom()}
          | {:migration_source, atom()}
          | {:books_metadata, atom()}
          | {:library, atom()}
          | {:module, module()}
          | :subtitles

  @type t :: %__MODULE__{
          id: String.t(),
          group: atom(),
          label: String.t(),
          probe: probe(),
          setup: :required | :any | :optional,
          dashboard: :always | :configured | :never,
          names_adapter: boolean()
        }
end
