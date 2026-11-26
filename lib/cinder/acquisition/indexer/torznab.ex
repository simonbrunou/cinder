defmodule Cinder.Acquisition.Indexer.Torznab do
  @moduledoc """
  The request half of the Torznab adapter (#1652): Torznab is Newznab's API for torrents, and
  Prowlarr's `Torznab.cs` reuses Newznab's request generator, so this module delegates each
  request function to `Cinder.Acquisition.Indexer.Newznab`, whose moduledoc gives the rules and
  whose `req_options` config it reads.
  """

  alias Cinder.Acquisition.Indexer.Newznab

  defdelegate plan(indexer, query, context), to: Newznab
  defdelegate refetch_caps(indexer, context), to: Newznab
  defdelegate request_options(indexer, params), to: Newznab
end
