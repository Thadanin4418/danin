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

## On the Mac

The command builds and opens:

- `~/Desktop/Soranin.app`

The app auto-starts the local control server:

- `http://127.0.0.1:8765/status`

## On the iPhone

In the `soranin` app:

1. tap `Control Mac`
2. paste the Mac URL shown by `START_CONTROL_MAC.command`
3. tap `Load Mac`
4. choose:
   - `Chrome Name`
   - `Page`
   - `Folders`
5. tap:
   - `Preflight`
   - or `Run Facebook Post`

## Example

If the script prints:

```text
http://192.168.1.8:8765
```

then use exactly that in the iPhone app.

## Notes

- Mac and iPhone should be on the same Wi-Fi network.
- If the Mac IP changes later, run `START_CONTROL_MAC.command` again and use the new URL.
- If you move the repo, rebuild the Mac app again.
