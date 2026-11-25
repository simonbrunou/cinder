defmodule Cinder.Test.GitAdvertisement do
  @moduledoc """
  Builds git smart HTTP ref advertisements for the indexer definitions source tests: pkt-lines,
  each four lowercase hex digits giving its length, its own four included, then its payload.
  """

  @doc "One pkt-line holding `payload`."
  def pkt(payload) do
    length = (byte_size(payload) + 4) |> Integer.to_string(16) |> String.downcase()
    String.pad_leading(length, 4, "0") <> payload
  end

  @doc """
  An advertisement shaped as GitHub sends one: the service line and a flush, a pkt-line for each
  payload in `ref_lines`, then the closing flush.
  """
  def advertisement(ref_lines) do
    pkt("# service=git-upload-pack\n") <> "0000" <> Enum.map_join(ref_lines, &pkt/1) <> "0000"
  end
end
