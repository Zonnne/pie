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

  @agent_options NimbleOptions.new!(
                   model: [
                     type: {:struct, Pie.AI.Model},
                     required: true,
                     doc: "The model to talk to (`Pie.AI.Model.new/3`)."
                   ],
                   tools: [
                     type: {:list, {:struct, Pie.Tool}},
                     default: [],
                     doc: "Tools the model may call, e.g. `Pie.Tools.coding(cwd)`."
                   ],
                   system_prompt: [
                     type: :string,
                     default: "",
                     doc: "The system prompt, e.g. from `Pie.Prompt.build/1`."
                   ],
                   session_path: [
                     type: {:or, [:string, nil]},
                     default: nil,
                     doc:
                       "A JSONL session file, created lazily or resumed if it exists. `nil` keeps the session in memory."
                   ],
                   cwd: [
                     type: :string,
                     doc: "Recorded in the session header. Defaults to the current directory."
                   ],
                   stream_opts: [
                     type: :keyword_list,
                     default: [],
                     doc:
                       "Passed to the provider on every request (`:api_key`, `:max_tokens`, `:thinking_budget`, `:req_options`)."
                   ],
                   max_concurrency: [
                     type: :pos_integer,
                     default: 4,
                     doc: "How many `parallel: true` tool calls may run at once."
                   ],
                   transform_context: [
                     type: {:fun, 1},
                     doc: "Projects the message history before each model call."
                   ],
                   extensions: [
                     type: {:list, {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}},
                     default: [],
                     doc: "`Pie.Extension` modules, or `{module, opts}` tuples."
                   ],
                   compaction: [
                     type: :keyword_list,
                     default: [],
                     keys: [
                       enabled: [type: :boolean, default: true, doc: "Compact automatically."],
                       reserve_tokens: [
                         type: :pos_integer,
                         default: 16_384,
                         doc:
                           "Compact when the context comes within this many tokens of the window."
                       ],
                       keep_recent_tokens: [
                         type: :non_neg_integer,
                         default: 20_000,
                         doc: "Roughly how much recent history to keep verbatim."
                       ]
                     ],
                     doc: "See `Pie.Compaction`."
                   ],
                   id: [type: :string, doc: "The agent's id. Random when omitted."]
                 )

  @doc """
  Starts a supervised agent (with its session) and returns its id.

  Raises `NimbleOptions.ValidationError` on unknown or ill-typed options.

  ## Options

  #{NimbleOptions.docs(@agent_options)}
  """
  @spec start_agent(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_agent(opts) do
    opts = NimbleOptions.validate!(opts, @agent_options)
    id = Keyword.get_lazy(opts, :id, &new_id/0)

    case DynamicSupervisor.start_child(
           Pie.AgentSupervisor,
           {Pie.Agent.Supervisor, Keyword.put(opts, :id, id)}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops an agent, its session and anything it is running."
  def stop_agent(id) do
    case GenServer.whereis(Pie.Agent.Supervisor.via(id)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Pie.AgentSupervisor, pid)
    end
  end

  @doc "The agent's session process (see `Pie.Session`)."
  def session(id), do: Pie.Session.via(id)

  defdelegate prompt(agent, input), to: Pie.Agent
  defdelegate steer(agent, input), to: Pie.Agent
  defdelegate follow_up(agent, input), to: Pie.Agent
  defdelegate abort(agent), to: Pie.Agent
  defdelegate compact(agent, instructions \\ nil), to: Pie.Agent
  defdelegate await(agent, timeout \\ :infinity), to: Pie.Agent
  defdelegate snapshot(agent), to: Pie.Agent
  defdelegate subscribe(agent), to: Pie.Agent

  @doc "pie's home directory (`PIE_HOME`, default `~/.pie`)."
  def home, do: System.get_env("PIE_HOME") || Path.expand("~/.pie")

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
