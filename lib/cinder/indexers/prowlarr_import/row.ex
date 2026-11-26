defmodule Cinder.Indexers.ProwlarrImport.Row do
  @moduledoc """
  One Prowlarr indexer in a Prowlarr import preview, as codes the dialog words (#1674).

    * `state`: `:direct` (a Newznab or Torznab indexer Cinder searches itself), `:via_prowlarr`
      (one that cannot go direct, offered unticked as a configured indexer at Prowlarr's
      `/<id>/api`), `:held` (a Cardigann indexer), `:already_imported` (linked to a configured
      indexer by an earlier import) or `:refused` (its settings fail the configured indexer's
      checks, or a through-Prowlarr row's protocol is `unknown`).
    * `reasons`: for `:via_prowlarr`, why it cannot go direct (`:implementation`, `:http_proxy`,
      `:socks_proxy`, `:flaresolverr`, `:other_proxy`, `:global_proxy`,
      `:additional_parameters` for a Torznab indexer that has some); for `:held`,
      `[:definitions_not_loaded]`; for `:refused`, each failed check as `{field, validation}`,
      such as `{:base_url, :base_url_userinfo}` or `{:settings, :credential_parameter}`, or
      `:protocol_unknown`; `[]` otherwise.
    * `type`: the configured indexer type it would be created as, `:newznab` or `:torznab`, or
      nil for a held, already imported or refused row.
    * `key`: for a direct row, `:masked` when Prowlarr answers a key that is not blank, which
      the admin types again, or `:none`; `:prowlarr` for a through-Prowlarr row, which gets the
      stored Prowlarr key at commit; nil otherwise.
    * `not_carried`: the Prowlarr settings set on it that the import does not carry:
      `:query_limit`, `:grab_limit`, `:query_timeout`, `:app_profile`, `:seed_settings`.
    * `tickable`: whether a commit can create it; `default_ticked`: whether the dialog ticks it
      first (direct rows only).

  `name`, `enabled` and `priority` are Prowlarr's. A refused row keeps no base URL, API path or
  setting, since a refused value can hold a credential (`https://u:p@...`, `&apikey=...`).
  `plan` is what a commit compares with Prowlarr's answer at that time.
  """

  @enforce_keys [:prowlarr_id, :name, :implementation, :protocol, :priority, :enabled, :state]
  defstruct [
    :prowlarr_id,
    :name,
    :implementation,
    :protocol,
    :priority,
    :enabled,
    :state,
    :type,
    :key,
    :plan,
    reasons: [],
    not_carried: [],
    tickable: false,
    default_ticked: false
  ]

  @type state :: :direct | :via_prowlarr | :held | :already_imported | :refused
  @type t :: %__MODULE__{}
end
