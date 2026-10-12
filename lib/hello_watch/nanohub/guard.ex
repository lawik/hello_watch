defmodule HelloWatch.Nanohub.Guard do
  @moduledoc """
  Unloads the sensor hub driver on watches whose hub has failed.

  A hub that never answers keeps the `nanohub` driver in an error loop: its
  thread retries every couple of seconds and hard-resets the hub, and the SPI
  bus fires around 560 interrupts a second with the screen off, more than
  everything else on the watch together (see POWER-MANAGEMENT.md). The driver
  logs `hard reset due to consistent error` when that happens; a working hub
  never does.

  This checks the kernel log a little after boot and then once a minute, and
  unloads the driver the first time it finds that line. Then it stops. Sensor
  streams fail with the driver gone, as they already do on a failed hub.
  `HelloWatch.Nanohub.Bootloader.release/0` loads the driver again.
  """

  use GenServer, restart: :transient
  require Logger

  @failure "hard reset due to consistent error"
  @first_check :timer.seconds(30)
  @interval :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check, @first_check)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    cond do
      not loaded?() ->
        {:stop, :normal, state}

      failing?() ->
        unload()
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :check, @interval)
        {:noreply, state}
    end
  end

  defp loaded?, do: File.exists?("/sys/module/nanohub")

  defp failing? do
    case System.cmd("dmesg", [], stderr_to_stdout: true) do
      {log, 0} -> String.contains?(log, @failure)
      _ -> false
    end
  end

  defp unload do
    # An open /dev/nanohub keeps the module busy.
    System.cmd("killall", ["nanohubctl"], stderr_to_stdout: true)

    case System.cmd("rmmod", ["nanohub"], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.warning("Nanohub: the hub is failing; unloaded its driver to stop the retry loop")

      {output, _} ->
        Logger.error("Nanohub: rmmod failed: #{String.trim(output)}")
    end
  end
end
