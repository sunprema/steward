defmodule Steward.Coordinator do
  @moduledoc """
  The branch coordinator (doc 07 §4, §5): one process per non-terminal branch,
  the registry that finds it, the supervisors that run it, the sweeps that keep
  processes and rows in step, and the heartbeat matrix (doc 13 §6.8).

  Process state is a cache of the `Branch` row, never a second copy of truth
  (doc 13 invariant 1): a process can be killed and rebuilt from Postgres at
  any time, and every transition is an Ash action whose result refreshes the
  cache. This namespace may depend on `Steward.Core` and never the reverse, so
  an Ash action cannot reach a process or a remote call (doc 13 invariant 10).

  Supervision tree (started by `Steward.Application`):

      Steward.Coordinator.Supervisor
      ├── Registry (Steward.Coordinator.Registry, unique, key: branch id)
      ├── PartitionSupervisor (Steward.Coordinator.BranchSupervisors)
      │     └── DynamicSupervisor × schedulers
      │           └── Steward.Coordinator.Branch × non-terminal branches
      ├── Steward.Coordinator.HeartbeatFlusher
      ├── Steward.Coordinator.Plane (stream registry + Plane.Session per data plane)
      └── Steward.Coordinator.BootSweeper (unless disabled in config)

  The `Session` stream (E3): `Steward.Coordinator.Plane` holds the per-identity
  sessions and the instruction queue, `Plane.Upstream` handles what data planes
  send, and `HeartbeatFlusher` writes heartbeat times in batches. The gRPC shell
  around them is `StewardWeb.Plane.Server`.

  Not here yet: Reactors (E4), the merge lease and `Merge` handling behind `:renew_lease`/`:advance_merged`/
  `:resend_merge` (E6), AshOban scheduling of `TerminalProcessSweep`, and
  cross-node uniqueness (`:pg`); this runs one node.
  """
  use Boundary,
    deps: [
      Steward.Core,
      Steward.Core.Branches,
      Steward.Core.Targets,
      Steward.Core.Authz,
      Steward.Core.Types
    ],
    exports: [
      Branch,
      HeartbeatMatrix,
      BootSweeper,
      TerminalProcessSweep,
      Heartbeat,
      HeartbeatActions,
      Lifecycle,
      Plane,
      Plane.Upstream,
      Plane.Wire,
      Plane.Limiter,
      Plane.Handlers,
      Plane.Directory,
      HeartbeatFlusher
    ]

  alias Steward.Coordinator.{Branch, BootSweeper, HeartbeatFlusher, Plane, Reports}

  @registry Steward.Coordinator.Registry
  @supervisors Steward.Coordinator.BranchSupervisors

  def registry, do: @registry
  def supervisors, do: @supervisors

  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Options: `:boot_sweep` (default from `config :steward, Steward.Coordinator,
  boot_sweep: true`): stream every non-terminal branch into a process before
  the node reports ready.
  """
  def start_link(opts \\ []) do
    boot_sweep? =
      Keyword.get_lazy(opts, :boot_sweep, fn ->
        Application.get_env(:steward, __MODULE__, []) |> Keyword.get(:boot_sweep, true)
      end)

    children =
      [
        {Registry, keys: :unique, name: @registry},
        {PartitionSupervisor, child_spec: DynamicSupervisor, name: @supervisors},
        HeartbeatFlusher,
        Plane,
        Reports,
        {Task.Supervisor, name: Steward.Coordinator.FlowTasks}
      ] ++ if(boot_sweep?, do: [BootSweeper], else: [])

    Supervisor.start_link(children, strategy: :rest_for_one, name: Steward.Coordinator.Supervisor)
  end

  @doc "The pid of the process for `branch_id`, or nil."
  def whereis(branch_id) do
    case Registry.lookup(@registry, branch_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Number of branch processes running on this node."
  def count, do: Registry.count(@registry)

  @doc "Starts (idempotently) the process for a branch. See `Steward.Coordinator.Branch.ensure_started/2`."
  defdelegate ensure_started(org_id, branch_id), to: Branch
end
