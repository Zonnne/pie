defmodule Pie.Tools.Bash do
  @moduledoc """
  Runs a shell command through an Erlang port, streaming output as it comes.

  Cancellation is by process death (D-010). The port is owned by a small
  runner process that monitors the tool process *before* opening the port;
  whenever the tool process dies (abort, timeout, agent crash), the runner
  kills the command's whole process group. OTP starts port programs in a
  session of their own, so the OS pid is also the group id and the group
  contains everything the command spawned.
  """

  @update_interval 250

  def tool(cwd) do
    %Pie.Tool{
      name: "bash",
      description:
        "Execute a bash command in the working directory. Returns stdout and stderr combined, " <>
          "truncated to the last 2000 lines or 50KB. Optionally pass a timeout in seconds.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The command to run"},
          timeout: %{type: "number", description: "Timeout in seconds (optional)"}
        },
        required: ["command"]
      },
      timeout: :infinity,
      execute: &execute(&1, &2, cwd)
    }
  end

  def execute(%{"command" => command} = args, ctx, cwd) do
    owner = self()
    runner = spawn(fn -> run(owner, command, cwd) end)
    ref = Process.monitor(runner)
    outcome = collect(runner, ref, ctx, "", deadline(args["timeout"]), nil)
    report(outcome, args["timeout"])
  end

  defp report({status, output}, timeout) do
    text = output |> String.replace_invalid() |> Pie.Tools.tail()
    text = if String.trim(text) == "", do: "(no output)", else: text

    case status do
      0 -> {:ok, text}
      :timeout -> {:error, "#{text}\n\nCommand timed out after #{timeout} seconds"}
      {:failed, reason} -> {:error, "Command failed to run: #{Exception.format_exit(reason)}"}
      code -> {:error, "#{text}\n\nCommand exited with code #{code}"}
    end
  end

  defp collect(runner, ref, ctx, output, deadline, last_update) do
    receive do
      {^runner, {:data, data}} ->
        output = cap(output <> data)
        collect(runner, ref, ctx, output, deadline, maybe_update(ctx, output, last_update))

      {^runner, {:exit, status}} ->
        Process.demonitor(ref, [:flush])
        {status, output}

      {:DOWN, ^ref, :process, _, reason} ->
        {{:failed, reason}, output}
    after
      remaining(deadline) ->
        send(runner, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> {:timeout, output}
        end
    end
  end

  ## The runner owns the port; it lives exactly as long as the command.

  defp run(owner, command, cwd) do
    watch = Process.monitor(owner)
    shell = System.find_executable("bash") || "/bin/sh"

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        # Commands must not wait on the agent's stdin.
        args: ["-c", "exec </dev/null\n" <> command],
        cd: cwd
      ])

    # nil when the command already finished: nothing left to kill.
    os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid
    relay(owner, watch, port, os_pid)
  end

  defp relay(owner, watch, port, os_pid) do
    receive do
      {^port, {:data, data}} ->
        send(owner, {self(), {:data, data}})
        relay(owner, watch, port, os_pid)

      {^port, {:exit_status, status}} ->
        send(owner, {self(), {:exit, status}})

      :kill ->
        kill(os_pid)

      {:DOWN, ^watch, :process, _, _} ->
        kill(os_pid)
    end
  end

  # Bound memory for chatty commands; the tail is what gets reported anyway.
  defp cap(output) when byte_size(output) > 400_000,
    do: binary_part(output, byte_size(output) - 200_000, 200_000)

  defp cap(output), do: output

  defp maybe_update(ctx, output, last) do
    now = System.monotonic_time(:millisecond)

    if last == nil or now - last >= @update_interval do
      ctx.update.(output |> String.replace_invalid() |> Pie.Tools.tail(50, 8_000))
      now
    else
      last
    end
  end

  defp deadline(nil), do: :infinity
  defp deadline(seconds), do: System.monotonic_time(:millisecond) + round(seconds * 1000)

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Kill the process group; fall back to the process if it has no group.
  defp kill(nil), do: :ok

  defp kill(os_pid) do
    case System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
    end
  end
end
