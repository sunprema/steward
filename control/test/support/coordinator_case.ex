defmodule Steward.CoordinatorCase do
  @moduledoc """
  Setup for tests that run branch processes: a shared sandbox (the processes
  query from their own pids), every process stopped after the test, and a
  `heartbeat_actions` module that records what the matrix asked for instead of
  doing it (`Steward.CoordinatorCase.RecordingActions`, messages `{:action,
  action, ctx}` to the test process).

  Also the bridge between protobuf heartbeats and the coordinator's maps, which
  E3's `Session` service will own; here it lets the fake data plane talk to the
  real coordinator.
  """
  use ExUnit.CaseTemplate

  alias Steward.FakeDataPlane.Matrix
  alias Steward.Plane.V1

  using do
    quote do
      import Steward.AuthzFixtures
      import Steward.CoordinatorCase

      alias Steward.Coordinator
      alias Steward.Coordinator.Branch, as: BranchProcess
      alias Steward.Core.Authz.System
      alias Steward.Core.Branches.Branch
    end
  end

  setup tags do
    Steward.DataCase.setup_sandbox(Map.put(tags, :async, false))
    on_exit(&stop_all/0)
    :ok
  end

  defmodule RecordingActions do
    @moduledoc false
    @behaviour Steward.Coordinator.HeartbeatActions

    @impl true
    def execute(action, ctx) do
      case :persistent_term.get({__MODULE__, :to}, nil) do
        nil -> :ok
        pid -> send(pid, {:action, action, ctx})
      end

      :ok
    end
  end

  @doc "Routes the matrix's actions to the calling test and reports them as done."
  def record_actions do
    previous = Application.get_env(:steward, Steward.Coordinator, [])
    :persistent_term.put({RecordingActions, :to}, self())

    Application.put_env(
      :steward,
      Steward.Coordinator,
      Keyword.put(previous, :heartbeat_actions, RecordingActions)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:steward, Steward.Coordinator, previous)
      :persistent_term.erase({RecordingActions, :to})
    end)
  end

  def stop_all do
    for {_id, pid, _org} <-
          Registry.select(Steward.Coordinator.Registry, [
            {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
          ]) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end
  end

  def eventually(fun, tries \\ 100) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # --- protobuf <-> coordinator maps (E3 owns the real ones) -------------------

  @doc "A `steward.plane.v1.Heartbeat` as the map `Steward.Coordinator.Heartbeat.handle/2` takes."
  def from_proto(%V1.Heartbeat{} = hb) do
    %{
      branch_id: hb.branch_id,
      overlay_id: hb.overlay_id,
      believed: Matrix.from_proto_believed(hb.believed_state),
      merge_progress:
        hb.merge_progress &&
          %{
            merge_id: hb.merge_progress.merge_id,
            rows_confirmed: hb.merge_progress.rows_confirmed,
            rows_total: hb.merge_progress.rows_total,
            complete: hb.merge_progress.complete,
            compensation_persisted: hb.merge_progress.compensation_persisted
          }
    }
  end

  @doc "The coordinator's reply as a `steward.plane.v1.HeartbeatReply`."
  def to_proto(%V1.Heartbeat{} = hb, reply) do
    %V1.HeartbeatReply{
      branch_id: hb.branch_id,
      overlay_id: hb.overlay_id,
      authoritative_state: Matrix.to_proto_authoritative(reply.authoritative),
      lease_renewed: reply.lease_renewed,
      freeze: reply.freeze,
      stale: reply.stale
    }
  end
end
