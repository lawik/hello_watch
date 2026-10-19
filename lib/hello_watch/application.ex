defmodule HelloWatch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
        # Starts a worker by calling: HelloWatch.Worker.start_link(arg)
        # {HelloWatch.Worker, arg},
      ] ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HelloWatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
        HelloWatch.Alarms,
        HelloWatch.Timers
      ]
    end
  else
    defp target_children() do
      [
        HelloWatch.GPS,
        HelloWatch.Vibrator,
        HelloWatch.Audio,
        HelloWatch.Recorder,
        HelloWatch.Nanohub.Guard,
        HelloWatch.Suspend,
        HelloWatch.Tailscale,
        %{
          id: HelloWatch.UI,
          type: :supervisor,
          start: {Supervisor, :start_link, [ui_children(), [strategy: :rest_for_one]]}
        },
        # After the UI, so a timer that ran out while the watch was off rings
        # on it.
        HelloWatch.Alarms,
        HelloWatch.Timers
      ]
    end

    # The viewport sends its frames to the Display process it finds at mount,
    # so a Display restart has to restart the viewport too.
    defp ui_children() do
      clock = Application.get_env(:hello_watch, HelloWatch.Clock, [])

      [
        HelloWatch.Clock.Display,
        {HelloWatch.Clock, [name: HelloWatch.Clock] ++ clock},
        {HelloWatch.Clock.Button, target: HelloWatch.Clock},
        {HelloWatch.Clock.Touch, target: HelloWatch.Clock}
      ]
    end
  end
end
