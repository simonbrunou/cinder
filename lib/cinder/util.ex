defmodule Cinder.Util do
  @moduledoc "Tiny cross-context helpers with no single natural context home."

  @doc """
  Trims a string and treats a blank result as absent (`nil`). Any non-string value (including
  `nil`) passes through unchanged.
  """
  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def blank_to_nil(value), do: value
end
