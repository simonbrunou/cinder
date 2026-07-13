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
    on_exit(fn -> Sandbox.checkin(Cinder.Repo) end)
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
