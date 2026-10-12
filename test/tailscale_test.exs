defmodule HelloWatch.TailscaleTest do
  use ExUnit.Case
  alias HelloWatch.Tailscale

  # A fake tailscaled that only stays up, and a fake CLI that logs its
  # arguments and answers `status --json` from a file the test writes.
  setup do
    dir = Path.join(System.tmp_dir!(), "hello_watch_ts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    daemon = Path.join(dir, "tailscaled")
    cli = Path.join(dir, "tailscale")
    log = Path.join(dir, "cli.log")
    status = Path.join(dir, "status.json")

    File.write!(daemon, "#!/bin/sh\necho \"$@\" > #{dir}/daemon.args\nexec sleep 600\n")

    File.write!(cli, """
    #!/bin/sh
    echo "$@" >> #{log}
    case "$2" in
      status) cat #{status} ;;
      ip) echo 100.64.0.7 ;;
      up) case "$3" in --auth-key=*) ;; *) sleep 2 ;; esac ;;
    esac
    """)

    File.chmod!(daemon, 0o755)
    File.chmod!(cli, 0o755)

    opts = [
      tailscaled: daemon,
      tailscale: cli,
      socket: Path.join(dir, "sock"),
      state_dir: Path.join(dir, "state"),
      tun_device: Path.join(dir, "no-tun"),
      authkey: fn -> "tskey-test" end
    ]

    ctx = %{dir: dir, opts: opts, log: log, status: status}
    backend(ctx, %{"BackendState" => "NeedsLogin"})
    ctx
  end

  defp backend(ctx, json), do: File.write!(ctx.status, Jason.encode!(json))

  defp poll(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  test "starts tailscaled, joins with the auth key and reports the tailnet", ctx do
    pid = start_supervised!({Tailscale, ctx.opts})
    poll(pid)

    assert File.read!(ctx.log) =~ ~r/up --auth-key=tskey-test --hostname=\S+ --accept-dns=false/
    assert File.read!(Path.join(ctx.dir, "daemon.args")) =~ "--tun=userspace-networking"

    backend(ctx, %{
      "BackendState" => "Running",
      "Self" => %{
        "DNSName" => "watch.tail1234.ts.net.",
        "TailscaleIPs" => ["100.64.0.7", "fd7a::7"]
      },
      "CurrentTailnet" => %{"Name" => "example.com"}
    })

    poll(pid)

    assert Tailscale.info() == %{
             state: "Running",
             logging_in: false,
             auth_url: nil,
             name: "watch.tail1234.ts.net",
             ip: "100.64.0.7",
             tailnet: "example.com"
           }
  end

  test "logs in without a key and reports the login URL meanwhile", ctx do
    pid = start_supervised!({Tailscale, [authkey: fn -> nil end] ++ ctx.opts})
    poll(pid)
    refute File.read!(ctx.log) =~ "up"

    assert Tailscale.login() == :ok
    url = "https://login.tailscale.com/a/1a2b3c4d5e6f7"
    backend(ctx, %{"BackendState" => "NeedsLogin", "AuthURL" => url})
    assert %{logging_in: true, auth_url: ^url} = Tailscale.info()

    # The fake `tailscale up` returns after 2 s, as when the URL is visited.
    Process.sleep(2500)
    assert %{logging_in: false} = Tailscale.info()
  end

  test "stop ends tailscaled and start brings it back", ctx do
    pid = start_supervised!({Tailscale, ctx.opts})
    %{daemon: daemon} = :sys.get_state(pid)
    ref = Process.monitor(daemon)

    assert Tailscale.stop() == :ok
    assert_receive {:DOWN, ^ref, _, _, _}
    assert %{state: "Off"} = Tailscale.info()

    assert Tailscale.start() == :ok
    assert %{state: "NeedsLogin"} = Tailscale.info()
  end

  test "stays off without autostart", ctx do
    start_supervised!({Tailscale, [autostart: false] ++ ctx.opts})
    assert %{state: "Off"} = Tailscale.info()
    refute File.exists?(ctx.log)
  end

  test "is unavailable where it doesn't run" do
    assert %{state: "Unavailable"} = Tailscale.info()
  end
end
