# Internet and nearby play brief

The last pieces were Internet play and nearby (Bluetooth) play.

- The Internet server lives in `backend/` and deploys to Cloudflare Workers.
- Its only job is to relay data. All game logic runs on the clients.
- The app lets the player choose the server URL and stores it locally.
