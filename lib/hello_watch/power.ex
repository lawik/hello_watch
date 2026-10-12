defmodule HelloWatch.Power do
  @moduledoc """
  What the watch can tell about its power, for the power meter on the face.

  There is no battery current anywhere on this board: the fuel gauge lives
  behind the sensor hub. What is measurable:

    * on USB, the PM660 charger reports its input current and voltage, so the
      meter shows the watts going into the watch (charging plus running it);
    * on battery, the PMIC ADC reports `vph_pwr`, the main system rail, which
      sits just under the battery voltage.

  With no fuel gauge, `estimate/3` turns `vph_pwr` into a battery percentage.

  See POWER-MANAGEMENT.md.
  """

  @charger "/sys/class/power_supply/pm660-charger"
  @vph_pwr "/sys/bus/iio/devices/iio:device*/in_voltage_vph_pwr_input"

  @type t :: %{
          source: :usb | :battery | :unknown,
          status: String.t() | nil,
          watts: float() | nil,
          volts: float() | nil
        }

  @doc """
  Reads the charger and the system rail. `opts` override the sysfs paths
  (`:charger`, a power_supply directory, and `:vph_pwr`, a glob), for tests.
  """
  @spec read(keyword()) :: t()
  def read(opts \\ []) do
    charger = Keyword.get(opts, :charger, @charger)
    volts = opts |> Keyword.get(:vph_pwr, @vph_pwr) |> vph_pwr()

    case integer(charger, "online") do
      1 ->
        %{
          source: :usb,
          status: string(charger, "status"),
          watts: watts(integer(charger, "current_now"), integer(charger, "voltage_now")),
          volts: volts
        }

      0 ->
        %{source: :battery, status: string(charger, "status"), watts: nil, volts: volts}

      nil ->
        %{source: :unknown, status: nil, watts: nil, volts: volts}
    end
  end

  @typedoc "A running battery estimate, carried from one reading to the next."
  @type estimate :: %{source: :usb | :battery, volts: float(), percent: integer()}

  # Charge against `vph_pwr` for the watch's cell: 595 mAh lithium-ion
  # polymer, 3.6-4.45 V by its device-tree node. The rail reads under the
  # cell's resting voltage while the watch runs, so the curve is a generic
  # high-voltage Li-ion discharge curve shifted down to where this watch reads
  # straight off a full charge (4.34-4.36 V). Good to roughly 10%; one logged
  # discharge from full to shutdown would calibrate it.
  @curve [
    {4.33, 100},
    {4.22, 90},
    {4.12, 80},
    {4.03, 70},
    {3.95, 60},
    {3.89, 50},
    {3.84, 40},
    {3.80, 30},
    {3.76, 20},
    {3.71, 10},
    {3.67, 5},
    {3.55, 0}
  ]

  # How far each reading moves the smoothed voltage, so a moment of load (a
  # radio transmitting, a burst of rendering) doesn't swing the percentage.
  @smoothing 0.3

  @doc "The battery percentage for a `vph_pwr` voltage on battery, from 0 to 100."
  @spec percent(float()) :: integer()
  def percent(volts) do
    @curve
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(0, fn [{high_v, high_p}, {low_v, low_p}] ->
      cond do
        volts >= high_v -> high_p
        volts >= low_v -> low_p + (volts - low_v) / (high_v - low_v) * (high_p - low_p)
        true -> nil
      end
    end)
    |> round()
  end

  @doc """
  Folds a `read/1` into the running battery estimate (`nil` to start).

  On battery the percentage only falls, and the voltage behind it is
  smoothed. On USB the charger lifts the rail above the cell's resting
  voltage, so the estimate reads high while charging: it only rises, stops at
  99 until the charger reports the cell full, and then shows 100. Plugging in
  or out starts over from the new reading. `restart: true` drops the smoothed
  voltage but keeps the percentage's direction, for a reading after the
  screen was off and nothing was sampled.
  """
  @spec estimate(estimate() | nil, t(), keyword()) :: estimate() | nil
  def estimate(previous, reading, opts \\ [])

  def estimate(previous, %{volts: nil}, _opts), do: previous
  def estimate(previous, %{source: :unknown}, _opts), do: previous

  def estimate(%{source: source} = previous, %{source: source} = reading, opts) do
    volts =
      if opts[:restart],
        do: reading.volts,
        else: previous.volts + @smoothing * (reading.volts - previous.volts)

    percent =
      case reading do
        %{source: :battery} -> Kernel.min(previous.percent, percent(volts))
        %{status: "Full"} -> 100
        _ -> volts |> percent() |> Kernel.min(99) |> Kernel.max(previous.percent)
      end

    %{previous | volts: volts, percent: percent}
  end

  def estimate(_previous, reading, _opts) do
    percent =
      case reading do
        %{source: :usb, status: "Full"} -> 100
        %{source: :usb} -> reading.volts |> percent() |> Kernel.min(99)
        _ -> percent(reading.volts)
      end

    %{source: reading.source, volts: reading.volts, percent: percent}
  end

  # Both in micro-units.
  defp watts(ua, uv) when is_integer(ua) and is_integer(uv), do: ua * uv / 1.0e12
  defp watts(_, _), do: nil

  defp vph_pwr(glob) do
    with [path | _] <- Path.wildcard(glob),
         {:ok, value} <- File.read(path),
         {microvolts, _} <- Integer.parse(value) do
      microvolts / 1.0e6
    else
      _ -> nil
    end
  end

  defp integer(dir, name) do
    with value when is_binary(value) <- string(dir, name),
         {integer, ""} <- Integer.parse(value) do
      integer
    else
      _ -> nil
    end
  end

  defp string(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, value} -> String.trim(value)
      _ -> nil
    end
  end
end
