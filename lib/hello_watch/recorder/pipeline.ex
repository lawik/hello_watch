defmodule HelloWatch.Recorder.Pipeline do
  @moduledoc """
  The microphone into a WAV file at `path`, until sent `:stop`. It ends
  once the file is complete: the WAV serializer seeks back to write the
  header's sizes when the stream ends.
  """
  use Membrane.Pipeline

  alias HelloWatch.Recorder.Mic

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:mic, Mic)
      |> child(:wav, Membrane.WAV.Serializer)
      |> child(:file, %Membrane.File.Sink{location: Keyword.fetch!(opts, :path)})

    {[spec: spec], %{}}
  end

  @impl true
  def handle_info(:stop, _ctx, state), do: {[notify_child: {:mic, :stop}], state}

  @impl true
  def handle_element_end_of_stream(:file, :input, _ctx, state),
    do: {[terminate: :normal], state}

  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}
end
