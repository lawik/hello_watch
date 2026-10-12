defmodule HelloWatch.Vibrator do
  @moduledoc """
  The watch's vibration motor.

  The kernel's `gpio-vibrator` driver owns the motor's two pins (its enable
  pin and the GPIO-switched `vib_vreg` supply) and exposes it as an evdev
  force-feedback device. Playing an effect needs an ioctl, so the
  `priv/vibrator` port program (see `c_src/vibrator.c`) holds the device open
  and plays durations it reads from this process. The motor is on/off only:
  there is no strength to set.

      HelloWatch.Vibrator.buzz()
      HelloWatch.Vibrator.pattern([100, 100, 100])
  """

  use GenServer
  require Logger

  @driver_name "gpio-vibrator"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs the motor for `ms` milliseconds, replacing anything playing."
  def buzz(ms \\ 100) when is_integer(ms) and ms > 0, do: pattern([ms])

  @doc """
  Plays alternating on and off durations in milliseconds, starting with on:
  `[200, 100, 200]` buzzes twice with a pause between. Replaces anything
  playing.
  """
  def pattern(durations) when is_list(durations) do
    GenServer.cast(__MODULE__, {:pattern, durations})
  end

  @doc "Stops the motor and any pattern in progress."
  def stop, do: GenServer.cast(__MODULE__, :stop)

  @impl true
  def init(opts) do
    executable =
      Keyword.get_lazy(opts, :executable, fn ->
        Application.app_dir(:hello_watch, "priv/vibrator")
      end)

    case Keyword.get_lazy(opts, :device, &find_device/0) do
      nil ->
        Logger.warning("Vibrator: no #{@driver_name} input device")
        :ignore

      device ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [device]
          ])

        {:ok, %{port: port, timer: nil}}
    end
  end

  @impl true
  def handle_cast({:pattern, durations}, state) do
    {:noreply, state |> cancel() |> step(durations, :on)}
  end

  def handle_cast(:stop, state) do
    {:noreply, state |> cancel() |> send_ms(0)}
  end

  @impl true
  def handle_info({:step, durations, phase}, state) do
    {:noreply, step(%{state | timer: nil}, durations, phase)}
  end

  def handle_info({port, {:data, output}}, %{port: port} = state) do
    Logger.warning("Vibrator: #{String.trim(output)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:vibrator_exited, status}, state}
  end

  # The kernel times each buzz itself; the timer only starts the next one.
  defp step(state, [], _phase), do: state

  defp step(state, [ms | rest], :on) do
    state |> send_ms(ms) |> schedule(ms, rest, :off)
  end

  defp step(state, [ms | rest], :off), do: schedule(state, ms, rest, :on)

  defp schedule(state, _ms, [], _phase), do: state

  defp schedule(state, ms, rest, phase) do
    %{state | timer: Process.send_after(self(), {:step, rest, phase}, ms)}
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp send_ms(state, ms) do
    Port.command(state.port, "#{ms}\n")
    state
  end

  defp find_device do
    Enum.find_value(Path.wildcard("/sys/class/input/event*"), fn path ->
      case File.read(Path.join(path, "device/name")) do
        {:ok, name} ->
          if String.trim(name) == @driver_name, do: "/dev/input/" <> Path.basename(path)

        _ ->
          nil
      end
    end)
  end
end
