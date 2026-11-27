defmodule Cinder.Indexers.ParityRun.Budget do
  @moduledoc """
  The per-indexer request allowance of one parity run (`Cinder.Indexers.ParityRun`, #1624 point
  7): at most `limit` requests to each configured indexer over the whole run, both sources,
  retries and link checks counted. An `:atomics` array any process can reach, since Native sends
  each indexer's requests from a search process of its own.

  `take/2` spends one request of an indexer's allowance; `take/3` spends several at once, or none
  when fewer are left. A refusal marks the indexer as refused, and `refused/1` lists every such
  indexer, so the run can stop it for the rest of the run. An id the budget was not built with is
  refused.
  """

  defstruct [:spent, :refused, :slots, :limit]

  @type t :: %__MODULE__{
          spent: :atomics.atomics_ref(),
          refused: :atomics.atomics_ref(),
          slots: %{pos_integer() => pos_integer()},
          limit: non_neg_integer()
        }

  @doc "A budget of `limit` requests for each of `ids`."
  @spec new([pos_integer()], non_neg_integer()) :: t()
  def new(ids, limit) when is_integer(limit) and limit >= 0 do
    ids = Enum.uniq(ids)
    size = max(length(ids), 1)

    %__MODULE__{
      spent: :atomics.new(size, signed: true),
      refused: :atomics.new(size, signed: false),
      slots: ids |> Enum.with_index(1) |> Map.new(),
      limit: limit
    }
  end

  @doc "Spends one request of `id`'s allowance: `:ok`, or `:refused` with none left."
  @spec take(t(), pos_integer()) :: :ok | :refused
  def take(budget, id), do: take(budget, id, 1)

  @doc "Spends `count` requests of `id`'s allowance at once: `:ok`, or `:refused` and none spent."
  @spec take(t(), pos_integer(), pos_integer()) :: :ok | :refused
  def take(%__MODULE__{} = budget, id, count) when is_integer(count) and count > 0 do
    case Map.fetch(budget.slots, id) do
      {:ok, slot} ->
        if :atomics.add_get(budget.spent, slot, count) <= budget.limit do
          :ok
        else
          :atomics.sub(budget.spent, slot, count)
          refuse(budget, slot)
        end

      :error ->
        :refused
    end
  end

  defp refuse(budget, slot) do
    :atomics.put(budget.refused, slot, 1)
    :refused
  end

  @doc "The requests `id` has left."
  @spec left(t(), pos_integer()) :: non_neg_integer()
  def left(%__MODULE__{} = budget, id) do
    case Map.fetch(budget.slots, id) do
      {:ok, slot} -> max(budget.limit - :atomics.get(budget.spent, slot), 0)
      :error -> 0
    end
  end

  @doc "The requests spent on `id` so far."
  @spec spent(t(), pos_integer()) :: non_neg_integer()
  def spent(%__MODULE__{} = budget, id) do
    case Map.fetch(budget.slots, id) do
      {:ok, slot} -> :atomics.get(budget.spent, slot)
      :error -> 0
    end
  end

  @doc "Every id whose allowance refused a request, sorted."
  @spec refused(t()) :: [pos_integer()]
  def refused(%__MODULE__{} = budget) do
    budget.slots
    |> Enum.filter(fn {_id, slot} -> :atomics.get(budget.refused, slot) == 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
