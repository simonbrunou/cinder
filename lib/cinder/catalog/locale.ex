defmodule Cinder.Catalog.Locale do
  @moduledoc """
  Process-scoped locale used when calling TMDB.

  LiveViews set this before calling `Cinder.Catalog` functions so the same
  context code can fetch localized metadata without threading a locale argument
  through every layer. Defaults to `"en"`.
  """

  @default "en"

  @doc "Stores `locale` in the current process."
  def put(locale) when is_binary(locale), do: Process.put(__MODULE__, locale)

  @doc "Reads the stored locale, falling back to `#{@default}`."
  def get, do: Process.get(__MODULE__, @default)

  @doc "Runs `fun` with `locale` set, restoring the previous value afterwards."
  def with_locale(locale, fun) when is_function(fun, 0) do
    old = put(locale)

    try do
      fun.()
    after
      if old, do: put(old), else: Process.delete(__MODULE__)
    end
  end
end
