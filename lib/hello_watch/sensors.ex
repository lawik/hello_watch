defmodule HelloWatch.Sensors do
  @moduledoc """
  Opens nanohub sensor streams as Elixir ports.

  The calling process receives `{:sensor, port, event}` messages after passing
  each raw `nanohubctl` JSON line to `decode/2`.

  The hub hands each event to a single reader, so one port serves every sensor
  a caller asks for; see `open/1`. The heart sensor reports beats per minute
  directly in `value`, and null when it has no skin contact.
  """

  @nanohubctl "/usr/bin/nanohubctl"
  @sensors [:heart, :accel, :gyro, :battery]

  @doc """
  Opens one `nanohubctl` process streaming every sensor given.

  The hub hands each event to a single reader, so one process has to serve
  every sensor at once; separate processes eat each other's samples.
  """
  def open(sensors) when is_list(sensors) and sensors != [] do
    args = ["stream" | Enum.map(sensors, &stream_arg/1)]

    if File.exists?(@nanohubctl) do
      {:ok,
       Port.open({:spawn_executable, @nanohubctl}, [
         :binary,
         :exit_status,
         :stderr_to_stdout,
         {:line, 4096},
         args: args
       ])}
    else
      {:error, :unsupported}
    end
  end

  def close(port) when is_port(port), do: Port.close(port)

  def decode(port, {port, {:data, {:eol, line}}}) do
    case Jason.decode(line) do
      {:ok, event} -> {:sensor, port, event}
      {:error, reason} -> {:sensor_error, port, reason, line}
    end
  end

  def decode(port, {port, {:data, data}}), do: {:sensor_raw, port, data}
  def decode(port, {port, {:exit_status, status}}), do: {:sensor_exit, port, status}
  def decode(_port, message), do: message

  @doc """
  Resolves the `sensor` field of an event back to its atom, or nil when the
  hub reports something this module does not model.
  """
  def sensor_from_event(%{"sensor" => name}),
    do: Enum.find(@sensors, &(Atom.to_string(&1) == name))

  def sensor_from_event(_event), do: nil

  defp stream_arg({sensor, rate_hz})
       when sensor in @sensors and is_number(rate_hz) and rate_hz > 0,
       do: "#{sensor}@#{rate_hz}"

  defp stream_arg(sensor) when sensor in @sensors, do: Atom.to_string(sensor)
end
