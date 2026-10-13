defmodule HelloWatch.Recorder do
  @moduledoc """
  Voice memos: `start/0` records the microphone into a new WAV file under
  `/root/recordings` (see HelloWatch.Recorder.Pipeline) until `stop/0`.
  Holding the bottom button does both (see HelloWatch.Clock.Button).

      HelloWatch.Recorder.list() |> List.last() |> HelloWatch.Audio.play()
  """
  use GenServer
  require Logger

  alias HelloWatch.Recorder.Pipeline

  # A pipeline that hasn't finished its file by then is stopped anyway.
  @stop_timeout 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts a recording, returning the file it goes into."
  def start, do: GenServer.call(__MODULE__, :start)

  @doc "Stops the recording, returning its file. It's complete moments later."
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "The recordings, oldest first."
  def list, do: Path.wildcard(Path.join(dir(), "*.wav")) |> Enum.sort()

  defp dir, do: Application.get_env(:hello_watch, :recordings_dir, "/root/recordings")

  @impl true
  def init(_opts), do: {:ok, %{pipeline: nil, path: nil}}

  @impl true
  def handle_call(:start, _from, %{pipeline: nil} = state) do
    File.mkdir_p!(dir())
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    path = Path.join(dir(), "#{stamp}.wav")

    case Membrane.Pipeline.start(Pipeline, path: path) do
      {:ok, _supervisor, pipeline} ->
        Process.monitor(pipeline)
        {:reply, {:ok, path}, %{state | pipeline: pipeline, path: path}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:start, _from, state), do: {:reply, {:error, :recording}, state}

  def handle_call(:stop, _from, %{pipeline: nil} = state), do: {:reply, {:error, :idle}, state}

  def handle_call(:stop, _from, state) do
    send(state.pipeline, :stop)
    Process.send_after(self(), {:stop_timeout, state.pipeline}, @stop_timeout)
    {:reply, {:ok, state.path}, %{state | pipeline: nil, path: nil}}
  end

  @impl true
  def handle_info({:stop_timeout, pipeline}, state) do
    if Process.alive?(pipeline), do: Membrane.Pipeline.terminate(pipeline, asynchronous?: true)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pipeline, reason}, state) do
    if reason != :normal, do: Logger.warning("Recording pipeline exited: #{inspect(reason)}")

    if pipeline == state.pipeline,
      do: {:noreply, %{state | pipeline: nil, path: nil}},
      else: {:noreply, state}
  end
end
