defmodule HelloWatch.AlarmsTest do
  use ExUnit.Case

  alias HelloWatch.{Alarms, Timers, Wakeup}

  @moduletag :tmp_dir

  defp start(module, %{tmp_dir: dir}, name) do
    Process.register(self(), :"#{name}_notify")

    start_supervised!(
      {module,
       name: name,
       file: Path.join(dir, "#{name}.etf"),
       notify: :"#{name}_notify",
       time_zone: "Europe/Brussels"},
      id: name
    )
  end

  describe "due/3" do
    test "rings once at the next time of day, or on the next of its weekdays" do
      # A Thursday, 10:00 in Brussels.
      now = ~U[2026-10-15 08:00:00Z]
      once = %{hour: 7, minute: 30, days: []}
      assert Alarms.due(once, now, "Europe/Brussels") == ~U[2026-10-16 05:30:00Z]
      assert Alarms.due(%{once | hour: 11}, now, "Europe/Brussels") == ~U[2026-10-15 09:30:00Z]

      weekend = %{once | days: [6, 7]}
      assert Alarms.due(weekend, now, "Europe/Brussels") == ~U[2026-10-17 05:30:00Z]
    end

    test "rings when the clocks go forward past it" do
      # 02:30 doesn't exist in Brussels on 29 March 2026.
      alarm = %{hour: 2, minute: 30, days: []}

      assert Alarms.due(alarm, ~U[2026-03-28 12:00:00Z], "Europe/Brussels") ==
               ~U[2026-03-29 01:00:00Z]
    end
  end

  describe "alarms" do
    test "are kept across restarts", ctx do
      pid = start(Alarms, ctx, :alarms_a)
      alarm = Alarms.add(pid, 6, 45)
      :ok = Alarms.update(pid, alarm.id, days: [1, 2, 3, 4, 5])
      stop_supervised!(:alarms_a)

      Process.unregister(:alarms_a_notify)
      pid = start(Alarms, ctx, :alarms_a)
      assert [%{hour: 6, minute: 45, days: [1, 2, 3, 4, 5], on: true}] = Alarms.list(pid)
      assert %DateTime{} = Alarms.next(pid)
    end

    test "one due since the last check rings, and a one-off then switches off", ctx do
      pid = start(Alarms, ctx, :alarms_b)
      {:ok, local} = DateTime.shift_zone(DateTime.add(DateTime.utc_now(), -60), "Europe/Brussels")
      alarm = Alarms.add(pid, local.hour, local.minute)
      refute_received {:ring, _, _}

      :sys.replace_state(pid, &%{&1 | checked: DateTime.add(DateTime.utc_now(), -120)})
      GenServer.cast(pid, :check)
      assert_receive {:ring, :alarm, %{id: id}}
      assert id == alarm.id
      assert [%{on: false}] = Alarms.list(pid)
    end
  end

  describe "timers" do
    test "ring when they run out and go away", ctx do
      pid = start(Timers, ctx, :timers_a)
      Timers.start(pid, 1)
      long = Timers.start(pid, 600)
      assert [%{seconds: 1}, %{seconds: 600}] = Timers.list(pid)

      assert_receive {:ring, :timer, %{seconds: 1}}, 2000
      assert [%{id: id}] = Timers.list(pid)
      assert id == long.id
      assert Timers.next(pid) == long.ends

      :ok = Timers.cancel(pid, long.id)
      assert Timers.list(pid) == []
    end
  end

  describe "Wakeup.arm/1" do
    test "sets the RTC for the soonest alarm or timer", %{tmp_dir: dir} do
      path = Path.join(dir, "wakealarm")
      # The application's own services, which may hold others from host runs.
      timer = Timers.start(5)
      on_exit(fn -> Timers.cancel(timer.id) end)
      assert Wakeup.soonest() == timer.ends
      assert Wakeup.arm(path) == :ok
      assert File.read!(path) in ["+4", "+5"]
    end
  end
end
