// Local HTTP bridge (127.0.0.1 only) that the Roblox Studio plugin long-polls.
import http from "node:http";
import { randomUUID } from "node:crypto";

export type Context = "edit" | "server" | "client";
interface Pending { id: string; cmd: string; args: unknown; context: Context; resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout; }
interface Waiter { res: http.ServerResponse; timer: NodeJS.Timeout; }

export class Bridge {
  private queues: Record<Context, Pending[]> = { edit: [], server: [], client: [] };
  private waiters: Record<Context, Waiter[]> = { edit: [], server: [], client: [] };
  private inflight = new Map<string, Pending>();
  private lastSeen: Record<Context, number> = { edit: 0, server: 0, client: 0 };
  private info: Record<Context, any> = { edit: null, server: null, client: null };
  constructor(private port: number, private secret?: string) {}

  connected(ctx: Context, withinMs = 40000) { return Date.now() - this.lastSeen[ctx] < withinMs; }
  status() {
    const out: Record<string, unknown> = {};
    for (const c of ["edit", "server", "client"] as Context[]) out[c] = { connected: this.connected(c), lastSeenMsAgo: this.lastSeen[c] ? Date.now() - this.lastSeen[c] : null, info: this.info[c] };
    return out;
  }

  send(context: Context, cmd: string, args: unknown, timeoutMs = 30000): Promise<any> {
    if (!this.connected(context)) {
      return Promise.reject(new Error(`Studio plugin (${context} context) is not connected. ` + (context === "edit" ? "Open Roblox Studio with the MCP plugin enabled and HTTP allowed." : "Is a playtest running?")));
    }
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const p: Pending = { id, cmd, args, context, resolve, reject, timer: setTimeout(() => {
        this.inflight.delete(id);
        const q = this.queues[context]; const i = q.indexOf(p); if (i >= 0) q.splice(i, 1);
        reject(new Error(`Timed out after ${timeoutMs}ms waiting for Studio (${cmd})`));
      }, timeoutMs) };
      this.queues[context].push(p);
      this.flush(context);
    });
  }

  private flush(ctx: Context) {
    while (this.queues[ctx].length && this.waiters[ctx].length) {
      const p = this.queues[ctx].shift()!; const w = this.waiters[ctx].shift()!;
      clearTimeout(w.timer); this.inflight.set(p.id, p);
      w.res.writeHead(200, { "content-type": "application/json" });
      w.res.end(JSON.stringify({ id: p.id, cmd: p.cmd, args: p.args ?? {} }));
    }
  }

  start(): Promise<void> {
    const srv = http.createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (this.secret && req.headers["x-bridge-secret"] !== this.secret) { res.writeHead(401); res.end("bad secret"); return; }
      const ctx = (url.searchParams.get("context") ?? "edit") as Context;
      if (!["edit", "server", "client"].includes(ctx)) { res.writeHead(400); res.end("bad context"); return; }
      if (req.method === "GET" && url.pathname === "/poll") {
        this.lastSeen[ctx] = Date.now();
        const info = url.searchParams.get("info"); if (info) { try { this.info[ctx] = JSON.parse(info); } catch {} }
        const w: Waiter = { res, timer: setTimeout(() => {
          const i = this.waiters[ctx].indexOf(w); if (i >= 0) this.waiters[ctx].splice(i, 1);
          res.writeHead(204); res.end();
        }, 20000) };
        res.on("close", () => { clearTimeout(w.timer); const i = this.waiters[ctx].indexOf(w); if (i >= 0) this.waiters[ctx].splice(i, 1); });
        this.waiters[ctx].push(w); this.flush(ctx); return;
      }
      if (req.method === "POST" && url.pathname === "/result") {
        let body = ""; req.on("data", (c) => (body += c));
        req.on("end", () => {
          this.lastSeen[ctx] = Date.now();
          try {
            const msg = JSON.parse(body); const p = this.inflight.get(msg.id);
            if (p) { this.inflight.delete(msg.id); clearTimeout(p.timer); msg.ok ? p.resolve(msg.result) : p.reject(new Error(String(msg.error ?? "unknown plugin error"))); }
            res.writeHead(200); res.end("ok");
          } catch (e) { res.writeHead(400); res.end("bad json"); }
        });
        return;
      }
      if (url.pathname === "/health") { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify(this.status())); return; }
      res.writeHead(404); res.end();
    });
    return new Promise((r) => srv.listen(this.port, "127.0.0.1", () => r()));
  }
}
