# Account and LAN play brief

The UI prototype was Chinese-only; the real app is bilingual.

## Scope

- Implement the account first: UUID and nickname. The first launch asks for a nickname.
- Leave room for medals and final match records, to be implemented later.
- Implement LAN play. Internet and MultipeerConnectivity follow later, so keep the interfaces reusable.
- Game logic and card balance follow the published standard ruleset exactly.

## Intended experience

- On first launch a welcome screen asks for a nickname.
- The home screen offers the play modes.
- LAN play offers Create Room and Join Room.
- When creating a room, the host chooses a room name and an optional password, then waits for others to join.
- Once everyone is in, the host opens the configuration screen while the other players watch the host's choices live. Configuration covers the game mode, AI players with adjustable difficulty, the victory condition (for the standard ruleset, the target score) and the per-turn time limit, 30 seconds by default.
- Then the match itself.
- The interface should be clean, multilingual, and use native components wherever possible.
