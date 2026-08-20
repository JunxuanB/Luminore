// One-off diagnostic: does a room's RoomRelay DO still hold state?
// 101 + "ready" => DO storage alive; 404 => orphaned directory row.
import { WebSocket } from "ws";

const roomID = process.argv[2];
if (!roomID) throw new Error("usage: node scripts/probe-room.mjs <roomID>");
const base = process.env.LUMINORE_RELAY_URL ?? "https://luminore-api.junxuanb.com";

const directory = await fetch(new URL("v1/rooms/" + roomID, base));
console.log("directory lookup:", directory.status, await directory.text());

const url = new URL("v1/rooms/" + roomID + "/connect?role=client", base.replace("https:", "wss:"));
const socket = new WebSocket(url);
socket.on("unexpected-response", (_request, response) => {
  console.log("relay DO:", response.statusCode, "=> storage EMPTY (orphaned row)");
  process.exit(0);
});
socket.on("message", (data) => {
  console.log("relay DO: alive, first frame =", data.toString());
  socket.close();
  process.exit(0);
});
socket.on("error", (error) => {
  console.log("socket error:", error.message);
  process.exit(1);
});
setTimeout(() => {
  console.log("relay DO: connected but sent no frame within 8s");
  process.exit(0);
}, 8_000);
