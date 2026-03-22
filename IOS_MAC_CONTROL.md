# iPhone Control Mac

This is the cleanest way to use the iPhone `soranin` app with the Mac `Soranin.app`.

## Fast start

Run:

```bash
./START_CONTROL_MAC.command
```

Or double-click:

- `START_CONTROL_MAC.command`

What it does:

- builds the Mac app
- opens `Soranin.app`
- waits for the local control server
- shows the server URL you should paste into the iPhone app
- if Tailscale is installed, `Facebook Runner` also shows a `Tailscale URL` for remote use

## On the Mac

The command builds and opens:

- `~/Desktop/Soranin.app`

The app auto-starts the local control server:

- `http://127.0.0.1:8765/status`

## On the iPhone

In the `soranin` app:

1. tap `Control Mac`
2. if iPhone and Mac are on the same Wi-Fi:
   - tap `Scan Mac`
3. if you are away from home or on a different Wi-Fi:
   - copy the `Tailscale URL` from `Soranin.app` on the Mac
   - paste that into `Server URL`
4. tap `Load Mac`
5. choose:
   - `Chrome Name`
   - `Page`
   - `Folders`
6. tap:
   - `Preflight`
   - or `Run Facebook Post`

## Example

If the script prints:

```text
http://192.168.1.8:8765
```

then use exactly that in the iPhone app.

## Notes

- `Scan Mac` works when Mac and iPhone are on the same Wi-Fi network.
- for remote control on different Wi-Fi or cellular, install Tailscale on both Mac and iPhone, sign in to the same Tailscale account, then use the `Tailscale URL`
- If the Mac IP changes later, run `START_CONTROL_MAC.command` again and use the new URL.
- If you move the repo, rebuild the Mac app again.
