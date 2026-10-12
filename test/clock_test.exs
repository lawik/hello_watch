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

    test "a drag moves the page with the finger and turns it only past halfway", %{clock: pid} do
      flush_frames()
      send(pid, {:drag, -100})
      assert %{drag: -100, page: 0} = :sys.get_state(pid)
      # The battery page shows beneath, at the right edge.
      assert pixel(next_frame(), 440, 227) == Palette.value(:deep)

      # Not far enough: it springs back.
      send(pid, {:release, -100})
      assert %{drag: nil, moving: %{to: 0}} = :sys.get_state(pid)
      assert %{page: :clock} = Clock.status()

      # A drag whose release never comes settles by itself.
      send(pid, {:drag, -60})
      Process.sleep(1100)
      assert %{drag: nil, page: 0} = :sys.get_state(pid)

      send(pid, {:drag, -300})
      send(pid, {:release, -300})
      assert %{page: :battery} = Clock.status()
      # It slides the rest of the way off over several frames.
      Process.sleep(250)
      assert frames() >= 3
      Process.sleep(400)
      assert %{moving: nil} = :sys.get_state(pid)
      assert pixel(latest_frame(), 227, 400) == Palette.value(:deep)
    end

    test "swipes page through the battery, network, sensor and Tailscale pages", %{
      clock: pid,
      frame: face
    } do
      send(pid, {:swipe, :left})
      assert %{page: :battery} = Clock.status()
      send(pid, {:swipe, :left})
      assert %{page: :network} = Clock.status()

      Process.sleep(700)
      network = latest_frame()
      assert %{moving: nil} = :sys.get_state(pid)
      # The network page's own colour, below its rows.
      assert pixel(network, 227, 330) == Palette.value(:ley)

      send(pid, {:swipe, :left})
      assert %{page: :sensors} = Clock.status()
      send(pid, {:swipe, :left})
      assert %{page: :tailscale} = Clock.status()
      # Tailscale doesn't run on the host.
      assert eventually(fn -> :sys.get_state(pid).tailscale end) == %{
               state: "Unavailable",
               logging_in: false,
               auth_url: nil,
               name: nil,
               ip: nil,
               tailnet: nil
             }

      send(pid, {:swipe, :left})
      assert %{page: :clock} = Clock.status()
      send(pid, {:swipe, :right})
      assert %{page: :tailscale} = Clock.status()
      refute network == face
    end

    test "ignores swipes while the screen is off", %{clock: pid} do
      send(pid, :screen_timeout)
      assert_receive :sleep
      send(pid, {:swipe, :left})
      assert %{page: :clock, on: false} = Clock.status()
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

  test "recognizes taps and horizontal multitouch drags, and ignores vertical movement" do
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
    assert {[:tap], _state} = Touch.gesture(tap)
  end
end
