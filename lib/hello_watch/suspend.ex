defmodule HelloWatch.Suspend do
  @moduledoc """
  Suspends the watch (s2idle) while the screen is off.

  The clock reports the screen going off and on. Once it has been off for
  `@grace`, and nothing below holds the watch awake, this freezes the system
  through `/sys/power/state`. Only the power key, the RTC alarm and the
  charger wake it (see POWER-MANAGEMENT.md); the RTC is set for the soonest
  alarm or timer (see HelloWatch.Wakeup). So:

    * it stays awake on USB power, where suspending saves nothing and would
      cut off a cable-attached session;
    * it stays awake while an SSH session is open, or while the Wi-Fi
      access point is up (see HelloWatch.AccessPoint), which a suspend would
      take down;
    * the power key, via `HelloWatch.Clock.Button`, turns the screen on after
      a wake, which holds the watch awake until the screen goes off again;
    * any other wake (RTC, charger) gets another `@grace` and suspends again.

  Wi-Fi and Bluetooth are soft blocked (rfkill) for each suspend and
  unblocked after it, as connected Wi-Fi keeps drawing current while the
  watch sleeps. A radio that was already off stays off. The USB controller
  is unbound meanwhile too: with no cable it keeps its PHY and clocks on,
  about 10 mA, and the watch only suspends off USB power.

  The `/sys/power/wakeup_count` handshake makes a wake event that arrives
  while deciding cancel the suspend instead of being lost.

  Erlang monotonic time, and so every timer, stands still while suspended.
  Wall-clock time doesn't (the VM runs with `multi_time_warp`).
  """

  use GenServer
  require Logger

  @grace :timer.seconds(10)
  @power "/sys/power"
  @charger_online "/sys/class/power_supply/pm660-charger/online"
  @ssh_port 22
  @rfkill "/sys/class/rfkill"
  @radios ["wlan", "bluetooth"]
  @usb {"/sys/bus/platform/drivers/msm_hsusb", "78db000.usb"}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The screen went dark: suspend once it has stayed that way for a while."
  def screen_off, do: GenServer.cast(__MODULE__, :screen_off)

  @doc "The screen is on: stay awake."
  def screen_on, do: GenServer.cast(__MODULE__, :screen_on)

  @impl true
  def init(_opts) do
    # The clock starts with the screen on.
    {:ok, %{screen: :on, timer: nil}}
  end

  @impl true
  def handle_cast(:screen_off, state), do: {:noreply, schedule(%{state | screen: :off})}
  def handle_cast(:screen_on, state), do: {:noreply, cancel(%{state | screen: :on})}

  @impl true
  def handle_info({:suspend, timer}, %{timer: timer, screen: :off} = state) do
    state = %{state | timer: nil}

    case hold_reason() do
      nil ->
        suspend()
        # Whatever woke the watch gets its turn before the next suspend: the
        # power key turns the screen on, which cancels this.
        {:noreply, schedule(state)}

      reason ->
        Logger.debug("Suspend: holding awake: #{reason}")
        {:noreply, schedule(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    state = cancel(state)
    timer = make_ref()
    Process.send_after(self(), {:suspend, timer}, @grace)
    %{state | timer: timer}
  end

  defp cancel(state), do: %{state | timer: nil}

  defp hold_reason do
    cond do
      on_usb?() -> "on USB power"
      ssh_sessions?() -> "SSH session open"
      HelloWatch.AccessPoint.up?() -> "access point up"
      true -> nil
    end
  end

  defp suspend do
    blocked = radios_off()
    usb = usb_off()
    HelloWatch.Wakeup.arm()
    result = freeze()
    if usb, do: usb_on()
    Enum.each(blocked, &File.write(Path.join(&1, "soft"), "0"))
    HelloWatch.Wakeup.resumed()
    result
  end

  defp freeze do
    with {:ok, count} <- File.read(Path.join(@power, "wakeup_count")),
         # Fails if a wake event came in since the read.
         :ok <- File.write(Path.join(@power, "wakeup_count"), String.trim(count)),
         # Blocks until the watch wakes up.
         :ok <- File.write(Path.join(@power, "state"), "freeze") do
      :ok
    else
      error ->
        Logger.debug("Suspend: aborted: #{inspect(error)}")
        error
    end
  end

  # Soft blocks the radios that are on, returning their rfkill switches.
  defp radios_off do
    for path <- Path.wildcard(Path.join(@rfkill, "rfkill*")),
        {:ok, type} <- [File.read(Path.join(path, "type"))],
        String.trim(type) in @radios,
        File.read(Path.join(path, "soft")) == {:ok, "0\n"},
        File.write(Path.join(path, "soft"), "1") == :ok,
        do: path
  end

  # Unbinds the USB controller if it's bound, returning whether it was.
  defp usb_off do
    {driver, device} = @usb

    File.exists?(Path.join(driver, device)) and
      File.write(Path.join(driver, "unbind"), device) == :ok
  end

  defp usb_on do
    {driver, device} = @usb
    File.write(Path.join(driver, "bind"), device)
  end

  defp on_usb? do
    case File.read(@charger_online) do
      {:ok, "1" <> _} -> true
      _ -> false
    end
  end

  # Established TCP connections to the SSH port, IPv4 or IPv6. In
  # /proc/net/tcp*, the local address ends in the port in hex and state 01 is
  # ESTABLISHED.
  defp ssh_sessions? do
    port = ":" <> String.pad_leading(Integer.to_string(@ssh_port, 16), 4, "0")

    Enum.any?(["/proc/net/tcp", "/proc/net/tcp6"], fn path ->
      case File.read(path) do
        {:ok, table} ->
          table
          |> String.split("\n", trim: true)
          |> Enum.drop(1)
          |> Enum.any?(fn line ->
            case String.split(line) do
              [_slot, local, _remote, "01" | _] -> String.ends_with?(local, port)
              _ -> false
            end
          end)

        _ ->
          false
      end
    end)
  end
end
