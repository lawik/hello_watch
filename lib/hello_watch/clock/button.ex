defmodule HelloWatch.Clock.Button do
  @moduledoc """
  Reads the watch's two buttons and toggles the display on a press.

  The bottom button is `gpio-keys` (KEY_VOLUMEDOWN, 114). The top one is the
  PMIC power key (`pm8941_pwrkey`, KEY_POWER, 116), the only button that can
  wake the watch from suspend (see HelloWatch.Suspend); its press arrives as
  the watch resumes.
  """
  use GenServer

  @keys %{"gpio-keys" => 114, "pm8941_pwrkey" => 116}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    ports =
      for path <- Path.wildcard("/sys/class/input/event*"),
          {:ok, name} <- [File.read(Path.join(path, "device/name"))],
          code = @keys[String.trim(name)],
          into: %{} do
        port =
          Port.open(
            {:spawn_executable, System.find_executable("cat")},
            [:binary, :exit_status, args: ["/dev/input/" <> Path.basename(path)]]
          )

        {port, %{code: code, buffer: <<>>}}
      end

    if ports == %{},
      do: {:stop, :button_not_found},
      else: {:ok, %{ports: ports, target: Keyword.fetch!(opts, :target)}}
  end

  # Linux aarch64 input_event: two 64-bit timestamps, type/code/value.
  def decode(
        <<_::binary-size(16), type::little-16, code::little-16, value::little-signed-32,
          rest::binary>>
      ) do
    {events, remainder} = decode(rest)
    {[{type, code, value} | events], remainder}
  end

  def decode(partial), do: {[], partial}

  @impl true
  def handle_info({port, {:data, data}}, %{ports: ports} = state)
      when is_map_key(ports, port) do
    %{code: code, buffer: buffer} = button = ports[port]
    {events, buffer} = decode(buffer <> data)
    for {1, ^code, 1} <- events, do: send(state.target, :toggle_display)
    {:noreply, put_in(state, [:ports, port], %{button | buffer: buffer})}
  end

  def handle_info({port, {:exit_status, status}}, %{ports: ports} = state)
      when is_map_key(ports, port),
      do: {:stop, {:input_closed, status}, state}
end
