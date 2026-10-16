defmodule Steward.Coordinator.StateMachineDeclarationTest do
  @moduledoc """
  The `Branch` state machine is exactly doc 13 §2.1's table (doc 07 §10):
  declared transitions equal the doc's, and every `(state, action)` pair is
  either allowed and works, or refused and changes nothing. Doc 13 §2.1:
  "A branch **must not** move from a terminal state to any state other than
  `closed`."
  """
  use Steward.DataCase, async: false

  import Steward.AuthzFixtures

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch

  @states [:open, :proposed, :merging, :merged, :rejected, :abandoned, :closed]
  @terminal [:merged, :rejected, :abandoned, :closed]

  # Doc 13 §2.1, one row per allowed from → to. The creation edge `[*] → open`
  # is the initial state.
  @doc_edges MapSet.new([
               {:open, :proposed},
               {:open, :abandoned},
               {:proposed, :open},
               {:proposed, :merging},
               {:proposed, :rejected},
               {:proposed, :abandoned},
               {:merging, :merged},
               {:merging, :proposed},
               {:merging, :abandoned},
               {:merged, :closed},
               {:rejected, :closed},
               {:abandoned, :closed}
             ])

  # The action that makes each doc edge, and the rows of the table it appears in.
  @edge_action %{
    {:open, :proposed} => :propose,
    {:proposed, :open} => :return_to_open,
    {:proposed, :merging} => :start_merge,
    {:proposed, :rejected} => :reject,
    {:open, :abandoned} => :abandon,
    {:proposed, :abandoned} => :abandon,
    {:merging, :merged} => :complete_merge,
    {:merging, :proposed} => :fail_merge,
    {:merging, :abandoned} => :lose_snapshot,
    {:merged, :closed} => :close,
    {:rejected, :closed} => :close,
    {:abandoned, :closed} => :close
  }

  test "the declared transitions are exactly doc 13 §2.1's" do
    declared =
      for t <- AshStateMachine.Info.state_machine_transitions(Branch),
          from <- List.wrap(t.from),
          to <- List.wrap(t.to),
          into: MapSet.new(),
          do: {from, to}

    assert declared == @doc_edges
  end

  test "the states are doc 02's seven, entered through `open`" do
    assert Enum.sort(AshStateMachine.Info.state_machine_all_states(Branch)) == Enum.sort(@states)
    assert AshStateMachine.Info.state_machine_initial_states!(Branch) == [:open]
  end

  test "terminal states lead only to `closed`" do
    for {from, to} <- @doc_edges, from in @terminal, do: assert(to == :closed)
  end

  # --- behaviour -------------------------------------------------------------

  @actions [
    :propose,
    :return_to_open,
    :start_merge,
    :reject,
    :abandon,
    :lose_snapshot,
    :complete_merge,
    :fail_merge,
    :close
  ]

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    %{org: org, owner: owner, target: target}
  end

  defp apply!(ctx, record, action, params) do
    record
    |> Ash.Changeset.for_update(action, params,
      tenant: ctx.org.id,
      actor: System.new(:coordinator, ctx.org.id)
    )
    |> Ash.update!()
  end

  defp params(_ctx, :start_merge), do: %{merge_id: uuid()}
  defp params(_ctx, :complete_merge), do: %{merge_id: uuid(), terminal_by_job: "test"}
  defp params(_ctx, :reject), do: %{reason: :review_rejected, terminal_by_job: "test"}

  defp params(ctx, :abandon),
    do: %{reason: :abandoned_by_principal, terminal_by_principal_id: ctx.owner.id}

  defp params(_ctx, :lose_snapshot), do: %{reason: :snapshot_lost, terminal_by_job: "test"}
  defp params(_ctx, :fail_merge), do: %{reason: :stale_base}

  defp params(_ctx, :close),
    do: %{overlay_released_at: DateTime.utc_now(), terminal_by_job: "test"}

  defp params(_ctx, _), do: %{}

  # Drives a fresh branch to `state` along legal edges only.
  defp branch_in(ctx, state) do
    b = branch(ctx.org, ctx.target, ctx.owner)

    path =
      case state do
        :open -> []
        :proposed -> [:propose]
        :merging -> [:propose, :start_merge]
        :merged -> [:propose, :start_merge, :complete_merge]
        :rejected -> [:propose, :reject]
        :abandoned -> [:abandon]
        :closed -> [:abandon, :close]
      end

    Enum.reduce(path, b, fn action, record -> apply!(ctx, record, action, params(ctx, action)) end)
  end

  for state <- @states, action <- @actions do
    test "#{state} × #{action}", ctx do
      allowed? =
        Enum.any?(unquote(Macro.escape(@edge_action)), fn {{from, _to}, a} ->
          a == unquote(action) and from == unquote(state)
        end) or
          (unquote(action) == :lose_snapshot and unquote(state) in [:open, :proposed, :merging])

      record = branch_in(ctx, unquote(state))
      assert record.state == unquote(state)

      result =
        record
        |> Ash.Changeset.for_update(unquote(action), params(ctx, unquote(action)),
          tenant: ctx.org.id,
          actor: System.new(:coordinator, ctx.org.id)
        )
        |> Ash.update()

      if allowed? do
        assert {:ok, updated} = result
        assert updated.state != unquote(state) or unquote(state) == :proposed
        assert {unquote(state), updated.state} in @doc_edges
      else
        assert {:error, _} = result
        reloaded = Ash.get!(Branch, record.id, tenant: ctx.org.id, authorize?: false)
        assert reloaded.state == unquote(state)
        assert reloaded.lock_version == record.lock_version
      end
    end
  end

  test "every transition carries a reason into a terminal state (doc 13 invariant 16)", ctx do
    for {action, state} <- [abandon: :abandoned, reject: :rejected] do
      record = branch_in(ctx, if(state == :rejected, do: :proposed, else: :open))
      updated = apply!(ctx, record, action, params(ctx, action))
      assert updated.state == state
      assert updated.reason != nil
      assert updated.terminal_at != nil
    end
  end

  test "a transition without a reason into a terminal state is refused by the database", ctx do
    record = branch_in(ctx, :open)

    error = assert_raise Ash.Error.Invalid, fn -> apply!(ctx, record, :abandon, %{}) end
    assert Exception.message(error) =~ "state"
    assert Ash.get!(Branch, record.id, tenant: ctx.org.id, authorize?: false).state == :open
  end
end
