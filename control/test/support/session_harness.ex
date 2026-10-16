defmodule Steward.SessionHarness do
  @moduledoc """
  The real `Session` listener with the E13 fake data plane dialled into it, for
  tests of flows that talk to a data plane (doc 07 §10: "fake data plane ...
  integration tests covering every failure row of doc 13 §6").

      setup_all do
        Steward.SessionHarness.start_listener()   # the shared listener's address
      end

      setup ctx do
        Steward.SessionHarness.world(ctx)   # org, principals, data plane, target, connected fake
      end

  """
  import ExUnit.Callbacks
  import Steward.AuthzFixtures
  import Steward.CoordinatorCase, only: [eventually: 1]

  alias Steward.Coordinator.Plane
  alias Steward.FakeDataPlane

  @doc """
  The shared plaintext listener, started once for the whole run by `test_helper.exs`.

  One Ranch listener name per VM is all there is (it derives from the endpoint
  module), so server-based test modules share this one instead of each starting and
  stopping its own, which races at module boundaries. The mTLS tests, which need a
  different configuration, swap it out with `stop_shared/0` and `start_shared/0`.
  """
  def start_shared do
    port = free_port()
    {:ok, pid} = GRPC.Server.Supervisor.start_link(StewardWeb.Plane.supervisor_opts(port: port))
    Process.unlink(pid)
    :persistent_term.put({__MODULE__, :shared}, %{address: "127.0.0.1:#{port}", pid: pid})
    :ok
  end

  def stop_shared do
    case :persistent_term.get({__MODULE__, :shared}, nil) do
      %{pid: pid} ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          5_000 -> Process.exit(pid, :kill)
        end

        :persistent_term.erase({__MODULE__, :shared})

      nil ->
        :ok
    end
  end

  @doc "Use in `setup_all`: the context gains `:address`."
  def start_listener do
    if :persistent_term.get({__MODULE__, :shared}, nil) == nil, do: start_shared()
    %{address: :persistent_term.get({__MODULE__, :shared}).address}
  end

  @doc """
  An org with an agent (owner, holding a key with `branch:write` and
  `branch:propose` on the target), a human `target_admin`, a data plane, a target
  served by it, and a fake data plane connected to the listener.
  """
  def world(%{address: address}) do
    org = org()
    admin = principal(org, :human, org_admin: true)
    agent = principal(org, :agent)
    dp = data_plane(org)
    target = target(org, admin, data_plane_id: dp.id)

    key = api_key(org, agent, ~w(branch:write branch:propose changeset:read), [target.id])
    t_admin = principal(org, :human)
    membership(org, target, t_admin, :target_admin, admin)

    {:ok, fake} = FakeDataPlane.start_link(data_plane_id: dp.id, transport: {:grpc, address, []})
    on_exit(fn -> if Process.alive?(fake), do: GenServer.stop(fake) end)
    eventually(fn -> FakeDataPlane.connected?(fake) and Plane.connected?(dp.id) end)

    %{
      org: org,
      admin: admin,
      agent: agent,
      key: key,
      t_admin: human_actor(t_admin),
      dp: dp,
      target: target,
      fake: fake
    }
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
