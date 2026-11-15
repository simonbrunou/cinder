defmodule Cinder.Catalog.AttentionBookCountsTest do
  # #773: `Attention.counts/0` tallies book targets by the fields `Books.Attention.classify/2`
  # reads, and `attention_count/0` (the Activity nav badge) adds the held ones.
  use Cinder.DataCase, async: false

  import Cinder.BooksFixtures
  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog.Attention
  alias Cinder.Repo

  defp seed_every_state do
    for {state, _} <- book_states(), kind <- [:ebook, :audiobook], do: book_target_in(state, kind)
  end

  # Every target classified in memory, from its own status and its own grab.
  defp in_memory_tally do
    Repo.all(BookTarget)
    |> Enum.reduce(%{active: 0, attention: 0, waiting: 0, idle: 0}, fn target, acc ->
      grab? = Repo.exists?(from g in BookGrab, where: g.book_target_id == ^target.id)
      Map.update!(acc, Books.Attention.classify(target, grab?).phase, &(&1 + 1))
    end)
  end

  test "counts/0's book entry agrees with classifying every book target" do
    seed_every_state()

    assert Attention.counts().book == in_memory_tally()
    # Each state twice: wanted, grabbing and replacing are active; available and paused idle.
    assert Attention.counts().book == %{active: 6, attention: 2, waiting: 0, idle: 4}
  end

  test "attention_count/0 adds held book targets and nothing else of theirs" do
    seed_every_state()

    assert Attention.attention_count() == 2
  end

  test "a target stops counting once it is no longer held" do
    held = book_target_in(:held, :ebook)
    assert Attention.attention_count() == 1

    {:ok, _retried} = Books.retry_target(held)
    assert Attention.attention_count() == 0
  end

  test "list_attention_targets/0 lists exactly the held targets, classified, works loaded" do
    [held | _] =
      targets =
      for state <- [:held, :wanted, :grabbing, :available, :replacing, :paused],
          do: book_target_in(state, :audiobook)

    second_held = book_target_in(:held, :ebook)
    assert length(targets) == 6

    listed = Books.list_attention_targets()

    assert listed |> Enum.map(fn {t, _} -> t.id end) |> Enum.sort() ==
             Enum.sort([held.id, second_held.id])

    for {target, attention} <- listed do
      assert %Attention{phase: :attention, reason: :held, actions: [:retry, :clear_blocklist]} =
               attention

      assert target.work.id == target.work_id
    end
  end
end
