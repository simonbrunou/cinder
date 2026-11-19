defmodule Cinder.Accounts.UserNotifier do
  @moduledoc false

  import Swoosh.Email

  require Logger

  alias Cinder.Mailer

  # Delivers the email using the application mailer. A raise, exit or throw inside the adapter
  # comes back as `{:error, reason}` with one warning, so a caller such as the settings LiveView
  # stays up (#1535). Two such exits:
  #
  #   * under Swoosh.Adapters.SMTP, `:idna` exits on a domain it refuses (`x@-bad.com`) while
  #     it renders the To header;
  #   * with no SMTP host, prod keeps Swoosh.Adapters.Local while `config :swoosh, local: false`
  #     leaves its mailbox process unstarted, so `Memory.push/1` exits with `:noproc`.
  #
  # The warning names the exception module or the reason's atom tag, never the value itself:
  # `Swoosh.Adapter.validate_config/2` raises a message that inspects the whole mailer config,
  # SMTP password included, and the `:noproc` exit holds the email, confirm-link token included.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  rescue
    e ->
      Logger.warning("update email delivery raised #{inspect(e.__struct__)}")
      {:error, e}
  catch
    kind, value ->
      Logger.warning("update email delivery #{kind}: #{reason_tag(value)}")
      {:error, {kind, value}}
  end

  defp reason_tag(tag) when is_atom(tag), do: inspect(tag)

  defp reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: inspect(elem(reason, 0))

  defp reason_tag(_reason), do: "(no tag)"

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end
end
