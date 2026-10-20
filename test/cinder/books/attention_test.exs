defmodule Cinder.Books.AttentionTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.EbookRelease
  alias Cinder.Books
  alias Cinder.Books.{Attention, BookGrab, BookTarget}
  alias Cinder.Download

  setup :set_mox_global
  setup :verify_on_exit!

  # {state, target status, a grab in progress?, phase, reason, offered actions}
  @states [
    {:wanted, :monitored, false, :active, nil, [:manual_search, :pause]},
    {:grabbing, :monitored, true, :active, nil, []},
    {:available, :available, false, :idle, nil, [:replace]},
    {:replacing, :available, true, :active, nil, []},
    {:held, :held, false, :attention, :held, [:retry, :clear_blocklist]},
    {:paused, :unmonitored, false, :idle, nil, [:resume]}
  ]

  describe "classify/2" do
    for {name, status, grab?, phase, reason, actions} <- @states do
      test "#{name}: #{phase}, offers #{inspect(actions)}" do
        assert %Cinder.Catalog.Attention{
                 phase: unquote(phase),
                 reason: unquote(reason),
                 actions: unquote(actions)
               } = Attention.classify(%BookTarget{status: unquote(status)}, unquote(grab?))
      end
    end

    test "every target status is classified" do
      covered = @states |> Enum.map(fn {_, status, _, _, _, _} -> status end) |> Enum.uniq()
      assert Enum.sort(covered) == Enum.sort(Ecto.Enum.values(BookTarget, :status))
    end
  end

  # Each operator action and the refusal it returns for a target that does not offer it.
  # `:manual_search` and `:replace` are both `Download.grab_book_target/3`, told which one by its
  # `replace:` flag; its in-transaction submission check refuses before any client call.
  defp run(:retry, target), do: Books.retry_target(target)

  defp run(:clear_blocklist, target),
    do: with(:ok <- Books.clear_blocklist(target), do: {:ok, target})

  defp run(:pause, target), do: Books.pause_target(target)
  defp run(:resume, target), do: Books.resume_target(target)
  defp run(:manual_search, target), do: Download.grab_book_target(target, release())
  defp run(:replace, target), do: Download.grab_book_target(target, release(), replace: true)

  # A grab is refused as busy only while another grab holds a target that would otherwise offer
  # it; any other target moved on.
  defp refusal(:clear_blocklist, _state), do: :not_held
  defp refusal(:pause, :grabbing), do: :grab_in_progress
  defp refusal(:manual_search, :grabbing), do: :download_intent_busy
  defp refusal(:replace, :replacing), do: :download_intent_busy
  defp refusal(grab, _state) when grab in [:manual_search, :replace], do: :stale_target
  defp refusal(_action, _state), do: :stale_status

  describe "every offered action succeeds and every other action is refused" do
    setup do
      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-new"} end)
      :ok
    end

    for {name, status, grab?, _phase, _reason, _actions} <- @states,
        action <- [:retry, :clear_blocklist, :pause, :resume, :manual_search, :replace] do
      test "#{name} × #{action}" do
        target = seed(unquote(status), unquote(grab?))
        action = unquote(action)
        grab? = unquote(grab?)

        if Attention.offers?(target, grab?, action) do
          assert {:ok, _} = run(action, target)
        else
          assert run(action, target) == {:error, refusal(action, unquote(name))}
          assert Repo.get!(BookTarget, target.id) == target
        end
      end
    end
  end

  defp seed(status, grab?) do
    target = monitored_target()

    target =
      case status do
        :monitored -> target
        :available -> available(target)
        :held -> held(target)
        :unmonitored -> elem(Books.pause_target(target), 1)
      end

    if grab?, do: {:ok, %BookGrab{}} = Books.Grabs.create(target.id, "remote-1", :torrent, "R")
    Repo.get!(BookTarget, target.id)
  end

  defp available(target) do
    {:ok, _file} =
      Books.Files.record_import(target, %{
        path: "/tmp/attention-#{target.id}.epub",
        size: 1000,
        format: :epub
      })

    Books.get_target(target.id)
  end

  defp held(target) do
    {:ok, held} = Books.hold_target(target, :download_failed, "Dead Release", true)
    held
  end

  defp release do
    %EbookRelease{
      title: "Le Guin - The Dispossessed (EPUB)",
      download_url: "magnet:?xt=urn:btih:abc",
      protocol: :torrent,
      formats: [:epub]
    }
  end

  defp monitored_target do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{
        name: "Ebooks #{id}",
        kind: :ebook,
        handling: :standard,
        library_path: "/tmp/cinder-books-#{id}"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    target
  end
end
