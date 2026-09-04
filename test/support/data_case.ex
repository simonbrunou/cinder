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

  # Mox's own globally-registered ownership server name (`mox.ex`'s private `@this`), reused
  # deliberately here — see the comment in `setup/1` below.
  @mox_server {:global, Mox.Server}

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

    # NimbleOwnership has a second, unrelated sharp edge in global/shared mode:
    # `NimbleOwnership.fetch_owner/4` resolves EVERY key to the shared owner "regardless of the
    # callers" (nimble_ownership.ex:280-282, doc-confirmed by its `{:shared, pid} ->
    # {:shared_owner, pid}` clause) — even for a mock the shared owner never itself stubbed.
    #
    # If ANY process — this test's own code, a child it started, or (the actually-observed
    # trigger behind CI run 33860036897, seed 281650, `AudiobookIntentTest`) an orphaned,
    # unlinked `Phoenix.LiveView.start_async` Task left over from an earlier, already-finished
    # async test (e.g. `discover_live.ex`'s off-process TMDB rail fetches,
    # `maybe_load_rails/1`) — dispatches a call to such a never-touched mock while THIS test is
    # the shared/global owner, Mox's own `fetch_fun_to_dispatch/2` (mox.ex:972-993) calls
    # `NimbleOwnership.get_and_update/5`, gets `nil` back for that mock (nothing owned yet), and
    # — even though the call correctly raises `Mox.UnexpectedCallError` to the caller, exactly
    # as designed — NimbleOwnership's `get_and_update` handler (nimble_ownership.ex:489-491)
    # unconditionally persists that unchanged `nil` into `state.owners[owner_pid][mock]`. Later,
    # THIS test's own `verify_on_exit!` on_exit (mox.ex:814-822) enumerates every mock this
    # owner has ever touched, including that one, and `Enum.reduce(nil, ...)` raises
    # `Protocol.UndefinedError: protocol Enumerable not implemented for Atom ... Got value: nil`
    # — regardless of whether the test itself did anything wrong.
    #
    # Establishing an empty (but present) ownership entry for every project mock up front closes
    # this permanently: `fetch_fun_to_dispatch`'s `nil` branch only ever fires for a MISSING
    # mock-level entry, never for a present-but-empty one, so once initialized here it can never
    # regress back to `nil`. This changes nothing about per-function dispatch — an
    # unstubbed/unexpected call still raises `Mox.UnexpectedCallError` exactly as before; only
    # the otherwise-invisible presence of the top-level map entry changes.
    #
    # The mock list itself is derived once, in test/test_helper.exs, from
    # `function_exported?(mod, :__mock_for__, 0)` — the same authoritative test Mox uses
    # internally to recognize a mock module — and stashed in `:persistent_term` there, so it can
    # never silently drift out of sync with the project's `Mox.defmock/2` calls the way a
    # hand-maintained list here could.
    for mock <- :persistent_term.get({Cinder.DataCase, :mox_mocks}) do
      NimbleOwnership.get_and_update(
        @mox_server,
        self(),
        mock,
        fn existing -> {:ok, existing || %{}} end,
        30_000
      )
    end

    for client <- [Cinder.Download.ClientMock, Cinder.Download.SabnzbdClientMock] do
      Mox.stub(client, :find_by_operation_key, fn _key -> :not_found end)
    end

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(%{unboxed: true}) do
    :ok = Sandbox.checkout(Cinder.Repo, sandbox: false)
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Cinder.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

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
