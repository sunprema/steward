defmodule Steward.Coordinator.Plane.Session do
  @moduledoc """
  The state of one data-plane identity on the control plane (doc 10 §5): the
  stream handler currently attached, if any, and the instructions waiting for a
  result. It outlives streams, which is what lets a reconnect re-send.

  An instruction is *pending* from `send` until its `InstructionResult` arrives
  or its reply deadline passes (the control plane enforces deadlines, not the
  transport: freeze 2 s, overlay init 10 s, others 5 s, compute 15 min). While no
  stream is attached it waits; on attach every unexpired pending instruction is
  sent again with its original `instruction_id`, so a data plane that already
  applied it can recognise the repeat. Pending state lives in memory only: a
  control-plane restart drops it, and the heartbeat matrix (`resend_merge`), the
  branch self-tick and the reconciliation jobs repair what mattered (doc 13 §6).
  """
  use GenServer, restart: :transient

  require Logger

  alias Steward.Coordinator.Plane
  alias Steward.Coordinator.Plane.Wire

  def start_link({_org_id, data_plane_id} = arg),
    do:
      GenServer.start_link(__MODULE__, arg,
        name: {:via, Registry, {Plane.registry(), data_plane_id}}
      )

  @impl true
  def init({org_id, data_plane_id}) do
    {:ok,
     %{org_id: org_id, dp_id: data_plane_id, handler: nil, monitor: nil, pending: %{}, order: []}}
  end

  @impl true
  def handle_call(:connected?, _from, s), do: {:reply, s.handler != nil, s}
  def handle_call(:pending, _from, s), do: {:reply, s.order, s}

  def handle_call({:attach, org_id, _handler}, _from, %{org_id: other} = s) when org_id != other,
    do: {:reply, {:error, :wrong_org}, s}

  def handle_call({:attach, _org_id, handler}, _from, s) do
    # A newer stream replaces the old one: exactly one per identity.
    if s.handler do
      Process.demonitor(s.monitor, [:flush])
      send(s.handler, :superseded)
    end

    s = %{s | handler: handler, monitor: Process.monitor(handler)}
    Enum.each(s.order, fn id -> push(s, s.pending[id].instruction) end)

    :telemetry.execute([:steward, :plane, :stream_attached], %{resent: length(s.order)}, %{
      data_plane_id: s.dp_id
    })

    {:reply, :ok, s}
  end

  def handle_call({:send, instruction, deadline_ms, waiter}, from, s) do
    id = instruction.instruction_id
    timer = Process.send_after(self(), {:deadline, id}, deadline_ms)
    waiter = if match?({:call, nil}, waiter), do: {:call, from}, else: waiter
    entry = %{instruction: instruction, waiter: waiter, timer: timer}

    s = %{s | pending: Map.put(s.pending, id, entry), order: s.order ++ [id]}
    if s.handler, do: push(s, instruction)

    case waiter do
      {:call, _} -> {:noreply, s}
      {:cast, _} -> {:reply, :ok, s}
    end
  end

  @impl true
  def handle_cast({:result, %{instruction_id: id} = result}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        # Late (after the deadline) or a repeat: counted, never applied twice.
        :telemetry.execute([:steward, :plane, :late_result], %{count: 1}, %{
          data_plane_id: s.dp_id
        })

        {:noreply, s}

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        answer(entry.waiter, id, {:ok, result})
        {:noreply, %{s | pending: pending, order: List.delete(s.order, id)}}
    end
  end

  @impl true
  def handle_info({:deadline, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {entry, pending} ->
        :telemetry.execute([:steward, :plane, :instruction_timeout], %{count: 1}, %{
          data_plane_id: s.dp_id
        })

        answer(entry.waiter, id, {:error, :timeout})
        {:noreply, %{s | pending: pending, order: List.delete(s.order, id)}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = s),
    do: {:noreply, %{s | handler: nil, monitor: nil}}

  def handle_info(_ignored, s), do: {:noreply, s}

  defp push(s, instruction), do: send(s.handler, {:push, Wire.control_message(instruction)})

  defp answer({:call, from}, _id, reply), do: GenServer.reply(from, reply)
  defp answer({:cast, pid}, id, reply), do: send(pid, {:instruction_result, id, reply})
end
