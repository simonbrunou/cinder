defmodule Cinder.Books.BookTargetTransition do
  @moduledoc false
  # The `book_targets` adapter of `Cinder.GuardedWrite`. Only `Cinder.Books.transition_target/3`
  # names it; `Cinder.Books.Files` and `Cinder.Books.Adoption` write through that.
  @behaviour Cinder.GuardedWrite

  alias Cinder.Books
  alias Cinder.Books.BookTarget

  @impl true
  def changeset(target, attrs), do: BookTarget.transition_changeset(target, attrs)

  # `Books.monitor_target/3` checks the profile's kind up front; the trigger is the fence behind it
  # for a caller that skips that check or races a re-kind.
  @impl true
  def refusal(message, _attrs) do
    if message =~ "book_targets_profile_integrity", do: :invalid_media_profile
  end

  @impl true
  def publish(targets), do: Enum.each(targets, &Books.broadcast({:book_target_updated, &1}))
end
