defmodule Cinder.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Cinder.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Cinder.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Cinder.DataCase
    end
  end

  setup tags do
    Cinder.DataCase.setup_sandbox(tags)

    # NimbleOwnership (Mox's backing ownership server) only resets global mode back to
    # `:private` via an async `:DOWN` handler fired when the previous global-mode test's
    # process exits (deps/nimble_ownership/lib/nimble_ownership.ex:568-569) — never via
    # anything ExUnit's `on_exit` awaits. That leaves a real window, right after such a test
    # finishes, where the ownership server still reports itself `{:shared, <dead pid>}`. If the
    # very next test lands here before that `:DOWN` is processed, `Mox.stub/3` below raises
    # "Mox is in global mode" for a process that no longer exists. Force private mode
    # synchronously first: a `set_mox_global` test's own later `setup :set_mox_global` still
    # re-enables shared mode for itself right after this runs, so this only removes stale state
    # inherited from a previous test, never a test's own global mode.
    Mox.set_mox_private()

    for client <- [Cinder.Download.ClientMock, Cinder.Download.SabnzbdClientMock] do
      Mox.stub(client, :find_by_operation_key, fn _key -> :not_found end)
    end

    # Issue #588: `Cinder.Library.StageEngine` now calls `backing_identity/1` on every candidate
    # (and, for a replace, backup) placement — not just on a rollback — so any test staging a
    # file through the real `Cinder.Library.FilesystemMock` needs this stubbed or it raises
    # `Mox.UnexpectedCallError` regardless of whether the test cares about backing identity at
    # all. `{:error, :outside_roots}` is the real, common answer for a mocked path (`Disk`'s own
    # default for anything under no configured root) and every caller already treats an error
    # here as "no evidence" — a plain `stub`, so any test asserting its own backing-identity
    # behavior (see `Cinder.Test.BarrierFilesystem`, used instead of this Mox for that) can still
    # override it.
    Mox.stub(Cinder.Library.FilesystemMock, :backing_identity, fn _path ->
      {:error, :outside_roots}
    end)

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags, and drains the shared `Cinder.Subtitles.Fetcher`
  when the test ends.

  Raises before any checkout when `check_timeout_tag!/1` refuses the tags.

  Every committed import queues a subtitle fetch on the Fetcher, and most tests that commit never
  wait for it. Left queued, the fetch ran inside a later test, which could have turned subtitle
  languages on and stubbed the mocks it calls (#685, #1028). The drain is registered after the
  checkout, and ExUnit runs `on_exit` callbacks last-registered first, so it runs before the
  sandbox owner stops and a draining fetch can still read the database. The test's Mox stubs are
  gone by then, so a test whose fetch calls a mock still awaits it in its own body
  (docs/agents/testing.md).
  """
  def setup_sandbox(tags) do
    check_timeout_tag!(tags)
    checkout_sandbox(tags)
    on_exit(&Cinder.LibraryStubs.await_subtitle_tasks/0)
  end

  defp checkout_sandbox(%{unboxed: true}) do
    :ok = Sandbox.checkout(Cinder.Repo, sandbox: false)
  end

  defp checkout_sandbox(tags) do
    pid = Sandbox.start_owner!(Cinder.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Raises `ArgumentError` when an async test's `timeout` tag exceeds 2 x `Cinder.Repo`'s
  `queue_target`, and returns `:ok` otherwise.

  An async test's checkout queues for the test pool's one connection, and DBConnection drops a
  request that has queued past 2 x `queue_target`. A longer `timeout` tag would let ExUnit run
  the test past that drop, so its checkout could still fail on `queue_timeout` (#947, #1021).
  Sync modules run after the async phase and never queue, so their tags pass.
  """
  def check_timeout_tag!(%{async: true, timeout: timeout}) do
    queue_target = Keyword.fetch!(Application.fetch_env!(:cinder, Cinder.Repo), :queue_target)
    bound = 2 * queue_target

    unless is_integer(timeout) and timeout <= bound do
      raise ArgumentError,
            "async test tagged timeout: #{inspect(timeout)} exceeds 2 x Cinder.Repo's " <>
              "queue_target (#{queue_target} ms), so DBConnection can drop its sandbox " <>
              "checkout on queue_timeout at #{bound} ms, before ExUnit's timeout. Tag " <>
              "timeout: #{bound} or less, or use async: false: sync modules run after the " <>
              "async phase and never queue for the connection."
    end

    :ok
  end

  def check_timeout_tag!(_tags), do: :ok

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(admin, %{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
