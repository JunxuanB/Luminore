# Project plan

Luminore is a gem-trading board game for iOS written in Swift, with several rulesets (Standard and the two-player Duel).

## Tech stack

- Front end: Swift
- Back end: TypeScript, entirely on Cloudflare services

## Key decisions

- iPhone is portrait only; iPad supports every orientation
- Only recent iOS versions need to be supported
- Adapt to iPhone 14 and later; iPhone SE-sized screens are out of scope
- Simple, clean UI in the native iOS style
- Anti-cheat is not a priority; local binary and save tampering are not handled

## Play modes

All are multiplayer, including tables of more than four players:

- Internet
- Local network (LAN)
- MultipeerConnectivity

Because the modes differ so much, the back-end server only relays data.

## Account model

- UUID
- Nickname
- Medals: after each match the losing side awards the winner a medal carrying the loser's UUID; the winner sees every medal in a list
- Final match records

These are stored locally and backed up to the user's own iCloud, in plain text.

## Possible future work

- High probability: playing against AI, and AI players joining a match (both now implemented)
- Low probability: macOS and web versions
