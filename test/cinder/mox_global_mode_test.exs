defmodule Cinder.MoxGlobalModeTest do
  @moduledoc """
  In global mode, another process's call to a mock the global owner never set up raises
  `Mox.UnexpectedCallError` in that process only. The owner's verification still runs and lists
  only its own unmet expectations. On CI (#1008), a subtitle fetch an earlier test left on the
  shared `Cinder.Subtitles.Fetcher` made such a call, and the next test failed in
  `verify_on_exit!` after its body passed.

  No case template here: none of them sets up every mock, so a test under any of them meets the
  same path as this one.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Catalog.TMDBMock
  alias Cinder.Library.FilesystemMock

  setup :set_mox_global
  setup :verify_on_exit!

  test "a stray call to a mock the owner never set up raises in the caller only" do
    expect(TMDBMock, :get_movie, fn 1 -> {:ok, %{}} end)

    assert %Mox.UnexpectedCallError{} = call_elsewhere(fn -> FilesystemMock.read("/stray") end)

    # Verification still runs, and lists only the owner's own unmet expectation.
    error = assert_raise Mox.VerificationError, fn -> verify!() end
    assert error.message =~ "Cinder.Catalog.TMDBMock.get_movie/1"
    refute error.message =~ "FilesystemMock"

    assert {:ok, %{}} = TMDBMock.get_movie(1)
    assert verify!() == :ok
  end

  # Runs `fun` in another process, and returns what it raised.
  defp call_elsewhere(fun) do
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         try do
           fun.()
           send(parent, :returned)
         rescue
           error -> send(parent, {:raised, error})
         end
       end}
    )

    assert_receive {:raised, error}
    error
  end
end
