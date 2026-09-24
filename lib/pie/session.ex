defmodule Pie.Session do
  @moduledoc """
  Layer 4: persistence, independent from context.

  A session is an append-only log of entries, stored as JSON lines (after
  Pi's session format). Entries form a tree: each one records its parent,
  and the *leaf* is where the next entry attaches. The current branch is the
  path from the root to the leaf.

  Nothing here knows what the model sees. The context is a *projection* of the
  current branch (`Pie.Session.Context`), so moving the leaf (`branch/2`) or
  appending a compaction entry changes the context without ever rewriting
  history.

  One process owns one file: appends are serialized by the mailbox, and the
  file is created lazily on the first append, so opening a session and
  quitting leaves nothing behind. A torn last line (crash mid-write) is
  skipped on load; every earlier entry survives.

  `path: nil` gives an in-memory session with the same behaviour.
  """
  use GenServer

  alias Pie.AI.Codec

  @version 1

  defstruct [:id, :path, :cwd, :file, :leaf, entries: %{}, order: []]

  @type entry :: %{required(String.t()) => term()}

  ## Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def via(id), do: {:via, Registry, {Pie.Registry, {:session, id}}}

  @doc "Appends an entry under the current leaf and returns its id."
  @spec append(GenServer.server(), entry()) :: String.t()
  def append(session, %{"type" => _} = entry), do: GenServer.call(session, {:append, entry})

  def append_message(session, message),
    do: append(session, %{"type" => "message", "message" => Codec.encode(message)})

  @doc "Records a compaction (see `Pie.Compaction`); the history before it stays in the log."
  def append_compaction(session, %{
        summary: summary,
        first_kept_id: first_kept,
        tokens_before: tokens
      }) do
    append(session, %{
      "type" => "compaction",
      "summary" => summary,
      "firstKeptEntryId" => first_kept,
      "tokensBefore" => tokens
    })
  end

  @doc "Moves the leaf to an earlier entry (`nil`: before the first); the next append forks there."
  def branch(session, entry_id), do: GenServer.call(session, {:branch, entry_id})

  @doc "Entries on the current branch, root first."
  @spec path(GenServer.server()) :: [entry()]
  def path(session), do: GenServer.call(session, :path)

  @doc "Every entry of every branch, in append order."
  def entries(session), do: GenServer.call(session, :entries)

  @doc "The messages the agent works with: the projection of the current branch."
  def context(session), do: session |> path() |> Pie.Session.Context.messages()

  def info(session), do: GenServer.call(session, :info)

  ## Locations

  @doc "Where sessions for `cwd` live: `$PIE_HOME/sessions/<encoded cwd>/`."
  def dir(cwd) do
    encoded =
      "--" <>
        (cwd |> Path.expand() |> String.trim_leading("/") |> String.replace(~r{[/\\:]}, "-")) <>
        "--"

    Path.join([Pie.home(), "sessions", encoded])
  end

  @doc "A fresh session file path for `cwd`."
  def new_path(cwd) do
    stamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9TZ]/, "")

    Path.join(dir(cwd), "#{stamp}_#{random_id(4)}.jsonl")
  end

  @doc "The most recently modified session file for `cwd`, if any."
  def latest(cwd) do
    cwd
    |> dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.max_by(&File.stat!(&1, time: :posix).mtime, fn -> nil end)
  end

  ## Server

  @impl true
  def init(opts) do
    state = %__MODULE__{id: uuid(), path: opts[:path], cwd: opts[:cwd] || File.cwd!()}
    if state.path && File.exists?(state.path), do: {:ok, load(state)}, else: {:ok, state}
  end

  @impl true
  def handle_call({:append, entry}, _from, s) do
    id = unique_id(s.entries)

    entry =
      Map.merge(entry, %{
        "id" => id,
        "parentId" => s.leaf,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    s = write(s, entry)
    {:reply, id, %{s | entries: Map.put(s.entries, id, entry), order: [id | s.order], leaf: id}}
  end

  def handle_call({:branch, id}, _from, s) do
    if id == nil or Map.has_key?(s.entries, id),
      do: {:reply, :ok, %{s | leaf: id}},
      else: {:reply, {:error, :not_found}, s}
  end

  def handle_call(:path, _from, s), do: {:reply, walk(s.entries, s.leaf, []), s}

  def handle_call(:entries, _from, s),
    do: {:reply, Enum.map(Enum.reverse(s.order), &s.entries[&1]), s}

  def handle_call(:info, _from, s),
    do: {:reply, %{id: s.id, path: s.path, cwd: s.cwd, leaf: s.leaf, entries: length(s.order)}, s}

  defp walk(_entries, nil, acc), do: acc

  defp walk(entries, id, acc) do
    case Map.fetch(entries, id) do
      {:ok, entry} -> walk(entries, entry["parentId"], [entry | acc])
      :error -> acc
    end
  end

  defp load(s) do
    lines =
      s.path
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case JSON.decode(line) do
          {:ok, %{"type" => _} = entry} -> [entry]
          _torn_or_blank -> []
        end
      end)

    {headers, entries} = Enum.split_with(lines, &(&1["type"] == "session"))
    header = List.first(headers, %{})

    %{
      s
      | id: header["id"] || s.id,
        cwd: header["cwd"] || s.cwd,
        entries: Map.new(entries, &{&1["id"], &1}),
        order: entries |> Enum.map(& &1["id"]) |> Enum.reverse(),
        leaf: entries |> List.last(%{}) |> Map.get("id")
    }
  end

  defp write(%{path: nil} = s, _entry), do: s

  defp write(s, entry) do
    s = ensure_open(s)
    :ok = IO.binwrite(s.file, [JSON.encode!(entry), ?\n])
    s
  end

  defp ensure_open(%{file: nil} = s) do
    File.mkdir_p!(Path.dirname(s.path))
    fresh? = not File.exists?(s.path)
    file = File.open!(s.path, [:append, :binary])

    if fresh? do
      header = %{
        "type" => "session",
        "version" => @version,
        "id" => s.id,
        "cwd" => s.cwd,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      IO.binwrite(file, [JSON.encode!(header), ?\n])
    end

    %{s | file: file}
  end

  defp ensure_open(s), do: s

  defp unique_id(entries) do
    id = random_id(4)
    if Map.has_key?(entries, id), do: unique_id(entries), else: id
  end

  defp random_id(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> to_string()
  end
end
