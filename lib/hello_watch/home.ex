defmodule HelloWatch.Home do
  @moduledoc """
  Joins the home cluster: makes the watch an Erlang distribution node and
  starts `home_base`, which lends the watch's mic and speaker to the other
  devices and shows their cameras here (see `HelloWatch.HomeVideo`). The
  capabilities are home_base's own config (`config :home_base, ...`).

  The cluster is the tailnet's devices tagged `tag:homecluster`, each a node
  named `home@<Tailscale IPv4>` (home_base's `Home.Cluster.Tailscale`), all
  with one cookie. Media goes over the tailnet too, as the phones' does: a
  source sends from its own media address, and a phone's (its Tailscale
  address) sent to the watch's Wi-Fi address is dropped by tailscaled's
  firewall, which takes tailnet sources only on tailscale0.

  home_base keys its `:pg` groups and node state on `node()`, so it can only
  start after `Node.start/2`, and the release only loads it. Once Tailscale
  has an address, this

    * starts epmd and the node, listening on the Tailscale address only,
    * raises the kernel's default socket send buffer (`:send_buffer`, 2 MB),
      as the phones do: media sockets get the default, and a camera
      keyframe's packets, sent at once, fill the 208 KB one,
    * links the watch's tailscaled socket where the CLI looks by default, as
      home_base's Tailscale backend runs it with no `--socket`,

  and starts home_base.

      config :hello_watch, :home,
        cookie: :"tag:homecluster",
        tag: "tag:homecluster",
        basename: "home"
  """

  use GenServer

  require Logger

  @poll_ms 2_000
  # Where the tailscale CLI looks for tailscaled when it isn't told.
  @default_socket "/run/tailscale/tailscaled.sock"

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether home_base is running on this node."
  @spec running?() :: boolean()
  def running?, do: List.keymember?(Application.started_applications(), :home_base, 0)

  @impl GenServer
  def init(_opts) do
    send(self(), :start)
    {:ok, Application.get_env(:hello_watch, :home, [])}
  end

  @impl GenServer
  def handle_info(:start, config) do
    with {:ok, ip} <- tailnet_address(),
         :ok <- start_node(config, ip) do
      start_home_base(config, ip)
    else
      _ -> Process.send_after(self(), :start, @poll_ms)
    end

    {:noreply, config}
  end

  defp start_node(config, ip) do
    if Node.alive?() do
      :ok
    else
      {_out, _status} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
      # Distribution only listens on the tailnet.
      Application.put_env(:kernel, :inet_dist_use_interface, ip)
      name = :"#{Keyword.get(config, :basename, "home")}@#{:inet.ntoa(ip)}"

      case Node.start(name, :longnames) do
        {:ok, _pid} ->
          Node.set_cookie(Keyword.get(config, :cookie, :"tag:homecluster"))
          Logger.info("Distribution started as #{node()}")
          :ok

        {:error, reason} ->
          Logger.warning("Starting distribution failed: #{inspect(reason)}")
          :error
      end
    end
  end

  defp start_home_base(config, ip) do
    set_send_buffer(Keyword.get(config, :send_buffer, 2_097_152))

    %{cli: tailscale, socket: socket} = HelloWatch.Tailscale.paths()
    File.mkdir_p!(Path.dirname(@default_socket))
    File.rm(@default_socket)
    File.ln_s!(socket, @default_socket)

    {:ok, hostname} = :inet.gethostname()
    media = Application.get_env(:home_base, :media, [])
    Application.put_env(:home_base, :media, Keyword.put(media, :ip, ip))
    Application.put_env(:home_base, :device_id, to_string(hostname))

    Application.put_env(:home_base, :cluster,
      backend:
        {Home.Cluster.Tailscale,
         cmd: tailscale,
         tag: Keyword.get(config, :tag, "tag:homecluster"),
         basename: Keyword.get(config, :basename, "home")}
    )

    case Application.ensure_all_started(:home_base) do
      {:ok, _apps} -> Logger.info("home_base started on #{node()}, media on #{:inet.ntoa(ip)}")
      {:error, reason} -> Logger.error("Starting home_base failed: #{inspect(reason)}")
    end
  end

  defp set_send_buffer(bytes) do
    case File.write("/proc/sys/net/core/wmem_default", Integer.to_string(bytes)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Couldn't set the send buffer: #{inspect(reason)}")
    end
  end

  defp tailnet_address do
    with {:ok, ip} <- HelloWatch.Tailscale.ip(),
         {:ok, ip} <- ip |> to_charlist() |> :inet.parse_ipv4_address() do
      {:ok, ip}
    else
      _ -> :error
    end
  end
end
