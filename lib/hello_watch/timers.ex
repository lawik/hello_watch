defmodule HelloWatch.Timers do
  @moduledoc """
  Countdown timers, any number at once, kept on the data partition across
  reboots. HelloWatch.Clock.TimersApp starts them.

  A timer is `%{id:, seconds:, ends:}`: how long it was set for, and when
  it runs out as a UTC DateTime. The end is fixed by the wall clock, so a
  timer keeps running through a suspend; the RTC wakes the watch for the
  soonest (see HelloWatch.Wakeup). One that runs out is sent to the clock
  as `{:ring, :timer, timer}` and goes away.
  """
  use GenServer
  require Logger

  alias HelloWatch.{Alarms, Wakeup}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The timers running, soonest first."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Starts a timer for `seconds`. Returns it."
  def start(server \\ __MODULE__, seconds), do: GenServer.call(server, {:start, seconds})

  def cancel(server \\ __MODULE__, id), do: GenServer.call(server, {:cancel, id})

  @doc "When the soonest timer runs out, as a UTC DateTime, or nil."
  def next(server \\ __MODULE__), do: GenServer.call(server, :next)

  @impl true
  def init(opts) do
    file = Keyword.get_lazy(opts, :file, fn -> Alarms.data_file("timers.etf") end)

    state = %{
      file: file,
      notify: Keyword.get(opts, :notify, HelloWatch.Clock),
      timers: load(file),
      timer: nil
    }

    # Any that ran out while the watch was off ring now.
    {:ok, check(state)}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.timers, state}

  def handle_call({:start, seconds}, _from, state) do
    id = Enum.reduce(state.timers, 0, &Kernel.max(&1.id, &2)) + 1
    timer = %{id: id, seconds: seconds, ends: DateTime.add(DateTime.utc_now(), seconds)}
    {:reply, timer, changed(state, [timer | state.timers])}
  end

  def handle_call({:cancel, id}, _from, state),
    do: {:reply, :ok, changed(state, Enum.reject(state.timers, &(&1.id == id)))}

  def handle_call(:next, _from, state), do: {:reply, soonest(state.timers), state}

  @impl true
  def handle_cast(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, check(%{state | timer: nil})}

  defp check(state) do
    now = DateTime.utc_now()
    {done, running} = Enum.split_with(state.timers, &(DateTime.compare(&1.ends, now) != :gt))

    for timer <- done,
        Process.whereis(state.notify),
        do: send(state.notify, {:ring, :timer, timer})

    if done != [], do: changed(state, running), else: schedule(state)
  end

  defp changed(state, timers) do
    save(state.file, timers)
    schedule(%{state | timers: Enum.sort_by(timers, & &1.ends, DateTime)})
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case Wakeup.delay(soonest(state.timers)) do
      nil -> %{state | timer: nil}
      ms -> %{state | timer: Process.send_after(self(), :check, ms)}
    end
  end

  defp soonest([]), do: nil
  defp soonest(timers), do: timers |> Enum.map(& &1.ends) |> Enum.min(DateTime)

  defp load(file) do
    with {:ok, binary} <- File.read(file),
         timers when is_list(timers) <- :erlang.binary_to_term(binary, [:safe]) do
      timers
    else
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  defp save(file, timers) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, :erlang.term_to_binary(timers), [:sync]),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      error -> Logger.warning("Timers: can't save #{file}: #{inspect(error)}")
    end
  end
end
