defmodule HelloWatch.Recorder.Mic do
  @moduledoc """
  A Membrane source for the watch's microphone: raw PCM from `arecord` on
  `hw:mobvoirover,1` (see HelloWatch.Audio), as 48 kHz 16-bit mono.

  The card only captures stereo, and the mic is on the left channel, so
  the right one is dropped, as is the first `@skip_ms`, where the codec
  pops as it starts. The parent notifies `:stop` to end the stream.
  """
  use Membrane.Source

  alias Membrane.{Buffer, RawAudio}

  @rate 48_000
  @skip_ms 150

  def_output_pad(:output, accepted_format: RawAudio, flow_control: :push)

  def_options(device: [spec: String.t(), default: "hw:mobvoirover,1"])

  @impl true
  def handle_init(_ctx, opts),
    do: {[], %{device: opts.device, port: nil, rest: <<>>, skip: div(@rate * @skip_ms, 1000) * 4}}

  @impl true
  def handle_playing(_ctx, state) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("arecord")},
        [
          :binary,
          :exit_status,
          args: ~w(-q -t raw -D #{state.device} -f S16_LE -r #{@rate} -c 2)
        ]
      )

    format = %RawAudio{sample_format: :s16le, sample_rate: @rate, channels: 1}
    {[stream_format: {:output, format}], %{state | port: port}}
  end

  @impl true
  def handle_info({port, {:data, data}}, _ctx, %{port: port, skip: skip} = state)
      when skip > 0 do
    case data do
      <<_::binary-size(^skip), data::binary>> ->
        handle_info({port, {:data, data}}, nil, %{state | skip: 0})

      _ ->
        {[], %{state | skip: skip - byte_size(data)}}
    end
  end

  def handle_info({port, {:data, data}}, _ctx, %{port: port} = state) do
    data = state.rest <> data
    whole = byte_size(data) - rem(byte_size(data), 4)
    <<frames::binary-size(^whole), rest::binary>> = data
    left = for <<l::binary-2, _r::binary-2 <- frames>>, into: <<>>, do: l
    {[buffer: {:output, %Buffer{payload: left}}], %{state | rest: rest}}
  end

  def handle_info({port, {:exit_status, status}}, _ctx, %{port: port}),
    do: raise("arecord exited with #{status}")

  # Output still in flight from a closed arecord.
  def handle_info({port, _message}, _ctx, state) when is_port(port), do: {[], state}

  @impl true
  def handle_parent_notification(:stop, _ctx, %{port: port} = state) when port != nil do
    Port.close(port)
    {[end_of_stream: :output], %{state | port: nil}}
  end

  def handle_parent_notification(:stop, _ctx, state), do: {[], state}
end
