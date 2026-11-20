defmodule CinderWeb.UserLive.SettingsPasskeysTest do
  # async: false: tests turn the IP limiter on and raise the logger level, both global.
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.ConfigCase, only: [put_env: 2]
  import Cinder.Test.PasskeyHelpers
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Cinder.Accounts.IpRateLimiter
  alias Cinder.Accounts.Passkeys
  alias Cinder.Accounts.Scope
  alias Cinder.Accounts.UserPasskey
  alias Cinder.Repo
  alias Cinder.Test.SoftAuthenticator
  alias CinderWeb.UserLive.Settings

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp stale_socket(user) do
    stale_user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(), -11, :minute)}

    %Phoenix.LiveView.Socket{
      endpoint: CinderWeb.Endpoint,
      assigns: %{current_scope: Scope.for_user(stale_user), flash: %{}, __changed__: %{}}
    }
  end

  # Runs the page's two registration events the way the PasskeyRegister hook does.
  defp add_passkey(view, name, auth \\ SoftAuthenticator.new()) do
    render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => name}})
    assert_reply(view, %{ok: true, handle: handle, publicKey: options})
    challenge = Base.url_decode64!(options.challenge, padding: false)
    response = SoftAuthenticator.attest(auth, challenge, rp().id, rp().origin)

    render_hook(view, "passkey_register", %{
      "passkey" => %{"handle" => handle, "name" => name, "response" => response}
    })
  end

  describe "the passkey list" do
    test "shows each passkey's name and creation date, or says there are none", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      assert has_element?(view, "#passkey_empty")

      {passkey, _} = register_passkey!(ctx.user, "Phone")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      row = "#passkey-#{passkey.id}"
      assert has_element?(view, "#{row} input[name=name][value=Phone]")
      date = CinderWeb.LiveHelpers.format_date_year(passkey.inserted_at)
      assert has_element?(view, "#{row} p", "Added #{date}")
      refute has_element?(view, "#passkey_empty")
    end

    test "each row's field and buttons name their passkey for assistive technology", ctx do
      {phone, _} = register_passkey!(ctx.user, "Phone")
      {laptop, _} = register_passkey!(ctx.user, "Laptop")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      for passkey <- [phone, laptop] do
        row = "#passkey-#{passkey.id}"
        input = "#{row} input#passkey_name_#{passkey.id}[name=name]"
        assert has_element?(view, ~s|#{input}[aria-label="Passkey name (#{passkey.name})"]|)
        assert has_element?(view, ~s(#{row} button[aria-label="Rename passkey #{passkey.name}"]))
        assert has_element?(view, ~s(#{row} button[aria-label="Delete passkey #{passkey.name}"]))
      end
    end

    test "keeps the credential id and the public key out of the socket", ctx do
      register_passkey!(ctx.user)
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      [shown] = :sys.get_state(view.pid).socket.assigns.passkeys
      assert shown |> Map.keys() |> Enum.sort() == [:id, :inserted_at, :last_used_at, :name]
    end
  end

  describe "adding a passkey" do
    test "registers it under its name and lists it", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      add_passkey(view, "Laptop")

      assert [%UserPasskey{name: "Laptop"} = passkey] = Passkeys.list(ctx.user)
      assert has_element?(view, "#passkey-#{passkey.id} input[name=name][value=Laptop]")
      assert has_element?(view, "#flash-info", "Passkey added.")
    end

    test "a blank name is refused before any challenge is stored", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => " "}})
      assert_reply(view, %{ok: false})
      assert has_element?(view, "#flash-error", "A passkey name needs 1 to 64 characters.")

      # The error also sits on the field itself.
      assert has_element?(
               view,
               ~s(#new_passkey_name[aria-invalid="true"][aria-describedby="new_passkey_name-error"])
             )

      assert has_element?(view, "#new_passkey_name-error", "A passkey name needs 1 to 64")
    end

    test "an options event of another shape is refused and the page stays up", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      for params <- [
            %{"passkey" => "Phone"},
            %{"passkey" => [1]},
            %{"passkey" => %{"name" => 42}},
            %{}
          ] do
        render_hook(view, "passkey_registration_options", params)
        assert_reply(view, %{ok: false})
      end

      assert has_element?(view, "#passkeys")
    end

    test "the register event replies whether the passkey was added", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      add_passkey(view, "Phone")
      assert_reply(view, %{ok: true})

      render_hook(view, "passkey_register", %{"passkey" => %{"handle" => "spent"}})
      assert_reply(view, %{ok: false})
    end

    test "a success replaces the error an earlier attempt left", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => " "}})
      assert has_element?(view, "#flash-error")

      add_passkey(view, "Phone")

      assert has_element?(view, "#flash-info", "Passkey added.")
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#new_passkey_name[aria-invalid]")
    end

    test "a name the options event accepts clears the add field's earlier error", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => " "}})
      assert has_element?(view, ~s(#new_passkey_name[aria-invalid="true"]))

      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Phone"}})
      assert_reply(view, %{ok: true})
      render_hook(view, "passkey_failed", %{"reason" => "failed"})

      assert has_element?(view, "#flash-error", "The passkey was not added.")
      refute has_element?(view, "#new_passkey_name[aria-invalid]")
      refute has_element?(view, "#new_passkey_name-error")
    end

    test "options past the user's :passkey_options budget are refused", ctx do
      put_env(:ip_rate_limiting, true)
      IpRateLimiter.reset()
      on_exit(&IpRateLimiter.reset/0)
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      for _ <- 1..10 do
        render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Key"}})
        assert_reply(view, %{ok: true})
      end

      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => " "}})
      assert_reply(view, %{ok: false})
      assert has_element?(view, ~s(#new_passkey_name[aria-invalid="true"]))

      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Key"}})
      assert_reply(view, %{ok: false})

      assert has_element?(
               view,
               "#flash-error",
               "Too many passkey requests. Try again in a minute."
             )

      # The refusal is about the budget, not the name, so the name's earlier error goes.
      refute has_element?(view, "#new_passkey_name[aria-invalid]")
    end

    test "an answer the server refuses adds nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Key"}})
      assert_reply(view, %{ok: true, handle: handle, publicKey: options})
      challenge = Base.url_decode64!(options.challenge, padding: false)

      response =
        SoftAuthenticator.attest(
          SoftAuthenticator.new(),
          challenge,
          rp().id,
          "https://evil.example"
        )

      render_hook(view, "passkey_register", %{
        "passkey" => %{"handle" => handle, "name" => "Key", "response" => response}
      })

      assert Passkeys.list(ctx.user) == []
      assert has_element?(view, "#flash-error", "The passkey was not added. Please try again.")
    end

    test "options the challenge store refuses reply not ok and say the passkey was not added",
         ctx do
      put_env(:passkey_challenge_max_entries, %{register: 0})
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Key"}})

      assert_reply(view, %{ok: false})
      assert has_element?(view, "#flash-error", "The passkey was not added. Please try again.")
    end

    test "a name the register event refuses marks the field, not the generic failure", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => "Key"}})
      assert_reply(view, %{ok: true, handle: handle, publicKey: options})
      challenge = Base.url_decode64!(options.challenge, padding: false)

      response =
        SoftAuthenticator.attest(SoftAuthenticator.new(), challenge, rp().id, rp().origin)

      render_hook(view, "passkey_register", %{
        "passkey" => %{"handle" => handle, "name" => " ", "response" => response}
      })

      assert_reply(view, %{ok: false})
      assert Passkeys.list(ctx.user) == []
      assert has_element?(view, "#flash-error", "A passkey name needs 1 to 64 characters.")
      assert has_element?(view, ~s(#new_passkey_name[aria-invalid="true"]))
    end

    test "a ceremony the browser ended shows a message", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      render_hook(view, "passkey_failed", %{"reason" => "unsupported"})
      assert has_element?(view, "#flash-error", "This browser cannot use passkeys.")

      render_hook(view, "passkey_failed", %{"reason" => "anything"})
      assert has_element?(view, "#flash-error", "The passkey was not added. Please try again.")
    end

    test "neither event logs the credential id, the public key or the challenge", ctx do
      primary = Logger.level()
      on_exit(fn -> Logger.configure(level: primary) end)
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      auth = SoftAuthenticator.new()

      Logger.configure(level: :debug)
      log = capture_log([level: :debug], fn -> add_passkey(view, "Logged", auth) end)
      Logger.configure(level: primary)

      # Positive control: the event lines were logged, with their parameters filtered.
      assert log =~ ~s(HANDLE EVENT "passkey_register")
      assert log =~ "[FILTERED]"
      assert [_] = Passkeys.list(ctx.user)

      %{-2 => x, -3 => y} = SoftAuthenticator.cose_key(auth)

      for bytes <- [auth.credential_id, x, y],
          encoded <- [
            Base.url_encode64(bytes, padding: false),
            Base.encode64(bytes),
            Base.encode16(bytes, case: :lower),
            inspect(bytes)
          ] do
        refute String.contains?(log, encoded)
      end
    end
  end

  describe "renaming and deleting" do
    test "renames the user's passkey", ctx do
      {passkey, _} = register_passkey!(ctx.user, "Old")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      view
      |> form("#rename_passkey_#{passkey.id}", %{"name" => "New"})
      |> render_submit()

      assert Repo.get!(UserPasskey, passkey.id).name == "New"
      assert has_element?(view, "#flash-info", "Passkey renamed.")
    end

    test "a refused rename marks that row's field, and the next rename clears it", ctx do
      {phone, _} = register_passkey!(ctx.user, "Phone")
      {laptop, _} = register_passkey!(ctx.user, "Laptop")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      view |> form("#rename_passkey_#{phone.id}", %{"name" => " "}) |> render_submit()

      assert has_element?(view, "#flash-error", "A passkey name needs 1 to 64 characters.")
      field = "#passkey_name_#{phone.id}"
      error = "passkey_name_#{phone.id}-error"
      assert has_element?(view, ~s(#{field}[aria-invalid="true"][aria-describedby="#{error}"]))
      assert has_element?(view, "##{error}", "A passkey name needs 1 to 64")
      refute has_element?(view, "#passkey_name_#{laptop.id}[aria-invalid]")

      view |> form("#rename_passkey_#{phone.id}", %{"name" => "Tablet"}) |> render_submit()

      assert has_element?(view, "#flash-info", "Passkey renamed.")
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#{field}[aria-invalid]")
    end

    # The FormState hook (and PasskeyRegister, which reuses it) puts back what the user typed
    # after a patch, unless the form's data-form-revision changed: only a save resets a field.
    test "a patch resets a passkey name field only when a save took it", ctx do
      {phone, _} = register_passkey!(ctx.user, "Phone")
      {laptop, _} = register_passkey!(ctx.user, "Laptop")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")
      phone_form = "#rename_passkey_#{phone.id}"
      laptop_form = "#rename_passkey_#{laptop.id}"

      assert has_element?(
               view,
               ~s|#{phone_form}[phx-hook="FormState"][data-form-revision="Phone"]|
             )

      assert has_element?(view, ~s|#add_passkey_form[data-form-revision="0"]|)

      view |> form(phone_form, %{"name" => " "}) |> render_submit()
      render_hook(view, "passkey_registration_options", %{"passkey" => %{"name" => " "}})

      assert has_element?(view, ~s|#{phone_form}[data-form-revision="Phone"]|)
      assert has_element?(view, ~s|#{laptop_form}[data-form-revision="Laptop"]|)
      assert has_element?(view, ~s|#add_passkey_form[data-form-revision="0"]|)

      view |> form(phone_form, %{"name" => "Tablet"}) |> render_submit()
      add_passkey(view, "Watch")

      assert has_element?(view, ~s|#{phone_form}[data-form-revision="Tablet"]|)
      assert has_element?(view, ~s|#{laptop_form}[data-form-revision="Laptop"]|)
      assert has_element?(view, ~s|#add_passkey_form[data-form-revision="1"]|)
    end

    test "deletes the user's passkey", ctx do
      {passkey, _} = register_passkey!(ctx.user)
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      view |> element("#passkey-#{passkey.id} button[phx-click=delete_passkey]") |> render_click()

      refute Repo.get(UserPasskey, passkey.id)
      refute has_element?(view, "#passkey-#{passkey.id}")
      assert has_element?(view, "#flash-info", "Passkey deleted.")
    end

    test "cannot rename or delete another user's passkey", ctx do
      {theirs, _} = register_passkey!(user_fixture(), "Theirs")
      {:ok, view, _html} = live(ctx.conn, ~p"/users/settings")

      render_hook(view, "rename_passkey", %{"passkey_id" => "#{theirs.id}", "name" => "Mine"})
      assert has_element?(view, "#flash-error", "That passkey no longer exists.")
      render_hook(view, "delete_passkey", %{"id" => "#{theirs.id}"})

      assert %UserPasskey{name: "Theirs"} = Repo.get!(UserPasskey, theirs.id)
    end
  end

  describe "a lapsed sudo window" do
    test "sends the page to re-authenticate at mount", ctx do
      conn =
        log_in_user(build_conn(), ctx.user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/settings")
    end

    test "refuses the options event and stores no challenge", ctx do
      size = :ets.info(:cinder_passkey_challenges, :size)

      assert {:reply, %{ok: false}, socket} =
               Settings.handle_event(
                 "passkey_registration_options",
                 %{"passkey" => %{"name" => "Key"}},
                 stale_socket(ctx.user)
               )

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert :ets.info(:cinder_passkey_challenges, :size) == size
    end

    test "refuses a valid registration answer and stores nothing", ctx do
      {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(ctx.user, rp())
      challenge = Base.url_decode64!(options.challenge, padding: false)

      response =
        SoftAuthenticator.attest(SoftAuthenticator.new(), challenge, rp().id, rp().origin)

      params = %{"passkey" => %{"handle" => handle, "name" => "Key", "response" => response}}

      assert {:reply, %{ok: false}, socket} =
               Settings.handle_event("passkey_register", params, stale_socket(ctx.user))

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert Passkeys.list(ctx.user) == []
    end

    test "refuses a delete and keeps the passkey", ctx do
      {passkey, _} = register_passkey!(ctx.user)

      assert {:noreply, socket} =
               Settings.handle_event(
                 "delete_passkey",
                 %{"id" => "#{passkey.id}"},
                 stale_socket(ctx.user)
               )

      assert {:redirect, %{to: "/users/log-in"}} = socket.redirected
      assert Repo.get(UserPasskey, passkey.id)
    end
  end
end
