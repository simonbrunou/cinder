defmodule CinderWeb.IndexerStateTextTest do
  # put_env(:household_timezone, ...) writes the app env.
  use Cinder.DataCase, async: false

  import Cinder.ConfigCase, only: [put_env: 2]

  alias Cinder.Acquisition.IndexerSource.Report
  alias CinderWeb.CoreComponents
  alias CinderWeb.IndexerStateText

  @now ~U[2026-11-26 12:00:00Z]

  @cardigann_reasons [
    :parser_failed,
    :regex_limit,
    :filter_output_cap,
    :forbidden_address,
    :secret_host,
    :too_many_redirects,
    :definition_error
  ]

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  describe "cause/1" do
    test "words every failure reason the status table records, none with the fallback" do
      causes =
        Map.new(
          (Report.failure_atoms() -- @cardigann_reasons) ++
            [:limit, {:http_status, 503}, {:indexer_error, 900}, {:query_error, 201}],
          &{&1, IndexerStateText.cause(&1)}
        )

      assert causes == %{
               :timeout => "Timed out",
               :dns => "Host not found",
               :connection_refused => "Connection refused",
               :connection_failed => "Connection failed",
               :bad_response => "The answer could not be read",
               :too_large => "The answer was too large",
               :rejected_credentials => "API key rejected",
               :challenge => "Blocked by a challenge page",
               :crashed => "The search crashed",
               :limit => "Limit reached",
               :invalid_json => "The answer is not valid JSON",
               :invalid_xml => "The answer is not valid XML",
               :xml_dtd => "The answer holds a DTD, which Cinder refuses",
               :no_results_list => "The answer has no results list",
               {:http_status, 503} => "HTTP 503",
               {:indexer_error, 900} => "Indexer error 900",
               {:query_error, 201} => "Query refused (code 201)"
             }

      # The positive control: a reason outside the table reads the fallback.
      assert IndexerStateText.cause(:something_new) == "Failed"
    end

    # #1671 adds these codes and #1676 their texts: until then each reads the fallback.
    test "the Cardigann failure reasons read the fallback until #1676 words them" do
      for reason <- @cardigann_reasons, do: assert(IndexerStateText.cause(reason) == "Failed")
    end

    test "HTTP 410 and 404 name their Prowlarr cause" do
      assert IndexerStateText.cause({:http_status, 410}) == "Disabled in Prowlarr"
      assert IndexerStateText.cause({:http_status, 404}) == "Not found in Prowlarr"
    end
  end

  describe "detail/2" do
    test "each state's line, the issue's table" do
      assert IndexerStateText.detail({:usable, at(-3_480)}, @now) == "Last answered at 11:02"

      assert IndexerStateText.detail(:never_checked, @now) ==
               "Not checked yet: press Test in Settings"

      assert IndexerStateText.detail({:failure_backoff, at(1_500), :timeout, 3}, @now) ==
               "Backing off until 12:25 (in 25 min): Timed out, 3 failures in a row"

      assert IndexerStateText.detail({:limit_backoff, at(6_720)}, @now) ==
               "Limit reached: searching again at 13:52 (in 1 h 52 min)"

      assert IndexerStateText.detail({:credentials_rejected, {:code, 101}}, @now) ==
               "API key rejected (code 101): update it in Settings"

      assert IndexerStateText.detail({:credentials_rejected, {:http_status, 401}}, @now) ==
               "API key rejected (HTTP 401): update it in Settings"

      assert IndexerStateText.detail({:credentials_rejected, nil}, @now) ==
               "API key rejected: update it in Settings"

      for method <- [:post, :get, :form] do
        assert {method,
                IndexerStateText.detail({:credentials_rejected, {:login_rejected, method}}, @now)} ==
                 {method, "Login rejected: check the username and password in Settings"}
      end

      assert IndexerStateText.detail({:credentials_rejected, {:login_rejected, :cookie}}, @now) ==
               "Cookie rejected: paste a new one in Settings"

      assert IndexerStateText.detail({:not_supported, :flaresolverr}, @now) ==
               "Not supported: FlareSolverr"

      assert IndexerStateText.detail({:not_supported, :cardigann}, @now) ==
               "Not supported: Cardigann"

      assert IndexerStateText.detail(:undecryptable, @now) ==
               "Credentials can't be decrypted: re-enter them"

      assert IndexerStateText.detail(:disabled, @now) == "Disabled"
    end

    test "a state it does not word yet gives nil, and the source row names that indexer alone" do
      assert IndexerStateText.detail({:some_new_state, @now}, @now) == nil

      assert IndexerStateText.indexers(
               [
                 %{name: "New", state: {:some_new_state, @now}},
                 %{name: "Fresh", state: :never_checked}
               ],
               0,
               @now
             ) =~ ~r/^New\b(?!:)/
    end

    test "a backoff that ended names its cause, and a limit that ended names none" do
      assert IndexerStateText.detail({:retry_due, at(-60), {:http_status, 410}, 2}, @now) ==
               "Backoff ended at 11:59: Disabled in Prowlarr, 2 failures in a row. " <>
                 "The next search asks it again"

      assert IndexerStateText.detail({:retry_due, at(-60), :limit, 0}, @now) ==
               "Limit ended at 11:59: the next search asks it again"

      assert IndexerStateText.detail({:retry_due, at(-60), :limit, 1}, @now) ==
               "Limit ended at 11:59, after 1 failure in a row: the next search asks it again"
    end

    test "the wait reads in hours and minutes, and a time already past as under a minute" do
      wait = fn seconds ->
        IndexerStateText.detail({:limit_backoff, at(seconds)}, @now)
        |> String.split("(")
        |> List.last()
      end

      assert wait.(59) == "in under a minute)"
      assert wait.(60) == "in 1 min)"
      assert wait.(3_599) == "in 59 min)"
      assert wait.(3_600) == "in 1 h)"
      assert wait.(3_660) == "in 1 h 1 min)"
      assert wait.(-3_600) == "in under a minute)"
    end

    test "a time on another household day carries its date" do
      put_env(:household_timezone, "Asia/Tokyo")

      assert IndexerStateText.detail({:usable, at(-3_600)}, @now) == "Last answered at 20:00"

      assert IndexerStateText.detail({:usable, at(-86_400)}, @now) ==
               "Last answered on Nov 25 at 21:00"

      assert IndexerStateText.detail({:failure_backoff, at(10_800), :dns, 1}, @now) ==
               "Backing off until Nov 27 at 00:00 (in 3 h): Host not found, 1 failure in a row"
    end
  end

  describe "last_test/2" do
    test "words each outcome, a failure by its cause" do
      lines =
        for outcome <- [
              :success,
              :rejected_credentials,
              :login_rejected,
              :cookie_rejected,
              :limit,
              :timeout,
              {:http_status, 503}
            ],
            do: IndexerStateText.last_test(%{outcome: outcome, at: at(-3_600)}, @now)

      assert lines == [
               "Last Test: worked at 11:00",
               "Last Test: API key rejected at 11:00",
               "Last Test: Login rejected at 11:00",
               "Last Test: Cookie rejected at 11:00",
               "Last Test: limit reached at 11:00",
               "Last Test: Timed out at 11:00",
               "Last Test: HTTP 503 at 11:00"
             ]
    end

    test "shows the household's time, with the date on another day" do
      put_env(:household_timezone, "Asia/Tokyo")

      assert IndexerStateText.last_test(%{outcome: :success, at: at(-86_400)}, @now) ==
               "Last Test: worked on Nov 25 at 21:00"
    end
  end

  describe "the source row's reasons in health_reason/1" do
    test "lists each indexer by name with its line, then the count left out" do
      listed = [
        %{name: "Movies", state: :never_checked},
        %{name: "Shows", state: {:credentials_rejected, nil}}
      ]

      assert IndexerStateText.indexers(listed, 2, @now) ==
               "Movies: Not checked yet: press Test in Settings; " <>
                 "Shows: API key rejected: update it in Settings; and 2 more"

      assert IndexerStateText.indexers(listed, 0, @now) ==
               "Movies: Not checked yet: press Test in Settings; " <>
                 "Shows: API key rejected: update it in Settings"
    end

    test "joins the lines with French punctuation on the French page" do
      listed = [
        %{name: "Movies", state: :never_checked},
        %{name: "Shows", state: {:credentials_rejected, nil}}
      ]

      french =
        Gettext.with_locale(CinderWeb.Gettext, "fr", fn ->
          IndexerStateText.indexers(listed, 0, @now)
        end)

      assert french ==
               "Movies : Pas encore vérifié : appuyez sur Tester dans les Paramètres ; " <>
                 "Shows : Clé API refusée : mettez-la à jour dans les Paramètres"
    end

    test "words the JSON and XML failure reasons on the French page" do
      french =
        Gettext.with_locale(CinderWeb.Gettext, "fr", fn ->
          Map.new(
            [:invalid_json, :invalid_xml, :xml_dtd, :no_results_list],
            &{&1, IndexerStateText.cause(&1)}
          )
        end)

      assert french == %{
               invalid_json: "La réponse n'est pas du JSON valide",
               invalid_xml: "La réponse n'est pas du XML valide",
               xml_dtd: "La réponse contient une DTD, que Cinder refuse",
               no_results_list: "La réponse n'a pas de liste de résultats"
             }
    end

    test "words the source's own reasons and the credential counts" do
      assert CoreComponents.health_reason(:no_indexer_added) == "No indexer added"
      assert CoreComponents.health_reason(:no_indexer_enabled) == "No indexer is enabled"

      assert CoreComponents.health_reason({:native_indexer, :undecryptable, @now}) ==
               "Credentials can't be decrypted: re-enter them"

      # Each reason words its waits from the instant it carries, not from the clock at render,
      # which here reads an hour later.
      put_env(Cinder.Acquisition.IndexerSource.Native, clock: fn -> at(3_600) end)

      assert CoreComponents.health_reason({:native_indexer, {:limit_backoff, at(1_500)}, @now}) ==
               "Limit reached: searching again at 12:25 (in 25 min)"

      assert CoreComponents.health_reason(
               {:native_indexers, [%{name: "Movies", state: {:limit_backoff, at(1_500)}}], 0,
                @now}
             ) == "Movies: Limit reached: searching again at 12:25 (in 25 min)"

      assert CoreComponents.health_reason({:undecryptable_indexer_secrets, 1}) ==
               "1 indexer's credentials can't be decrypted. " <>
                 "Re-enter them for that indexer in Settings, under Indexers."

      assert CoreComponents.health_reason({:undecryptable_indexer_secrets, 2}) ==
               "2 indexers' credentials can't be decrypted. " <>
                 "Re-enter them for each indexer in Settings, under Indexers."

      both = CoreComponents.health_reason({:undecryptable_secrets, 1, 2})
      assert both =~ CoreComponents.health_reason({:undecryptable_secrets, 1})
      assert both =~ CoreComponents.health_reason({:undecryptable_indexer_secrets, 2})
    end
  end
end
