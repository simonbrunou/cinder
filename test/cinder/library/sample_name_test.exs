defmodule Cinder.Library.SampleNameTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.SampleName

  test "a sample or preview token delimited by an ASCII separator counts" do
    assert SampleName.token?("/dl/Show - 01 sample.mkv")
    assert SampleName.token?("/dl/abc123.Preview.mkv")
    assert SampleName.token?("/dl/[Grp] Show (sample).mkv")
  end

  test "a Unicode space delimits the token (#1452)" do
    assert SampleName.token?("/dl/Show\u{a0}sample.mkv")
    assert SampleName.token?("/dl/[Grp] Show\u{3000}sample.mkv")
    assert SampleName.token?("/dl/Show\u{a0}preview\u{3000}1080p.mkv")
  end

  test "a token inside a word does not count" do
    refute SampleName.token?("/dl/Frieren.Sampler.mkv")
    refute SampleName.token?("/dl/Show.S01E01.mkv")
  end

  test "only the basename is read" do
    refute SampleName.token?("/dl/Sample/Show.S01E01.mkv")
    assert SampleName.token?("/dl/" <> <<255>> <> "/Show.sample.mkv")
  end

  test "a basename that is not valid UTF-8 answers false without raising (#1452)" do
    refute SampleName.token?("/dl/" <> <<255>> <> ".sample.mkv")
  end
end
