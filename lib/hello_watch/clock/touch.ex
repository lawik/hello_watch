defmodule HelloWatch.Clock.Touch do
  @moduledoc """
  Reads taps and horizontal drags from the Zinitix touchscreen, whose
  coordinates are panel pixels (0-453).

  It sends the target `:touch` when a finger lands, `{:drag, dx}` as a
  horizontal drag moves (dx in pixels from where it started, the latest
  only), `{:release, dx}` when a drag lets go, and `:tap` for a touch that
  barely moved. Vertical movement is ignored.
  """
  use GenServer

  @ev_syn 0
  @ev_key 1
  @ev_abs 3
  @btn_touch 330
  @abs_x 0
  @abs_y 1
  @abs_mt_x 53
  @abs_mt_y 54
  @abs_mt_tracking_id 57
  # A touch becomes a drag once it has moved this far, mostly sideways.
  @drag_slop 12
  # A touch that moves less than this is a tap.
  @tap_slop 25

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path =
      Path.wildcard("/sys/class/input/event*")
      |> Enum.find(fn path ->
        case File.read(Path.join(path, "device/name")) do
          {:ok, name} -> String.contains?(String.downcase(name), "zinitix")
          _ -> false
        end
      end)

    if path do
      port =
        Port.open({:spawn_executable, System.find_executable("cat")}, [
          :binary,
          :exit_status,
          args: ["/dev/input/" <> Path.basename(path)]
        ])

      {:ok,
       %{
         port: port,
         buffer: <<>>,
         target: Keyword.fetch!(opts, :target),
         x: nil,
         y: nil,
         start: nil,
         down: false,
         dragging: false
       }}
    else
      {:stop, :touchscreen_not_found}
    end
  end

  def decode(
        <<_::binary-size(16), type::little-16, code::little-16, value::little-signed-32,
          rest::binary>>
      ) do
    {events, remainder} = decode(rest)
    {[{type, code, value} | events], remainder}
  end

  def decode(partial), do: {[], partial}

  def gesture(events, state \\ %{x: nil, y: nil, start: nil, down: false, dragging: false}) do
    {gestures, state} = Enum.reduce(events, {[], state}, &event/2)
    {Enum.reverse(gestures), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {events, buffer} = decode(state.buffer <> data)

    {gestures, gesture_state} =
      gesture(events, Map.take(state, [:x, :y, :start, :down, :dragging]))

    if gesture_state.down and not state.down, do: send(state.target, :touch)
    Enum.each(latest_drag(gestures), &send(state.target, &1))
    {:noreply, state |> Map.merge(gesture_state) |> Map.put(:buffer, buffer)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:input_closed, status}, state}

  defp event({@ev_abs, code, value}, {gestures, state}) when code in [@abs_x, @abs_mt_x],
    do: {gestures, %{state | x: value}}

  defp event({@ev_abs, code, value}, {gestures, state}) when code in [@abs_y, @abs_mt_y],
    do: {gestures, %{state | y: value}}

  defp event({@ev_abs, @abs_mt_tracking_id, value}, acc) when value >= 0, do: begin_touch(acc)
  defp event({@ev_abs, @abs_mt_tracking_id, -1}, acc), do: end_touch(acc)
  defp event({@ev_key, @btn_touch, 1}, acc), do: begin_touch(acc)
  defp event({@ev_key, @btn_touch, 0}, acc), do: end_touch(acc)

  defp event({@ev_syn, 0, 0}, {gestures, %{down: true, start: nil, x: x, y: y} = state})
       when is_integer(x) and is_integer(y), do: {gestures, %{state | start: {x, y}}}

  defp event({@ev_syn, 0, 0}, {gestures, %{down: true, start: {sx, sy}, x: x, y: y} = state}) do
    dx = x - sx

    if state.dragging or (abs(dx) >= @drag_slop and abs(dx) > abs(y - sy)),
      do: {[{:drag, dx} | gestures], %{state | dragging: true}},
      else: {gestures, state}
  end

  defp event(_, acc), do: acc

  # A new contact while a drag is still going (the controller can start a
  # fresh tracking id mid-drag) lets that drag go first, so it never hangs.
  defp begin_touch({gestures, %{dragging: true, start: {sx, _}, x: x} = state}),
    do: begin_touch({[{:release, x - sx} | gestures], %{state | dragging: false}})

  defp begin_touch({gestures, state}),
    do: {gestures, %{state | down: true, start: nil, dragging: false}}

  defp end_touch({gestures, %{down: true, start: {sx, sy}, x: x, y: y} = state}) do
    dx = x - sx

    gesture =
      cond do
        state.dragging -> [{:release, dx}]
        abs(dx) < @tap_slop and abs(y - sy) < @tap_slop -> [:tap]
        true -> []
      end

    {gesture ++ gestures, %{state | down: false, start: nil, dragging: false}}
  end

  defp end_touch({gestures, state}),
    do: {gestures, %{state | down: false, start: nil, dragging: false}}

  # A batch of events can hold many drag steps; only the last one of each
  # run matters to the display.
  defp latest_drag(gestures) do
    gestures
    |> Enum.chunk_by(&match?({:drag, _}, &1))
    |> Enum.flat_map(fn
      [{:drag, _} | _] = drags -> [List.last(drags)]
      other -> other
    end)
  end
end
