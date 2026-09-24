defmodule Pie.Extension.Server do
  @moduledoc """
  Hosts one extension module: holds its state, answers queries from the agent
  and feeds it the agent's events. It registers itself under
  `{:extensions, agent_id}` so the agent can find it, and a restart simply
  re-registers.
  """
  use GenServer

  def start_link({_agent_id, _index, _module, _opts} = args),
    do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({agent_id, index, module, opts}) do
    Code.ensure_loaded!(module)

    {:ok, state} =
      if function_exported?(module, :init, 1), do: module.init(opts), else: {:ok, opts}

    {:ok, _} = Registry.register(Pie.PubSub, {:extensions, agent_id}, {index, module})
    if function_exported?(module, :handle_event, 2), do: Pie.Agent.subscribe(agent_id)
    {:ok, %{module: module, state: state}}
  end

  @impl true
  def handle_call(:tools, _from, s), do: {:reply, s.module.tools(s.state), s}

  def handle_call({:system_prompt, prompt}, _from, s),
    do: {:reply, s.module.system_prompt(prompt, s.state), s}

  def handle_call({:before_tool_call, call}, _from, s),
    do: {:reply, s.module.before_tool_call(call, s.state), s}

  @impl true
  def handle_info({:pie_event, _agent_id, event}, s) do
    {:ok, state} = s.module.handle_event(event, s.state)
    {:noreply, %{s | state: state}}
  end
end
