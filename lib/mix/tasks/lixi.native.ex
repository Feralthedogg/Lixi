defmodule Mix.Tasks.Lixi.Native do
  use Mix.Task
  @shortdoc "Build and package the Rust audio executable"
  def run(_) do
    root = Path.dirname(Mix.Project.project_file())
    manifest = Path.join(root, "native/audio_engine/Cargo.toml")

    {_, status} =
      System.cmd("cargo", ["build", "--release", "--locked", "--manifest-path", manifest],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Native audio build failed")
    target = Path.join(root, "priv/bin/lixi-audio")
    File.mkdir_p!(Path.dirname(target))
    File.cp!(Path.join(root, "native/audio_engine/target/release/lixi-audio"), target)
    File.chmod!(target, 0o755)
    Mix.shell().info("Packaged #{target}")
  end
end
