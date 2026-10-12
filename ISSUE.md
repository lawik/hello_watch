# TicWatch Pro 3 GPS: issues on a second unit

Watch: GPS (`rubyfish`), `version-bootloader: rubyfish-03.02.04.02.16`,
unlocked + critical unlocked. Flashed with `flash.sh --unlock` from
system v0.2.0; it went straight back to stock fastboot on every boot.

## Boot

1. **Stock `vbmeta` blocks lk2nd.** `fastboot boot lk2nd.img` fails with
   `FAILED (remote: 'unknown reason')`. Fixed by flashing an empty vbmeta with
   flags=3 (verity + verification disabled, as `avbtool make_vbmeta_image
   --flags 3`), then `fastboot reboot bootloader`. Takes effect only after the
   bootloader restarts.
2. **Shipped `dtbo.img` doesn't work on GPS watches.** Its header is the
   unmodified stock one: it claims 2 entries, and the 437 (GPS) entry sits at
   `0x17275`, past the end of the 254-byte file. The bootloader reads leftover
   partition data there, so the result depends on the unit's history
   (`dtb not found` here). `prebuilt/dtbo/dtbo-empty.img` works. NekoCWD's notes
   also say to flash `dtbobak`.
3. **A failed `fastboot boot` leaves the stock bootloader stuck.** Every later
   attempt returns `unknown reason` until `fastboot reboot bootloader`, which
   makes testing misleading.

Suggested `flash.sh` change: flash `dtbo-empty.img` (to `dtbo` and `dtbobak`)
and a disabled `vbmeta`, then `fastboot reboot bootloader` before anything else.

## Runtime

4. **`/data` is a plain directory on the read-only squashfs.** `post-build.sh`
   replaces the skeleton's `/data -> root` symlink for the GPS bind mount, so
   NervesSSH fails to write `/data/nerves_ssh/...` (`:erofs`). Proposed fix in my
   checkout: keep the symlink and have `gpsctl` `mkdir -p /data/{vendor,misc,system}/gps`
   with no bind mount.
5. **The `fwup` and `sftp` SSH subsystems are refused** (`subsystem request
   failed on channel 0`) even though `:ssh.daemon_info` lists both. So
   `mix upload` doesn't work. NervesSSH also logged `No host key available` on
   first boot. Not yet root-caused.
6. **The sensor hub fails on this unit:** `nanohubctl` prints
   `enable sensor: Operation not permitted`, plus repeated
   `nanohub_kthread: kthread_err_cnt=N, ret = -1`.

## hello_watch

7. **`HelloWatch.Clock` crash-loops and the app exits** when `nanohubctl`
   prints a non-JSON line. The port isn't `:binary`, so `String.trim/1` gets a
   charlist (`lib/hello_watch/clock.ex:244`). Fix: add `:binary` to the
   `Port.open` options in `lib/hello_watch/sensors.ex`.
