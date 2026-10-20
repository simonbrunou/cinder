defmodule Cinder.GuardedWrite do
  @moduledoc """
  The guarded status write: a compare-and-swap on one row of a lifecycle table (movies, episodes,
  book targets, requests), with one contract for every caller. Each table has one adapter that
  implements this behaviour, and one owner that calls `write/4` with it.

  `write/4` runs one `update_all ... where id == ^row.id and <expect>` with `RETURNING`. Each
  `expect` entry is `field` (the row's own value) or `{field, value}`, both nil-safe, or
  `{field, {:in, values}}`, which never matches nil. It writes every attr the caller names, even
  one the row already holds (the row may be stale everywhere it is not guarded), plus
  `updated_at`, and returns the fresh row.

    * **One stale shape.** A miss is `{:error, :stale_status}`. An owner may rename it at its own
      public boundary.
    * **Constraint translation.** `update_all` skips Ecto's `to_constraints`, so a trigger's
      `RAISE(ABORT, ...)` arrives as a raw `Exqlite.Error`, the same class as a transient busy.
      The adapter's `refusal/2` names the messages it knows; any other error re-raises.
    * **In-transaction safety.** A write never opens a transaction of its own. Inside a
      transaction it must run in `transaction/2` (in a raw `Repo.transaction` it raises). A
      refused write (stale, constraint or invalid changeset) dooms that frame: the caller may roll
      back with its own reason, which wins, and if it carries on anyway the frame rolls back with
      the write's refusal. SQLite's `RAISE(ABORT)` reverts only the statement and leaves the
      transaction open, so nothing can commit a transaction that holds a refused write.
    * **Publication after commit.** Callers never publish. Outside a transaction a write publishes
      right after its statement. Inside a frame, each adapter's `publish/1` runs once after the
      outermost commit, before `transaction/2` returns, with the latest row per id, adapters in
      first-write order. A rollback publishes nothing.
  """

  import Ecto.Query

  alias Cinder.Repo

  @doc "The row's changeset for `attrs`; an invalid one refuses the write before the database."
  @callback changeset(row :: struct(), attrs :: map()) :: Ecto.Changeset.t()

  @doc """
  The refusal a raw `Exqlite.Error` message means for this table, or nil to re-raise it. Match on
  the constraint's own name, never the exception class.
  """
  @callback refusal(message :: String.t(), attrs :: map()) :: atom() | nil

  @doc "Announces committed rows: the latest row per id, after commit, never inside a transaction."
  @callback publish(rows :: [struct()]) :: :ok

  @type expectation :: atom() | {atom(), term()} | {atom(), {:in, [term()]}}

  @frame {__MODULE__, :frame}

  @raw_transaction "a guarded write inside a transaction must run in " <>
                     "Cinder.GuardedWrite.transaction/2, which publishes it after commit; " <>
                     "this one is inside a raw Repo.transaction"

  @doc """
  Writes `attrs` to `row` through `adapter` if the row still holds every `expect`ed value.

  Returns `{:ok, fresh_row}`, `{:error, :stale_status}` on a miss, `{:error, refusal}` for a
  constraint the adapter names, or `{:error, changeset}` for invalid attrs.
  """
  @spec write(module(), struct(), map(), [expectation()]) ::
          {:ok, struct()} | {:error, :stale_status | atom() | Ecto.Changeset.t()}
  def write(adapter, %schema{} = row, attrs, expect \\ []) do
    framed? = framed?()
    changeset = adapter.changeset(row, attrs)

    result =
      if changeset.valid?,
        do: compare_and_swap(adapter, row, write_set(schema, changeset, attrs), expect, attrs),
        else: {:error, changeset}

    settle(framed?, adapter, result)
  end

  @doc """
  `Repo.transaction/2` for a body that makes guarded writes: the frame that publishes them after
  the outermost commit, and rolls back when one of them was refused. A nested call joins the
  outer frame. Raises inside a raw `Repo.transaction`, whose commit it cannot see.
  """
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []) when is_function(fun, 0) do
    if framed?(), do: Repo.transaction(fun, opts), else: outermost(fun, opts)
  end

  defp outermost(fun, opts) do
    Process.put(@frame, %{written: [], refused: nil})

    try do
      Repo.transaction(fn -> fun.() |> unless_refused() end, opts)
    else
      {:ok, _value} = committed ->
        @frame |> Process.delete() |> Map.fetch!(:written) |> flush()
        committed

      {:error, _reason} = rolled_back ->
        rolled_back
    after
      Process.delete(@frame)
    end
  end

  defp unless_refused(value) do
    case Process.get(@frame) do
      %{refused: nil} -> value
      %{refused: reason} -> Repo.rollback(reason)
    end
  end

  # True inside a frame, false outside any transaction; a raw transaction cannot publish after its
  # commit, so a guarded write or frame inside one is a bug.
  defp framed? do
    cond do
      Process.get(@frame) -> true
      Repo.in_transaction?() -> raise ArgumentError, @raw_transaction
      true -> false
    end
  end

  defp settle(false, adapter, {:ok, written} = ok) do
    adapter.publish([written])
    ok
  end

  defp settle(false, _adapter, {:error, _reason} = error), do: error

  defp settle(true, adapter, {:ok, written} = ok) do
    update_frame(&%{&1 | written: [{adapter, written} | &1.written]})
    ok
  end

  defp settle(true, _adapter, {:error, reason} = error) do
    update_frame(&%{&1 | refused: &1.refused || reason})
    error
  end

  defp update_frame(fun), do: Process.put(@frame, fun.(Process.get(@frame)))

  defp flush(written) do
    in_order = Enum.reverse(written)

    for adapter <- in_order |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      rows = for {^adapter, row} <- in_order, do: row
      rows |> Enum.reverse() |> Enum.uniq_by(& &1.id) |> Enum.reverse() |> adapter.publish()
    end

    :ok
  end

  defp write_set(schema, changeset, attrs) do
    attrs
    |> Map.new(fn {field, _value} -> {field, Ecto.Changeset.get_field(changeset, field)} end)
    |> Map.merge(changeset.changes)
    |> Map.merge(autoupdate(schema))
    |> Map.to_list()
  end

  # `updated_at` in the schema's own timestamp type, as `Repo.update/2` would write it.
  defp autoupdate(schema) do
    for {fields, {module, fun, args}} <- schema.__schema__(:autoupdate),
        value = apply(module, fun, args),
        field <- fields,
        into: %{},
        do: {field, value}
  end

  defp compare_and_swap(adapter, %schema{} = row, set, expect, attrs) do
    query =
      Enum.reduce(
        expect,
        from(r in schema, where: r.id == ^row.id, select: r),
        &expect(&2, row, &1)
      )

    case Repo.update_all(query, set: set) do
      {1, [written]} -> {:ok, written}
      {0, _none} -> {:error, :stale_status}
    end
  rescue
    error in Exqlite.Error ->
      case adapter.refusal(error.message, attrs) do
        nil -> reraise error, __STACKTRACE__
        reason -> {:error, reason}
      end
  end

  defp expect(query, row, field) when is_atom(field),
    do: expect(query, row, {field, Map.fetch!(row, field)})

  defp expect(query, _row, {field, {:in, values}}) when is_list(values),
    do: where(query, [r], field(r, ^field) in ^values)

  defp expect(query, _row, {field, nil}), do: where(query, [r], is_nil(field(r, ^field)))
  defp expect(query, _row, {field, value}), do: where(query, [r], field(r, ^field) == ^value)
end
