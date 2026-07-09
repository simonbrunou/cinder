defmodule Cinder.Subtitles.Moviehash do
  @moduledoc """
  The OpenSubtitles OSDb moviehash: `filesize + Σ(u64 little-endian words of the first 64 KiB) +
  Σ(same of the last 64 KiB)`, taken mod 2^64 and rendered as 16-char lowercase hex. Sent as the
  `moviehash` search param so OpenSubtitles can return subtitles synced to this exact rip.

  `compute/3` is pure (tested with vectors). `of_file/1` reads size + the two 64 KiB chunks
  through the `Cinder.Library.Filesystem` behaviour, so tests use the Mox mock and never touch
  disk. A file smaller than 128 KiB (never a real movie) is `:too_small`.
  """

  import Bitwise

  @u64 0xFFFF_FFFF_FFFF_FFFF

  @doc "Pure OSDb hash of a file's `size` and its 65536-byte `head`/`tail` chunks."
  @spec compute(non_neg_integer(), binary(), binary()) :: String.t()
  def compute(size, head, tail) do
    (size + sum_words(head) + sum_words(tail))
    |> band(@u64)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  @doc "Hash of the file at `path`, or `:too_small` / `{:error, _}` (best-effort — never raises for the caller to handle)."
  @spec of_file(String.t()) :: {:ok, String.t()} | :too_small | {:error, term()}
  def of_file(path) do
    case fs().moviehash_data(path) do
      {:ok, {size, head, tail}} -> {:ok, compute(size, head, tail)}
      other -> other
    end
  end

  defp sum_words(bin) do
    for <<word::little-unsigned-64 <- bin>>, reduce: 0 do
      acc -> acc + word
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
