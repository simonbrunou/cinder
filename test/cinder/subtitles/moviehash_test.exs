defmodule Cinder.Subtitles.MoviehashTest do
  use ExUnit.Case, async: true

  import Mox
  setup :verify_on_exit!

  alias Cinder.Subtitles.Moviehash

  @chunk_bits 65_536 * 8

  test "compute/3: all-zero bytes => hash equals the file size (16-hex, zero-padded)" do
    zeros = <<0::size(@chunk_bits)>>
    # 131_072 = 0x20000
    assert Moviehash.compute(131_072, zeros, zeros) == "0000000000020000"
  end

  test "compute/3: sums little-endian u64 words of head and tail with the size" do
    # one word = 1 in the head, everything else zero, size 0 => total 1
    head = <<1::little-unsigned-64, 0::size(@chunk_bits - 64)>>
    tail = <<0::size(@chunk_bits)>>
    assert Moviehash.compute(0, head, tail) == "0000000000000001"
  end

  test "compute/3: wraps at 2^64 (a max u64 word + size 1 overflows to 0)" do
    head = <<0xFFFFFFFFFFFFFFFF::little-unsigned-64, 0::size(@chunk_bits - 64)>>
    tail = <<0::size(@chunk_bits)>>
    assert Moviehash.compute(1, head, tail) == "0000000000000000"
  end

  test "of_file/1: hashes {size, head, tail} from the filesystem" do
    zeros = <<0::size(@chunk_bits)>>

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn "/lib/M/M.mkv" ->
      {:ok, {131_072, zeros, zeros}}
    end)

    assert Moviehash.of_file("/lib/M/M.mkv") == {:ok, "0000000000020000"}
  end

  test "of_file/1: passes :too_small and {:error, _} straight through" do
    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    assert Moviehash.of_file("/lib/small.mkv") == :too_small

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> {:error, :enoent} end)
    assert Moviehash.of_file("/lib/gone.mkv") == {:error, :enoent}
  end
end
