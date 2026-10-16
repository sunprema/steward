defmodule Steward.Coordinator.Flows do
  @moduledoc """
  The entry points for the branch lifecycle flows (doc 07 §5.1–5.2, doc 13 §6): the
  functions a controller or a job calls. Each runs one Reactor from
  `Steward.Coordinator.Reactors`, whose steps do the work; nothing here is a
  transaction.

  Inputs are ids and the actor, never loaded records, so a flow re-reads state
  through actions (doc 07 §5.0).
  """
  require Ash.Query

  alias Steward.Coordinator.Reactors.{Abandon, CreateBranch, Propose, Withdraw}
  alias Steward.Core.Authz
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch

  @tasks Steward.Coordinator.FlowTasks

  def tasks, do: @tasks

  @doc """
  Creates a branch. `params`: `:org_id`, `:actor`, `:target_id`, `:idempotency_key`,
  optionally `:copy_overlay_from`.

  A repeat of a call that already created a branch returns that branch (doc 13
  §6.1 f7). A repeat after a failure runs the flow again with fresh ids (§6.1,
  "Retry with fresh IDs"). `{:error, reason}` otherwise, `reason` being an Ash
  error from the intent (authorisation, validation), `:target_not_found`,
  `:no_data_plane`, `:data_plane_unreachable`, `{:rejected, code}`.
  """
  def create_branch(%{org_id: org_id, actor: actor, idempotency_key: key} = params) do
    case existing(org_id, Authz.principal_id(actor), key) do
      %Branch{} = branch ->
        {:ok, branch}

      nil ->
        inputs = %{
          org_id: org_id,
          actor: actor,
          target_id: params.target_id,
          idempotency_key: key,
          copy_overlay_from: Map.get(params, :copy_overlay_from)
        }

        case Reactor.run(CreateBranch, inputs) do
          {:ok, %Branch{} = branch} -> {:ok, branch}
          {:error, errors} -> {:error, unwrap(errors)}
        end
    end
  end

  @doc """
  Proposes a branch. Returns `{:ok, changeset}` as soon as the branch is `proposed`
  and the `computing` changeset exists (the API answers 202 with its id), while the
  flow continues in the background under `tasks/0`. `{:error, reason}` if that
  first step failed, in which case nothing changed.

  `params`: `:org_id`, `:actor`, `:branch_id`, optionally `:rationale`, `:trigger`.
  Pass `await: :finished` to wait for the whole flow instead and get
  `{:ok, %{changeset:, verdict:}}`.
  """
  def propose(%{org_id: _, actor: _, branch_id: _} = params, opts \\ []) do
    run_propose(params, opts, false)
  end

  @doc """
  Re-enters `Propose` for a branch left `proposed` with a `computing` changeset by
  a flow that died (the minute reconciliation calls this; doc 13 §6.3 f3).
  """
  def resume_propose(%{org_id: _, branch_id: _} = params, opts \\ []) do
    run_propose(Map.put_new(params, :actor, System.new(:coordinator, params.org_id)), opts, true)
  end

  defp run_propose(params, opts, resume?) do
    ref = make_ref()
    caller = self()

    inputs = %{
      org_id: params.org_id,
      actor: params.actor,
      branch_id: params.branch_id,
      rationale: Map.get(params, :rationale),
      trigger: Map.get(params, :trigger),
      resume: resume?,
      reply_to: caller,
      ref: ref
    }

    {:ok, _pid} =
      Task.Supervisor.start_child(@tasks, fn ->
        send(caller, {ref, :finished, Reactor.run(Propose, inputs)})
      end)

    await_propose(ref, Keyword.get(opts, :await, :proposed), Keyword.get(opts, :timeout, 30_000))
  end

  defp await_propose(ref, :proposed, timeout) do
    receive do
      {^ref, :proposed, changeset} -> {:ok, changeset}
      {^ref, :finished, {:error, errors}} -> {:error, unwrap(errors)}
      {^ref, :finished, {:ok, _}} -> {:error, :finished_without_announcing}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp await_propose(ref, :finished, timeout) do
    receive do
      {^ref, :finished, {:ok, result}} -> {:ok, result}
      {^ref, :finished, {:error, errors}} -> {:error, unwrap(errors)}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Withdraws a proposed branch. `params`: `:org_id`, `:actor`, `:branch_id`."
  def withdraw(%{org_id: _, actor: _, branch_id: _} = params), do: run(Withdraw, params)

  @doc """
  Abandons a branch. `params`: `:org_id`, `:actor`, `:branch_id`, optionally
  `:reason` (default `abandoned_by_principal`) and `:terminal_by_job` (for a job
  running as a system actor). `{:error, :merge_in_progress}` for a `merging` branch.
  """
  def abandon(%{org_id: _, actor: _, branch_id: _} = params) do
    run(Abandon, %{
      org_id: params.org_id,
      actor: params.actor,
      branch_id: params.branch_id,
      reason: Map.get(params, :reason),
      terminal_by_job: Map.get(params, :terminal_by_job)
    })
  end

  defp run(reactor, inputs) do
    case Reactor.run(reactor, inputs) do
      {:ok, result} -> {:ok, result}
      {:error, errors} -> {:error, unwrap(errors)}
    end
  end

  defp existing(org_id, principal_id, key) do
    Branch
    |> Ash.Query.filter(principal_id == ^principal_id and idempotency_key == ^key)
    |> Ash.read_one!(tenant: org_id, actor: System.new(:coordinator, org_id))
  end

  # Reactor wraps the step's error; callers want the step's own reason.
  defp unwrap(%{errors: [first | _]}), do: unwrap(first)
  defp unwrap(%Reactor.Error.Invalid.RunStepError{error: error}), do: unwrap(error)
  defp unwrap(other), do: other
end
