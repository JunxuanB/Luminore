# Stepping away, pausing, saving and reconnecting

Players sometimes need to leave the app briefly, for example to answer a message. The requirements were:

- **Step away**: switching apps must not drop the player or make reconnecting hard. Timers keep running.
- **Pause**: the host can pause the match from the top-right corner. A cover over the board says the match is paused.
- **Save**: the players of a match can stop and continue later. The save is stored on the host.
- **Reconnect**: a disconnected player must be able to get back in.

All of this must work over LAN, Internet and nearby (Bluetooth) play.

## Current state of saving (rewritten 2026-08-19)

A save is no longer tied to a room, a transport or reconnect credentials. There is no automatic restore of the original room, no substitute assignment and no "rejoin" prompt on the home screen.

- **Saving**: the host pauses the match and chooses Save & Exit. The match ends and everyone returns to the home screen. One account can hold several saves.
- **Loading**: create a room as usual, wait for everyone, open the configuration screen and choose Load Save. Only saves whose seat count **exactly** matches the number of connected players can be loaded. Loading ignores the settings on the configuration screen and uses the `GameConfiguration` stored with the save.
- **Seat matching**: before loading, the host assigns each saved seat to a player in the room (human or AI). Matching UUIDs are paired automatically and can be changed by hand. Seat order is turn order, and progress follows the seat.
- **Deleting**: swipe left in the save list. Leaving a match no longer deletes a save.

All three play modes share one loading path (`MatchSessionService.loadSavedGame`), which uses the same broadcast chain as `startGame`. A Dynamic Island / Live Activity was considered and is not planned.
