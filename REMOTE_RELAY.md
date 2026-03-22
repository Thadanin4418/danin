# Remote Relay

Use this when iPhone and Mac are on different internet connections and you want `Control Mac` to work with your own server.

## What it does

- `Same Wi-Fi` still uses `Scan Mac (Wi-Fi Fast)`
- `Different Wi-Fi / 4G / 5G` uses `Remote Mac`
- your Mac connects out to the relay
- your iPhone connects to the relay
- the relay forwards jobs to your Mac using:
  - `relay_url`
  - `user_name`
  - `mac_name`
  - `secret token`
  - `control password`

## Relay server

The relay server is:

- [mac_control_relay_server.py](/Users/nin/Downloads/SoraninControlSuite/scripts/mac_control_relay_server.py)

It uses only Python standard library.

Default port:

- `8788`

Health check:

- `GET /status`

## Start locally

From [SoraninControlSuite](/Users/nin/Downloads/SoraninControlSuite):

```bash
python3 scripts/mac_control_relay_server.py
```

Or use:

- [START_REMOTE_RELAY.command](/Users/nin/Downloads/SoraninControlSuite/START_REMOTE_RELAY.command)

## Deploy on Render

This repo now includes:

- [render.yaml](/Users/nin/Downloads/SoraninControlSuite/render.yaml)
- [requirements.txt](/Users/nin/Downloads/SoraninControlSuite/requirements.txt)

So you can deploy the relay as a Render web service.

Health check:

- `/status`

## Save relay settings on Mac

In [Soranin.app](/Users/nin/Desktop/Soranin.app):

1. Open `Facebook Runner`
2. In `Remote Relay`, fill:
   - Relay URL
   - user label
   - mac label
   - secret token
3. Click `Save Relay`
4. The local Mac control server will restart
5. Copy `Remote Mac (Relay)` URL to iPhone if needed

The config is saved in:

- `~/.soranin/control_relay.json`

## Example config

```json
{
  "relay_url": "https://your-relay.example.com",
  "relay_user_name": "danin",
  "relay_mac_name": "NIN-MBP",
  "relay_secret_token": "abc123",
  "control_password": "your-password",
  "poll_seconds": 3
}
```

## What works through relay

- `facebook-post-bootstrap`
- `facebook-post-preflight`
- `facebook-post-run`
- `quit-chrome`
- `remote-run`
- `facebook-packages`
- `facebook-package-thumbnail`
- `facebook-package-delete`
- `source-video-upload`

## Security

Use both:

- secret relay client URL
- control password

The relay client URL identifies the Mac.
The control password confirms the iPhone is allowed to use it.
