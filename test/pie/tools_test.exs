defmodule Pie.ToolsTest do
  use ExUnit.Case, async: true

  alias Pie.Tools.{Bash, Edit, Read, Write}

  @moduletag :tmp_dir

  defp ctx, do: %{tool_call_id: "t", update: fn _ -> :ok end}

  test "write, read and edit round-trip", %{tmp_dir: dir} do
    assert {:ok, _} =
             Write.execute(%{"path" => "a/b.txt", "content" => "one\ntwo\nthree"}, ctx(), dir)

    assert {:ok, "one\ntwo\nthree"} = Read.execute(%{"path" => "a/b.txt"}, ctx(), dir)

    assert {:ok, "two"} =
             Read.execute(%{"path" => "a/b.txt", "offset" => 2, "limit" => 1}, ctx(), dir)
             |> strip_notice()

    assert {:ok, "Edited a/b.txt at line 2", _} =
             Edit.execute(
               %{"path" => "a/b.txt", "oldText" => "two", "newText" => "2"},
               ctx(),
               dir
             )

    assert File.read!(Path.join(dir, "a/b.txt")) == "one\n2\nthree"
  end

  test "edit refuses missing and ambiguous matches", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "f"), "x x")

    assert {:error, "Could not find" <> _} =
             Edit.execute(%{"path" => "f", "oldText" => "y", "newText" => ""}, ctx(), dir)

    assert {:error, "oldText occurs 2 times" <> _} =
             Edit.execute(%{"path" => "f", "oldText" => "x", "newText" => ""}, ctx(), dir)
  end

  test "read pages large files and rejects binaries", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "big"), Enum.map_join(1..3000, "\n", &"line #{&1}"))
    assert {:ok, text} = Read.execute(%{"path" => "big"}, ctx(), dir)
    assert text =~ "[Showing lines 1-2000 of 3000. Use offset=2001 to continue.]"

    File.write!(Path.join(dir, "bin"), <<0, 255, 1>>)
    assert {:error, _} = Read.execute(%{"path" => "bin"}, ctx(), dir)
  end

  test "bash returns output, exit codes and streams updates", %{tmp_dir: dir} do
    assert {:ok, "hello\n" <> _} = Bash.execute(%{"command" => "echo hello; pwd"}, ctx(), dir)
    assert {:error, text} = Bash.execute(%{"command" => "echo oops >&2; exit 3"}, ctx(), dir)
    assert text =~ "oops" and text =~ "exited with code 3"

    test = self()
    ctx = %{ctx() | update: &send(test, {:update, &1})}
    assert {:ok, _} = Bash.execute(%{"command" => "echo a; sleep 0.4; echo b"}, ctx, dir)
    assert_received {:update, "a" <> _}
  end

  test "bash timeouts kill the whole process group", %{tmp_dir: dir} do
    pidfile = Path.join(dir, "pid")
    command = "sleep 30 & echo $! > #{pidfile}; wait"
    assert {:error, text} = Bash.execute(%{"command" => command, "timeout" => 0.5}, ctx(), dir)
    assert text =~ "timed out"
    assert_dead(File.read!(pidfile) |> String.trim())
  end

  test "killing the tool process kills the command", %{tmp_dir: dir} do
    pidfile = Path.join(dir, "pid")

    pid =
      spawn(fn ->
        Bash.execute(%{"command" => "sleep 30 & echo $! > #{pidfile}; wait"}, ctx(), dir)
      end)

    wait_for(pidfile)
    Process.exit(pid, :kill)
    assert_dead(File.read!(pidfile) |> String.trim())
  end

  defp strip_notice({:ok, text}), do: {:ok, text |> String.split("\n\n[Showing") |> hd()}

  defp wait_for(path, tries \\ 100) do
    cond do
      File.exists?(path) and File.read!(path) != "" -> :ok
      tries == 0 -> flunk("#{path} never appeared")
      true -> Process.sleep(20) && wait_for(path, tries - 1)
    end
  end

  # A killed process may linger as a zombie when PID 1 does not reap orphans
  # (common in containers); that still counts as dead.
  defp assert_dead(os_pid, tries \\ 50) do
    {stat, status} = System.cmd("ps", ["-o", "stat=", "-p", os_pid], stderr_to_stdout: true)

    cond do
      status != 0 or String.starts_with?(String.trim(stat), "Z") -> :ok
      tries == 0 -> flunk("process #{os_pid} is still alive")
      true -> Process.sleep(20) && assert_dead(os_pid, tries - 1)
    end
  end
end
