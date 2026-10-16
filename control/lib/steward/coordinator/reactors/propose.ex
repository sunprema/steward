defmodule Steward.Coordinator.Reactors.Propose do
  @moduledoc """
  Propose a branch (doc 13 §6.3, doc 07 §5.2). The checkpoint is the verdict
  recorded against the changeset.

      open_changeset ─ freeze ─ compute ─ record_computed ─ evaluate ─ floor
                                                                        │
                                                       **checkpoint** ◀─┘ ─▶ followup

    1. `open_changeset`: `Branch.propose` (`open → proposed`, a `computing`
       changeset, the previous one superseded), as the *caller*, so ownership and
       `branch:propose` are checked here. Compensable: the undo is
       `return_to_open`, which supersedes the changeset with `compute_failed`.
    2. `freeze`: `FreezeWrites`, 2 s. A timeout is not a failure: the branch is
       `proposed`, and the data plane will freeze from its next heartbeat reply
       (§6.3 f2).
    3. `compute`: `ComputeChangeset`, then wait for the `ChangesetReport`. A
       retryable failure is retried under the same changeset id, three attempts
       (doc 07 §5.2); past that, or on a non-retryable one, the reactor fails and
       step 1 is undone. A `base_snapshot_gone` error abandons the branch with
       `snapshot_lost` instead (§6.2 f3).
    4. `record_computed`: the report's summary, impact and digest onto the changeset.
    5. `evaluate`: `Steward.Coordinator.PolicyEvaluator` (E5). An evaluator that
       errors yields `hold` / `policy_error`, never a failed flow (§6.3 f5).
    6. `floor`: the revert conflict floor (doc 13 §6.6). It lives here, not in the
       policy engine.
    7. **`checkpoint`**: `Changeset.record_verdict`, the verdict and the
       `changeset.evaluated` event in one transaction. No undo.
    8. After it, best effort: `block` rejects the branch, `hold` enters the review
       queue, `auto-merge` starts the merge (E6; counted until it exists). Anything
       left undone is repaired by the minute reconciliation (§6.3 f7).

  `reply_to` and `ref` let the caller learn the changeset id as soon as step 1
  commits (the API answers 202 then); see `Steward.Coordinator.Flows.propose/1`.
  `resume: true` re-enters a branch already `proposed` with a `computing`
  changeset (a node died mid-flow), skipping the transition.
  """
  use Reactor

  alias Steward.Coordinator.Reactors.Propose.Steps

  input :org_id
  input :actor
  input :branch_id
  input :rationale
  input :trigger
  input :resume
  input :reply_to
  input :ref

  step :open_changeset, Steps.OpenChangeset do
    argument :org_id, input(:org_id)
    argument :actor, input(:actor)
    argument :branch_id, input(:branch_id)
    argument :rationale, input(:rationale)
    argument :trigger, input(:trigger)
    argument :resume, input(:resume)
    argument :reply_to, input(:reply_to)
    argument :ref, input(:ref)
  end

  step :freeze, Steps.Freeze do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
  end

  step :compute, Steps.Compute do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
    wait_for :freeze
    max_retries 2
  end

  step :record_computed, Steps.RecordComputed do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
    argument :report, result(:compute)
  end

  step :evaluate, Steps.Evaluate do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
    argument :report, result(:compute)
    argument :computed, result(:record_computed)
  end

  step :floor, Steps.Floor do
    argument :opened, result(:open_changeset)
    argument :report, result(:compute)
    argument :verdict, result(:evaluate)
  end

  step :checkpoint, Steps.Checkpoint do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
    argument :verdict, result(:floor)
  end

  step :followup, Steps.Followup do
    argument :org_id, input(:org_id)
    argument :opened, result(:open_changeset)
    argument :outcome, result(:checkpoint)
  end

  return :checkpoint

  defmodule Steps do
    @moduledoc false

    defmodule OpenChangeset do
      @moduledoc false
      use Reactor.Step

      require Ash.Query

      alias Steward.Coordinator.Branch, as: BranchProcess
      alias Steward.Coordinator.Reactors.Support
      alias Steward.Core.Branches.{Branch, Changeset}

      @impl true
      def run(%{resume: true} = args, _context, _opts) do
        with {:ok, branch} <- fetch(args),
             true <- branch.state == :proposed || {:error, :not_proposed},
             %Changeset{state: :computing} = changeset <- live_changeset(args) do
          announce(args, changeset)
          {:ok, %{branch: branch, changeset: changeset}}
        else
          {:error, _} = error -> error
          _ -> {:error, :nothing_to_resume}
        end
      end

      def run(%{org_id: org_id, branch_id: branch_id, actor: actor} = args, _context, _opts) do
        params = %{rationale: args.rationale, trigger: args.trigger || "propose"}

        case BranchProcess.transition(org_id, branch_id, :propose, params, actor: actor) do
          {:ok, branch} ->
            changeset = branch.__metadata__.changeset
            announce(args, changeset)
            {:ok, %{branch: branch, changeset: changeset}}

          {:error, _} = error ->
            error
        end
      end

      # A flow failing here changed nothing.
      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok

      # Doc 07 §5.2: the transition is compensated by returning to open with the failing
      # reason, which supersedes the changeset in the same transaction. If the branch has
      # since gone terminal (snapshot lost, abandoned), there is nothing to return to.
      @impl true
      def undo(%{branch: branch}, %{org_id: org_id}, _context, _opts) do
        case BranchProcess.transition(org_id, branch.id, :return_to_open, %{
               reason: :compute_failed
             }) do
          {:ok, _} ->
            :ok

          {:error, reason}
          when reason in [:invalid_transition, :terminal, :not_found, :stale_transition] ->
            :ok

          {:error, _} = error ->
            error
        end
      end

      defp fetch(%{org_id: org_id, branch_id: id}) do
        case Ash.get(Branch, id, tenant: org_id, actor: Support.system(org_id)) do
          {:ok, branch} -> {:ok, branch}
          {:error, _} -> {:error, :not_found}
        end
      end

      defp live_changeset(%{org_id: org_id, branch_id: id}) do
        Changeset
        |> Ash.Query.filter(branch_id == ^id and state != :superseded)
        |> Ash.read_one!(tenant: org_id, actor: Support.system(org_id))
      end

      defp announce(%{reply_to: pid, ref: ref}, changeset) when is_pid(pid),
        do: send(pid, {ref, :proposed, changeset})

      defp announce(_args, _changeset), do: :ok
    end

    defmodule Freeze do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Plane.V1

      # Never fails: "if it times out the control plane proceeds; the proxy will learn
      # `proposed` from its next heartbeat and write the freeze marker then" (doc 13 §6.3).
      @impl true
      def run(%{org_id: org_id, opened: %{branch: branch}}, _context, _opts) do
        freeze = %V1.FreezeWrites{branch_id: branch.id, overlay_id: branch.overlay_id}

        with {:ok, dp} <- Support.data_plane_for(org_id, branch.target_id),
             {:ok, _} <-
               Support.instruct(org_id, dp, Support.instruction({:freeze_writes, freeze}),
                 deadline_ms: 2_000
               ) do
          {:ok, :frozen}
        else
          _ -> {:ok, :unconfirmed}
        end
      end
    end

    defmodule Compute do
      @moduledoc false
      use Reactor.Step

      require Ash.Query

      alias Steward.Coordinator.Branch, as: BranchProcess
      alias Steward.Coordinator.Reactors.Support
      alias Steward.Coordinator.Reports
      alias Steward.Core.Targets.{ImpactQuery, TargetSettings}
      alias Steward.Plane.V1

      # One attempt: forget any report from the last one, ask, and wait for the new one.
      @impl true
      def run(%{org_id: org_id, opened: %{branch: branch, changeset: changeset}}, _context, _opts) do
        Reports.forget(changeset.id)

        with {:ok, dp} <- Support.data_plane_for(org_id, branch.target_id),
             :ok <- bump(org_id, changeset),
             {:ok, _} <-
               Support.instruct(
                 org_id,
                 dp,
                 Support.instruction({:compute_changeset, compute(org_id, branch, changeset)})
               ),
             {:ok, report} <- await(changeset.id) do
          classify(org_id, branch, report)
        end
      end

      # Retry a failure the data plane called retryable (or a lost reply) under the same
      # changeset id; `max_retries 2` on the step makes it three attempts. A
      # `snapshot_lost` abandon is final.
      @impl true
      def compensate(reason, _arguments, _context, _opts) do
        if retryable?(reason), do: :retry, else: :ok
      end

      defp retryable?({:compute_error, _code, true}), do: true
      defp retryable?(:data_plane_unreachable), do: true
      defp retryable?(:compute_timeout), do: true
      defp retryable?(_), do: false

      defp classify(org_id, branch, %{error: nil} = report),
        do: {:ok, report} |> tap(fn _ -> org_id && branch end)

      defp classify(org_id, branch, %{error: %{code: "base_snapshot_gone"}}) do
        # Doc 13 §6.2 f3: from any non-terminal state, reason `snapshot_lost`. The flow then
        # fails, and step 1's undo finds the branch terminal and leaves it be.
        BranchProcess.transition(org_id, branch.id, :lose_snapshot, %{
          reason: :snapshot_lost,
          terminal_by_job: "propose"
        })

        {:error, :snapshot_lost}
      end

      defp classify(_org_id, _branch, %{error: error}),
        do: {:error, {:compute_error, error.code, error.retryable}}

      defp await(changeset_id) do
        case Reports.await(changeset_id, wait_ms()) do
          {:ok, report} -> {:ok, report}
          {:error, :timeout} -> {:error, :compute_timeout}
        end
      end

      defp wait_ms,
        do:
          Application.get_env(:steward, Steward.Coordinator, [])
          |> Keyword.get(:compute_wait_ms, 100_000)

      defp bump(org_id, changeset) do
        changeset
        |> Ash.Changeset.for_update(:bump_compute_attempts, %{},
          tenant: org_id,
          actor: Support.system(org_id)
        )
        |> Ash.update()
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end
      end

      defp compute(org_id, branch, changeset) do
        actor = Support.system(org_id)

        impact =
          ImpactQuery
          |> Ash.Query.filter(target_id == ^branch.target_id)
          |> Ash.read!(tenant: org_id, actor: actor)
          |> Enum.map(
            &%V1.ImpactQuery{id: &1.id, name: &1.name, sql: &1.sql, timeout_s: &1.timeout_s}
          )

        %V1.ComputeChangeset{
          changeset_id: changeset.id,
          branch_id: branch.id,
          overlay_id: branch.overlay_id,
          base_snapshot_ref: branch.base_snapshot_ref,
          impact_queries: impact,
          assertion_budget_s: assertion_budget(org_id, branch.target_id, actor),
          revert_of_merge_id: branch.revert_of_merge_id && to_string(branch.revert_of_merge_id)
        }
      end

      defp assertion_budget(org_id, target_id, actor) do
        case Ash.get(TargetSettings, target_id, tenant: org_id, actor: actor) do
          {:ok, %{assertion_budget_s: s}} -> s
          _ -> 60
        end
      end
    end

    defmodule RecordComputed do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Plane.Wire
      alias Steward.Coordinator.Reactors.Support

      @impl true
      def run(%{org_id: org_id, opened: %{changeset: changeset}, report: report}, _context, _opts) do
        changeset
        |> Ash.Changeset.for_update(:record_computed, Wire.computed_attrs(report),
          tenant: org_id,
          actor: Support.system(org_id)
        )
        |> Ash.update()
      end
    end

    defmodule Evaluate do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.PolicyEvaluator

      # An evaluator that errors holds the changeset rather than failing the flow, and
      # never passes it silently (doc 13 §6.3 f5, doc 06 §5.1).
      @impl true
      def run(
            %{org_id: org_id, opened: %{branch: branch}, computed: computed, report: report},
            _context,
            _opts
          ) do
        case PolicyEvaluator.impl().evaluate(org_id, branch, computed, report) do
          {:ok, verdict} -> {:ok, verdict}
          {:error, _} -> {:ok, policy_error()}
        end
      rescue
        _ -> {:ok, policy_error()}
      end

      defp policy_error,
        do: %{
          outcome: :hold,
          reason: :policy_error,
          policy_outcome: :hold,
          policy_version_ids: [],
          control_plane_ms: 0,
          data_plane_ms: 0
        }
    end

    defmodule Floor do
      @moduledoc false
      use Reactor.Step

      # Doc 13 §6.6: a revert whose changeset has conflicts (or partial keys) is at least
      # `hold`, whatever the policies said. The policy outcome is kept as it was.
      @impl true
      def run(%{opened: %{branch: branch}, report: report, verdict: verdict}, _context, _opts) do
        conflicted? =
          report.conflicts_count > 0 or (report.summary && report.summary.partial_keys_count > 0)

        if branch.revert_of_merge_id && conflicted? && verdict.outcome == :"auto-merge",
          do: {:ok, %{verdict | outcome: :hold, reason: :revert_conflict}},
          else: {:ok, verdict}
      end
    end

    defmodule Checkpoint do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Core.Branches.Changeset

      # The checkpoint (doc 13 §6.3 step 9). No `undo/4`, by design (doc 07 §5.0).
      # Earlier steps updated the changeset behind the copy this flow holds, so it is
      # read afresh: the caller gets the row as stored (summary, attempts, ...).
      @impl true
      def run(
            %{org_id: org_id, opened: %{changeset: changeset}, verdict: verdict},
            _context,
            _opts
          ) do
        actor = Support.system(org_id)

        with {:ok, fresh} <- Ash.get(Changeset, changeset.id, tenant: org_id, actor: actor),
             {:ok, evaluated} <-
               fresh
               |> Ash.Changeset.for_update(:record_verdict, %{verdict: verdict},
                 tenant: org_id,
                 actor: actor
               )
               |> Ash.update() do
          {:ok, %{changeset: evaluated, verdict: evaluated.__metadata__.verdict}}
        end
      end
    end

    defmodule Followup do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      alias Steward.Coordinator.Branch, as: BranchProcess
      alias Steward.Coordinator.Reactors.Support
      alias Steward.Core.Branches.QueueEntry

      def attempt(
            %{
              org_id: org_id,
              opened: %{branch: branch},
              outcome: %{changeset: changeset, verdict: verdict}
            },
            _context,
            _opts
          ) do
        case verdict.outcome do
          :block ->
            # `block` is terminal for the branch, not merely the changeset (doc 13 §4).
            case BranchProcess.transition(org_id, branch.id, :reject, %{
                   reason: :verdict_block,
                   terminal_by_job: "policy"
                 }) do
              {:ok, _} -> :ok
              {:error, _} = error -> error
            end

          :hold ->
            QueueEntry
            |> Ash.Changeset.for_create(
              :upsert,
              %{
                target_id: branch.target_id,
                changeset_id: changeset.id,
                branch_id: branch.id,
                principal_id: branch.principal_id,
                hold_reasons: [%{reason: verdict.reason}]
              },
              tenant: org_id,
              actor: Support.system(org_id)
            )
            |> Ash.create()
            |> case do
              {:ok, _} -> :ok
              {:error, _} = error -> error
            end

          :"auto-merge" ->
            # The `Merge` reactor arrives with E6; the minute reconciliation will start the
            # merge for an evaluated auto-merge verdict with no merge row.
            :telemetry.execute([:steward, :reactor, :merge_start_deferred], %{count: 1}, %{
              branch_id: branch.id
            })

            :ok
        end
      end
    end
  end
end
