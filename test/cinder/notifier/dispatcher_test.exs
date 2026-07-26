defmodule Cinder.Notifier.DispatcherTest do
  # async: false — the isolation test mutates Discord's Application env, and both tests
  # need Logger bumped to :info (the suite default is :warning) to see Log's output.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Notifier.Dispatcher

  setup do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    :ok
  end

  defp movie, do: %{tmdb_id: 1, title: "Dune", year: 2021, poster_path: nil}

  test "fans an event out to every transport (Log always fires)" do
    log =
      capture_log(fn ->
        assert :ok = Dispatcher.notify({:movie_available, movie()})
      end)

    assert log =~ "[notifier]"
    assert log =~ "Dune"
  end

  test "a raising transport is isolated — the rest still run" do
    original = Application.get_env(:cinder, Cinder.Notifier.Discord)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)

    # Not a keyword list: Discord.notify/1's Keyword.get raises a FunctionClauseError.
    # Proves isolate/2 catches it and Log (called first) still ran.
    Application.put_env(:cinder, Cinder.Notifier.Discord, :not_a_keyword_list)
    email = "kim@example.com"

    log =
      capture_log(fn ->
        assert :ok = Dispatcher.notify({:user_registered, %{id: 9, email: email}})
      end)

    assert log =~ "Cinder.Notifier.Discord notify failed for user_registered user #9"
    assert log =~ "[notifier]"
    refute log =~ email
  end
end
