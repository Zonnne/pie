defmodule Pie.Agent.Supervisor do
  @moduledoc """
  One supervision tree per agent, `:rest_for_one`, in dependency order:

      Pie.Agent.Supervisor
      ├── Pie.Session   the log: the durable truth
      └── Pie.Agent     the runtime: a disposable projection of the log

  If the agent crashes, only the agent restarts, and it re-hydrates its
  context from the session. If the session crashes, everything after it
  restarts, so the agent re-reads what the session re-loaded from disk. The
  agent's in-memory state can always be thrown away.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  def via(id), do: {:via, Registry, {Pie.Registry, {:tree, id}}}

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    session = Pie.Session.via(id)

    children = [
      {Pie.Session, path: opts[:session_path], cwd: opts[:cwd], name: session},
      {Pie.Agent, Keyword.put(opts, :session, session)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
