defmodule HelloWatch.Tailscale do
  @moduledoc """
  Runs tailscaled and keeps the watch on the tailnet. Ported from
  nerves_phone's `NervesPhone.Tailscale`.

  The static Tailscale build comes from the `add_tailscale` release step in
  mix.exs, into `priv/tailscale`. Its state lives in `/root/tailscale` on the
  application partition, so the watch keeps its name and address across
  reboots and firmware updates.

  There are two ways to join the first time:

    * Log in from the watch's Tailscale page (`login/0`): tap it, and it
      shows the login URL as a QR code to scan with a phone signed in to
      Tailscale. The watch joins as one of your devices.
    * An auth key, for joining unattended, from either the Nerves KV store:

          Nerves.Runtime.KV.put("tailscale_authkey", "tskey-auth-...")

      or the file `authkey` in the state directory.

  Once joined, the state carries the identity, and neither is needed again.
  The node's name is the KV `tailscale_hostname`, or the watch's hostname.

  `stop/0` and `start/0` switch tailscaled off and on, so a power mode can
  drop it: it wakes the watch for keepalives, which works against idle and
  suspend (see POWER-MANAGEMENT.md). Stopped, the node shows as offline and
  keeps its identity. `config :hello_watch, HelloWatch.Tailscale, autostart:
  false` keeps it stopped at boot.

  If tailscaled won't run, this retries every few seconds rather than
  crashing, so the rest of the watch keeps working.
  """
  use GenServer
  require Logger

  @poll_ms 5_000
  @running_poll_ms :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts tailscaled, if it isn't running."
  def start, do: GenServer.call(__MODULE__, :start)

  @doc "Stops tailscaled. The watch leaves the tailnet until `start/0`."
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "tailscaled's backend state, such as `\"Running\"` or `\"NeedsLogin\"`."
  @spec status() :: {:ok, String.t()} | {:error, term()}
  def status do
    with {:ok, %{"BackendState" => state}} <- status_json(config()), do: {:ok, state}
  end

  @typedoc """
  What the Tailscale page shows. `state` is tailscaled's backend state
  (`"NeedsLogin"`, `"NeedsMachineAuth"`, `"Starting"`, `"Running"`, ...),
  `"NoDaemon"` while tailscaled isn't answering, `"Off"` when stopped, or
  `"Unavailable"` where Tailscale doesn't run (the host). `auth_url` is set
  while a login waits for the URL to be visited.
  """
  @type info :: %{
          state: String.t(),
          logging_in: boolean(),
          auth_url: String.t() | nil,
          name: String.t() | nil,
          ip: String.t() | nil,
          tailnet: String.t() | nil
        }

  @doc "The state, the watch's name and address on the tailnet, and any login URL."
  @spec info() :: info()
  def info do
    unavailable = %{
      state: "Unavailable",
      logging_in: false,
      auth_url: nil,
      name: nil,
      ip: nil,
      tailnet: nil
    }

    case GenServer.whereis(__MODULE__) && GenServer.call(__MODULE__, :daemon) do
      nil ->
        unavailable

      %{running: false} ->
        %{unavailable | state: "Off"}

      %{logging_in: logging_in, config: config} ->
        case status_json(config) do
          {:ok, json} ->
            self = json["Self"] || %{}
            name = nonempty(self["DNSName"])

            %{
              state: json["BackendState"],
              logging_in: logging_in,
              auth_url: nonempty(json["AuthURL"]),
              name: name && String.trim_trailing(name, "."),
              ip: Enum.find(self["TailscaleIPs"] || [], &String.contains?(&1, ".")),
              tailnet: get_in(json, ["CurrentTailnet", "Name"])
            }

          {:error, _reason} ->
            %{unavailable | state: "NoDaemon", logging_in: logging_in}
        end
    end
  end

  @doc """
  Starts logging in without an auth key. Runs `tailscale up` in the
  background until the login URL (in `info/0`) is visited, or for 15
  minutes.
  """
  @spec login() :: :ok
  def login do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :login), else: :ok
  end

  @doc "The watch's tailnet IPv4 address."
  @spec ip() :: {:ok, String.t()} | {:error, term()}
  def ip, do: ip(config())

  @doc "Runs the tailscale CLI against tailscaled."
  @spec cli([String.t()]) :: {:ok, String.t()} | {:error, {term(), String.t()}}
  def cli(args), do: cli(config(), args)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = config(opts)

    state = %{
      config: config,
      wanted: config.autostart,
      daemon: nil,
      up?: false,
      login: nil,
      warned?: false,
      poll: nil
    }

    if state.wanted, do: send(self(), :start_daemon)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start, _from, state) do
    if state.daemon == nil, do: send(self(), :start_daemon)
    {:reply, :ok, %{state | wanted: true}}
  end

  def handle_call(:stop, _from, %{daemon: nil} = state),
    do: {:reply, :ok, %{state | wanted: false}}

  def handle_call(:stop, _from, state) do
    Process.unlink(state.daemon)
    GenServer.stop(state.daemon)
    {:reply, :ok, %{cancel_poll(state) | wanted: false, daemon: nil, up?: false}}
  end

  def handle_call(:daemon, _from, state) do
    reply = %{running: state.daemon != nil, logging_in: state.login != nil, config: state.config}
    {:reply, reply, state}
  end

  def handle_call(:login, _from, %{login: nil, daemon: daemon} = state) when daemon != nil do
    # VintageNet owns resolv.conf, so tailscaled leaves DNS alone.
    args = ["up", "--hostname=#{hostname()}", "--accept-dns=false", "--timeout=15m"]
    config = state.config
    task = Task.async(fn -> cli(config, args) end)
    {:reply, :ok, %{state | login: task.ref}}
  end

  def handle_call(:login, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info(:start_daemon, %{wanted: true, daemon: nil} = state) do
    config = state.config
    File.mkdir_p!(config.state_dir)
    args = ["--statedir=#{config.state_dir}", "--socket=#{config.socket}"] ++ tun_args(config)

    case MuonTrap.Daemon.start_link(config.tailscaled, args,
           log_output: :debug,
           log_prefix: "tailscaled: ",
           stderr_to_stdout: true
         ) do
      {:ok, pid} ->
        {:noreply, schedule_poll(%{state | daemon: pid}, 0)}

      {:error, reason} ->
        Logger.warning("tailscaled failed to start: #{inspect(reason)}")
        Process.send_after(self(), :start_daemon, @poll_ms)
        {:noreply, state}
    end
  end

  def handle_info(:start_daemon, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{daemon: pid} = state) do
    Logger.warning("tailscaled exited: #{inspect(reason)}")
    Process.send_after(self(), :start_daemon, @poll_ms)
    {:noreply, %{cancel_poll(state) | daemon: nil, up?: false}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The login finished: logged in, timed out, or failed.
  def handle_info({ref, result}, %{login: ref} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _out} -> Logger.info("Logged in to Tailscale")
      {:error, {code, out}} -> Logger.warning("tailscale up ended (#{code}): #{out}")
    end

    {:noreply, %{state | login: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{login: ref} = state) do
    Logger.warning("Tailscale login crashed: #{inspect(reason)}")
    {:noreply, %{state | login: nil}}
  end

  # Joins the tailnet with the auth key whenever tailscaled says it needs
  # to, unless a login from the watch is under way.
  def handle_info(:poll, %{daemon: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    state =
      case status_json(state.config) do
        {:ok, %{"BackendState" => "Running"}} ->
          if not state.up?,
            do: Logger.info("Tailscale is up at #{elem(ip(state.config), 1)}")

          %{state | up?: true, warned?: false}

        {:ok, %{"BackendState" => "NeedsLogin"}} when state.login == nil ->
          %{state | up?: false, warned?: up(state)}

        _other ->
          %{state | up?: false}
      end

    {:noreply, schedule_poll(state, if(state.up?, do: @running_poll_ms, else: @poll_ms))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Returns whether the missing key has been warned about, to warn once.
  defp up(state) do
    case state.config.authkey.() do
      nil ->
        if not state.warned? do
          Logger.info(
            "Tailscale needs a login: tap the watch's Tailscale page, or set an " <>
              "auth key (KV tailscale_authkey or #{state.config.state_dir}/authkey)"
          )
        end

        true

      key ->
        args = ["up", "--auth-key=#{key}", "--hostname=#{hostname()}", "--accept-dns=false"]

        case cli(state.config, args) do
          {:ok, _} -> Logger.info("Joined the tailnet")
          {:error, {code, out}} -> Logger.warning("tailscale up failed (#{code}): #{out}")
        end

        state.warned?
    end
  end

  # TUN is a module in the watch's kernel. Without it, tailscaled runs its
  # own network stack: the watch is still reachable over the tailnet, but its
  # own outgoing connections don't route through it.
  defp tun_args(config) do
    if not File.exists?(config.tun_device), do: modprobe("tun")
    if File.exists?(config.tun_device), do: [], else: ["--tun=userspace-networking"]
  end

  defp modprobe(module) do
    System.cmd("modprobe", [module], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp schedule_poll(state, delay) do
    state = cancel_poll(state)
    %{state | poll: Process.send_after(self(), :poll, delay)}
  end

  defp cancel_poll(%{poll: nil} = state), do: state

  defp cancel_poll(state) do
    Process.cancel_timer(state.poll)
    %{state | poll: nil}
  end

  defp status_json(config) do
    with {:ok, out} <- cli(config, ["status", "--json"]), do: Jason.decode(out)
  end

  defp ip(config) do
    with {:ok, out} <- cli(config, ["ip", "-4"]), do: {:ok, String.trim(out)}
  end

  defp cli(config, args) do
    case System.cmd(config.tailscale, ["--socket=#{config.socket}" | args],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  rescue
    error -> {:error, {:enoent, Exception.message(error)}}
  end

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  # `opts` override the binaries, paths and key lookup, for tests.
  defp config(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:hello_watch, __MODULE__, []), opts)
    state_dir = Keyword.get(opts, :state_dir, "/root/tailscale")

    %{
      autostart: Keyword.get(opts, :autostart, true),
      tailscaled: Keyword.get_lazy(opts, :tailscaled, fn -> bin("tailscaled") end),
      tailscale: Keyword.get_lazy(opts, :tailscale, fn -> bin("tailscale") end),
      socket: Keyword.get(opts, :socket, "/tmp/tailscaled.sock"),
      # /data is the GPS stack's; the application partition is /root.
      state_dir: state_dir,
      tun_device: Keyword.get(opts, :tun_device, "/dev/net/tun"),
      authkey: Keyword.get(opts, :authkey, fn -> authkey(state_dir) end)
    }
  end

  defp bin(name), do: Application.app_dir(:hello_watch, "priv/tailscale/#{name}")

  defp authkey(state_dir) do
    from_file =
      case File.read(Path.join(state_dir, "authkey")) do
        {:ok, contents} -> String.trim(contents)
        _ -> nil
      end

    Enum.find([kv("tailscale_authkey"), from_file], &(&1 not in [nil, ""]))
  end

  defp hostname do
    case kv("tailscale_hostname") do
      name when name not in [nil, ""] ->
        name

      _ ->
        {:ok, name} = :inet.gethostname()
        to_string(name)
    end
  end

  defp kv(key) do
    Nerves.Runtime.KV.get(key)
  rescue
    _ -> nil
  end
end
