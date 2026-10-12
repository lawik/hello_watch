defmodule HelloWatch.PowerTest do
  use ExUnit.Case, async: true
  alias HelloWatch.Power

  setup do
    dir = Path.join(System.tmp_dir!(), "hello_watch_power_#{System.unique_integer([:positive])}")
    charger = Path.join(dir, "pm660-charger")
    adc = Path.join(dir, "iio:device0")
    File.mkdir_p!(charger)
    File.mkdir_p!(adc)
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [charger: charger, vph_pwr: Path.join(dir, "iio:device*/in_voltage_vph_pwr_input")]
    %{charger: charger, adc: adc, opts: opts}
  end

  defp write(dir, values),
    do: for({name, value} <- values, do: File.write!(Path.join(dir, name), value <> "\n"))

  test "reports the watts going in over USB", ctx do
    write(ctx.charger, [
      {"online", "1"},
      {"status", "Charging"},
      {"current_now", "216411"},
      {"voltage_now", "4492187"}
    ])

    write(ctx.adc, [{"in_voltage_vph_pwr_input", "4248618"}])

    assert %{source: :usb, status: "Charging", watts: watts, volts: 4.248618} =
             Power.read(ctx.opts)

    assert_in_delta watts, 0.9722, 0.0001
  end

  test "reports the system rail on battery", ctx do
    write(ctx.charger, [{"online", "0"}, {"status", "Discharging"}, {"current_now", "0"}])
    write(ctx.adc, [{"in_voltage_vph_pwr_input", "3912000"}])

    assert Power.read(ctx.opts) == %{
             source: :battery,
             status: "Discharging",
             watts: nil,
             volts: 3.912
           }
  end

  test "reports nothing it cannot read", ctx do
    File.rm_rf!(ctx.charger)
    File.rm_rf!(ctx.adc)
    assert Power.read(ctx.opts) == %{source: :unknown, status: nil, watts: nil, volts: nil}
  end

  describe "estimate" do
    defp battery(volts), do: %{source: :battery, status: "Discharging", watts: nil, volts: volts}
    defp usb(status, volts), do: %{source: :usb, status: status, watts: 1.0, volts: volts}

    test "maps the rail voltage onto the cell's charge" do
      assert Power.percent(4.36) == 100
      assert Power.percent(3.89) == 50
      assert Power.percent(3.865) == 45
      assert Power.percent(3.4) == 0
    end

    test "on battery, smooths the voltage and never rises" do
      start = Power.estimate(nil, battery(3.89))
      assert start.percent == 50

      # A dip under load moves it only part of the way, and the recovery
      # after it doesn't push the percentage back up.
      dipped = Power.estimate(start, battery(3.79))
      assert dipped.percent in 40..49
      assert Power.estimate(dipped, battery(3.95)).percent == dipped.percent

      assert Power.estimate(dipped, battery(3.79), restart: true).percent == 28
    end

    test "while charging, stops short of 100 until the charger reports full" do
      charging = Power.estimate(Power.estimate(nil, battery(3.89)), usb("Charging", 4.4))
      assert charging.percent == 99
      assert Power.estimate(charging, usb("Full", 4.4)).percent == 100
      assert Power.estimate(charging, battery(4.30)).percent == 97
    end

    test "keeps the last estimate when there is no reading" do
      start = Power.estimate(nil, battery(3.89))

      assert Power.estimate(start, %{source: :unknown, status: nil, watts: nil, volts: nil}) ==
               start

      assert Power.estimate(nil, %{source: :unknown, status: nil, watts: nil, volts: nil}) == nil
    end
  end
end
