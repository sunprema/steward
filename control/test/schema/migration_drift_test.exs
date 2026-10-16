defmodule Steward.Schema.MigrationDriftTest do
  @moduledoc """
  Doc 12 §0: migrations are generated from the Ash resources, committed,
  and reviewed; CI fails on drift between them (doc 17 §4's
  `MigrationDriftTest`). `mix ash.codegen --check` is exactly that check —
  it fails if generating migrations right now would produce anything the
  committed migrations don't already have.
  """
  use ExUnit.Case, async: false

  @tag :integration
  test "mix ash.codegen --check reports no drift" do
    {output, exit_code} =
      System.cmd("mix", ["ash.codegen", "--check"],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, """
    `mix ash.codegen --check` found drift between the Ash resources and the
    committed migrations under priv/repo/migrations/ — run
    `mix ash.codegen` and commit the result.

    #{output}
    """
  end
end
