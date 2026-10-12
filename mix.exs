defmodule HelloWatch.MixProject do
  use Mix.Project

  @app :hello_watch
  @version "0.1.0"
  @all_targets [:ticwatch_pro3]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.15"],
      listeners: listeners(Mix.target(), Mix.env()),
      # Builds priv/vibrator from c_src (see the Makefile).
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {HelloWatch.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:jason, "~> 1.4"},
      {:tz, "~> 0.28"},

      # UI: Emerge renders the watch face and pages, on the CPU into the
      # framebuffer on the watch (see UI.md) or in a window on the host.
      {:emerge, "~> 0.4.2"},

      # Runs tailscaled (see HelloWatch.Tailscale).
      {:muontrap, "~> 1.8"},
      # The QR code for logging in to Tailscale from the watch.
      {:eqrcode, "~> 0.2.1"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:circuits_gpio, "~> 2.1", targets: @all_targets},
      {:circuits_spi, "~> 2.0", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_tickwatch_pro3,
       github: "mlainez/nerves_system_tickwatch_pro3",
       tag: "v0.2.0",
       runtime: false,
       targets: :ticwatch_pro3}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble, &keep_target_nif/1, &add_tailscale/1],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # deps/emerge/priv collects Emerge's NIF for every platform and variant it
  # was compiled for (the host's for tests, the watch's minimal raster build
  # selected by `compiled_backends: []` in config/target.exs), each 15-25 MB.
  # Keep only the watch's in the firmware.
  defp keep_target_nif(%Mix.Release{} = release) do
    if Mix.target() != :host do
      release.path
      |> Path.join("lib/emerge-*/priv/native/libemerge_skia-*.so")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "-aarch64-unknown-linux-gnu--raster.so"))
      |> Enum.each(&File.rm!/1)
    end

    release
  end

  # Tailscale isn't in the Nerves system, so its static build goes into
  # priv/tailscale (see HelloWatch.Tailscale). It's downloaded once per
  # version into _build/tailscale and checked against its SHA-256 (from
  # pkgs.tailscale.com/stable/<tarball>.sha256).
  @tailscale_version "1.104.1"
  @tailscale_sha256 "f60294374967f3dfd8cf57bbbd474d6cfce32d123e3a8ddeab82a87940daa806"

  defp add_tailscale(%Mix.Release{} = release) do
    if Mix.target() != :host do
      bin =
        Path.join(Mix.Project.build_path(), "../tailscale/#{@tailscale_version}") |> Path.expand()

      if not File.exists?(Path.join(bin, "tailscaled")), do: fetch_tailscale(bin)

      priv = Path.join(release.path, "lib/#{@app}-#{@version}/priv")
      File.mkdir_p!(priv)
      File.cp_r!(bin, Path.join(priv, "tailscale"))
    end

    release
  end

  defp fetch_tailscale(bin) do
    tarball = "tailscale_#{@tailscale_version}_arm64.tgz"
    Mix.shell().info("==> Fetching #{tarball}")

    archive =
      case Mix.Utils.read_path("https://pkgs.tailscale.com/stable/#{tarball}", timeout: 300_000) do
        {:ok, body} -> body
        {_kind, message} -> Mix.raise("Downloading #{tarball} failed: #{message}")
      end

    if Base.encode16(:crypto.hash(:sha256, archive), case: :lower) != @tailscale_sha256 do
      Mix.raise("#{tarball} doesn't match its pinned SHA-256")
    end

    dir = "tailscale_#{@tailscale_version}_arm64"
    files = for name <- ~w(tailscale tailscaled), do: ~c"#{dir}/#{name}"
    {:ok, extracted} = :erl_tar.extract({:binary, archive}, [:compressed, :memory, files: files])

    File.mkdir_p!(bin)

    for {path, contents} <- extracted do
      dest = Path.join(bin, Path.basename(to_string(path)))
      File.write!(dest, contents)
      File.chmod!(dest, 0o755)
    end
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
