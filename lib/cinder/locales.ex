defmodule Cinder.Locales do
  @moduledoc "Locales supported by Cinder and their canonical storage locale."

  def supported, do: ~w(en fr)
  def canonical, do: "en"
  def noncanonical, do: ["fr"]
end
