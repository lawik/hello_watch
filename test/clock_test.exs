defmodule HelloWatch.ClockTest do
  use ExUnit.Case
  alias HelloWatch.Clock
  alias HelloWatch.Clock.{Button, Display, Moon, Palette, Touch}

  @size 454
  @frame_bytes @size * @size * 4

  # Stands in for HelloWatch.Clock.Display: frames come straight to the test
  # process, and sleep/wake are reported to it.
  defmodule FakeDisplay do
    def target, do: Application.fetch_env!(:hello_watch, :display_test_owner)
    def sleep, do: send(target(), :sleep)
    def wake, do: send(target(), :wake)
    def dim, do: :ok
    def undim, do: :ok
  end

  defp start_clock(_context) do
    Application.put_env(:hello_watch, :display_test_owner, self())
    on_exit(fn -> Application.delete_env(:hello_watch, :display_test_owner) end)
    pid = start_supervised!({Clock, name: Clock, display: FakeDisplay})
    on_exit(fn -> Palette.bgr(false) end)
    # The first frames can come before the fonts have loaded.
    next_frame()
    Process.sleep(500)
    %{clock: pid, frame: latest_frame()}
  end

  defp next_frame(timeout \\ 5000) do
    receive do
      {:emerge_skia_frame, %VideoInterop.Frame{storage: %{data: data}}} -> data
    after
      timeout -> flunk("no frame within #{timeout} ms")
    end
  end

  # Opens `app` from the inventory, as a finger would.
  @apps [:clock, :alarms, :timers, :stopwatch, :battery, :network, :sensors, :moon, :tailscale]

  defp open(pid, app) do
    send(pid, {:vdrag, -200})
    send(pid, {:vrelease, -200})
    Process.sleep(600)
    assert %{overlay: :inventory} = :sys.get_state(pid)

    angle = 2 * :math.pi() * Enum.find_index(@apps, &(&1 == app)) / length(@apps)
    send(pid, {:tap, {227 + 124 * :math.sin(angle), 227 - 124 * :math.cos(angle)}})
    Process.sleep(600)
    assert %{overlay: nil, app: ^app} = :sys.get_state(pid)
  end

  # The read is asynchronous; poll until it lands.
  defp eventually(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end

  defp latest_frame(last \\ nil) do
    receive do
      {:emerge_skia_frame, %VideoInterop.Frame{storage: %{data: data}}} -> latest_frame(data)
    after
      0 -> last || next_frame()
    end
  end

  defp frames(count \\ 0) do
    receive do
      {:emerge_skia_frame, _} -> frames(count + 1)
    after
      0 -> count
    end
  end

  # How many different pictures have arrived.
  defp distinct_frames(seen \\ MapSet.new()) do
    receive do
      {:emerge_skia_frame, %VideoInterop.Frame{storage: %{data: data}}} ->
        distinct_frames(MapSet.put(seen, :erlang.md5(data)))
    after
      0 -> MapSet.size(seen)
    end
  end

  defp flush_frames do
    receive do
      {:emerge_skia_frame, _} -> flush_frames()
    after
      0 -> :ok
    end
  end

  # Frames are drawn with red and blue swapped for the framebuffer; this
  # reads back the colour the panel shows.
  defp pixel(frame, x, y) do
    <<b, g, r, _x>> = binary_part(frame, (y * @size + x) * 4, 4)
    {r, g, b}
  end

  describe "the viewport" do
    setup :start_clock

    test "renders the night-sky face for the framebuffer, once a minute", %{
      clock: pid,
      frame: frame
    } do
      assert byte_size(frame) == @frame_bytes
      {r, g, b} = pixel(frame, 4, 227)
      assert b > r and b > g and b < 60, "a dark violet sky, got #{inspect({r, g, b})}"
      # No second hand: the face only ticks with the minute.
      assert is_reference(:sys.get_state(pid).tick_ref)
    end

    test "the button sleeps the display and stops rendering, and wakes it", %{clock: pid} do
      Clock.toggle()
      # Contact bounce right after the real press does not wake it again.
      Clock.toggle()
      assert_receive :sleep
      refute_receive :wake, 300
      assert %{on: false} = Clock.status()

      flush_frames()
      refute_receive {:emerge_skia_frame, _}, 1200
      # The minute's tick, arriving while off, doesn't schedule another.
      send(pid, {:tick, :sys.get_state(pid).tick_ref})
      assert %{tick_ref: nil} = :sys.get_state(pid)

      Process.sleep(250)
      Clock.toggle()
      # The face hasn't changed, so there may be no new frame; the display
      # unblanks on its own after a moment.
      assert_receive :wake
      assert %{on: true} = Clock.status()
    end

    test "touch wakes a dark screen and resets the idle timer while it is on", %{clock: pid} do
      %{idle_timer: before} = :sys.get_state(pid)
      send(pid, :touch)
      refute :sys.get_state(pid).idle_timer == before
      refute_received :wake

      send(pid, :screen_timeout)
      assert_receive :sleep
      send(pid, :touch)
      assert_receive :wake
      assert %{on: true} = Clock.status()
    end

    test "the inventory opens apps, and they become the recents", %{clock: pid} do
      open(pid, :battery)
      assert %{page: :battery, recents: [:battery, :clock], overlay: nil} = Clock.status()
      open(pid, :network)
      assert %{recents: [:network, :battery, :clock]} = Clock.status()

      # Reopening one moves it back to the front.
      open(pid, :clock)
      assert %{page: :clock, recents: [:clock, :network, :battery]} = Clock.status()

      open(pid, :tailscale)
      # Tailscale doesn't run on the host.
      assert eventually(fn -> :sys.get_state(pid).tailscale end) == %{
               state: "Unavailable",
               logging_in: false,
               auth_url: nil,
               name: nil,
               ip: nil,
               tailnet: nil
             }
    end

    test "the open inventory is drawn over the face", %{clock: pid} do
      send(pid, {:vdrag, -200})
      send(pid, {:vrelease, -200})
      Process.sleep(600)
      frame = latest_frame()

      # Its dark circle covers the middle of the panel.
      {r, g, b} = pixel(frame, 227, 250)
      assert r < 12 and g < 12 and b < 24, "the inventory's darkness, got #{inspect({r, g, b})}"
    end

    test "a sideways drag pulls the previous app in over this one, switching past halfway", %{
      clock: pid
    } do
      open(pid, :battery)
      flush_frames()

      # The battery is the newest app: there's nothing to pull in from the right.
      send(pid, {:drag, -100})
      assert %{drag: nil} = :sys.get_state(pid)

      # Right brings back the clock, over the battery, which stays put.
      send(pid, {:drag, 100})
      assert %{drag: 100} = :sys.get_state(pid)
      assert byte_size(next_frame()) == @frame_bytes

      # Not far enough: it slides back out.
      send(pid, {:release, 100})

      assert %{drag: nil, moving: %{base: :battery, incoming: :clock, to: to}} =
               :sys.get_state(pid)

      assert to < 0
      assert %{page: :battery} = Clock.status()

      # A drag whose release never comes settles by itself.
      send(pid, {:drag, 60})
      Process.sleep(1100)
      assert %{drag: nil, app: :battery} = :sys.get_state(pid)

      flush_frames()
      send(pid, {:drag, 300})
      send(pid, {:release, 300})
      assert %{page: :clock, recents: [:battery, :clock]} = Clock.status()
      # It slides the rest of the way in over several frames.
      Process.sleep(250)
      assert frames() >= 3
      Process.sleep(400)
      assert %{moving: nil} = :sys.get_state(pid)

      # And left goes forward to the battery again.
      send(pid, {:swipe, :left})
      assert %{page: :battery} = Clock.status()
    end

    test "pulling down shows the sky, and up closes it; short pulls spring back", %{clock: pid} do
      send(pid, {:vdrag, 200})
      assert %{vdrag: %{kind: :sky}} = :sys.get_state(pid)
      send(pid, {:vrelease, 260})
      Process.sleep(700)
      assert %{overlay: :sky} = Clock.status()

      # Sideways drags do nothing in the sky; a tap away from the stars
      # flips nothing. (The host's own rfkill switches are real: tests never
      # tap a star.)
      send(pid, {:drag, -300})
      send(pid, {:tap, {227, 430}})
      assert %{drag: nil, control_task: nil} = :sys.get_state(pid)

      send(pid, {:vdrag, -150})
      send(pid, {:vrelease, -300})
      Process.sleep(700)
      assert %{overlay: nil} = Clock.status()

      send(pid, {:vdrag, 60})
      send(pid, {:vrelease, 60})
      Process.sleep(500)
      assert %{overlay: nil, vmoving: nil} = :sys.get_state(pid)

      # Up opens the inventory, and down closes it.
      send(pid, {:vdrag, -200})
      send(pid, {:vrelease, -200})
      Process.sleep(600)
      assert %{overlay: :inventory} = Clock.status()
      send(pid, {:vdrag, 200})
      send(pid, {:vrelease, 200})
      Process.sleep(600)
      assert %{overlay: nil, page: :clock} = Clock.status()
    end

    test "a pull opens past 40% when let go, and springs back short of it", %{clock: pid} do
      # 40% of the inventory's travel is just over 134 px, past the dead zone.
      send(pid, {:vdrag, -130})
      send(pid, {:vrelease, -130})
      Process.sleep(500)
      assert %{overlay: nil, vmoving: nil} = :sys.get_state(pid)

      send(pid, {:vdrag, -140})
      send(pid, {:vrelease, -140})
      Process.sleep(500)
      assert %{overlay: :inventory, vmoving: nil} = :sys.get_state(pid)

      # Closing is the same the other way: it stays open short of 40%.
      send(pid, {:vdrag, 130})
      send(pid, {:vrelease, 130})
      Process.sleep(500)
      assert %{overlay: :inventory, vmoving: nil} = :sys.get_state(pid)

      send(pid, {:vdrag, 140})
      send(pid, {:vrelease, 140})
      Process.sleep(500)
      assert %{overlay: nil, vmoving: nil} = :sys.get_state(pid)
    end

    test "a pull let go eases the rest of the way over several frames", %{clock: pid} do
      # The first pull mounts nothing new: the inventory is there, closed.
      send(pid, {:vdrag, -180})
      Process.sleep(200)
      flush_frames()
      send(pid, {:vrelease, -180})
      Process.sleep(400)
      assert distinct_frames() >= 3
      assert %{overlay: :inventory} = :sys.get_state(pid)

      Process.sleep(200)
      send(pid, {:vdrag, 200})
      Process.sleep(200)
      flush_frames()
      send(pid, {:vrelease, 200})
      Process.sleep(400)
      assert distinct_frames() >= 3
      assert %{overlay: nil} = :sys.get_state(pid)
    end

    test "a pull whose release never comes settles by itself", %{clock: pid} do
      send(pid, {:vdrag, -200})
      assert %{vdrag: %{kind: :inventory}} = :sys.get_state(pid)
      Process.sleep(1100)
      assert %{vdrag: nil} = :sys.get_state(pid)
      Process.sleep(500)
      assert %{overlay: :inventory, vmoving: nil} = :sys.get_state(pid)

      send(pid, {:vdrag, 60})
      Process.sleep(1600)
      assert %{overlay: :inventory, vdrag: nil, vmoving: nil} = :sys.get_state(pid)

      # A pull that keeps moving doesn't time out.
      send(pid, {:vdrag, 100})
      Process.sleep(700)
      send(pid, {:vdrag, 250})
      Process.sleep(700)
      assert %{vdrag: %{kind: :inventory}} = :sys.get_state(pid)
      send(pid, {:vrelease, 250})
      Process.sleep(500)
      assert %{overlay: nil, vdrag: nil, vmoving: nil} = :sys.get_state(pid)
    end

    test "ignores swipes while the screen is off", %{clock: pid} do
      send(pid, :screen_timeout)
      assert_receive :sleep
      send(pid, {:swipe, :left})
      assert %{page: :clock, on: false} = Clock.status()
    end

    test "the stopwatch runs on a tap, keeping the screen on, and stops on another", %{
      clock: pid
    } do
      open(pid, :stopwatch)
      send(pid, {:tap, {227, 333}})
      assert %{stopwatch: %{since: since}} = :sys.get_state(pid)
      assert since != nil

      # It redraws fast while it runs, and neither dims nor sleeps.
      flush_frames()
      Process.sleep(500)
      assert frames() >= 5
      send(pid, :dim)
      send(pid, :screen_timeout)
      assert %{on: true, dimmed: false} = :sys.get_state(pid)

      send(pid, {:tap, {227, 333}})
      assert %{stopwatch: %{since: nil, total: total}, app_ref: nil} = :sys.get_state(pid)
      assert total >= 500
      send(pid, :screen_timeout)
      assert %{on: false} = :sys.get_state(pid)
    end

    test "a ring wakes the screen on its app until a tap stops it", %{clock: pid} do
      Clock.toggle()
      assert_receive :sleep
      send(pid, {:ring, :timer, %{id: 1, seconds: 60, ends: DateTime.utc_now()}})
      assert %{on: true, app: :timers, ringing: %{kind: :timer}} = :sys.get_state(pid)

      # It stays on, past the idle timeout, until a tap.
      send(pid, :screen_timeout)
      assert %{on: true} = :sys.get_state(pid)
      send(pid, {:tap, {227, 227}})
      assert %{ringing: nil, on: true} = :sys.get_state(pid)
    end
  end

  describe "Display" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "hello_watch_display_#{System.unique_integer([:positive])}")

      sysfs = Path.join(dir, "fb0")
      backlight = Path.join(dir, "backlight/panel")
      File.mkdir_p!(sysfs)
      File.mkdir_p!(backlight)

      for {name, value} <- [
            {"virtual_size", "454,454"},
            {"bits_per_pixel", "32"},
            {"stride", "1920"},
            {"blank", "0"}
          ],
          do: File.write!(Path.join(sysfs, name), value)

      File.write!(Path.join(backlight, "max_brightness"), "255")
      File.write!(Path.join(backlight, "brightness"), "0")
      File.write!(Path.join(dir, "fb"), "")
      on_exit(fn -> File.rm_rf!(dir) end)

      pid =
        start_supervised!(
          {Display,
           name: :test_display,
           device: Path.join(dir, "fb"),
           sysfs: sysfs,
           backlight: Path.join(dir, "backlight/*"),
           vtconsole: Path.join(dir, "vtcon*")}
        )

      %{display: pid, dir: dir, sysfs: sysfs, backlight: backlight}
    end

    defp frame(rgb), do: :binary.copy(rgb, @size * @size)

    defp send_frame(display, data) do
      frame = %VideoInterop.Frame{
        coded_width: @size,
        coded_height: @size,
        visible_rect: %VideoInterop.Rect{x: 0, y: 0, width: @size, height: @size},
        storage: %VideoInterop.Binary{
          data: data,
          planes: [%VideoInterop.Binary.Plane{offset: 0, stride: @size * 4}]
        }
      }

      send(display, {:emerge_skia_frame, frame})
      :sys.get_state(display)
    end

    defp read(dir, name), do: File.read!(Path.join(dir, name))

    test "writes frames to the framebuffer as they are, in padded rows", %{
      display: display,
      dir: dir
    } do
      send_frame(display, frame(<<1, 2, 3, 4>>))
      fb = read(dir, "fb")
      assert byte_size(fb) == 1920 * @size
      assert binary_part(fb, 0, 8) == <<1, 2, 3, 4, 1, 2, 3, 4>>
      assert binary_part(fb, 1816, 104) == :binary.copy(<<0>>, 104)
      assert binary_part(fb, 1920, 4) == <<1, 2, 3, 4>>
    end

    test "fades the brightness down before blanking, and up after the next frame", ctx do
      assert read(ctx.backlight, "brightness") == "255"

      Display.sleep(:test_display)
      Process.sleep(700)
      assert read(ctx.backlight, "brightness") == "0"
      assert read(ctx.sysfs, "blank") == "4"

      Display.wake(:test_display)
      :sys.get_state(ctx.display)
      assert read(ctx.sysfs, "blank") == "4"

      send_frame(ctx.display, frame(<<9, 9, 9, 9>>))
      assert read(ctx.sysfs, "blank") == "0"
      Process.sleep(700)
      assert read(ctx.backlight, "brightness") == "255"
    end

    test "unblanks without a new frame once the wake times out", ctx do
      Display.sleep(:test_display)
      Process.sleep(700)
      Display.wake(:test_display)
      Process.sleep(400)
      assert read(ctx.sysfs, "blank") == "0"
    end
  end

  test "encodes frames for packed 24 bpp and padded 32 bpp framebuffers" do
    frame = :binary.copy(<<1, 2, 3, 4>>, @size * @size)

    assert Display.encode(frame, 32, 1816) == frame

    assert IO.iodata_to_binary(Display.encode(frame, 24, 1362)) ==
             :binary.copy(<<1, 2, 3>>, @size * @size)

    padded = IO.iodata_to_binary(Display.encode(frame, 32, 1920))
    assert byte_size(padded) == 1920 * @size
    assert binary_part(padded, 1816, 104) == :binary.copy(<<0>>, 104)
    assert binary_part(padded, 1920, 4) == <<1, 2, 3, 4>>
  end

  test "knows the moon's phase" do
    # A new moon, and a full one about half a synodic month later.
    assert Moon.phase(~U[2000-01-06 18:14:00Z]) < 0.001
    assert_in_delta Moon.phase(~U[2026-10-26 04:12:00Z]), 0.5, 0.02
    assert_in_delta Moon.lit(0.5), 1.0, 0.001
    assert_in_delta Moon.lit(0.25), 0.5, 0.001
  end

  test "decodes split and batched evdev events without treating repeats as presses" do
    event = fn value -> <<0::128, 1::little-16, 114::little-16, value::little-signed-32>> end
    <<first::binary-size(11), rest::binary>> = event.(1)
    assert {[], ^first} = Button.decode(first)

    assert {[{1, 114, 1}, {1, 114, 2}, {1, 114, 0}], <<>>} =
             Button.decode(first <> rest <> event.(2) <> event.(0))
  end

  test "recognizes taps, and drags locked to an axis" do
    events = [
      {3, 57, 4},
      {3, 53, 350},
      {3, 54, 200},
      {0, 0, 0},
      {3, 53, 330},
      {0, 0, 0},
      {3, 53, 210},
      {3, 54, 220},
      {0, 0, 0},
      {3, 57, -1}
    ]

    assert {[{:drag, -20}, {:drag, -140}, {:release, -140}], %{down: false}} =
             Touch.gesture(events)

    vertical = [
      {1, 330, 1},
      {3, 53, 200},
      {3, 54, 100},
      {0, 0, 0},
      {3, 53, 220},
      {3, 54, 300},
      {1, 330, 0}
    ]

    assert {[], _state} = Touch.gesture(vertical)

    # A new contact mid-drag lets the old drag go.
    restarted = [
      {3, 57, 7},
      {3, 53, 300},
      {3, 54, 200},
      {0, 0, 0},
      {3, 53, 250},
      {0, 0, 0},
      {3, 57, 8}
    ]

    assert {[{:drag, -50}, {:release, -50}], %{down: true, dragging: false}} =
             Touch.gesture(restarted)

    tap = [{1, 330, 1}, {3, 53, 200}, {3, 54, 100}, {0, 0, 0}, {3, 53, 210}, {1, 330, 0}]
    assert {[{:tap, {200, 100}}], _state} = Touch.gesture(tap)

    pull = [
      {1, 330, 1},
      {3, 53, 200},
      {3, 54, 100},
      {0, 0, 0},
      {3, 54, 160},
      {0, 0, 0},
      {1, 330, 0}
    ]

    assert {[{:vdrag, 60}, {:vrelease, 60}], _state} = Touch.gesture(pull)
  end
end
