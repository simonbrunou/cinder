defmodule Cinder.Acquisition.IndexerSource.Native.IndexerStatusTest do
  # Native's backoff state (#1654): the transitions an answer makes (#1619 points 1, 3 and 11,
  # #1636 point 2), the `config_version` reset, which answers write the row, and the row's life
  # beside its configured indexer. Every expected time is a literal.
  use Cinder.DataCase, async: true

  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-26 12:00:00Z]

  defp fresh, do: IndexerStatus.new(1)

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  # Folds `answers` over a fresh status, each answered at `@now`.
  defp after_answers(answers, status \\ fresh()),
    do: Enum.reduce(answers, status, &IndexerStatus.transition(&2, &1, @now))

  defp indexer!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Indexer #{System.unique_integer([:positive])}",
          type: :newznab,
          base_url: "https://indexer.example",
          api_path: "/api"
        },
        overrides
      )

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  describe "a failure" do
    test "ten in a row back off 1, 5, 15 and 30 min, then 1, 3, 6, 12, 24 and 24 h" do
      untils =
        Enum.map_reduce(1..10, fresh(), fn _n, status ->
          status = IndexerStatus.transition(status, {:http_status, 500}, @now)
          {status.backoff_until, status}
        end)
        |> elem(0)

      assert untils == [
               ~U[2026-11-26 12:01:00Z],
               ~U[2026-11-26 12:05:00Z],
               ~U[2026-11-26 12:15:00Z],
               ~U[2026-11-26 12:30:00Z],
               ~U[2026-11-26 13:00:00Z],
               ~U[2026-11-26 15:00:00Z],
               ~U[2026-11-26 18:00:00Z],
               ~U[2026-11-27 00:00:00Z],
               ~U[2026-11-27 12:00:00Z],
               ~U[2026-11-27 12:00:00Z]
             ]
    end

    test "stays at the top step, level 9, past nine in a row" do
      top = after_answers(List.duplicate(:timeout, 9))
      assert top.level == 9
      assert IndexerStatus.transition(top, :timeout, @now).level == 9
      assert IndexerStatus.transition(top, {:disabled_till, at(600)}, @now).level == 9
    end

    test "records a failure backoff, the level, the count and the last failure with its time" do
      status = after_answers([{:indexer_error, 900}, :timeout, {:http_status, 410}])

      assert %{
               backoff: :failure,
               level: 3,
               backoff_until: ~U[2026-11-26 12:15:00Z],
               failures_in_row: 3,
               last_failure: :http_status,
               last_failure_code: 410,
               last_failure_at: @now
             } = status
    end

    test "keeps each failure tag of the closed set apart" do
      for {answer, tag, code} <- [
            {:timeout, :timeout, nil},
            {:connection_failed, :connection_failed, nil},
            {:bad_response, :bad_response, nil},
            {:too_large, :too_large, nil},
            {:challenge, :challenge, nil},
            {{:http_status, 404}, :http_status, 404},
            {{:http_status, 410}, :http_status, 410},
            {{:indexer_error, 900}, :indexer_error, 900},
            {:dns, :dns, nil},
            {:connection_refused, :connection_refused, nil}
          ] do
        status = after_answers([answer])
        assert {answer, status.last_failure, status.last_failure_code} == {answer, tag, code}
        assert {answer, status.backoff} == {answer, :failure}
      end
    end

    test "a DNS failure and a refused connection climb no higher than the first step" do
      for answer <- [:dns, :connection_refused] do
        status = after_answers(List.duplicate(answer, 5))

        assert {answer, status.level, status.backoff_until, status.failures_in_row} ==
                 {answer, 1, ~U[2026-11-26 12:01:00Z], 5}
      end
    end

    test "a DNS failure above the first step keeps the level and backs off 1 min" do
      status = after_answers([:timeout, :timeout, :timeout, :dns])
      assert {status.level, status.backoff_until} == {3, ~U[2026-11-26 12:01:00Z]}
    end

    test "during a running limit backoff keeps the limit and its end, and climbs the level" do
      limited = after_answers([{:limit, at(7_200)}])
      status = IndexerStatus.transition(limited, :timeout, @now)

      assert {status.backoff, status.backoff_until, status.level, status.failures_in_row} ==
               {:limit, ~U[2026-11-26 14:00:00Z], 1, 1}

      # A failure whose step would end after the limit still keeps the limit and its end, so a
      # success, a passing Test and a config_version rise all leave it running.
      climbing = after_answers([:timeout, {:limit, at(60)}])
      status = IndexerStatus.transition(climbing, :timeout, @now)

      assert {status.backoff, status.backoff_until, status.level} ==
               {:limit, ~U[2026-11-26 12:01:00Z], 2}

      for answer <- [:success, :test_success] do
        after_success = IndexerStatus.transition(status, answer, at(30))

        assert {answer, after_success.backoff, after_success.backoff_until} ==
                 {answer, :limit, ~U[2026-11-26 12:01:00Z]}
      end

      reset = IndexerStatus.reset(status, 2)
      assert {reset.backoff, reset.backoff_until} == {:limit, ~U[2026-11-26 12:01:00Z]}

      # Once the limit has ended, a failure starts a failure backoff.
      ended = after_answers([{:limit, at(60)}])
      status = IndexerStatus.transition(ended, {:http_status, 503}, at(60))
      assert {status.backoff, status.backoff_until} == {:failure, ~U[2026-11-26 12:02:00Z]}
    end
  end

  describe "a success" do
    test "at level 3 leaves level 2, no backoff, no failures and a last success" do
      status = after_answers([:timeout, :timeout, :timeout])
      later = ~U[2026-11-26 12:20:00Z]
      status = IndexerStatus.transition(status, :success, later)

      assert {status.level, status.backoff, status.backoff_until, status.failures_in_row,
              status.last_success_at} == {2, :none, nil, 0, later}
    end

    test "at level 0 stays at 0" do
      assert after_answers([:success]).level == 0
    end

    test "during a limit backoff leaves the limit and its until-time" do
      status = after_answers([{:limit, at(600)}, :success])

      assert {status.backoff, status.backoff_until, status.last_success_at} ==
               {:limit, ~U[2026-11-26 12:10:00Z], @now}
    end

    test "clears a limit backoff that has ended" do
      status = after_answers([{:limit, at(600)}])

      for {now, backoff, until} <- [
            {at(599), :limit, ~U[2026-11-26 12:10:00Z]},
            {at(600), :none, nil},
            {at(601), :none, nil}
          ] do
        changed = IndexerStatus.transition(status, :success, now)
        assert {now, changed.backoff, changed.backoff_until} == {now, backoff, until}
      end
    end

    test "from a search leaves rejected credentials, which only a passing Test ends" do
      rejected = after_answers([{:rejected_credentials, {:code, 101}}])
      status = IndexerStatus.transition(rejected, :success, @now)

      assert {status.credentials_rejected, status.credentials_rejected_by,
              status.credentials_rejected_code} == {true, :code, 101}

      status = IndexerStatus.transition(rejected, :test_success, @now)

      assert {status.credentials_rejected, status.credentials_rejected_by,
              status.credentials_rejected_code} == {false, nil, nil}
    end

    test "from a passing Test does what a search success does, and leaves a running limit" do
      status = after_answers([:timeout, :timeout, :timeout])
      later = ~U[2026-11-26 12:20:00Z]
      status = IndexerStatus.transition(status, :test_success, later)

      assert {status.level, status.backoff, status.backoff_until, status.failures_in_row,
              status.last_success_at} == {2, :none, nil, 0, later}

      status = after_answers([{:limit, at(600)}, :test_success])
      assert {status.backoff, status.backoff_until} == {:limit, ~U[2026-11-26 12:10:00Z]}
    end
  end

  describe "a limit" do
    test "backs off until the wait the answer states, clamped, and leaves the level" do
      climbed = after_answers([:timeout, :timeout])

      for {wait, until} <- [
            {at(120), ~U[2026-11-26 12:02:00Z]},
            {at(172 * 60), ~U[2026-11-26 14:52:00Z]},
            {nil, ~U[2026-11-26 13:00:00Z]},
            {at(10), ~U[2026-11-26 12:01:00Z]},
            {at(3 * 24 * 3600), ~U[2026-11-27 12:00:00Z]}
          ] do
        status = IndexerStatus.transition(climbed, {:limit, wait}, @now)

        assert {wait, status.backoff, status.backoff_until, status.level, status.failures_in_row} ==
                 {wait, :limit, until, 2, 2}

        assert {status.last_failure, status.last_failure_at} == {:limit, @now}
      end
    end
  end

  describe "Indexer is disabled till" do
    test "is a failure backoff ending at its Retry-After, which a success ends" do
      status = after_answers([{:disabled_till, at(600)}])

      assert {status.backoff, status.backoff_until, status.level, status.failures_in_row} ==
               {:failure, ~U[2026-11-26 12:10:00Z], 1, 1}

      assert {status.last_failure, status.last_failure_code} == {:http_status, 429}
      assert IndexerStatus.transition(status, :success, @now).backoff == :none
    end

    test "clamps its Retry-After between 1 min and 24 h" do
      for {wait, until} <- [
            {at(3 * 24 * 3600), ~U[2026-11-27 12:00:00Z]},
            {at(10), ~U[2026-11-26 12:01:00Z]},
            {at(-600), ~U[2026-11-26 12:01:00Z]}
          ] do
        status = after_answers([{:disabled_till, wait}])
        assert {wait, status.backoff_until} == {wait, until}
      end
    end

    test "without a Retry-After backs off the ladder step" do
      status = after_answers([:timeout, {:disabled_till, nil}])
      assert {status.backoff_until, status.level} == {~U[2026-11-26 12:05:00Z], 2}
    end
  end

  describe "rejected credentials" do
    test "mark the answer that rejected them, with no until-time" do
      for by <- [{:code, 100}, {:code, 101}, {:code, 102}, {:code, 910}, {:http_status, 401}] do
        status = after_answers([{:rejected_credentials, by}])
        {kind, code} = by

        assert {by, status.credentials_rejected, status.credentials_rejected_by,
                status.credentials_rejected_code, status.backoff, status.backoff_until} ==
                 {by, true, kind, code, :none, nil}

        assert {status.last_failure, status.last_failure_at} == {:rejected_credentials, @now}
      end
    end

    test "a refused Cardigann login marks its method, which only a passing Test ends (#1680)" do
      for {method, by} <- [
            post: :login_post,
            get: :login_get,
            form: :login_form,
            cookie: :login_cookie
          ] do
        status = after_answers([{:rejected_credentials, {:login_rejected, method}}, :success])

        assert {method, status.credentials_rejected, status.credentials_rejected_by,
                status.credentials_rejected_code, status.backoff, status.last_failure} ==
                 {method, true, by, nil, :none, :rejected_credentials}

        assert IndexerStatus.gate(status, @now) == {:failed, :rejected_credentials}

        status = IndexerStatus.transition(status, :test_success, @now)
        assert {method, status.credentials_rejected} == {method, false}
      end
    end

    test "a refused Cardigann login stores its method's kind as the last Test (#1680)" do
      indexer = indexer!()

      for {method, outcome} <- [
            post: :login_rejected,
            get: :login_rejected,
            form: :login_rejected,
            cookie: :cookie_rejected
          ] do
        answer = {:rejected_credentials, {:login_rejected, method}}

        assert {method, IndexerStatus.record_test(indexer, answer, @now)} ==
                 {method, {:written, %{outcome: outcome, at: @now}}}

        assert IndexerStatus.last_test(Repo.get(IndexerStatus, indexer.id)) ==
                 %{outcome: outcome, at: @now}
      end
    end
  end

  describe "other answers" do
    test "a rejection with no code and a grab's :indexer_auth_failed reject the credentials" do
      for answer <- [:rejected_credentials, :indexer_auth_failed] do
        status = after_answers([{:limit, at(600)}, answer])

        assert {answer, status.credentials_rejected, status.credentials_rejected_by,
                status.credentials_rejected_code} == {answer, true, nil, nil}

        assert {answer, status.backoff, status.backoff_until} ==
                 {answer, :limit, ~U[2026-11-26 12:10:00Z]}
      end
    end

    test "a crash is a failure" do
      status = after_answers([:crashed])
      assert {status.backoff, status.level, status.last_failure} == {:failure, 1, :crashed}
    end

    test "an answer outside the closed set raises" do
      assert_raise ArgumentError, fn -> after_answers([:not_an_answer]) end
      assert_raise ArgumentError, fn -> after_answers([{:http_status, "503"}]) end
    end
  end

  describe "an answer that changes nothing" do
    test "a query error and a deadline cut leave the status as it was" do
      status = after_answers([:timeout, {:limit, at(600)}])

      for answer <- [{:query_error, 200}, {:query_error, 203}, {:query_error, 300}, :deadline] do
        assert {answer, IndexerStatus.transition(status, answer, at(5))} == {answer, status}
      end
    end
  end

  describe "the gate a search reads" do
    test "skips a backoff until its until-time, and asks from that time on" do
      status = after_answers([:timeout])

      assert IndexerStatus.gate(status, at(59)) ==
               {:skipped, {:backoff, ~U[2026-11-26 12:01:00Z]}}

      assert IndexerStatus.gate(status, at(60)) == :ask
      assert IndexerStatus.gate(status, at(61)) == :ask

      limited = after_answers([{:limit, at(600)}])
      assert IndexerStatus.gate(limited, at(599)) == {:skipped, {:backoff, at(600)}}
      assert IndexerStatus.gate(limited, at(600)) == :ask
    end

    test "fails rejected credentials, whatever the backoff, and asks a fresh status" do
      rejected = after_answers([{:rejected_credentials, {:http_status, 401}}])
      assert IndexerStatus.gate(rejected, at(3600)) == {:failed, :rejected_credentials}

      both = after_answers([:timeout, {:rejected_credentials, {:code, 100}}])
      assert IndexerStatus.gate(both, @now) == {:failed, :rejected_credentials}

      assert IndexerStatus.gate(fresh(), @now) == :ask
    end
  end

  describe "a config_version rise" do
    test "clears the last success, ends a failure backoff and rejected credentials" do
      status =
        after_answers([:success, :timeout, :timeout, {:rejected_credentials, {:code, 100}}])

      reset = IndexerStatus.reset(status, 2)

      assert {reset.config_version, reset.last_success_at, reset.backoff, reset.backoff_until,
              reset.level, reset.failures_in_row, reset.credentials_rejected,
              reset.credentials_rejected_by, reset.credentials_rejected_code} ==
               {2, nil, :none, nil, 0, 0, false, nil, nil}
    end

    test "keeps a limit backoff with its until-time" do
      status = after_answers([:timeout, {:limit, at(5_400)}])
      reset = IndexerStatus.reset(status, 2)

      assert {reset.backoff, reset.backoff_until, reset.level} ==
               {:limit, ~U[2026-11-26 13:30:00Z], 0}
    end

    test "is no reset at the same version" do
      status = after_answers([:success, :timeout])
      assert IndexerStatus.reset(status, 1) == status
    end
  end

  describe "record/3 and read/1" do
    test "a failure writes the row that the next read gives back" do
      indexer = indexer!()

      assert IndexerStatus.record(indexer, :timeout, @now) == :written

      assert %IndexerStatus{} = status = IndexerStatus.read([indexer])[indexer.id]

      assert {status.backoff, status.backoff_until, status.level, status.last_failure} ==
               {:failure, ~U[2026-11-26 12:01:00Z], 1, :timeout}
    end

    test "an indexer with no row reads a fresh status at its own config_version" do
      indexer = indexer!()

      assert IndexerStatus.read([indexer]) == %{
               indexer.id =>
                 IndexerStatus.new(indexer.config_version)
                 |> Map.put(:configured_indexer_id, indexer.id)
             }
    end

    test "a query error changes no row, byte for byte" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :timeout, @now)
      before = raw_row(indexer.id)
      assert [_row] = before

      for code <- [200, 201, 202, 203, 300] do
        assert IndexerStatus.record(indexer, {:query_error, code}, at(5)) == :unchanged
      end

      assert raw_row(indexer.id) == before
    end

    test "stores every failure reason the report can carry as the last failure" do
      tagged = [{:http_status, 500}, {:indexer_error, 900}]

      # The partial kinds are no failure: the next test.
      for reason <- (Report.failure_atoms() -- [:regex_limit, :filter_output_cap]) ++ tagged do
        indexer = indexer!()
        assert {reason, IndexerStatus.record(indexer, reason, @now)} == {reason, :written}
        {tag, code} = if is_tuple(reason), do: reason, else: {reason, nil}
        stored = IndexerStatus.read([indexer])[indexer.id]
        assert {reason, stored.last_failure, stored.last_failure_code} == {reason, tag, code}
      end
    end

    test "a Cardigann partial kind is the last partial, with no backoff and no failure (#1671)" do
      for kind <- [:regex_limit, :filter_output_cap] do
        indexer = indexer!()
        :written = IndexerStatus.record(indexer, :timeout, @now)
        before = IndexerStatus.read([indexer])[indexer.id]

        assert IndexerStatus.record(indexer, kind, at(5)) == :written
        stored = IndexerStatus.read([indexer])[indexer.id]

        assert {stored.last_partial, stored.last_partial_at} == {kind, at(5)}
        # The failure's backoff, level and count stay as they were.
        assert Map.take(stored, [
                 :backoff,
                 :backoff_until,
                 :level,
                 :failures_in_row,
                 :last_failure
               ]) ==
                 Map.take(before, [
                   :backoff,
                   :backoff_until,
                   :level,
                   :failures_in_row,
                   :last_failure
                 ])
      end
    end

    test "a Cardigann Test with no row is a success for the status, stored as :no_rows (#1671)" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :timeout, @now)

      assert {:written, %{outcome: :no_rows}} =
               IndexerStatus.record_test(indexer, :no_rows, at(5))

      stored = IndexerStatus.read([indexer])[indexer.id]

      assert {stored.backoff, stored.failures_in_row, stored.last_success_at} == {:none, 0, at(5)}
      assert IndexerStatus.last_test(stored) == %{outcome: :no_rows, at: at(5)}
    end

    test "rejected credentials, then a passing Test, clear every rejected field in the row" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, {:rejected_credentials, {:code, 101}}, @now)
      :written = IndexerStatus.record(indexer, :test_success, at(5))

      status = IndexerStatus.read([indexer])[indexer.id]

      assert {status.credentials_rejected, status.credentials_rejected_by,
              status.credentials_rejected_code} == {false, nil, nil}
    end

    test "a success with no backoff writes the last success only once 15 minutes have passed" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)

      assert IndexerStatus.record(indexer, :success, at(5 * 60)) == :unchanged
      assert last_success(indexer) == @now

      assert IndexerStatus.record(indexer, :success, at(15 * 60 - 1)) == :unchanged
      assert IndexerStatus.record(indexer, :success, at(15 * 60)) == :written
      assert last_success(indexer) == ~U[2026-11-26 12:15:00Z]

      assert IndexerStatus.record(indexer, :success, at(31 * 60)) == :written
      assert last_success(indexer) == ~U[2026-11-26 12:31:00Z]
    end

    test "a success 5 minutes after a failure writes, also when nothing else changes" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)
      # A limit leaves the level at 0, and a success while it runs leaves it, so the later
      # success changes no field but the last success.
      :written = IndexerStatus.record(indexer, {:limit, at(3600)}, at(60))

      assert IndexerStatus.record(indexer, :success, at(5 * 60)) == :written
      assert last_success(indexer) == ~U[2026-11-26 12:05:00Z]
      assert %{backoff: :limit, level: 0} = IndexerStatus.read([indexer])[indexer.id]
    end

    test "a success after a failure in the same second as the last success writes" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)
      :written = IndexerStatus.record(indexer, {:limit, at(3600)}, @now)

      assert IndexerStatus.record(indexer, :success, at(60)) == :written
      assert last_success(indexer) == ~U[2026-11-26 12:01:00Z]
    end

    test "a success that steps the level down writes at once" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)
      :written = IndexerStatus.record(indexer, :timeout, at(60))

      assert IndexerStatus.record(indexer, :success, at(120)) == :written
      assert %{level: 0, backoff: :none} = IndexerStatus.read([indexer])[indexer.id]
    end

    test "an outcome of a request started under an older config_version changes no row" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)
      before = raw_row(indexer.id)

      {:ok, edited} =
        Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/newznab/api"})

      assert edited.config_version == indexer.config_version + 1

      for answer <- [:timeout, {:limit, nil}, {:rejected_credentials, {:http_status, 401}}] do
        assert {answer, IndexerStatus.record(indexer, answer, at(60))} == {answer, :dropped}
      end

      assert raw_row(indexer.id) == before

      # The control: the same failure under the new version writes.
      assert IndexerStatus.record(edited, :timeout, at(60)) == :written
    end

    test "a config_version rise reads reset, and the next write stores the reset row" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :success, @now)
      :written = IndexerStatus.record(indexer, :timeout, at(60))
      :written = IndexerStatus.record(indexer, {:rejected_credentials, {:code, 100}}, at(60))

      {:ok, edited} =
        Indexers.update(nil, indexer.id, indexer.lock_version, %{
          base_url: "https://moved.example"
        })

      status = IndexerStatus.read([edited])[edited.id]

      assert {status.config_version, status.backoff, status.level, status.credentials_rejected,
              status.last_success_at} == {edited.config_version, :none, 0, false, nil}

      assert IndexerStatus.record(edited, :success, at(120)) == :written
      assert [[config_version | _rest]] = raw_row(indexer.id)
      assert config_version == edited.config_version
    end

    test "a limit survives a config_version rise and a disable and re-enable" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, {:limit, at(5_400)}, @now)

      {:ok, off} = Indexers.set_enabled(nil, indexer.id, indexer.lock_version, false)
      {:ok, on} = Indexers.set_enabled(nil, off.id, off.lock_version, true)
      assert on.config_version == indexer.config_version

      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 13:30:00Z]} =
               IndexerStatus.read([on])[on.id]

      {:ok, edited} = Indexers.update(nil, on.id, on.lock_version, %{api_path: "/v2/api"})

      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 13:30:00Z]} =
               IndexerStatus.read([edited])[edited.id]
    end

    test "deleting the configured indexer deletes its row" do
      indexer = indexer!()
      other = indexer!()
      :written = IndexerStatus.record(indexer, :timeout, @now)
      :written = IndexerStatus.record(other, :timeout, @now)
      assert [_row] = raw_row(indexer.id)

      :ok = Indexers.delete(nil, indexer.id)

      assert raw_row(indexer.id) == []
      assert [_row] = raw_row(other.id)
    end

    test "an outcome for a deleted indexer is dropped" do
      indexer = indexer!()
      :ok = Indexers.delete(nil, indexer.id)

      assert IndexerStatus.record(indexer, :timeout, @now) == :dropped
      assert raw_row(indexer.id) == []
    end
  end

  describe "record_test/3" do
    test "a passing Test ends rejected credentials and stores its outcome and time" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, {:rejected_credentials, {:code, 101}}, @now)

      assert IndexerStatus.record_test(indexer, :test_success, at(60)) ==
               {:written, %{outcome: :success, at: ~U[2026-11-26 12:01:00Z]}}

      status = IndexerStatus.read([indexer])[indexer.id]

      assert {status.credentials_rejected, status.last_success_at,
              IndexerStatus.last_test(status)} ==
               {false, ~U[2026-11-26 12:01:00Z],
                %{outcome: :success, at: ~U[2026-11-26 12:01:00Z]}}
    end

    test "a failing Test climbs one step and stores the reason the report carries" do
      indexer = indexer!()

      for {answer, outcome} <- [
            {{:http_status, 410}, {:http_status, 410}},
            {{:indexer_error, 900}, {:indexer_error, 900}},
            {{:disabled_till, nil}, {:http_status, 429}},
            {{:rejected_credentials, {:code, 100}}, :rejected_credentials},
            {:timeout, :timeout}
          ] do
        assert {answer, IndexerStatus.record_test(indexer, answer, @now)} ==
                 {answer, {:written, %{outcome: outcome, at: @now}}}
      end

      status = IndexerStatus.read([indexer])[indexer.id]
      # Three failures climbed the ladder; the rejection climbed nothing.
      assert {status.level, status.failures_in_row, status.credentials_rejected} == {4, 4, true}
    end

    test "a limit answer starts a limit backoff and stores :limit" do
      indexer = indexer!()

      assert IndexerStatus.record_test(indexer, {:limit, at(600)}, @now) ==
               {:written, %{outcome: :limit, at: @now}}

      assert %{backoff: :limit, backoff_until: ~U[2026-11-26 12:10:00Z]} =
               IndexerStatus.read([indexer])[indexer.id]
    end

    test "a query error leaves the status and stores the code" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :timeout, @now)
      before = raw_row(indexer.id)

      assert IndexerStatus.record_test(indexer, {:query_error, 201}, at(30)) ==
               {:written, %{outcome: {:query_error, 201}, at: ~U[2026-11-26 12:00:30Z]}}

      assert raw_row(indexer.id) == before
    end

    test "a search's write afterwards keeps the last Test" do
      indexer = indexer!()
      {:written, _last_test} = IndexerStatus.record_test(indexer, :test_success, @now)
      :written = IndexerStatus.record(indexer, :timeout, at(60))

      assert IndexerStatus.last_test(IndexerStatus.read([indexer])[indexer.id]) ==
               %{outcome: :success, at: @now}
    end

    test "a status no Test reached has no last Test" do
      indexer = indexer!()
      :written = IndexerStatus.record(indexer, :timeout, @now)
      assert IndexerStatus.last_test(IndexerStatus.read([indexer])[indexer.id]) == nil
    end

    test "a Test started under an older config_version changes neither the row nor the last Test" do
      indexer = indexer!()
      {:written, _last_test} = IndexerStatus.record_test(indexer, {:http_status, 503}, @now)
      before = raw_row(indexer.id)
      before_test = IndexerStatus.last_test(IndexerStatus.read([indexer])[indexer.id])

      {:ok, edited} =
        Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/newznab/api"})

      assert IndexerStatus.record_test(indexer, :test_success, at(60)) == :dropped
      assert raw_row(indexer.id) == before
      assert IndexerStatus.last_test(IndexerStatus.read([edited])[edited.id]) == before_test

      # The control: a Test under the new version writes.
      assert {:written, %{outcome: :success}} =
               IndexerStatus.record_test(edited, :test_success, at(60))
    end

    test "a Test of a deleted indexer is dropped" do
      indexer = indexer!()
      :ok = Indexers.delete(nil, indexer.id)
      assert IndexerStatus.record_test(indexer, :test_success, @now) == :dropped
    end
  end

  defp last_success(indexer), do: IndexerStatus.read([indexer])[indexer.id].last_success_at

  # The row as SQLite stores it, every column in table order.
  defp raw_row(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT config_version, backoff, level, backoff_until, failures_in_row, last_failure, " <>
          "last_failure_code, last_failure_at, credentials_rejected, credentials_rejected_by, " <>
          "credentials_rejected_code, last_success_at " <>
          "FROM native_indexer_status WHERE configured_indexer_id = ?",
        [id]
      )

    rows
  end
end
