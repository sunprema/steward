defmodule Steward.Coordinator.PlaneSessionTest do
  @moduledoc """
  The instruction queue (doc 10 §5): reply deadlines enforced by the control
  plane, queueing while the stream is down, re-send with the original id on
  reconnect, one stream per identity. A test process stands in for the stream
  handler and receives `{:push, ControlPlaneMessage}`.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Plane
  alias Steward.Plane.V1

  setup do
    org = org()
    %{org: org, dp: Ecto.UUID.generate()}
  end

  defp init_overlay(branch_id \\ "b1"),
    do: %V1.Instruction{
      body: {:initialise_overlay, %V1.InitialiseOverlay{branch_id: branch_id, target_id: "t1"}}
    }

  defp ok_result(id), do: %V1.InstructionResult{instruction_id: id, ok: true}

  # A stream handler: forwards what the session pushes to the test.
  defp handler do
    parent = self()

    spawn_link(fn ->
      receive_loop = fn loop ->
        receive do
          {:push, message} -> send(parent, {:pushed, self(), message}) && loop.(loop)
          :superseded -> send(parent, {:superseded, self()})
        end
      end

      receive_loop.(receive_loop)
    end)
  end

  describe "sending" do
    test "the call returns the data plane's result, correlated by instruction_id", ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)

      task = Task.async(fn -> Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay()) end)

      assert_receive {:pushed, ^h,
                      %V1.ControlPlaneMessage{
                        body: {:instruction, %{instruction_id: id} = instruction}
                      }}

      assert id != ""
      assert {:initialise_overlay, _} = instruction.body

      Plane.deliver_result(ctx.dp, ok_result(id))
      assert {:ok, %V1.InstructionResult{instruction_id: ^id, ok: true}} = Task.await(task)
      assert Plane.pending(ctx.dp) == []
    end

    test "a caller-chosen instruction id is kept", ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)
      instruction = %{init_overlay() | instruction_id: "chosen-1"}

      task = Task.async(fn -> Plane.send_instruction(ctx.org.id, ctx.dp, instruction) end)
      assert_receive {:pushed, ^h, %{body: {:instruction, %{instruction_id: "chosen-1"}}}}
      Plane.deliver_result(ctx.dp, ok_result("chosen-1"))
      assert {:ok, _} = Task.await(task)
    end

    test "an unsuccessful result is still a result; the caller reads `ok`", ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)
      task = Task.async(fn -> Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay()) end)
      assert_receive {:pushed, ^h, %{body: {:instruction, %{instruction_id: id}}}}

      Plane.deliver_result(ctx.dp, %V1.InstructionResult{
        instruction_id: id,
        ok: false,
        error_code: "object_store_unavailable"
      })

      assert {:ok, %{ok: false, error_code: "object_store_unavailable"}} = Task.await(task)
    end

    test "send_async delivers the result to the named process", ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)

      assert {:ok, id} = Plane.send_async(ctx.org.id, ctx.dp, init_overlay())
      assert_receive {:pushed, ^h, _}
      Plane.deliver_result(ctx.dp, ok_result(id))
      assert_receive {:instruction_result, ^id, {:ok, %{ok: true}}}
    end

    test "the reply deadline is by kind: freeze 2 s, overlay init 10 s, compute 15 min, others 5 s" do
      freeze = %V1.Instruction{body: {:freeze_writes, %V1.FreezeWrites{}}}
      compute = %V1.Instruction{body: {:compute_changeset, %V1.ComputeChangeset{}}}
      merge = %V1.Instruction{body: {:merge, %V1.Merge{}}}

      assert Plane.deadline_ms(freeze) == 2_000
      assert Plane.deadline_ms(init_overlay()) == 10_000
      assert Plane.deadline_ms(compute) == 900_000
      assert Plane.deadline_ms(merge) == 5_000
    end
  end

  describe "deadlines" do
    test "no answer by the deadline is {:error, :timeout}, and the instruction is forgotten",
         ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)

      assert {:error, :timeout} =
               Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay(), deadline_ms: 50)

      assert Plane.pending(ctx.dp) == []
    end

    test "a result after the deadline is counted as late and applied to nothing", ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :plane, :late_result],
        fn _, _, _, _ -> send(parent, :late) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)

      {:error, :timeout} =
        Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay(), deadline_ms: 30)

      assert_receive {:pushed, ^h, %{body: {:instruction, %{instruction_id: id}}}}

      Plane.deliver_result(ctx.dp, ok_result(id))
      assert_receive :late
    end

    test "an unknown instruction id is late too, and harmless", ctx do
      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)
      assert :ok = Plane.deliver_result(ctx.dp, ok_result("never-sent"))
    end
  end

  describe "the stream is down" do
    test "the instruction waits, and is re-sent with the same id when a stream attaches", ctx do
      task =
        Task.async(fn ->
          Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay(), deadline_ms: 2_000)
        end)

      eventually(fn -> Plane.pending(ctx.dp) != [] end)
      refute Plane.connected?(ctx.dp)

      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)
      assert_receive {:pushed, ^h, %{body: {:instruction, %{instruction_id: id}}}}

      Plane.deliver_result(ctx.dp, ok_result(id))
      assert {:ok, %{instruction_id: ^id}} = Task.await(task)
    end

    test "a stream that dies mid-flight leaves the instruction pending, and the next stream gets it again",
         ctx do
      h1 = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h1)

      task =
        Task.async(fn ->
          Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay(), deadline_ms: 2_000)
        end)

      assert_receive {:pushed, ^h1, %{body: {:instruction, %{instruction_id: id}}}}

      Process.unlink(h1)
      Process.exit(h1, :kill)
      eventually(fn -> not Plane.connected?(ctx.dp) end)
      assert Plane.pending(ctx.dp) == [id]

      h2 = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h2)
      assert_receive {:pushed, ^h2, %{body: {:instruction, %{instruction_id: ^id}}}}

      Plane.deliver_result(ctx.dp, ok_result(id))
      assert {:ok, _} = Task.await(task)
    end

    test "an instruction that expires while the stream is down is not re-sent", ctx do
      assert {:error, :timeout} =
               Plane.send_instruction(ctx.org.id, ctx.dp, init_overlay(), deadline_ms: 30)

      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)
      refute_receive {:pushed, ^h, _}, 100
    end

    test "re-sent instructions keep their order", ctx do
      for n <- 1..3,
          do:
            Plane.send_async(
              ctx.org.id,
              ctx.dp,
              %{init_overlay("b#{n}") | instruction_id: "i-#{n}"},
              deadline_ms: 5_000
            )

      h = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h)

      ids =
        for _ <- 1..3,
            do:
              (
                assert_receive {:pushed, ^h, %{body: {:instruction, %{instruction_id: id}}}}
                id
              )

      assert ids == ["i-1", "i-2", "i-3"]
    end
  end

  describe "one stream per identity" do
    test "a new stream supersedes the old, which is told, and instructions go to the new one",
         ctx do
      h1 = handler()
      h2 = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h1)
      :ok = Plane.attach(ctx.org.id, ctx.dp, h2)

      assert_receive {:superseded, ^h1}
      {:ok, _} = Plane.send_async(ctx.org.id, ctx.dp, init_overlay())
      assert_receive {:pushed, ^h2, _}
      refute_receive {:pushed, ^h1, _}, 50
    end

    test "the old stream dying after being superseded does not detach the new one", ctx do
      h1 = handler()
      h2 = handler()
      :ok = Plane.attach(ctx.org.id, ctx.dp, h1)
      :ok = Plane.attach(ctx.org.id, ctx.dp, h2)
      Process.unlink(h1)
      Process.exit(h1, :kill)

      Process.sleep(30)
      assert Plane.connected?(ctx.dp)
    end

    test "an identity cannot be attached by another org", ctx do
      :ok = Plane.attach(ctx.org.id, ctx.dp, handler())
      assert {:error, :wrong_org} = Plane.attach(org().id, ctx.dp, handler())
    end
  end
end
