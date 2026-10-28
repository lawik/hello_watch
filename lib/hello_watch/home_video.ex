defmodule HelloWatch.HomeVideo do
  @moduledoc """
  Cameras of the home cluster, shown on the watch.

  `start/1` shows a camera (`{node, id}`) here: an H.264
  `Home.Media.Session` from the camera to the watch's `"watch_video"`
  display (`HelloWatch.HomeVideo.Display`). A phone's camera is encoded by
  its hardware encoder, any other by its node, and the watch decodes with
  Venus. The session holds and renews both leases; when it ends (the
  camera's node goes, a revoke, `stop/0`), this process lets go.

  The frames name this process as their owner.
  """

  use GenServer

  require Logger

  @display "watch_video"
  # What the watch asks for, within its decoder's limits (config :home_base,
  # video:). The picture is cropped to cover the 454x454 panel, so it wants
  # at least 454 lines: 720p is the smallest the phones send that has them.
  # 1 Mbit/s is the phones' most, well within the watch's ~4 Mbit/s Wi-Fi.
  @size {1280, 720}
  @fps 24
  @bitrate 1_000_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Shows `camera` (`{node, id}`) on the watch. Ends what was on first."
  @spec start({node(), String.t()}) :: :ok | {:error, term()}
  def start(camera), do: GenServer.call(__MODULE__, {:start, camera}, 30_000)

  @doc "Stops showing a camera."
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc "The camera being shown, or nil."
  @spec showing() :: {node(), String.t()} | nil
  def showing do
    GenServer.call(__MODULE__, :showing)
  catch
    :exit, _ -> nil
  end

  @doc """
  The cluster's cameras, as `%{ref: {node, id}, device: device_id, id: id}`,
  sorted by device. Empty while the watch isn't in the cluster.
  """
  @spec cameras() :: [map()]
  def cameras do
    if HelloWatch.Home.running?() do
      for entry <- Home.Registry.list(kind: :video_in) do
        {_node, id} = entry.ref
        %{ref: entry.ref, device: entry.device_id, id: id}
      end
      |> Enum.sort_by(&{&1.device, &1.id})
    else
      []
    end
  catch
    :exit, _ -> []
  end

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_call({:start, camera}, _from, state) do
    stop_stream(state)

    case start_stream(camera) do
      {:ok, stream} -> {:reply, :ok, stream}
      {:error, reason} -> {:reply, {:error, reason}, nil}
    end
  end

  def handle_call(:stop, _from, state) do
    stop_stream(state)
    {:reply, :ok, nil}
  end

  def handle_call(:showing, _from, state), do: {:reply, state && state.camera, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    Logger.info("Home video from #{inspect(state.camera)} ended: #{inspect(reason)}")
    {:noreply, nil}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_stream(camera) do
    with {:ok, source} <- Home.Lease.acquire(camera, purpose: "watch video") do
      case Home.Lease.acquire({node(), @display}, purpose: "watch video") do
        {:ok, sink} ->
          opts = [
            source: source,
            sinks: [sink],
            codec: :h264,
            size: @size,
            fps: @fps,
            bitrate: @bitrate,
            surface: {self(), :home_video}
          ]

          case Home.Media.Session.start(opts) do
            {:ok, session} ->
              {:ok, %{session: session, monitor: Process.monitor(session), camera: camera}}

            failed ->
              # Leases the session didn't take over are still this process's.
              Enum.each([source, sink], &Home.Lease.release/1)
              failed
          end

        failed ->
          Home.Lease.release(source)
          failed
      end
    end
  end

  defp stop_stream(nil), do: :ok

  defp stop_stream(%{session: session, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    Home.Media.Session.stop(session)
  catch
    :exit, _ -> :ok
  end
end
