defmodule Pie do
  @moduledoc """
  pie: a minimal coding agent in Elixir, after Pi.

      {:ok, agent} = Pie.start_agent(model: model, tools: Pie.Tools.coding(File.cwd!()))
      Pie.subscribe(agent)
      :ok = Pie.prompt(agent, "What does mix.exs configure?")
      Pie.await(agent)

  Agents are addressed by id; every function below also accepts a pid.
  See the README for the layers and DECISIONS.md for why they look this way.
  """

  @doc "Starts a supervised agent and returns its id."
  @spec start_agent(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_agent(opts) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)

    case DynamicSupervisor.start_child(
           Pie.AgentSupervisor,
           {Pie.Agent, Keyword.put(opts, :id, id)}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops an agent (and anything it is running)."
  def stop_agent(id) do
    case GenServer.whereis(Pie.Agent.via(id)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Pie.AgentSupervisor, pid)
    end
  end

  defdelegate prompt(agent, input), to: Pie.Agent
  defdelegate steer(agent, input), to: Pie.Agent
  defdelegate follow_up(agent, input), to: Pie.Agent
  defdelegate abort(agent), to: Pie.Agent
  defdelegate await(agent, timeout \\ :infinity), to: Pie.Agent
  defdelegate snapshot(agent), to: Pie.Agent
  defdelegate subscribe(agent), to: Pie.Agent

  @doc "pie's home directory (`PIE_HOME`, default `~/.pie`)."
  def home, do: System.get_env("PIE_HOME") || Path.expand("~/.pie")

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
