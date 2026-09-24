defmodule Pie.TelemetryTest do
  use ExUnit.Case, async: true

  alias Pie.AI.Model
  alias Pie.AI.Providers.Faux

  def forward(event, measurements, meta, test),
    do: send(test, {:telemetry, event, measurements, meta})

  test "runs, turns and tool calls emit telemetry spans" do
    test = self()
    handler = "telemetry-test-#{inspect(test)}"

    :telemetry.attach_many(
      handler,
      Pie.Telemetry.events(),
      &__MODULE__.forward/4,
      test
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    echo = %Pie.Tool{
      name: "echo",
      description: "e",
      parameters: %{type: "object"},
      execute: fn _, _ -> {:ok, "hi"} end
    }

    model =
      Model.new(:faux, "faux",
        options: %{responder: Faux.sequence([[{:tool_call, "echo", %{}}], "done"])}
      )

    {:ok, id} = Pie.start_agent(model: model, tools: [echo])
    on_exit(fn -> Pie.stop_agent(id) end)
    :ok = Pie.prompt(id, "go")
    Pie.await(id)

    assert_receive {:telemetry, [:pie, :run, :start], %{system_time: _}, %{agent_id: ^id}}

    assert_receive {:telemetry, [:pie, :tool, :stop], %{duration: d},
                    %{agent_id: ^id, tool_name: "echo", is_error: false}}

    assert d >= 0

    assert_receive {:telemetry, [:pie, :turn, :stop], %{input_tokens: input},
                    %{agent_id: ^id, stop_reason: :tool_use, tool_calls: 1}}

    assert input > 0
    assert_receive {:telemetry, [:pie, :turn, :stop], _, %{agent_id: ^id, stop_reason: :stop}}
    assert_receive {:telemetry, [:pie, :run, :stop], %{messages: 4}, %{agent_id: ^id}}
  end
end
