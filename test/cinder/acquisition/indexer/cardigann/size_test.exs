defmodule Cinder.Acquisition.Indexer.Cardigann.SizeTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.Size

  # Each expected value is worked by hand from Prowlarr's ParseUtil.GetBytes (b0b5774).
  test "reads the units Prowlarr reads, each a power of 1,024" do
    cases = [
      {"1.4 GiB", 1_503_238_553},
      {"700 MB", 734_003_200},
      {"700 MiB", 734_003_200},
      {"1.2 GB", 1_288_490_188},
      {"512 KiB", 524_288},
      {"512 kb", 524_288},
      {"2 TiB", 2_199_023_255_552},
      {"123", 123},
      {"123 B", 123},
      {"9.9 bytes", 9}
    ]

    for {text, bytes} <- cases, do: assert({text, Size.bytes(text)} == {text, bytes})
  end

  test "takes out a lowercase i only, so KIB is no unit Prowlarr knows" do
    assert Size.bytes("2 KIB") == 2
    assert Size.bytes("2 KiB") == 2048
  end

  test "reads a French unit it does not know as bytes" do
    assert Size.bytes("700 Mo") == 700
  end

  test "reads a comma as the decimal point, and only the last point as one" do
    assert Size.bytes("1,5 KB") == 1536
    assert Size.bytes("1.234.567") == 1234
    assert Size.bytes("1.000,5 KB") == 1_024_512
  end

  test "reads no digit or a lone point as nothing, never 0" do
    assert Size.bytes("n/a") == nil
    assert Size.bytes("") == nil
    assert Size.bytes(".") == nil
  end

  test "answers nothing past a signed 64-bit integer, however long the number" do
    assert Size.bytes("9000000 TB") == nil
    assert Size.bytes("8000000 TB") == 8_796_093_022_208_000_000
    assert Size.bytes(String.duplicate("9", 300) <> " TB") == nil
    assert Size.bytes(String.duplicate("9", 400)) == nil
    # Leading zeros and a long fraction are no long number.
    assert Size.bytes(String.duplicate("0", 400) <> "1 KB") == 1024
    assert Size.bytes("1." <> String.duplicate("0", 400) <> " KB") == 1024
  end
end
