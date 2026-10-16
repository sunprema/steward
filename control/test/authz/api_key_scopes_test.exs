defmodule Steward.Authz.ApiKeyScopesTest do
  @moduledoc """
  Doc 15 §3.2: an agent key must not carry `review:decide`, `policy:write`,
  `policy:admin`, `merge:revert` (or `target:admin`), "enforced at key creation".
  The failure mode the product exists to prevent is an agent editing the gate
  in front of it, so the refusal is in the action, not in the caller.
  """
  use Steward.DataCase, async: true

  import Steward.AuthzFixtures

  alias Steward.Core.Targets.ApiKey

  setup do
    org = org()

    %{
      org: org,
      agent: principal(org, :agent),
      svc: principal(org, :service),
      t: target(org, principal(org, :human))
    }
  end

  defp mint(ctx, principal, scopes) do
    ApiKey
    |> Ash.Changeset.for_create(
      :create,
      %{
        principal_id: principal.id,
        prefix: "p#{System.unique_integer([:positive])}",
        secret_sha256: :crypto.hash(:sha256, "synthetic"),
        scopes: scopes,
        target_ids: [ctx.t.id]
      },
      tenant: ctx.org.id,
      authorize?: false
    )
    |> Ash.create()
  end

  test "an agent key may carry the agent scopes", ctx do
    assert {:ok, _} = mint(ctx, ctx.agent, ~w(branch:write branch:propose changeset:read))
  end

  test "an agent key may not carry a gate-editing scope", ctx do
    for scope <- ~w(review:decide policy:write policy:admin merge:revert target:admin) do
      assert {:error, error} = mint(ctx, ctx.agent, ["branch:write", scope])
      assert Exception.message(error) =~ scope
    end
  end

  test "a service key may carry them", ctx do
    assert {:ok, _} =
             mint(
               ctx,
               ctx.svc,
               ~w(review:decide policy:write policy:admin merge:revert target:admin)
             )
  end

  test "unknown scopes are refused for everyone", ctx do
    assert {:error, error} = mint(ctx, ctx.svc, ["org:admin"])
    assert Exception.message(error) =~ "org:admin"
  end

  test "widening an agent key later is refused too", ctx do
    {:ok, key} = mint(ctx, ctx.agent, ["branch:write"])

    assert {:error, _} =
             key
             |> Ash.Changeset.for_update(:update, %{scopes: ["branch:write", "policy:admin"]},
               tenant: ctx.org.id,
               authorize?: false
             )
             |> Ash.update()

    assert {:ok, _} =
             key
             |> Ash.Changeset.for_update(:update, %{last_used_at: DateTime.utc_now()},
               tenant: ctx.org.id,
               authorize?: false
             )
             |> Ash.update()
  end
end
