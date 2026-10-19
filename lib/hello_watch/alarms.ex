defmodule HelloWatch.Alarms do
  @moduledoc """
  Alarms: times of day that ring once, or on chosen weekdays, kept on the
  data partition across reboots. HelloWatch.Clock.AlarmsApp sets them.

  An alarm is `%{id:, hour:, minute:, days:, on:}`, its time in the clock's
  time zone and `days` the ISO weekdays (1 is Monday) it repeats on, or `[]`
  to ring once and switch itself off. A due alarm is sent to the clock as
  `{:ring, :alarm, alarm}`. Across a suspend the RTC wakes the watch for the
  soonest one (see HelloWatch.Wakeup).
  """
  use GenServer
  require Logger

  alias HelloWatch.Wakeup

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The alarms, in order of time of day."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Adds an alarm at `hour:minute`, on, ringing once. Returns it."
  def add(server \\ __MODULE__, hour, minute), do: GenServer.call(server, {:add, hour, minute})

  @doc "Changes some of an alarm's `:hour`, `:minute`, `:days` and `:on`."
  def update(server \\ __MODULE__, id, changes),
    do: GenServer.call(server, {:update, id, changes})

  def delete(server \\ __MODULE__, id), do: GenServer.call(server, {:delete, id})

  @doc "When the soonest alarm that's on rings, as a UTC DateTime, or nil."
  def next(server \\ __MODULE__), do: GenServer.call(server, :next)

  @impl true
  def init(opts) do
    state = %{
      file: Keyword.get_lazy(opts, :file, fn -> data_file("alarms.etf") end),
      time_zone: Keyword.get_lazy(opts, :time_zone, &time_zone/0),
      notify: Keyword.get(opts, :notify, HelloWatch.Clock),
      alarms: [],
      checked: DateTime.utc_now(),
      timer: nil
    }

    {:ok, state |> Map.put(:alarms, load(state.file)) |> schedule()}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, sorted(state.alarms), state}

  # Changes come after a check, so an alarm moved to a moment just past
  # doesn't ring for it.
  def handle_call({:add, hour, minute}, _from, state) do
    state = check(state)
    id = Enum.reduce(state.alarms, 0, &Kernel.max(&1.id, &2)) + 1
    alarm = %{id: id, hour: hour, minute: minute, days: [], on: true}
    {:reply, alarm, changed(state, [alarm | state.alarms])}
  end

  def handle_call({:update, id, changes}, _from, state) do
    state = check(state)
    changes = Map.take(Map.new(changes), [:hour, :minute, :days, :on])
    alarms = Enum.map(state.alarms, &if(&1.id == id, do: Map.merge(&1, changes), else: &1))
    {:reply, :ok, changed(state, alarms)}
  end

  def handle_call({:delete, id}, _from, state),
    do: {:reply, :ok, changed(state, Enum.reject(state.alarms, &(&1.id == id)))}

  def handle_call(:next, _from, state), do: {:reply, soonest(state), state}

  @impl true
  def handle_cast(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, check(%{state | timer: nil})}

  # Each alarm that's on rings if it came due since the last check. The
  # first check is at start, so alarms missed while the watch was off stay
  # missed.
  defp check(state) do
    now = DateTime.utc_now()

    rung =
      for alarm <- state.alarms,
          alarm.on,
          at <- [due(alarm, state.checked, state.time_zone)],
          at != nil and DateTime.compare(at, now) != :gt,
          do: alarm

    for alarm <- rung, do: send_ring(state.notify, alarm)
    once = for alarm <- rung, alarm.days == [], do: alarm.id
    alarms = Enum.map(state.alarms, &if(&1.id in once, do: %{&1 | on: false}, else: &1))
    state = %{state | checked: now}
    if once != [], do: changed(state, alarms), else: schedule(state)
  end

  defp send_ring(notify, alarm) do
    if Process.whereis(notify), do: send(notify, {:ring, :alarm, alarm})
  end

  defp changed(state, alarms) do
    save(state.file, alarms)
    schedule(%{state | alarms: alarms})
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case Wakeup.delay(soonest(state)) do
      nil -> %{state | timer: nil}
      ms -> %{state | timer: Process.send_after(self(), :check, ms)}
    end
  end

  defp soonest(state) do
    now = DateTime.utc_now()

    state.alarms
    |> Enum.filter(& &1.on)
    |> Enum.map(&due(&1, now, state.time_zone))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  When `alarm` next rings after `from`, a UTC DateTime, ignoring whether
  it's on. On a day the clocks go forward past it, it rings when they do.
  """
  def due(alarm, from, time_zone) do
    {:ok, local} = DateTime.shift_zone(from, time_zone)
    today = DateTime.to_date(local)

    Enum.find_value(0..7, fn days ->
      day = Date.add(today, days)

      if alarm.days == [] or Date.day_of_week(day) in alarm.days do
        at =
          case DateTime.new(day, Time.new!(alarm.hour, alarm.minute, 0), time_zone) do
            {:ok, at} -> at
            {:ambiguous, first, _second} -> first
            {:gap, _before, just_after} -> just_after
          end

        if DateTime.compare(at, from) == :gt, do: DateTime.shift_zone!(at, "Etc/UTC")
      end
    end)
  end

  defp sorted(alarms), do: Enum.sort_by(alarms, &{&1.hour, &1.minute, &1.id})

  defp time_zone,
    do:
      Keyword.get(Application.get_env(:hello_watch, HelloWatch.Clock, []), :time_zone, "Etc/UTC")

  @doc false
  def data_file(name), do: Path.join(Application.get_env(:hello_watch, :data_dir, "/root"), name)

  defp load(file) do
    with {:ok, binary} <- File.read(file),
         alarms when is_list(alarms) <- :erlang.binary_to_term(binary, [:safe]) do
      alarms
    else
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  defp save(file, alarms) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, :erlang.term_to_binary(alarms), [:sync]),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      error -> Logger.warning("Alarms: can't save #{file}: #{inspect(error)}")
    end
  end
end
