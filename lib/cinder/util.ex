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

  @doc """
  Trims a string and returns the trimmed value, or `nil` when blank. Non-string values
  (including `nil`) are `nil`. Use `blank_to_nil/1` when the original spacing must survive.
  """
  def trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def trim_to_nil(_value), do: nil

  @doc "True when the value is a non-blank string."
  def present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Integers greater than zero pass through; anything else is `nil`."
  def positive_integer(value) when is_integer(value) and value > 0, do: value
  def positive_integer(_value), do: nil

  @doc """
  Runs `fun` on the value of an `{:ok, value}` result for its side effects and returns the
  result unchanged. Any other term passes through untouched.
  """
  def tap_ok({:ok, value} = res, fun) do
    fun.(value)
    res
  end

  def tap_ok(other, _fun), do: other
end
