defmodule Cinder.Acquisition.Indexer.Newznab.XML.RootHandler do
  @moduledoc false
  # The Saxy handler of `Cinder.Acquisition.Indexer.Newznab.XML.root/1`: it halts on the first
  # start tag with that element's name, so Saxy reads nothing after it.

  @behaviour Saxy.Handler

  @impl true
  def handle_event(:start_element, {name, _attributes}, nil), do: {:halt, name}
  def handle_event(_event, _data, state), do: {:ok, state}
end
