// PhoneCast relay: lets the Mac/PC reach the phone from any network without Tailscale.
//
// Both sides dial out, so no port forwarding is needed. Each phone has a room: 64 hex chars derived
// from the mirror key that only the phone and its paired computers know.
//   phone  ->  /v1/<room>/phone          control socket, always open; gets {"open": id, "port": p},
//                                        sends {"addrs": [...]} (its public IPv6 addresses) when they change
//   Mac    ->  /v1/<room>/mac?port=p     one socket per TCP connection to the phone's port p
//   phone  ->  /v1/<room>/accept?id=id   the phone's half of that connection
//   Mac    ->  GET /v1/<room>/addrs      {"online": bool, "addrs": [...]}: try a direct IPv6 connection first
// The relay only pipes bytes, and the apps encrypt every tunnel end to end (AES-GCM with a key from
// the mirror key), on top of the link's own TLS. So the relay can't read anything or log in.
//
// ALLOWED (optional secret, comma-separated rooms): only these rooms may use this relay, so a public
// build doesn't run on someone else's free quota. `relay/allow.sh` adds the Mac's current room.
import { DurableObject } from "cloudflare:workers";

const PORTS = new Set([27183, 27185]);   // mirror, link

export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    const m = u.pathname.match(/^\/v1\/([0-9a-f]{64})\/(phone|mac|accept|addrs)$/);
    if (!m) return new Response("PhoneCast relay\n", { status: u.pathname === "/" ? 200 : 404 });
    const allowed = (env.ALLOWED || "").split(",").map((s) => s.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(m[1])) return new Response("this relay doesn't serve this phone\n", { status: 403 });
    if (m[2] !== "addrs" && req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("websocket only\n", { status: 426 });
    return env.ROOMS.get(env.ROOMS.idFromName(m[1])).fetch(req);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // id -> messages from the Mac before the phone picked up. Memory only: if the object is evicted in
    // that second, the Mac's first bytes are lost, it hears nothing for 15 s and simply tries again.
    this.pending = new Map();
    // keep-alive pings are answered without waking the object up (the phone's socket is open all day)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(req) {
    const u = new URL(req.url);
    const kind = u.pathname.split("/")[3];

    if (kind === "addrs") {
      const online = this.ctx.getWebSockets("phone").length > 0;
      const addrs = online ? (await this.ctx.storage.get("addrs")) || [] : [];
      return Response.json({ online, addrs }, { headers: { "cache-control": "no-store" } });
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    if (kind === "phone") {
      for (const old of this.ctx.getWebSockets("phone")) { try { old.close(4000, "replaced"); } catch {} }
      this.ctx.acceptWebSocket(server, ["phone"]);
      server.serializeAttachment({ role: "phone" });
    } else if (kind === "mac") {
      const port = Number(u.searchParams.get("port"));
      if (!PORTS.has(port)) return new Response("bad port\n", { status: 400 });
      const phone = this.ctx.getWebSockets("phone")[0];
      if (!phone) return new Response("phone offline\n", { status: 404 });
      const id = crypto.randomUUID();
      this.ctx.acceptWebSocket(server, ["mac:" + id]);
      server.serializeAttachment({ role: "mac", id });
      this.pending.set(id, []);
      try { phone.send(JSON.stringify({ open: id, port })); }
      catch { return new Response("phone offline\n", { status: 404 }); }
    } else {
      const id = u.searchParams.get("id") || "";
      if (!this.ctx.getWebSockets("mac:" + id)[0]) return new Response("gone\n", { status: 404 });
      this.ctx.acceptWebSocket(server, ["acc:" + id]);
      server.serializeAttachment({ role: "acc", id });
      for (const msg of this.pending.get(id) || []) server.send(msg);
      this.pending.delete(id);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  peer(a) {
    if (a.role === "mac") return this.ctx.getWebSockets("acc:" + a.id)[0];
    if (a.role === "acc") return this.ctx.getWebSockets("mac:" + a.id)[0];
    return undefined;
  }

  async webSocketMessage(ws, msg) {
    const a = ws.deserializeAttachment();
    if (!a) return;
    if (a.role === "phone") {
      if (typeof msg !== "string" || msg.length > 2000) return;
      try {
        const o = JSON.parse(msg);
        if (Array.isArray(o.addrs)) {
          const addrs = o.addrs.filter((x) => typeof x === "string" && /^[0-9a-f:]{2,39}$/i.test(x)).slice(0, 8);
          await this.ctx.storage.put("addrs", addrs);
        }
      } catch {}
      return;
    }
    const p = this.peer(a);
    if (p) { try { p.send(msg); } catch { this.closeBoth(ws, a); } return; }
    const q = a.role === "mac" ? this.pending.get(a.id) : undefined;
    if (q && q.length < 256) q.push(msg); else this.closeBoth(ws, a);
  }

  closeBoth(ws, a) {
    try { ws.close(1000, "closed"); } catch {}
    const p = a && this.peer(a);
    if (p) { try { p.close(1000, "peer closed"); } catch {} }
    if (a?.id) this.pending.delete(a.id);
  }

  webSocketClose(ws) { this.closeBoth(ws, ws.deserializeAttachment()); }
  webSocketError(ws) { this.closeBoth(ws, ws.deserializeAttachment()); }
}
