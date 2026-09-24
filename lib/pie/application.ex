defmodule Pie.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Names agents by id, so a restarted agent keeps its address.
      {Registry, keys: :unique, name: Pie.Registry},
      # Event subscriptions, keyed by agent id (they outlive agent restarts).
      {Registry, keys: :duplicate, name: Pie.PubSub},
      # Runs agent loops and every tool call, each in its own process.
      {Task.Supervisor, name: Pie.TaskSupervisor},
      # Agents are independent: one crashing repeatedly must not take the
      # others down, so this supervisor tolerates many restarts.
      {DynamicSupervisor,
       name: Pie.AgentSupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 5}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pie.Supervisor)
  end
end
