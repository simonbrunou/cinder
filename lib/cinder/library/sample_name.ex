defmodule Cinder.Library.SampleName do
  @moduledoc """
  Owns the sample/preview name token that the movie, standard TV, season adoption and anime
  imports read (#125, #1452).

  `token?/1` reads only a path's basename. The token is `sample` or `preview` with a separator
  or the name's edge on each side, so "Sampler" holds no token. A separator is any whitespace,
  Unicode spaces such as U+00A0 and U+3000 included, or one of `.`, `_`, `-`, `[`, `]`, `(` and
  `)`. A basename that is not valid UTF-8 holds no token.

  The size rule that goes with the token stays beside each caller:
  `Cinder.Library.MovieSources.sample_name?/2` for the movie, standard TV and season adoption
  imports, and
  `AnimePreflight`'s own rule, which also weighs the file against its largest sibling.
  """

  @token ~r/(?:^|[\s._\-\[\]()])(?:sample|preview)(?:$|[\s._\-\[\]()])/iu

  @doc "Whether the basename of `path` holds the sample/preview token."
  @spec token?(Path.t()) :: boolean()
  def token?(path) do
    name = Path.basename(path)
    String.valid?(name) and Regex.match?(@token, name)
  end
end
