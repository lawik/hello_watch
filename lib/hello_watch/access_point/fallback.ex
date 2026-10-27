defmodule HelloWatch.AccessPoint.Fallback do
  @moduledoc """
  Brings the access point (`HelloWatch.AccessPoint`) up by itself when the
  watch can't get on Wi-Fi, so it can still be reached over SSH and
  `mix upload` however broken the UI is. It runs beside the UI, not in it.

    * With no network configured on wlan0, the access point comes up as soon
      as wlan0 exists, and stays up.
    * With one configured but no connection for `@grace` (since boot, or since
      it last tried), the access point comes up for `@window`, then wlan0 goes
      back to its network for another `@grace`, and so on until it connects.
      Away from home it's reachable either way; back home it rejoins.

  Wi-Fi that's off (its rfkill soft block, from the sky's switch or a
  suspend) isn't a failure, and an access point started by hand is left
  alone. The passphrase is the access point's usual one, kept in
  `/root/access_point_psk`: a phone that joined `watch-XXXX` once, from the
  Network app, joins again by itself.

  `decide/3` makes every choice; the process only reads the state of wlan0
  every `@poll` and acts on it.
  """

  use GenServer

  require Logger

  alias HelloWatch.AccessPoint

  @interface "wlan0"
  @rfkill "/sys/class/rfkill"
  @poll :timer.seconds(15)
  @grace :timer.minutes(3)
  @window :timer.minutes(10)

  @typedoc """
  What wlan0 is doing: `:absent` (no interface yet), `:blocked` (rfkill),
  `:ap` (the access point is up), `:connected`, or `:trying` / `:unconfigured`
  (client mode, with or without a network to join).
  """
  @type wlan :: :absent | :blocked | :ap | :connected | :trying | :unconfigured

  @typedoc """
  `since`: when the current attempt to connect began; `ours`: when the
  fallback raised the access point, or nil; `stay`: whether it stays up, as
  there was no network to go back to.
  """
  @type state :: %{since: integer(), ours: integer() | nil, stay: boolean()}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  What to do about `wlan` at `now` (ms): `{:start | :stop | :nothing, state}`.
  `opts` take `:grace` and `:window` in ms.
  """
  @spec decide(state(), wlan(), integer(), keyword()) :: {:start | :stop | :nothing, state()}
  def decide(state, wlan, now, opts \\ []) do
    grace = Keyword.get(opts, :grace, @grace)
    window = Keyword.get(opts, :window, @window)

    case wlan do
      # Nothing to fall back from: start the wait over. An access point seen
      # after this was started by hand.
      w when w in [:absent, :blocked, :connected] ->
        {:nothing, %{state | since: now, ours: nil, stay: false}}

      :unconfigured ->
        {:start, %{state | ours: now, stay: true}}

      :trying when now - state.since >= grace ->
        {:start, %{state | ours: now, stay: false}}

      :trying ->
        {:nothing, %{state | ours: nil, stay: false}}

      # Up by hand, or with no network to go back to: leave it.
      :ap when state.ours == nil or state.stay ->
        {:nothing, state}

      :ap ->
        if now - state.ours >= window,
          do: {:stop, %{state | ours: nil, since: now}},
          else: {:nothing, state}
    end
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{since: now(), ours: nil, stay: false}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll)
    wlan = wlan()
    {action, state} = decide(state, wlan, now())
    act(action, wlan)
    {:noreply, state}
  end

  # A failed start is tried again on the next poll: wlan0 is still unconnected.
  defp act(:start, wlan) do
    Logger.warning("No Wi-Fi (#{wlan}): bringing up the access point #{AccessPoint.ssid()}")

    with {:error, reason} <- AccessPoint.start(),
         do: Logger.warning("Access point fallback: #{inspect(reason)}")
  end

  defp act(:stop, _wlan) do
    Logger.info("Access point fallback timed out: trying Wi-Fi again")
    AccessPoint.stop()
  end

  defp act(:nothing, _wlan), do: :ok

  defp wlan do
    cond do
      not Code.ensure_loaded?(VintageNet) -> :absent
      blocked?() -> :blocked
      true -> vintage_net_state()
    end
  end

  defp vintage_net_state do
    case apply(VintageNet, :get_configuration, [@interface]) do
      nil ->
        :absent

      %{vintage_net_wifi: %{networks: [%{mode: :ap} | _]}} ->
        :ap

      %{vintage_net_wifi: %{networks: [_ | _]}} ->
        if apply(VintageNet, :get, [["interface", @interface, "connection"]]) in [:lan, :internet],
          do: :connected,
          else: :trying

      _no_networks ->
        if apply(VintageNet, :get, [["interface", @interface, "present"]]),
          do: :unconfigured,
          else: :absent
    end
  end

  defp blocked? do
    @rfkill
    |> Path.join("rfkill*")
    |> Path.wildcard()
    |> Enum.any?(fn path ->
      File.read(Path.join(path, "type")) == {:ok, "wlan\n"} and
        File.read(Path.join(path, "soft")) == {:ok, "1\n"}
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
