defmodule HelloWatch.Wakeup do
  @moduledoc """
  Ringing on time through a suspend, for HelloWatch.Alarms and
  HelloWatch.Timers.

  Erlang timers stand still while the watch is suspended, so neither can
  rely on one alone. Before each suspend, HelloWatch.Suspend calls `arm/0`,
  which sets the RTC to wake the watch for the soonest alarm or timer. After
  each wake it calls `resumed/0`, and they ring whatever has come due by the
  wall clock.
  """

  require Logger

  @sources [HelloWatch.Alarms, HelloWatch.Timers]
  @wakealarm "/sys/class/rtc/rtc0/wakealarm"

  @doc """
  Sets the RTC alarm for the soonest alarm or timer, or clears it if there
  is none.
  """
  def arm(path \\ @wakealarm) do
    # The RTC refuses a new alarm while one is set.
    File.write(path, "0")

    case soonest() do
      nil ->
        :ok

      due ->
        seconds = Kernel.max(ceil(DateTime.diff(due, DateTime.utc_now(), :millisecond) / 1000), 1)

        with {:error, reason} <- File.write(path, "+#{seconds}") do
          Logger.warning("Wakeup: can't set the RTC alarm: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @doc "The watch is awake again: ring whatever came due meanwhile."
  def resumed, do: Enum.each(@sources, &GenServer.cast(&1, :check))

  @doc "The soonest time anything wants to ring, as a UTC DateTime, or nil."
  def soonest do
    @sources
    |> Enum.map(&next/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp next(source) do
    GenServer.call(source, :next, 1000)
  catch
    :exit, _reason -> nil
  end

  @doc """
  How long to wait, in milliseconds, before checking for `due` again while
  awake. It's capped, so a check never waits on a timer that a suspend
  stretched.
  """
  def delay(nil), do: nil

  def delay(due),
    do: Kernel.min(Kernel.max(DateTime.diff(due, DateTime.utc_now(), :millisecond), 0), 60_000)
end
