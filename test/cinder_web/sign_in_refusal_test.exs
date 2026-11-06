defmodule CinderWeb.SignInRefusalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Assent.Strategy.OIDC
  alias CinderWeb.SignInRefusal

  describe "render/1" do
    test "a changeset becomes the sorted names of its fields with errors, never their values" do
      changeset =
        {%{}, %{email: :string, plex_id: :integer}}
        |> Ecto.Changeset.cast(%{email: "secret@example.com", plex_id: "x"}, [:email, :plex_id])
        |> Ecto.Changeset.add_error(:email, "has already been taken")

      assert SignInRefusal.render(changeset) == "changeset:email,plex_id"
    end

    test "a struct becomes its module name, whatever its fields hold" do
      response = %Req.Response{status: 500, body: %{"accessToken" => "secret-token-123"}}

      assert SignInRefusal.render(response) == "Req.Response"
    end

    test "an exception becomes its module name and never its message" do
      exception = RuntimeError.exception("secret-token-123")
      assert SignInRefusal.render(exception) == "RuntimeError"

      response = %Assent.HTTPAdapter.HTTPResponse{status: 400, body: "secret-token-123"}
      exception = %Assent.InvalidResponseError{response: response}
      assert SignInRefusal.render(exception) == "Assent.InvalidResponseError"
    end

    test "an exception's atom reason, or the struct in it, follows in parentheses" do
      assert SignInRefusal.render(%Req.TransportError{reason: :timeout}) ==
               "Req.TransportError(timeout)"

      exception = %Assent.ServerUnreachableError{
        request_url: "https://id.example.com/?token=secret-token-123",
        reason: %Req.TransportError{reason: :econnrefused}
      }

      assert SignInRefusal.render(exception) ==
               "Assent.ServerUnreachableError(Req.TransportError(econnrefused))"

      assert SignInRefusal.render(%Assent.ServerUnreachableError{reason: "secret-token-123"}) ==
               "Assent.ServerUnreachableError"
    end

    test "an Assent.CallbackError adds the provider's error code, not its description" do
      exception = %Assent.CallbackError{message: "secret description", error: "access_denied"}

      assert SignInRefusal.render(exception) == "Assent.CallbackError(access_denied)"

      # The code comes from the visitor's query string: anything else is left out.
      for code <- ["someone@example.com", "Access Denied", "", String.duplicate("a", 65)] do
        exception = %Assent.CallbackError{error: code}
        assert SignInRefusal.render(exception) == "Assent.CallbackError", inspect(code)
      end
    end

    test "a map and a list become placeholders, whatever they hold" do
      assert SignInRefusal.render(%{token: "secret-token-123"}) == "map"
      assert SignInRefusal.render([%{"accessToken" => "secret-token-123"}]) == "list"
      assert SignInRefusal.render([1 | 2]) == "list"
    end

    test "a tuple renders each element by the same rules" do
      assert SignInRefusal.render({:plex_tv_status, 401}) == "{plex_tv_status,401}"
      assert SignInRefusal.render({:unexpected_body, [%{"a" => 1}]}) == "{unexpected_body,list}"
    end

    test "atoms and numbers print as they are, quoted when they hold a space, \" or =" do
      assert SignInRefusal.render(:forbidden) == "forbidden"
      assert SignInRefusal.render(nil) == "nil"
      assert SignInRefusal.render(42) == "42"
      assert SignInRefusal.render(:"a b") == ~s("a b")
      assert SignInRefusal.render(:"a\"b") == ~s("a\\"b")
      assert SignInRefusal.render(:"a=b") == ~s("a=b")
      assert SignInRefusal.render(:"") == ~s("")
    end

    test "a string prints only as one of Assent's messages, whatever else it holds" do
      assert SignInRefusal.render("The ID Token has expired") == ~s("The ID Token has expired")

      assert SignInRefusal.render(~s(Invalid issuer "someone@example.com" in ID Token)) ==
               ~s("Invalid issuer <value> in ID Token")

      assert SignInRefusal.render(
               ~s(Expected `alg` in ID Token to be "RS256", got "someone@example.com")
             ) == ~s("Expected `alg` in ID Token to be <value>, got <value>")

      for other <- ["Invalid", "someone@example.com", "secret-token-123", "", ~s(a"b)] do
        assert SignInRefusal.render(other) == "string", inspect(other)
      end

      assert SignInRefusal.render({:rejected, "someone@example.com"}) == "{rejected,string}"
    end

    # The shapes a pattern-based redaction let through on #1214: a claim holding quote pairs, an
    # audience that inspect/1 writes as bytes, an apostrophe in an email. Each one, in every slot
    # of every message.
    test "no value in a slot of an Assent message reaches the line" do
      hostile = [
        "someone@example.com",
        ~s(https://idp" secret-claim-text "x),
        inspect([~s(a" hidden word), ~s(b")]),
        inspect(["pers\0on@example.com"]),
        "o'brien@example.com",
        "line\nbreak secret-claim-text"
      ]

      markers = ["someone", "example.com", "secret-claim-text", "hidden", "brien", "112, 101"]

      for template <- SignInRefusal.assent_messages(),
          String.contains?(template, "<value>"),
          value <- hostile do
        rendered = template |> String.replace("<value>", value) |> SignInRefusal.render()

        refute rendered == "string", "#{inspect(template)} with #{inspect(value)} unmatched"

        for marker <- markers do
          refute rendered =~ marker,
                 "#{inspect(template)} with #{inspect(value)} printed #{rendered}"
        end
      end
    end

    # Each `{:error, "..."}` Assent's OpenID flow can return, read off its sources, must be one
    # of `assent_messages/0`: a message Assent adds after an upgrade otherwise prints as `string`.
    test "assent_messages/0 holds every bare-string error of Assent's OpenID flow" do
      sources = [
        "deps/assent/lib/assent.ex",
        "deps/assent/lib/assent/strategy.ex",
        "deps/assent/lib/assent/strategies/oauth2.ex",
        "deps/assent/lib/assent/strategies/oidc.ex",
        "deps/assent/lib/assent/jwt_adapter.ex",
        "deps/assent/lib/assent/jwt_adapter/assent_jwt.ex"
      ]

      found = Enum.flat_map(sources, &error_strings/1)

      assert length(found) >= 30, "read only #{length(found)} messages: #{inspect(found)}"

      for message <- Enum.uniq(found) do
        assert message in SignInRefusal.assent_messages(), "missing: #{inspect(message)}"
      end
    end

    test "Assent's own invalid-issuer error keeps its text and loses the issuer it quotes" do
      claims = %{
        "iss" => "private-person@example.com",
        "sub" => "subject",
        "aud" => "cinder",
        "exp" => System.system_time(:second) + 3600,
        "iat" => System.system_time(:second)
      }

      {:ok, jwt} = Assent.JWTAdapter.sign(claims, "HS256", "client-secret", [])

      config = [
        client_id: "cinder",
        client_secret: "client-secret",
        id_token_signed_response_alg: "HS256",
        openid_configuration: %{"issuer" => "https://id.example.com"}
      ]

      assert {:error, reason} = OIDC.validate_id_token(config, jwt)
      assert reason =~ "private-person@example.com"

      assert SignInRefusal.render(reason) == ~s("Invalid issuer <value> in ID Token")
    end

    test "line breaks are dropped and a long value is cut to 500 bytes" do
      assert SignInRefusal.render(:"one\r\ntwo") == "onetwo"

      long = List.to_tuple(List.duplicate(:a, 300))
      assert byte_size(SignInRefusal.render(long)) == 500
    end

    test "a binary that is not UTF-8 prints as string, like any other unknown string" do
      assert SignInRefusal.render(<<0xFF, 0xFE>>) == "string"
    end

    test "other terms print as inspect/1 writes them" do
      assert SignInRefusal.render(self()) =~ "#PID<"
    end
  end

  describe "at/2" do
    test "passes {:ok, value} through and tags anything else with the step" do
      assert SignInRefusal.at(:account, {:ok, 1}) == {:ok, 1}
      assert SignInRefusal.at(:account, {:error, :nope}) == {:refused, :account, :nope, []}
      assert SignInRefusal.at(:account, :ok) == {:refused, :account, :ok, []}
      assert SignInRefusal.at(:account, :error) == {:refused, :account, :error, []}
    end
  end

  describe "warn/3" do
    test "writes the prefix, the context, the step, the fields and last the reason" do
      refusal = SignInRefusal.refusal(:server_access, :forbidden, plex_id: 7, resources: 3)

      log = capture_log(fn -> SignInRefusal.warn(:plex, refusal, intent: :login) end)

      assert log =~
               "[warning] plex_signin refused intent=login step=server_access plex_id=7 " <>
                 "resources=3 reason=forbidden\n"
    end

    test "names each provider by its own prefix" do
      refusal = SignInRefusal.refusal(:config, :not_configured)

      assert capture_log(fn -> SignInRefusal.warn(:jellyfin, refusal, intent: :link) end) =~
               "jellyfin_signin refused intent=link step=config reason=not_configured"

      assert capture_log(fn -> SignInRefusal.warn(:oidc, refusal) end) =~
               "oidc_signin refused step=config reason=not_configured"
    end
  end

  # Every `{:error, "..."}` in the Assent source at `relative`, each interpolation written as
  # `<value>`, read off the AST so a message split over lines or holding escapes still counts.
  defp error_strings(relative) do
    {_ast, found} =
      Mix.Project.deps_paths()
      |> Map.fetch!(:assent)
      |> Path.join(String.replace_prefix(relative, "deps/assent/", ""))
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:error, message} = node, acc when is_binary(message) -> {node, [message | acc]}
        {:error, {:<<>>, _meta, parts}} = node, acc -> {node, [template(parts) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  defp template(parts) do
    Enum.map_join(parts, fn
      part when is_binary(part) -> part
      _interpolation -> "<value>"
    end)
  end
end
