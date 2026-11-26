defmodule Cinder.NzbFixture do
  @moduledoc """
  NZB bodies for the tests of a download fetch, which `Cinder.Download.Client.DownloadCheck`
  hands to a client only once it reads as an NZB (#1658). `minimal/0` starts as the NZBs Cinder
  grabbed in production do: a UTF-8 XML declaration, then the NZB 1.1 document type
  declaration with its public and system identifiers.
  """

  @prolog ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" ) <>
            ~s("http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">\n)

  @doc "The XML declaration and the NZB 1.1 document type declaration `minimal/0` starts with."
  def prolog, do: @prolog

  @doc "A one-file NZB, as an indexer serves it."
  def minimal, do: @prolog <> document()

  @doc "`minimal/0`'s document after its prolog: the `nzb` root and its one file."
  def document(segments \\ "") do
    ~s(<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">\n) <>
      ~s(<head><meta type="name">Movie.2024.1080p.WEB-DL</meta></head>\n) <>
      ~s(<file poster="poster &lt;p@example.invalid&gt;" date="1765143878" ) <>
      ~s|subject="[1/1] - &quot;movie.mkv&quot; yEnc (1/1)">\n| <>
      ~s(<groups><group>alt.binaries.test</group></groups>\n) <>
      ~s(<segments><segment bytes="739980" number="1">part1@example.invalid</segment>) <>
      segments <> ~s(</segments>\n</file>\n</nzb>\n)
  end

  @doc """
  `minimal/0` padded to exactly `size` bytes with whitespace inside its `segments` element, so it
  still reads as an NZB.
  """
  def padded(size) do
    short = byte_size(minimal())
    if size < short, do: raise(ArgumentError, "an NZB of #{size} bytes is shorter than minimal/0")
    @prolog <> document(:binary.copy(" ", size - short))
  end
end
