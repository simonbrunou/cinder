defmodule Cinder.Download.ClientTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Download.ClientMock

  setup :verify_on_exit!

  test "the behaviour exposes remove/2 — Mox mocks can expect it" do
    expect(ClientMock, :remove, fn "abc", opts ->
      assert Keyword.get(opts, :delete_files, true) == true
      :ok
    end)

    assert :ok = ClientMock.remove("abc", [])
  end
end
