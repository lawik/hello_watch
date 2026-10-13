defmodule HelloWatch.Clock.TailscalePage do
  @moduledoc """
  The Tailscale page: Whether the watch is on the tailnet, its
  name and address there, and joining. Tapping the page while logged out
  starts a login, which shows its URL as a QR code to scan with a phone
  signed in to Tailscale. Ported from nerves_phone's Settings › Tailscale.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Pages, Palette}

  @size 454
  @title "Tailscale"
  # The code's quiet zone, in modules, and the most it may span: the largest
  # square that fits the round panel between the title and the caption is
  # about 250 px.
  @quiet 2
  @max_side 236

  @doc "`info` is `HelloWatch.Tailscale.info/0`, or `nil` before the first read."
  def render(info, page)

  def render(%{logging_in: true, auth_url: url}, page) when is_binary(url) do
    Pages.page(
      @title,
      column([width(px(@size)), padding_each(104, 0, 0, 0), spacing(10)], [
        el(
          [
            center_x(),
            Background.color(Palette.c(:white)),
            Border.rounded(10)
          ],
          qr_code(url)
        ),
        el(
          [
            center_x(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(17),
            Font.color(Palette.c(:lilac))
          ],
          text("Scan to log in")
        )
      ]),
      page
    )
  end

  def render(info, page), do: Pages.render(@title, rows(info), page)

  defp rows(nil), do: ["Reading…"]
  defp rows(%{state: "Unavailable"}), do: ["Not running on this device"]
  defp rows(%{state: "Off"}), do: [{"status", "Off"}, "", "HelloWatch.Tailscale.start()"]

  defp rows(info) do
    rows =
      for {label, value} <- [
            {"status", state(info)},
            {"name", info.name && short_name(info.name)},
            {"address", info.ip},
            {"tailnet", info.tailnet}
          ],
          value != nil,
          do: {label, value}

    rows ++ hint(info)
  end

  defp hint(%{state: "NeedsLogin", logging_in: false}), do: ["", "Tap to log in"]

  defp hint(%{state: "NeedsMachineAuth"}),
    do: ["", "An admin has to approve", "the watch in the console"]

  defp hint(_info), do: []

  # The first label of the MagicDNS name; the tailnet's domain is its own row.
  defp short_name(name), do: name |> String.split(".") |> hd()

  defp state(%{state: "Running"}), do: "Connected"
  defp state(%{state: "NeedsLogin", logging_in: true}), do: "Logging in…"
  defp state(%{state: "NeedsLogin"}), do: "Logged out"
  defp state(%{state: "NeedsMachineAuth"}), do: "Needs approval"
  defp state(%{state: "Starting"}), do: "Connecting…"
  defp state(%{state: "Stopped"}), do: "Stopped"
  defp state(%{state: "NoDaemon"}), do: "Starting…"
  defp state(%{state: state}), do: state

  # Each row of the code as runs of dark and light modules, so a row is a
  # few elements rather than one per module.
  defp qr_code(url) do
    rows = EQRCode.encode(url).matrix |> Tuple.to_list()
    count = length(rows) + 2 * @quiet
    module = Kernel.max(div(@max_side, count), 2)

    column(
      [padding(module * @quiet)],
      for row <- rows do
        runs =
          row
          |> Tuple.to_list()
          |> Enum.chunk_by(& &1)
          |> Enum.map(fn [bit | _] = run ->
            color = if bit == 1, do: Palette.c(:black), else: Palette.c(:white)

            el(
              [width(px(module * length(run))), height(px(module)), Background.color(color)],
              none()
            )
          end)

        row([], runs)
      end
    )
  end
end
