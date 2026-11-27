defmodule CinderWeb.DefinitionTextTest do
  # Every Cardigann definition code has words of its own, in English and in French (#1676; #1619
  # point 13). The codes come from their producers' lists, so a code a later slice adds with no
  # words turns this red.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.Indexer.Cardigann.Grab
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Indexers.Definitions.{Hold, LoadCheck, Loader, Updater, UpdateRun}
  alias CinderWeb.{DefinitionText, IndexerFormText, IndexerStateText}

  @locales ["en", "fr"]

  # The bare atoms `Cardigann.report_feature/1` makes of the codes that carry a keyword.
  @named_kinds [:filter, :row_filter, :login, :setting]

  # `LoadCheck.codes/0` lists `{:xml_selector, :invalid}` for every `{:xml_selector, name}`, so
  # the walk adds one named pseudo-class too.
  defp feature_codes do
    Enum.map(Loader.features(), &elem(&1, 0)) ++
      @named_kinds ++
      Enum.map(Loader.unknown_slots(), &{:unknown_value, &1}) ++
      LoadCheck.codes() ++ [{:xml_selector, "has"}] ++ Cardigann.copy_codes()
  end

  defp hold_reasons do
    Enum.map(Hold.reason_tags(), fn
      :not_supported -> {:not_supported, :html_search}
      tag -> tag
    end) ++ [{:needs_newer_cinder, 13}]
  end

  defp fetch_errors do
    Enum.map(Updater.error_tags(), fn
      :http_status -> {:http_status, 503}
      tag -> tag
    end)
  end

  defp run_outcomes do
    Enum.map(Ecto.Enum.values(UpdateRun, :outcome), fn
      :failed -> {:failed, :timeout}
      outcome -> outcome
    end)
  end

  @at ~U[2026-11-26 08:00:00Z]

  # The definition states of `Cinder.Acquisition.IndexerSource.Native.IndexerState`.
  @definition_states [
    {:not_supported, :html_search},
    {:definition_no_longer_loads, :fails},
    {:definition_update_held, :hosts, @at},
    {:removed_upstream, @at},
    {:replaced_by, "newer.yml", @at}
  ]

  # A refused Cardigann login (#1680): its state's detail and its Test outcome. The password
  # methods share one text on purpose, as `IndexerStateText.detail/2` words them.
  @login_states for method <- [:post, :get, :form, :cookie],
                    do: {:credentials_rejected, {:login_rejected, method}}
  @login_outcomes [:login_rejected, :cookie_rejected]

  # The Cardigann form's refusals, `{field, validation}` (`Cinder.Indexers`,
  # `Cinder.Indexers.CardigannSettings`).
  @form_refusals [
    {:definition, :definition_changed},
    {:definition, :definition_not_in_mirror},
    {:definition, :definition_fails},
    {:definition, :fixed_at_create},
    {:base_url, :base_url_links},
    {:settings, :settings_keys},
    {:settings, :settings_values},
    {:settings, :select_option},
    {:secrets, :settings_keys},
    {:secrets, :settings_values},
    {:secrets, :select_option},
    {:secrets, :secret_fields},
    {:secrets, :secrets_unreadable}
  ]

  defp form_message({field, validation}) do
    changeset = %Ecto.Changeset{
      errors: [{field, {"is invalid", [validation: validation]}}],
      types: %{}
    }

    [message] = changeset |> IndexerFormText.errors(:cardigann) |> Map.values() |> List.flatten()
    message
  end

  # `{name, words, the function's fallback}` for each code of each lookup.
  defp walk, do: definition_walk() ++ state_walk()

  defp definition_walk do
    for(code <- feature_codes(), do: {:feature, code, DefinitionText.feature(code)}) ++
      for(code <- hold_reasons(), do: {:hold_reason, code, DefinitionText.hold_reason(code)}) ++
      for(code <- fetch_errors(), do: {:fetch_error, code, DefinitionText.fetch_error(code)}) ++
      for(code <- run_outcomes(), do: {:run_outcome, code, DefinitionText.run_outcome(code)}) ++
      for(tag <- Grab.failure_tags(), do: {:grab_failure, tag, DefinitionText.grab_failure(tag)})
  end

  defp state_walk do
    for(code <- Report.failure_atoms(), do: {:cause, code, IndexerStateText.cause(code)}) ++
      for(
        code <- [:no_rows | @login_outcomes],
        do: {:test_outcome, code, IndexerStateText.test_outcome(code)}
      ) ++
      for(state <- @definition_states, do: {:detail, state, IndexerStateText.detail(state, @at)}) ++
      for(state <- @login_states, do: {:login, state, IndexerStateText.detail(state, @at)}) ++
      for(refusal <- @form_refusals, do: {:form, refusal, form_message(refusal)})
  end

  defp fallback(:cause), do: IndexerStateText.cause(:__no_such_code__)
  defp fallback(:test_outcome), do: IndexerStateText.cause(:__no_such_code__)
  defp fallback(:detail), do: nil

  defp fallback(:login),
    do: IndexerStateText.detail({:credentials_rejected, :__no_such_code__}, @at)

  defp fallback(:form), do: form_message({:definition, :__no_such_code__})
  defp fallback(function), do: apply(DefinitionText, function, [:__no_such_code__])

  for locale <- @locales do
    test "every code has words of its own, not its lookup's fallback (#{locale})" do
      Gettext.with_locale(CinderWeb.Gettext, unquote(locale), fn ->
        unworded =
          for {function, code, words} <- walk(),
              words == fallback(function) or not is_binary(words),
              do: {function, code}

        assert unworded == []
      end)
    end
  end

  test "no two codes of one lookup share words" do
    shared =
      walk()
      |> Enum.uniq_by(fn {function, code, _words} -> {function, code} end)
      |> Enum.group_by(fn {function, _code, words} -> {function, words} end)
      |> Enum.filter(fn {_key, codes} -> length(codes) > 1 end)
      |> Enum.reject(fn {{function, _words}, codes} ->
        function == :form or (function == :login and Enum.all?(codes, &password_login?/1))
      end)
      |> Enum.map(fn {_key, codes} -> Enum.map(codes, &elem(&1, 1)) end)

    assert shared == []
  end

  defp password_login?({:login, {:credentials_rejected, {:login_rejected, method}}, _words}),
    do: method in [:post, :get, :form]

  defp password_login?(_code), do: false

  test "a code that carries a keyword shows the keyword as written" do
    assert DefinitionText.feature({:filter, "fuzzytime"}) == "the fuzzytime filter"
    assert DefinitionText.feature({:login, "form"}) == "the form login"
    assert DefinitionText.feature({:xml_selector, "has"}) == "the XML selector :has"
    assert DefinitionText.hold_reason({:needs_newer_cinder, 13}) == "needs a newer Cinder (v13)"
  end

  test "a failure outside the Cardigann kinds has no words here" do
    assert DefinitionText.failure(:timeout) == nil
    assert DefinitionText.fallback?(:failure, DefinitionText.failure(:timeout))
    assert DefinitionText.fallback?(:feature, DefinitionText.feature(:__later_code__))
  end
end
