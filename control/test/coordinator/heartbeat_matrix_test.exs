defmodule Steward.Coordinator.HeartbeatMatrixTest do
  @moduledoc """
  Doc 13 §6.8, the control plane's half: all 40 `(believed, authoritative)`
  cells, generated from the `HeartbeatMatrix` declaration and checked against
  `test/support/heartbeat_matrix.exs`, which is what reviewers diff against the
  doc's table (doc 07 §10).
  """
  use Steward.LifecycleMatrixCase,
    matrix: Steward.Coordinator.HeartbeatMatrix,
    expectations: "test/support/heartbeat_matrix.exs"

  alias Steward.Coordinator.HeartbeatMatrix

  describe "actions gated by merge progress (doc 13 §6.5, §6.8)" do
    test "the lease is renewed only while progress advances" do
      stalled = %{advancing: false, complete: false, compensation_persisted: true}
      moving = %{stalled | advancing: true}

      assert {_, []} = HeartbeatMatrix.decide(:merging, :merging, stalled)
      assert {_, [:renew_lease]} = HeartbeatMatrix.decide(:merging, :merging, moving)
      assert {_, []} = HeartbeatMatrix.decide(:merging, :merging, nil)
    end

    test "the branch advances to merged only when the apply is complete and the compensation persisted" do
      done = %{advancing: false, complete: true, compensation_persisted: true}

      assert {_, [:advance_merged]} = HeartbeatMatrix.decide(:done, :merging, done)
      assert {_, []} = HeartbeatMatrix.decide(:done, :merging, %{done | complete: false})

      assert {_, []} =
               HeartbeatMatrix.decide(:done, :merging, %{done | compensation_persisted: false})

      assert {_, []} = HeartbeatMatrix.decide(:done, :merging, nil)
    end

    test "an alert is never conditional" do
      assert {_, [:alert]} = HeartbeatMatrix.decide(:done, :open, nil)
    end
  end

  describe "freeze" do
    test "the reply asks the data plane to freeze exactly while the branch is proposed or merging" do
      for authoritative <- [:unknown, :open, :merged, :rejected, :abandoned, :closed] do
        {reply, _} = HeartbeatMatrix.decide(:open, authoritative, nil)
        refute reply.freeze, "#{authoritative}"
      end

      for authoritative <- [:proposed, :merging] do
        {reply, _} = HeartbeatMatrix.decide(:open, authoritative, nil)
        assert reply.freeze, "#{authoritative}"
      end
    end
  end

  describe "the alert cells are the ones doc 13 §6.8 marks" do
    test "exactly these ten" do
      alerts =
        for %{believed: b, authoritative: a, actions: actions} <- HeartbeatMatrix.cells(),
            :alert in actions,
            do: {b, a}

      assert Enum.sort(alerts) ==
               Enum.sort([
                 {:merging, :unknown},
                 {:merging, :open},
                 {:merging, :rejected},
                 {:merging, :abandoned},
                 {:done, :open},
                 {:done, :proposed},
                 {:dead, :open},
                 {:dead, :proposed},
                 {:dead, :merging}
               ])
    end
  end
end
