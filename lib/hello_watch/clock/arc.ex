defmodule HelloWatch.Clock.Arc do
  @moduledoc """
  Text for a round panel: along the rim, and sized to fit where it sits.

  Emerge lays text out in straight lines and can't measure our fonts, so
  this reads each font's glyph widths from its TTF at compile time. Text on
  the rim is a layer per glyph, the size of the panel, with the glyph at its
  top (or bottom) and the layer rotated about the panel's centre.
  """
  use Emerge.UI

  import Bitwise

  alias HelloWatch.Clock.Palette

  @size 454
  @center div(@size, 2)

  @fonts %{
    macondo: {"Macondo", 400, false, "Macondo-Regular.ttf"},
    sans: {"Alegreya Sans", 400, false, "AlegreyaSans-Regular.ttf"},
    medium: {"Alegreya Sans", 500, false, "AlegreyaSans-Medium.ttf"},
    italic: {"Alegreya Sans", 400, true, "AlegreyaSans-Italic.ttf"}
  }

  # Per font: units per em, ascender, descender, and each character's
  # advance, all in font units.
  @metrics (for {key, {_family, _weight, _italic, file}} <- @fonts, into: %{} do
              path = Path.join([__DIR__, "../../../priv/fonts", file]) |> Path.expand()
              Module.put_attribute(__MODULE__, :external_resource, path)
              data = File.read!(path)

              tables =
                for <<tag::binary-4, _sum::32, offset::32,
                      length::32 <-
                        binary_part(
                          data,
                          12,
                          16 * :binary.decode_unsigned(binary_part(data, 4, 2))
                        )>>,
                    into: %{},
                    do: {tag, binary_part(data, offset, length)}

              <<_::binary-18, units::16, _::binary>> = tables["head"]

              <<_::binary-4, ascender::signed-16, descender::signed-16, _::binary-26,
                hmetrics::16>> = tables["hhea"]

              advances =
                for <<advance::16, _lsb::16 <- binary_part(tables["hmtx"], 0, 4 * hmetrics)>>,
                  do: advance

              last = List.last(advances)
              advances = List.to_tuple(advances)

              # The Unicode subtable: format 4 (BMP) or 12.
              cmap = tables["cmap"]
              <<_::16, count::16, records::binary-size(count * 8), _::binary>> = cmap

              subtable =
                for(<<platform::16, encoding::16, offset::32 <- records>>,
                  do: {platform, encoding, offset}
                )
                |> Enum.filter(fn {p, e, _} -> {p, e} in [{3, 10}, {0, 4}, {3, 1}, {0, 3}] end)
                |> Enum.map(fn {_, _, offset} ->
                  binary_part(cmap, offset, byte_size(cmap) - offset)
                end)
                |> Enum.max_by(fn <<format::16, _::binary>> -> format end)

              glyphs =
                case subtable do
                  <<12::16, _::16, _::32, _::32, groups::32, rest::binary>> ->
                    for <<first::32, last_code::32,
                          glyph::32 <- binary_part(rest, 0, groups * 12)>>,
                        code <- first..Kernel.min(last_code, 0x2FFF)//1,
                        do: {code, glyph + code - first}

                  <<4::16, _::16, _::16, seg_x2::16, _::binary-6, rest::binary>> ->
                    <<ends::binary-size(^seg_x2), _::16, starts::binary-size(^seg_x2),
                      deltas::binary-size(^seg_x2), range_offsets::binary-size(^seg_x2),
                      _::binary>> = rest

                    # Where idRangeOffset[] starts, after the 14-byte header, endCode[],
                    # the pad, startCode[] and idDelta[].
                    ranges_at = 16 + 3 * seg_x2
                    seg = fn bin, i -> :binary.decode_unsigned(binary_part(bin, 2 * i, 2)) end

                    for i <- 0..(div(seg_x2, 2) - 1),
                        code <- seg.(starts, i)..Kernel.min(seg.(ends, i), 0x2FFF)//1,
                        code != 0xFFFF do
                      delta = seg.(deltas, i)
                      range = seg.(range_offsets, i)

                      glyph =
                        if range == 0 do
                          code + delta
                        else
                          at = ranges_at + 2 * i + range + 2 * (code - seg.(starts, i))
                          g = :binary.decode_unsigned(binary_part(subtable, at, 2))
                          if g == 0, do: 0, else: g + delta
                        end

                      {code, glyph &&& 0xFFFF}
                    end
                end

              widths =
                for {code, glyph} <- glyphs,
                    glyph != 0,
                    into: %{},
                    do:
                      {code,
                       if(glyph < tuple_size(advances), do: elem(advances, glyph), else: last)}

              {key, {units, ascender, -descender, widths}}
            end)

  @doc "How wide `text` is in `font` (see `@fonts`) at `size`, in pixels."
  def width(text, font, size) do
    {units, _ascender, _descender, widths} = Map.fetch!(@metrics, font)
    fallback = Map.get(widths, ?n, units / 2)

    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, sum -> sum + Map.get(widths, char, fallback) end)
    |> Kernel.*(size / units)
  end

  @doc """
  The largest size up to `size` at which `text` fits in `width` pixels, but
  no smaller than `min`.
  """
  def fit(text, font, size, width, min \\ 12) do
    natural = width(text, font, size)
    if natural <= width, do: size, else: Kernel.max(min, Float.floor(size * width / natural))
  end

  @doc "How wide the panel is `dy` pixels above or below its centre, less `margin` each side."
  def chord(dy, margin \\ 0) do
    half = :math.sqrt(Kernel.max(@center * @center - dy * dy, 0))
    Kernel.max(2 * (half - margin), 0)
  end

  @doc """
  `text` along the rim, centred at the top or the bottom, as panel-sized
  layers for `Nearby.in_front/1`.

  At the top it reads clockwise with the glyphs' tops outward; at the
  bottom it reads counterclockwise with them upright, so both read left to
  right. `inset` is how far the text's outer edge is from the rim.

  Options: `:font` (default `:sans`), `:size` (20), `:color`, `:inset` (16),
  `:tracking`, extra pixels between glyphs (0).
  """
  def rim(text, at, opts \\ []) when at in [:top, :bottom] do
    font = Keyword.get(opts, :font, :sans)
    size = Keyword.get(opts, :size, 20)
    inset = Keyword.get(opts, :inset, 16)
    tracking = Keyword.get(opts, :tracking, 0)
    {family, weight, italic, _file} = Map.fetch!(@fonts, font)
    {units, ascender, descender, _widths} = Map.fetch!(@metrics, font)
    ascent = ascender * size / units
    descent = descender * size / units

    # Glyph tops sit `inset` in from the rim at the top; at the bottom their
    # feet (the descenders) do. The arc runs along the middle of the glyphs.
    {top, radius} =
      case at do
        :top -> {inset, @center - inset - (ascent + descent) / 2}
        :bottom -> {@size - inset - ascent - descent, @center - inset - (ascent + descent) / 2}
      end

    chars = String.graphemes(text)
    advances = Enum.map(chars, &(width(&1, font, size) + tracking))
    total = Enum.sum(advances) - tracking
    sign = if at == :top, do: 1, else: -1

    font_attrs =
      [
        Font.family(family),
        Font.size(size),
        Font.color(Keyword.get_lazy(opts, :color, fn -> Palette.c(:bone) end))
      ] ++
        if(weight != 400, do: [Font.weight(weight)], else: []) ++
        if(italic, do: [Font.italic()], else: [])

    chars
    |> Enum.zip(advances)
    |> Enum.map_reduce(-total / 2, fn {char, advance}, from ->
      middle = from + (advance - tracking) / 2
      degrees = sign * middle / radius * 180 / :math.pi()

      layer =
        if char != " " do
          el(
            [
              width(px(@size)),
              height(px(@size)),
              padding_each(round(top), 0, 0, 0),
              Transform.rotate(degrees)
            ],
            el([center_x()] ++ font_attrs, text(char))
          )
        end

      {layer, from + advance}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end
end
