defmodule Cinder.Books.Attention do
  @moduledoc """
  Operator attention for a book target: the `Cinder.Catalog.Attention` classification, read from
  the target's status and whether a grab for it is in progress (a grab never changes
  `book_targets.status`, so the caller says).

  | Action | Operator function |
  |---|---|
  | `:retry` | `Books.retry_target/1` |
  | `:clear_blocklist` | `Books.clear_blocklist/1` |
  | `:pause` | `Books.pause_target/1` |
  | `:resume` | `Books.resume_target/1` |
  | `:manual_search` | `Download.grab_book_target/3` |
  | `:replace` | `Download.grab_book_target/3` with `replace: true` |

  `badge` is `nil`: a book's badge folds in its request (`CinderWeb.LiveHelpers.book_badge_state/2`).
  A held target needs attention on `/books/:id`; `/activity` does not list book targets, so the
  Activity nav badge does not count them.
  """

  alias Cinder.Books.BookTarget
  alias Cinder.Catalog.Attention

  @doc "Classifies `target`, given whether a grab for it is in progress."
  @spec classify(BookTarget.t(), boolean()) :: Attention.t()
  def classify(%BookTarget{status: :held}, _grab_in_progress?),
    do: %Attention{phase: :attention, reason: :held, actions: [:retry, :clear_blocklist]}

  def classify(%BookTarget{status: status}, true) when status in [:monitored, :available],
    do: %Attention{phase: :active}

  def classify(%BookTarget{status: :monitored}, false),
    do: %Attention{phase: :active, actions: [:manual_search, :pause]}

  def classify(%BookTarget{status: :available}, false),
    do: %Attention{phase: :idle, actions: [:replace]}

  def classify(%BookTarget{status: :unmonitored}, _grab_in_progress?),
    do: %Attention{phase: :idle, actions: [:resume]}

  @doc "True when `target` offers `action`, given whether a grab for it is in progress."
  @spec offers?(BookTarget.t(), boolean(), Attention.action()) :: boolean()
  def offers?(target, grab_in_progress?, action),
    do: action in classify(target, grab_in_progress?).actions
end
