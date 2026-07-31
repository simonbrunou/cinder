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

  test "a raising webhook transport is isolated — the rest still run" do
    original = Application.get_env(:cinder, Cinder.Notifier.Webhook)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Webhook, original) end)

    # Same shape as the Discord case above: Webhook.notify/1's Keyword.get raises, proving the
    # fourth transport inherits isolate/2 rather than skipping Log/Discord/Email.
    Application.put_env(:cinder, Cinder.Notifier.Webhook, :not_a_keyword_list)

    log =
      capture_log(fn ->
        assert :ok = Dispatcher.notify({:movie_available, movie()})
      end)

    assert log =~ "Cinder.Notifier.Webhook notify failed for movie_available"
    assert log =~ "[notifier]"
    assert log =~ "Dune"
  end

  describe "async dispatch (the prod/dev default)" do
    setup do
      Application.put_env(:cinder, :notifier_dispatch, :async)
      on_exit(fn -> Application.put_env(:cinder, :notifier_dispatch, :sync) end)
      :ok
    end

    test "delivers off the caller's process and still reaches every transport" do
      log =
        capture_log(fn ->
          assert :ok = Dispatcher.notify({:movie_available, movie()})
          drain_notifier_tasks()
        end)

      assert log =~ "[notifier]"
      assert log =~ "Dune"
    end

    test "a raising transport is isolated even off-process — the rest still run" do
      original = Application.get_env(:cinder, Cinder.Notifier.Discord)
      on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)
      Application.put_env(:cinder, Cinder.Notifier.Discord, :not_a_keyword_list)

      log =
        capture_log(fn ->
          assert :ok = Dispatcher.notify({:user_registered, %{id: 9}})
          drain_notifier_tasks()
        end)

      assert log =~ "Cinder.Notifier.Discord notify failed for user_registered user #9"
      assert log =~ "[notifier]"
    end
  end

  # Waits for the spawned delivery tasks to finish so capture_log sees their output. Bounded so a
  # genuine leak fails the test rather than hangs it.
  defp drain_notifier_tasks(retries \\ 400) do
    case Task.Supervisor.children(Cinder.Notifier.TaskSupervisor) do
      [] -> :ok
      _ when retries > 0 -> Process.sleep(5) && drain_notifier_tasks(retries - 1)
      _ -> :ok
    end
  end
end
