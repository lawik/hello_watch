defmodule HelloWatch.Nanohub.Bootloader do
  @moduledoc """
  Talks to the sensor hub's STM32 ROM bootloader from userspace.

  The hub sits on SPI behind the `nanohub` kernel module. `take/0` unloads that
  module and binds `spidev` to the hub instead; `release/0` reverses it. In
  between, `session/1` resets the hub into its ROM bootloader (boot0 high) and
  speaks the STM32 SPI bootloader protocol (ST AN4286), the same way the
  downstream driver's `bl.c` does. The ROM bootloader lives in system memory,
  so it is always reachable, whatever is in flash.

      HelloWatch.Nanohub.Bootloader.take()
      HelloWatch.Nanohub.Bootloader.probe()
      HelloWatch.Nanohub.Bootloader.release()

  `probe/0` and `compare/1` only read. `flash/1` erases and writes; it follows
  Android's `nanoapp_cmd download`: compare each flash bank against the image
  and only erase and rewrite the banks that differ.
  """

  import Bitwise

  @spi_device "spidev1.0"
  @spi_sysfs "/sys/bus/spi/devices/spi1.0"
  @gpiochip "gpiochip0"

  # Pin numbers from the device tree (tlmm). nreset is active high.
  @nreset 70
  @boot0 65
  @wakeup 63
  @cs 98

  @sof 0x5A
  @sof_ack 0xA5
  @ack 0x79
  @nack 0x1F

  @cmd_get_version 0x01
  @cmd_get_id 0x02
  @cmd_read_memory 0x11
  @cmd_write_memory 0x31
  @cmd_erase 0x44

  @sync_tries 65_535
  @ack_tries 100_000

  @bl_addr 0x0800_0000
  # {sector, address, length}: the downstream `sensorhub,flash-banks`. Sector 1
  # and the shared sectors 2 and 3 are left alone, as Android does.
  @flash_banks [
    {0, 0x0800_0000, 0x0_4000},
    {4, 0x0801_0000, 0x1_0000},
    {5, 0x0802_0000, 0x2_0000},
    {6, 0x0804_0000, 0x2_0000},
    {7, 0x0806_0000, 0x2_0000},
    {8, 0x0808_0000, 0x2_0000}
  ]

  @firmware "/mnt/vendor/firmware/nanohub.full.rover_evb.22011110.bin"

  @doc "Unloads the nanohub driver and binds spidev to the hub."
  def take do
    # Anything streaming from /dev/nanohub keeps the module busy.
    cmd("killall", ["nanohubctl"])

    with {_, 0} <- cmd("rmmod", ["nanohub"]),
         :ok <- File.write(Path.join(@spi_sysfs, "driver_override"), "spidev"),
         {_, 0} <- cmd("modprobe", ["spidev"]) do
      unless File.exists?("/dev/" <> @spi_device) do
        File.write("/sys/bus/spi/drivers/spidev/bind", "spi1.0")
      end

      if File.exists?("/dev/" <> @spi_device), do: :ok, else: {:error, :no_spidev}
    else
      error -> {:error, error}
    end
  end

  @doc "Hands the hub back to the nanohub driver, which resets it normally."
  def release do
    File.write("/sys/bus/spi/drivers/spidev/unbind", "spi1.0")
    # An empty write is ignored; a bare newline clears the override.
    File.write(Path.join(@spi_sysfs, "driver_override"), "\n")

    with {_, 0} <- cmd("modprobe", ["nanohub"]) do
      unless File.exists?(Path.join(@spi_sysfs, "driver")) do
        File.write("/sys/bus/spi/drivers/nanohub/bind", "spi1.0")
      end

      :ok
    else
      error -> {:error, error}
    end
  end

  @doc """
  Resets the hub into the ROM bootloader, syncs and runs `fun` with the open
  session. The hub is reset back to its flash firmware afterwards.
  """
  def session(fun) do
    {:ok, spi} = Circuits.SPI.open(@spi_device, mode: 0, speed_hz: 8_000_000)
    pins = open_pins()

    try do
      reset(pins, :bootloader)
      Circuits.GPIO.write(pins.cs, 0)

      case sync(spi) do
        :ok -> fun.(spi)
        error -> error
      end
    after
      Circuits.GPIO.write(pins.cs, 1)
      reset(pins, :flash)
      Enum.each(Map.values(pins), &Circuits.GPIO.close/1)
      Circuits.SPI.close(spi)
    end
  end

  @doc "Reads the bootloader version and chip ID, and compares flash to the stock image."
  def probe(image_path \\ @firmware) do
    session(fn spi ->
      with {:ok, version} <- get_version(spi),
           {:ok, id} <- get_id(spi) do
        %{
          bootloader_version: version,
          chip_id: id,
          banks: compare_banks(spi, File.read!(image_path))
        }
      end
    end)
  end

  @doc "Compares each flash bank with the image without writing anything."
  def compare(image_path \\ @firmware) do
    session(fn spi -> compare_banks(spi, File.read!(image_path)) end)
  end

  @doc """
  Writes the image the way Android's download does: banks whose contents
  already match are skipped, banks that only need bits cleared are written,
  and the rest are erased first. Returns the per-bank result.
  """
  def flash(image_path \\ @firmware) do
    image = File.read!(image_path)

    session(fn spi ->
      Enum.reduce_while(compare_banks(spi, image), [], fn
        {sector, :same}, acc ->
          {:cont, [{sector, :same} | acc]}

        {sector, :outside_image}, acc ->
          {:cont, [{sector, :outside_image} | acc]}

        {sector, need}, acc when need in [:write, :erase] ->
          {_, addr, _} = bank = List.keyfind(@flash_banks, sector, 0)

          with :ok <- if(need == :erase, do: erase_sector(spi, sector), else: :ok),
               :ok <- write_memory(spi, addr, bank_slice(image, bank)) do
            {:cont, [{sector, need} | acc]}
          else
            error -> {:halt, [{sector, error} | acc]}
          end

        {sector, error}, acc ->
          {:halt, [{sector, error} | acc]}
      end)
      |> Enum.reverse()
    end)
  end

  # --- Bank comparison -----------------------------------------------------

  defp compare_banks(spi, image) do
    for {sector, _addr, _len} = bank <- @flash_banks do
      case bank_slice(image, bank) do
        "" -> {sector, :outside_image}
        wanted -> {sector, classify(read_memory(spi, elem(bank, 1), byte_size(wanted)), wanted)}
      end
    end
  end

  defp bank_slice(image, {_sector, addr, len}) do
    offset = addr - @bl_addr

    if offset >= byte_size(image),
      do: "",
      else: binary_part(image, offset, min(len, byte_size(image) - offset))
  end

  defp classify({:ok, same}, same), do: :same

  defp classify({:ok, current}, wanted) do
    # Flash programming only clears bits; anything that needs a 0 -> 1 needs
    # an erase first.
    if :crypto.exor(band_bin(current, wanted), wanted) == :binary.copy(<<0>>, byte_size(wanted)),
      do: :write,
      else: :erase
  end

  defp classify(error, _wanted), do: error

  defp band_bin(a, b) do
    size = byte_size(a) * 8
    <<x::size(^size)>> = a
    <<y::size(^size)>> = b
    <<band(x, y)::size(size)>>
  end

  # --- Bootloader commands -------------------------------------------------

  defp get_version(spi) do
    with :ok <- command(spi, @cmd_get_version),
         {:ok, <<version>>} <- read_data(spi, 1),
         :ok <- read_ack(spi) do
      {:ok, version}
    end
  end

  defp get_id(spi) do
    with :ok <- command(spi, @cmd_get_id),
         {:ok, <<len>>} <- read_data(spi, 1),
         {:ok, <<id::16, _::binary>>} <- read_data(spi, len + 1),
         :ok <- read_ack(spi) do
      {:ok, id}
    end
  end

  defp read_memory(spi, addr, len, acc \\ [])
  defp read_memory(_spi, _addr, 0, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_memory(spi, addr, len, acc) do
    n = min(len, 256)

    with :ok <- command(spi, @cmd_read_memory),
         :ok <- write_data(spi, <<addr::32>>),
         :ok <- read_ack_loop(spi),
         :ok <- write_data(spi, <<n - 1>>),
         :ok <- read_ack_loop(spi),
         {:ok, data} <- read_data(spi, n) do
      read_memory(spi, addr + n, len - n, [data | acc])
    end
  end

  defp write_memory(_spi, _addr, <<>>), do: :ok

  defp write_memory(spi, addr, data) do
    n = min(byte_size(data), 256)
    <<chunk::binary-size(^n), rest::binary>> = data

    with :ok <- command(spi, @cmd_write_memory),
         :ok <- write_data(spi, <<addr::32>>),
         :ok <- read_ack_loop(spi),
         :ok <- write_data(spi, <<n - 1, chunk::binary>>),
         :ok <- read_ack_loop(spi) do
      write_memory(spi, addr + n, rest)
    end
  end

  defp erase_sector(spi, sector) do
    # Extended erase of one sector: count - 1 = 0, then the sector number.
    with :ok <- command(spi, @cmd_erase),
         :ok <- write_data(spi, <<0::16>>),
         :ok <- read_ack_loop(spi),
         :ok <- write_data(spi, <<sector::16>>) do
      read_ack_loop(spi)
    end
  end

  # --- SPI framing ---------------------------------------------------------

  defp sync(spi), do: sync(spi, @sync_tries)
  defp sync(_spi, 0), do: {:error, :no_sync}

  defp sync(spi, tries) do
    case xfer(spi, <<@sof>>) do
      <<@sof_ack>> -> read_ack(spi)
      _ -> sync(spi, tries - 1)
    end
  end

  defp command(spi, cmd) do
    xfer(spi, <<@sof, cmd, bxor(cmd, 0xFF)>>)
    read_ack(spi)
  end

  # The checksum byte rides along; the hub ACKs separately.
  defp write_data(spi, data) do
    xfer(spi, data <> <<checksum(data)>>)
    :ok
  end

  defp read_data(spi, n) do
    <<_, data::binary-size(^n)>> = xfer(spi, :binary.copy(<<0>>, n + 1))
    {:ok, data}
  end

  # Clock zeros until the hub answers ACK or NACK, then acknowledge the ACK.
  defp read_ack(spi), do: read_ack(spi, @ack_tries)
  defp read_ack(_spi, 0), do: {:error, :ack_timeout}

  defp read_ack(spi, tries) do
    case xfer(spi, <<0>>) do
      <<@ack>> ->
        xfer(spi, <<@ack>>)
        :ok

      <<@nack>> ->
        xfer(spi, <<@ack>>)
        {:error, :nack}

      _ ->
        read_ack(spi, tries - 1)
    end
  end

  defp read_ack_loop(spi), do: read_ack(spi)

  defp checksum(<<byte>>), do: bxor(byte, 0xFF)
  defp checksum(data), do: for(<<b <- data>>, reduce: 0, do: (acc -> bxor(acc, b)))

  defp xfer(spi, data) do
    {:ok, rx} = Circuits.SPI.transfer(spi, data)
    rx
  end

  # --- Pins ----------------------------------------------------------------

  defp open_pins do
    %{
      nreset: gpio(@nreset, 1),
      boot0: gpio(@boot0, 0),
      wakeup: gpio(@wakeup, 1),
      cs: gpio(@cs, 1)
    }
  end

  defp gpio(line, initial) do
    {:ok, ref} = Circuits.GPIO.open({@gpiochip, line}, :output, initial_value: initial)
    ref
  end

  defp reset(pins, mode) do
    Circuits.GPIO.write(pins.nreset, 1)
    Circuits.GPIO.write(pins.boot0, if(mode == :bootloader, do: 1, else: 0))
    Process.sleep(1)
    Circuits.GPIO.write(pins.nreset, 0)
    Process.sleep(if mode == :bootloader, do: 75, else: 800)
  end

  defp cmd(command, args), do: System.cmd(command, args, stderr_to_stdout: true)
end
