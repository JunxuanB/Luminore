# Privacy Policy — Luminore

Last updated: 12 November 2026

Luminore is an open-source, independently made board game app. It has no ads, no analytics, no tracking and no account system. This page explains exactly what data exists and where it goes. The source code is public, so every statement here can be checked: <https://github.com/JunxuanB/Luminore>.

## What the app stores

| Data | Where it lives | Who can read it |
| --- | --- | --- |
| Your profiles: a random ID (UUID) and the nickname you chose | On your device, mirrored to **your own private iCloud** database | You. The developer has no access to private iCloud data. |
| Medals, finished-match results and saved matches | Same as above | You |
| A "playing on this device" marker with your device's name, used to warn you when the same profile is active on another of your devices | Same as above | You |
| App settings (language, server address) and a random per-install ID | On your device only | You |

If iCloud is turned off, everything stays on the device. Deleting the app removes the local copy; delete the iCloud copy in Settings › your name › iCloud › Manage Storage.

## What other players see

During a match, the players in the same room receive your nickname, your profile ID, your medal count and your game moves. This is how multiplayer works and how the losing players award a medal to the winner. A room password, if you set one, stays on the host's device.

## Local Network and Nearby play

These modes connect devices directly over Wi‑Fi or Bluetooth. Nothing is sent to any server. iOS asks for Local Network and Bluetooth permission the first time; they are used only to find and connect to other players.

## Internet play

Internet play passes messages between players through a relay server run by the developer on Cloudflare (`luminore-api.junxuanb.com`).

- The relay keeps a room's listing (room name, host nickname, player count, room code) and forwards game messages only while the room is open. The listing is deleted when the room closes or expires.
- The relay does not keep match history, does not build profiles and does not sell or share anything.
- Like any web service, the hosting provider processes your IP address to deliver the connection, and operational logs record technical request information (time, path, status) to diagnose failures. These logs are not used to identify players.
- You can point the app at your own relay server in the Internet mode's server settings; the relay is open source in the same repository.

## What the app does not do

No advertising, no analytics SDKs, no third-party trackers, no location, no contacts, no photos, no microphone, no camera, no purchases.

## Children

The app does not knowingly collect personal information from anyone, including children.

## Changes

If a future version changes how data is handled (for example, to support optional paid online features), this page and the in-app notice will be updated before that version ships.

## Contact

Questions or requests: open an issue at <https://github.com/JunxuanB/Luminore/issues>.
