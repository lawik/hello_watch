defmodule HelloWatch.Audio do
  @moduledoc """
  The speaker and the microphone.

  The sound card (`mobvoirover`) appears once the ADSP has booted, a few
  seconds after Erlang starts. Its routing lives in ALSA mixer controls that
  start out off, so this process waits for the card and sets them:

    * the speaker amp plays what is written to `hw:mobvoirover,0`
    * the digital mic records on the left channel of `hw:mobvoirover,1`

  The card runs at 48 kHz, 16-bit stereo; the ADSP converts other formats.
  There is no hardware volume, so scale samples to set the level. The amp
  has no speaker protection running, so keep it below full scale.

      HelloWatch.Audio.tone(440, 500)
      HelloWatch.Audio.record("/root/rec.wav", 3)
      HelloWatch.Audio.play("/root/rec.wav")
  """

  # Exits once the routing is set.
  use GenServer, restart: :transient
  require Logger

  @card "mobvoirover"
  @rate 48_000

  @routing [
    {"QUAT_MI2S_RX Audio Mixer MultiMedia1", "1"},
    {"MultiMedia2 Mixer TERT_MI2S_TX", "1"},
    {"DEC1 MUX", "DMIC1"},
    {"CIC1 MUX", "DMIC"},
    # 84 is 0 dB; the bare mic records speech around -55 dBFS.
    {"TX1 Digital Volume", "108"}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Plays a WAV file on the speaker. Blocks until it has played."
  def play(path), do: cmd("aplay", ["-q", "-D", "hw:#{@card},0", path])

  @doc "Records `seconds` from the mic into a WAV file."
  def record(path, seconds) when is_integer(seconds) and seconds > 0 do
    cmd("arecord", ~w(-q -D hw:#{@card},1 -f S16_LE -r #{@rate} -c 2 -d #{seconds}) ++ [path])
  end

  @doc "Plays a sine tone at a tenth of full scale."
  def tone(hz, ms) do
    path = Path.join(System.tmp_dir!(), "tone.wav")
    File.write!(path, sine_wav(hz, ms, 0.1))
    play(path)
  end

  @impl true
  def init(_opts) do
    send(self(), :wait)
    {:ok, 0}
  end

  @impl true
  def handle_info(:wait, tries) do
    cond do
      card?() ->
        Enum.each(@routing, fn {name, value} ->
          cmd("amixer", ["-q", "-c", @card, "cset", "name=#{name}", value])
        end)

        {:stop, :normal, tries}

      tries < 60 ->
        Process.send_after(self(), :wait, 1000)
        {:noreply, tries + 1}

      true ->
        Logger.warning("No sound card #{@card}; no audio")
        {:stop, :normal, tries}
    end
  end

  defp card? do
    case File.read("/proc/asound/cards") do
      {:ok, cards} -> String.contains?(cards, "[#{@card}")
      _ -> false
    end
  end

  defp cmd(prog, args) do
    case System.cmd(prog, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp sine_wav(hz, ms, level) do
    frames = div(@rate * ms, 1000)
    amp = level * 32_767

    data =
      for n <- 0..(frames - 1), into: <<>> do
        s = round(amp * :math.sin(2 * :math.pi() * hz * n / @rate))
        <<s::little-signed-16, s::little-signed-16>>
      end

    size = byte_size(data)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 2::little-16,
      @rate::little-32, @rate * 4::little-32, 4::little-16, 16::little-16, "data",
      size::little-32>> <> data
  end
end
