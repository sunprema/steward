defmodule Steward.Coordinator.Plane do
  @moduledoc """
  The control plane's side of the `steward.plane.v1.Session` stream, below the
  gRPC framing (doc 10 §5, doc 07 §3.1): who is connected, what was asked of
  them, and what came back. The gRPC service (`StewardWeb.Plane.Server`) is a
  thin shell over this; everything here runs and tests without a socket.

    * **Sessions.** One `Plane.Session` process per data-plane identity, started
      on demand and outliving any one stream. It holds the instructions
      awaiting a result, so a reconnect finds them and re-sends.
    * **Instructions.** `send_instruction/4` is how a Reactor or the branch
      coordinator asks the data plane to do something; it returns when the
      `InstructionResult` arrives or the reply deadline passes. Never call it
      inside an Ash action's transaction (doc 13 invariant 10).
    * **Upstream.** `Plane.Upstream` handles what the data plane sends.

  One node today: the stream's handler and its session must be on the same node.
  Routing an instruction to the node that holds the stream (`:pg`, doc 07 §4) is
  not built yet.
  """
  alias Steward.Coordinator.Plane.Session

  @registry Steward.Coordinator.Plane.Registry
  @sessions Steward.Coordinator.Plane.Sessions

  def registry, do: @registry
  def sessions, do: @sessions

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Registry, keys: :unique, name: @registry},
             {DynamicSupervisor, strategy: :one_for_one, name: @sessions}
           ],
           [strategy: :one_for_all]
         ]}
    }
  end

  # Reply deadlines by instruction kind (doc 07 §3.2, doc 10 §5): freeze 2 s,
  # overlay init 10 s, compute 15 min, everything else 5 s.
  @deadlines %{freeze_writes: 2_000, initialise_overlay: 10_000, compute_changeset: 15 * 60_000}
  @default_deadline 5_000

  @doc "The reply deadline in milliseconds for an instruction."
  def deadline_ms(%{body: {kind, _}}), do: Map.get(@deadlines, kind, @default_deadline)

  @doc """
  Sends `instruction` to the data plane `data_plane_id` (of `org_id`) and waits
  for its `InstructionResult`.

    * `{:ok, %InstructionResult{}}`: the data plane answered, successfully or not
      (`result.ok`).
    * `{:error, :timeout}`: no answer by the deadline (`opts[:deadline_ms]`,
      default by kind). While the stream is down the instruction waits, and is
      re-sent on reconnect with the same `instruction_id`, until the deadline.

  The caller owns the retry budget (doc 13 §6): a retry of an instruction whose
  *effect* must not repeat uses a fresh id and fresh ids in its body; a re-send
  of the same instruction is the queue's job.
  """
  def send_instruction(org_id, data_plane_id, instruction, opts \\ []) do
    {instruction, deadline} = prepare(instruction, opts)
    session = session!(org_id, data_plane_id)
    GenServer.call(session, {:send, instruction, deadline, {:call, nil}}, deadline + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  As `send_instruction/4`, without waiting: returns `{:ok, instruction_id}` and
  later sends `{:instruction_result, id, {:ok, result} | {:error, :timeout}}` to
  `opts[:reply_to]` (default the caller).
  """
  def send_async(org_id, data_plane_id, instruction, opts \\ []) do
    {instruction, deadline} = prepare(instruction, opts)
    reply_to = Keyword.get(opts, :reply_to, self())
    session = session!(org_id, data_plane_id)
    :ok = GenServer.call(session, {:send, instruction, deadline, {:cast, reply_to}})
    {:ok, instruction.instruction_id}
  end

  @doc """
  Attaches a stream handler process to the identity's session, superseding any
  earlier stream (a data plane keeps exactly one open, doc 10 §5), and re-sends
  what is still waiting. `{:error, :wrong_org}` if the identity belongs to
  another org's session.
  """
  def attach(org_id, data_plane_id, handler) when is_pid(handler) do
    GenServer.call(session!(org_id, data_plane_id), {:attach, org_id, handler})
  end

  @doc "Routes an `InstructionResult` from the stream to its waiting caller."
  def deliver_result(data_plane_id, %Steward.Plane.V1.InstructionResult{} = result) do
    case whereis(data_plane_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:result, result})
    end
  end

  @doc "Is a stream attached for this data plane?"
  def connected?(data_plane_id) do
    case whereis(data_plane_id) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  @doc "Instruction ids still waiting for a result, oldest first. For tests and operators."
  def pending(data_plane_id) do
    case whereis(data_plane_id) do
      nil -> []
      pid -> GenServer.call(pid, :pending)
    end
  end

  def whereis(data_plane_id) do
    case Registry.lookup(@registry, data_plane_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp prepare(%Steward.Plane.V1.Instruction{} = instruction, opts) do
    id =
      if instruction.instruction_id in [nil, ""],
        do: Ash.UUIDv7.generate(),
        else: instruction.instruction_id

    {%{instruction | instruction_id: id},
     Keyword.get(opts, :deadline_ms, deadline_ms(instruction))}
  end

  defp session!(org_id, data_plane_id) do
    case whereis(data_plane_id) do
      pid when is_pid(pid) ->
        pid

      nil ->
        spec = %{
          id: {Session, data_plane_id},
          start: {Session, :start_link, [{org_id, data_plane_id}]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(@sessions, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
