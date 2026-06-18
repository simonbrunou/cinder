defmodule Cinder.Library.MediaServer do
  @moduledoc """
  Behaviour for the media server (Jellyfin): trigger a library scan.

  Fleshed out in Phase 4.
  """

  @callback scan() :: :ok | {:error, term()}
end
