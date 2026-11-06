defmodule CinderWeb.SignInRefusal do
  @moduledoc """
  The one warning line a refused Plex, Jellyfin or OIDC sign-in or link writes, so the next
  sign-in outage takes one log search to diagnose (#1206):

      plex_signin refused intent=login step=server_access plex_id=42 resources=3 reason=forbidden

  A controller wraps each step of its `with` chain in `at/2`, so a failure keeps the name of the
  step that refused it, builds the other refusals with `refusal/3`, and hands each one to
  `warn/3` before its flash and redirect.

  Every value goes through `render/1`, which prints no map and no struct body:

    * an `Ecto.Changeset` becomes `changeset:` and the names of its fields with errors;
    * any other struct, an exception included, becomes its module name. An exception's atom
      `reason`, or the struct in it, follows in parentheses, and so does the provider's error
      code of an `Assent.CallbackError` when it reads like one (lowercase letters and `_`). An
      exception's `message/1` is never called: Assent's
      `RequestError`, `InvalidResponseError` and `UnexpectedResponseError` put the whole HTTP
      response, tokens included, in it;
    * a plain map becomes `map` and a list `list`, whatever they hold;
    * a tuple renders each element by these rules;
    * a string prints only when it is one of Assent's error messages (`assent_messages/0`), as
      that message's fixed text with each value it interpolated shown as `<value>`
      ("The ID Token has expired", `Invalid issuer <value> in ID Token`). Any other string prints
      as `string`;
    * an atom or a number prints as `to_string/1` writes it.

  The result then goes through `Cinder.HTTPPolicy.sanitize_log/1`, which drops line breaks and
  keeps 500 bytes. A value holding a space, a `"` or a `=` is quoted, as logfmt quotes it.
  """

  require Logger

  alias Cinder.HTTPPolicy

  @typedoc "A refused step: its name, the reason it gave, and any extra fields to log."
  @type t :: {:refused, step :: atom(), reason :: term(), fields :: keyword()}

  @prefixes %{plex: "plex_signin", jellyfin: "jellyfin_signin", oidc: "oidc_signin"}

  @doc """
  Tags the result of the step named `step`. `{:ok, value}` passes through, `{:error, reason}`
  becomes a refusal at `step` with that reason, and any other value becomes a refusal whose
  reason is that value. So a `with` clause matching `{:ok, _}` on it hands its `else` only
  refusals.
  """
  @spec at(atom(), term()) :: {:ok, term()} | t()
  def at(_step, {:ok, _value} = ok), do: ok
  def at(step, {:error, reason}), do: refusal(step, reason)
  def at(step, other), do: refusal(step, other)

  @doc "A refusal at `step`, for a branch that refuses without calling anything."
  @spec refusal(atom(), term(), keyword()) :: t()
  def refusal(step, reason, fields \\ []), do: {:refused, step, reason, fields}

  @doc """
  Writes the warning line of `refusal` for `provider`: the provider's prefix, then `context`
  (`intent:`), `step=`, the refusal's own fields and last `reason=`.
  """
  @spec warn(:plex | :jellyfin | :oidc, t(), keyword()) :: :ok
  def warn(provider, {:refused, step, reason, fields}, context \\ []) do
    pairs = context ++ [step: step] ++ fields ++ [reason: reason]
    line = Enum.map_join(pairs, " ", fn {key, value} -> "#{key}=#{render(value)}" end)

    Logger.warning("#{Map.fetch!(@prefixes, provider)} refused #{line}")
  end

  @doc "Renders one field value by the rules in the moduledoc."
  @spec render(term()) :: String.t()
  def render(value) do
    value
    |> text()
    |> HTTPPolicy.sanitize_log()
    |> quote_value()
  end

  defp text(%Ecto.Changeset{} = changeset) do
    fields = changeset |> Ecto.Changeset.traverse_errors(& &1) |> Map.keys() |> Enum.sort()
    "changeset:" <> Enum.map_join(fields, ",", &to_string/1)
  end

  defp text(%module{} = struct), do: inspect(module) <> detail(struct)
  defp text(value) when is_map(value), do: "map"
  defp text(value) when is_list(value), do: "list"

  defp text(value) when is_tuple(value),
    do: "{" <> Enum.map_join(Tuple.to_list(value), ",", &text/1) <> "}"

  defp text(value) when is_binary(value) do
    if String.valid?(value),
      do: Enum.find_value(assent_messages(), "string", &assent_message(&1, value)),
      else: "string"
  end

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(value), do: inspect(value)

  @doc """
  The error messages Assent's OpenID flow returns as a bare string (`Assent.Strategy.OIDC`,
  `Assent.Strategy.OAuth2`, `Assent.JWTAdapter` and `Assent.JWTAdapter.AssentJWT`), each value it
  interpolates written as `<value>`. A string reason prints only as one of these, without the
  values: they come off the provider's ID token or token response (`Invalid issuer "<iss>"`), and
  a claim can hold anything, an email included. `CinderWeb.SignInRefusalTest` reads Assent's
  sources and fails on a message this list lacks.
  """
  def assent_messages do
    [
      "`<value>` not found in OpenID configuration",
      "Unsupported client authentication method: <value>",
      "Invalid client authentication method: <value>",
      "The `id_token` key not found in token params, only found these keys: <value>",
      "The ID Token is not a valid JWT",
      "Invalid Base64URL",
      ~s(No keys found for the `kid` value "<value>" provided in ID Token),
      "No keys found in `jwks_uri` provider configuration",
      "Multiple public keys found in provider configuration and no `kid` value in ID Token",
      "Missing `<value>` in ID Token claims",
      ~s(Invalid issuer "<value>" in ID Token),
      "`:client_id` not in audience <value> in ID Token",
      "Untrusted audience(s) <value> in ID Token",
      ~s(Invalid authorized party "<value>" in ID Token),
      ~s(Expected `alg` in ID Token to be "<value>", got "<value>"),
      "Invalid JWT signature for ID Token",
      "The ID Token has expired",
      "The ID Token was issued too long ago",
      "Invalid `nonce` included in ID Token",
      "`nonce` is not included in ID Token",
      "`nonce` included in ID Token but doesn't exist in session params",
      "`sub` in userinfo response not the same as in ID Token",
      "`sub` not in userinfo response",
      "Invalid `:auth_method` <value>",
      "Authorization with token type `<value>` not supported",
      "No `<value>` in token map",
      ~s(Failed to read "<value>", got; <value>),
      "Unsupported JWT alg <value> or invalid JWK",
      "Invalid SHA-2 algorithm bit size: <value>",
      "Invalid private key",
      "Private key should only have one entry",
      ~s(No "alg" found in header),
      "Unable to decode the JWK"
    ]
  end

  # `value` matches `template` when each `<value>` slot stands for any text. The match prints the
  # template's own text, the quotes around a slot dropped, so nothing the slots matched survives.
  defp assent_message(template, value) do
    pattern =
      template
      |> String.split("<value>")
      |> Enum.map_join("(?s:.*)", &Regex.escape/1)

    if Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z", "u"), value),
      do: String.replace(template, ~s("<value>"), "<value>")
  end

  # Only an atom, a struct (rendered by its module, so no body) or a provider error code: never a
  # free-text field such as `message`, `data` or `response`. The error code comes from the
  # callback's query string, which the visitor controls, so only the shape of an OAuth error code
  # (`access_denied`, `login_required`) prints.
  defp detail(%Assent.CallbackError{error: error}) when is_binary(error) do
    if String.match?(error, ~r/\A[a-z_]{1,64}\z/), do: "(" <> error <> ")", else: ""
  end

  defp detail(%{__exception__: true, reason: reason})
       when (is_atom(reason) and not is_nil(reason)) or is_struct(reason),
       do: "(" <> text(reason) <> ")"

  defp detail(_struct), do: ""

  defp quote_value(""), do: ~s("")

  defp quote_value(value) do
    if String.match?(value, ~r/[\s"=]/u), do: inspect(value), else: value
  end
end
