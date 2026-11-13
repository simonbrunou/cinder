defmodule Cinder.Catalog.GrabTransition do
  @moduledoc false
  # The `grabs` adapter of `Cinder.GuardedWrite`: a TV grab's verification and mapping holds, and
  # the claims that guard its import, its residual-file decisions and its deletion. Only
  # `Cinder.Catalog.Grabs` names it.
  @behaviour Cinder.GuardedWrite

  alias Cinder.Catalog.{Grab, Grabs}

  @impl true
  def changeset(grab, attrs), do: Grab.transition_changeset(grab, attrs)

  # No trigger guards a grab row; a CHECK violation is a bug and re-raises.
  @impl true
  def refusal(_message, _attrs), do: nil

  # One `{:series_updated, id}` per series that owns one of the grabs' episodes. A claim publishes
  # nothing (`Cinder.GuardedWrite`), so a frame that claims a grab and writes its episodes is
  # announced once, by the episode writes or by `Grabs` after commit.
  @impl true
  def publish(grabs), do: Grabs.announce(grabs)
end
