defmodule HelloWatch.AccessPoint.Fallback do
  @moduledoc """
  Brings the access point (`HelloWatch.AccessPoint`) up by itself when the
  watch can't get on Wi-Fi, so it can still be reached over SSH and
  `mix upload` however broken the UI is. It runs beside the UI, not in it.

    * With no network configured on wlan0, the access point comes up as soon
      as wlan0 exists, and stays up.
    * With one configured but no connection for `@grace` (since boot, or since
      it last tried), the access point comes up. Once nobody has been on it
      for `@window`, wlan0 goes back to its network for another `@grace`, and
      so on until it connects. Away from home it's reachable either way; back
      home it rejoins.

  That goes for an access point started by hand from the Network app too:
  what's left alone is one in use. Nothing here remembers who raised it, so
  a restart of this process, or a stop that failed (tried again on the next
  poll), can't leave the watch on its access point for good. Wi-Fi that's
  off (its rfkill soft block, from the sky's switch or a suspend) isn't a
  failure. The passphrase is the access point's usual one, kept in
  `/root/access_point_psk`: a phone that joined `watch-XXXX` once, from the
  Network app, joins again by itself.

  `decide/4` makes every choice; the process only reads the state of wlan0
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
  `:connected`, `:trying` / `:unconfigured` (client mode, with or without a
  network to join), or the access point is up: `:ap_in_use` (someone's on
  it), `:ap_idle`, or `:ap_only` (there's no network to go back to).
  """
  @type wlan ::
          :absent
          | :blocked
          | :connected
          | :trying
          | :unconfigured
          | :ap_in_use
          | :ap_idle
          | :ap_only

  @typedoc """
  `since`: when the current attempt to connect began; `idle`: since when the
  access point has had nobody on it, or nil.
  """
  @type state :: %{since: integer(), idle: integer() | nil}

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
      # Nothing to fall back from: start the wait over.
      w when w in [:absent, :blocked, :connected] ->
        {:nothing, %{state | since: now, idle: nil}}

      :unconfigured ->
        {:start, %{state | idle: nil}}

      :trying when now - state.since >= grace ->
        {:start, %{state | idle: nil}}

      w when w in [:trying, :ap_in_use, :ap_only] ->
        {:nothing, %{state | idle: nil}}

      :ap_idle ->
        idle = state.idle || now

        # `idle` stays put, so a stop that failed is tried again next poll.
        if now - idle >= window,
          do: {:stop, %{state | since: now, idle: idle}},
          else: {:nothing, %{state | idle: idle}}
    end
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{since: now(), idle: nil}}
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
    Logger.info("Nobody on the access point: trying Wi-Fi again")

    with {:error, reason} <- AccessPoint.stop(),
         do: Logger.warning("Access point fallback: #{inspect(reason)}")
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
        ap_state()

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

  defp ap_state do
    clients = apply(VintageNet, :get, [["interface", @interface, "wifi", "clients"]]) || []

    cond do
      not AccessPoint.returnable?() -> :ap_only
      clients != [] -> :ap_in_use
      true -> :ap_idle
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
