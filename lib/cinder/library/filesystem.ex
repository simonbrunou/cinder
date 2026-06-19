defmodule Cinder.Library.Filesystem do
  @moduledoc """
  Thin filesystem primitives behind a behaviour so the import is testable
  without touching disk. The "pick the right video file" policy lives in
  `Cinder.Library`, not here.
  """

  @callback dir?(path :: String.t()) :: boolean()
  @callback find_files(dir :: String.t()) ::
              {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  @callback mkdir_p(dir :: String.t()) :: :ok | {:error, term()}
  @callback ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
end
