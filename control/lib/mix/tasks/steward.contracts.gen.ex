defmodule Mix.Tasks.Steward.Contracts.Gen do
  @shortdoc "Regenerates lib/steward_plane/ from contracts/proto (--check to diff only)"

  @moduledoc """
  Generates the Elixir stubs for `steward.plane.v1` (`contracts/proto`, doc 10
  §5, doc 07 §3.1) into `lib/steward_plane/`. The generated modules are checked
  in (doc 03 §8, `contracts/README.md`); CI runs `mix steward.contracts.gen
  --check`, which regenerates into a temporary directory and fails on any
  difference.

  Needs `protoc` and the Elixir plugin:

    * `python3 -m grpc_tools.protoc` (`pip install grpcio-tools`, the same
      dependency `contracts/check.sh` has). Set `STEWARD_PYTHON` to use a
      specific interpreter.
    * `protoc-gen-elixir` (`mix escript.install hex protobuf`), found on `PATH`
      or in `~/.mix/escripts`. Its version must match the `protobuf` dependency.

  Hand edits to the generated files are lost on the next run.
  """
  use Mix.Task

  @proto "steward/plane/v1/session.proto"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])
    root = Path.expand("..", File.cwd!())
    target = Path.join(File.cwd!(), "lib/steward_plane")

    tmp = Path.join(System.tmp_dir!(), "steward-plane-gen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      protoc!(root, tmp)
      generated = Path.join(tmp, "steward/plane/v1/session.pb.ex")
      File.exists?(generated) || Mix.raise("protoc produced no #{generated}")
      format!(generated)

      if opts[:check], do: check!(generated, target), else: install!(generated, target)
    after
      File.rm_rf!(tmp)
    end
  end

  defp protoc!(root, out) do
    python = System.get_env("STEWARD_PYTHON") || "python3"

    args = [
      "-m",
      "grpc_tools.protoc",
      "--plugin=protoc-gen-elixir=#{plugin!()}",
      "-I",
      Path.join(root, "contracts/proto"),
      "--elixir_out=plugins=grpc:#{out}",
      Path.join(root, "contracts/proto/#{@proto}")
    ]

    case System.cmd(python, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("protoc failed (#{status}) with #{python}:\n#{output}")
    end
  end

  defp plugin! do
    System.find_executable("protoc-gen-elixir") ||
      Enum.find([Path.expand("~/.mix/escripts/protoc-gen-elixir")], &File.exists?/1) ||
      Mix.raise("protoc-gen-elixir not found; run: mix escript.install hex protobuf")
  end

  defp format!(file) do
    {_, 0} = System.cmd("mix", ["format", file], stderr_to_stdout: true)
  end

  defp install!(generated, target) do
    File.mkdir_p!(target)
    File.cp!(generated, Path.join(target, "session.pb.ex"))
    Mix.shell().info("Wrote lib/steward_plane/session.pb.ex")
  end

  defp check!(generated, target) do
    current = Path.join(target, "session.pb.ex")

    if File.exists?(current) and File.read!(current) == File.read!(generated) do
      Mix.shell().info("lib/steward_plane/ is up to date")
    else
      Mix.raise("lib/steward_plane/ is stale; run: mix steward.contracts.gen")
    end
  end
end
