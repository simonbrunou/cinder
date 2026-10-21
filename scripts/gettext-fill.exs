# Refill French msgstrs after a .po conflict, once you took one side's catalog and ran
# `MIX_ENV=test mix gettext.extract --merge`:
#
#     MIX_ENV=test mix run --no-start scripts/gettext-fill.exs <target.po> <source.po>
#
# For every entry of <target.po> that is untranslated or flagged fuzzy, it copies the msgstr of
# the entry with the same msgctxt, msgid and msgid_plural from <source.po>, when that one is
# translated and not fuzzy, and drops the fuzzy flag. Then it rewrites <target.po> and lists the
# entries still left to translate by hand. <source.po> is the copy from the side of the merge
# you did not take, for example
# `git show <other side>:priv/gettext/fr/LC_MESSAGES/default.po > /tmp/other-default.po`.

defmodule GettextFill do
  alias Expo.Message.{Plural, Singular}

  def run([target, source]) do
    translations =
      source
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> Enum.filter(&(translated?(&1) and not fuzzy?(&1)))
      |> Map.new(&{key(&1), &1})

    po = Expo.PO.parse_file!(target)
    messages = Enum.map(po.messages, &fill(&1, translations))
    File.write!(target, Expo.PO.compose(%{po | messages: messages}))

    filled = Enum.count(Enum.zip(po.messages, messages), fn {old, new} -> old != new end)
    unfilled = Enum.filter(messages, &(not &1.obsolete and (fuzzy?(&1) or not translated?(&1))))
    IO.puts("#{target}: filled #{filled}, #{length(unfilled)} left to translate by hand")
    Enum.each(unfilled, &IO.puts("  #{inspect(key(&1))}"))
  end

  def run(_args) do
    IO.puts(:stderr, "usage: mix run --no-start scripts/gettext-fill.exs <target.po> <source.po>")
    System.halt(2)
  end

  defp fill(%{obsolete: true} = message, _translations), do: message

  defp fill(message, translations) do
    with true <- fuzzy?(message) or not translated?(message),
         %{msgstr: msgstr} <- Map.get(translations, key(message)) do
      %{message | msgstr: msgstr, flags: drop_fuzzy(message.flags)}
    else
      _ -> message
    end
  end

  defp key(%Singular{} = message), do: Expo.Message.key(message)

  defp key(%Plural{} = message),
    do: {Expo.Message.key(message), IO.iodata_to_binary(message.msgid_plural)}

  defp translated?(%Singular{msgstr: msgstr}), do: IO.iodata_to_binary(msgstr) != ""

  defp translated?(%Plural{msgstr: msgstr}),
    do: map_size(msgstr) > 0 and Enum.all?(msgstr, fn {_n, s} -> IO.iodata_to_binary(s) != "" end)

  defp fuzzy?(message), do: Expo.Message.has_flag?(message, "fuzzy")

  defp drop_fuzzy(flags),
    do: flags |> Enum.map(&List.delete(&1, "fuzzy")) |> Enum.reject(&(&1 == []))
end

GettextFill.run(System.argv())
