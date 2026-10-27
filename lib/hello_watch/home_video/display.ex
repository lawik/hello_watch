defmodule HelloWatch.HomeVideo.Display do
  @moduledoc """
  The watch's screen as a home_base `:display` capability, for video:

      %{id: "watch_video", kind: :display, adapter: HelloWatch.HomeVideo.Display,
        meta: %{w: 454, h: 454, touch: false}}

  Its endpoint is `HelloWatch.HomeVideo.Surface`, which draws a video
  session's frames in the watch's own UI. The renderer is the UI's, so
  scene-forwarded apps (`Home.Render.show/2`) can't be shown on it.
  """

  @behaviour Home.Adapter

  @impl Home.Adapter
  def init(cap), do: {:ok, %{cap: cap}}

  @impl Home.Adapter
  def start(state), do: {:ok, state}

  @impl Home.Adapter
  def stop(state), do: {:ok, state}

  @impl Home.Adapter
  def endpoint(_state), do: Process.whereis(HelloWatch.HomeVideo.Surface)
end
