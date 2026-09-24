defmodule Pie.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Runs agent loops and every tool call, each in its own process.
      {Task.Supervisor, name: Pie.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pie.Supervisor)
  end
end
