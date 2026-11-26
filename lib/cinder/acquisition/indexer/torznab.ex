defmodule Cinder.Acquisition.Indexer.Torznab do
  @moduledoc """
  The Torznab adapter of `Cinder.Acquisition.Indexer` (#1652, #1653): Torznab is Newznab's API for
  torrents, and Prowlarr's `Torznab.cs` reuses Newznab's request generator, so this module
  delegates each function to `Cinder.Acquisition.Indexer.Newznab`, whose moduledoc gives the
  rules and whose `req_options` config it reads. The indexer's type picks what differs: a Torznab
  row is a torrent row, its link a torrent file or a magnet
  (`Cinder.Acquisition.Indexer.Newznab.Items`). Native's adapter map names this module for the
  `torznab` type.
  """
  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.Acquisition.Indexer.Newznab

  @impl true
  defdelegate search(indexer, query, context), to: Newznab

  defdelegate plan(indexer, query, context), to: Newznab

  @impl true
  defdelegate test(indexer, context, record), to: Newznab
  defdelegate request_options(indexer, params), to: Newznab
end
