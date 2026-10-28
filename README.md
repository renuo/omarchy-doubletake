# doubletake — Omarchy plugin

Share your screen to an AirPlay receiver (Apple TV, AirPlay TV, Mac) from the Omarchy bar, using [doubletake](https://github.com/omarroth/doubletake).

Click the AirPlay icon:

- **On/off:** the switch in the panel's header starts and stops the doubletake daemon. It stays that way after you log in again (`systemctl --user enable --now` / `disable --now`). While it's off, the daemon isn't running and the icon is dimmed; the widget only asks systemd for the switch's state, every 30 s. Right-click the icon to flip the switch; turning it off also stops any sharing.
- **Not sharing:** the panel lists the receivers on your network, **Paired** first, then **Not paired**. Within each, Apple TVs come first and Macs (MacBook, iMac, Mac mini, …) last. Click a paired receiver and it connects right away. A receiver that is not paired asks *Pair first?*. Click **Pair**, then type the code the receiver shows (or its AirPlay password, if it has one set).
- **Choosing the screen:** the first time you share to a receiver, Omarchy's share picker asks which screen to send. Keep *restore* ticked (Omarchy's default) and doubletake remembers your choice for that receiver, so after that, sharing starts without asking.
- **Sharing:** the icon turns red and the panel has a single **Stop sharing** button.

The panel closes once a connection starts, so that it doesn't cover the share picker or hold on to the keyboard. It opens again when the receiver asks for a code, or when the connection fails.

Keyboard: `j`/`k` move between the switch and the rows below it, `Enter` flips or picks, `s` stops sharing, `Esc` backs out of *Pair first?* or closes the panel.

## Install

```bash
bin/install
```

This installs:

1. doubletake from the AUR, unless `doubletake` is already on `PATH` or in `~/.local/bin`.
2. `~/.config/systemd/user/doubletake.service`, which runs `doubletake -daemonize` with the graphical session. Installing doesn't enable or start it; that's the panel's switch. A daemon that is already running is restarted, so it picks up a new binary.
3. The plugin itself, copied to `~/.config/omarchy/plugins/renuo.doubletake/`, and added to the bar.

It does not change your Hyprland or portal configuration.

## How "paired" is decided

The daemon does not report pairing. The plugin reads doubletake's credential file (`~/.config/doubletake/credentials.json`) instead: a receiver counts as paired if its device id has a saved `pairing_id`.

Some things to know:

- Many receivers accept a connection with no code at all. doubletake then pairs only for that session and saves nothing, so these receivers stay under **Not paired** and ask *Pair first?* every time, even though no code is ever needed.
- With `-cred-backend keyring` the file is not used, so every receiver shows up as not paired.

## Remove

```bash
systemctl --user disable --now doubletake.service
rm ~/.config/systemd/user/doubletake.service
omarchy plugin remove renuo.doubletake
```

## Development

```bash
bin/setup   # checks the tools bin/check needs
bin/check   # validates the manifest, runs the tests
bin/install # installs into the shell, which hot-reloads it
```

The panel never talks to the daemon or systemd directly. All of its calls go through [`ctl.sh`](ctl.sh), which wraps `doubletake-ctl` and `systemctl`:

```
ctl.sh state         # enabled or not, daemon status, receivers each marked paired or not
ctl.sh enable        # systemctl --user enable --now doubletake.service
ctl.sh disable       # systemctl --user disable --now doubletake.service
ctl.sh connect IP    # start mirroring; the daemon pairs first if it has to
ctl.sh code IP       # answer IP's PIN or password prompt with the value on stdin
ctl.sh stop          # stop every stream
```

`doubletake-ctl` accepts the code only as a command-line argument. So for the moment the call runs, the code is visible in the process list.
