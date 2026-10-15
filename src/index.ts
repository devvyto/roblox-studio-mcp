import express from "express";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { Bridge, type Context } from "./bridge.js";
import { captureStudio } from "./screenshot.js";

const MCP_TOKEN = process.env.MCP_TOKEN ?? "";
const MCP_PORT = Number(process.env.MCP_PORT ?? 3333);
const MCP_HOST = process.env.MCP_HOST ?? "127.0.0.1";
const BRIDGE_PORT = Number(process.env.BRIDGE_PORT ?? 44755);
const BRIDGE_SECRET = process.env.BRIDGE_SECRET || undefined;
if (MCP_TOKEN.length < 16) { console.error("MCP_TOKEN env var is required (min 16 chars)."); process.exit(1); }

const bridge = new Bridge(BRIDGE_PORT, BRIDGE_SECRET);
const ctxSchema = z.enum(["edit", "server", "client"]).optional()
  .describe("Which Studio DataModel runs the command. 'edit' (default) = the edit session; during a playtest use 'server' or 'client' to act on the running game.");

const text = (v: unknown) => ({ content: [{ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }] });
const fail = (e: unknown) => ({ isError: true, content: [{ type: "text" as const, text: `Error: ${(e as Error)?.message ?? String(e)}` }] });
async function call(cmd: string, args: Record<string, unknown>, timeoutMs?: number) {
  const { context, ...rest } = args as { context?: Context };
  try { return text(await bridge.send(context ?? "edit", cmd, rest, timeoutMs)); } catch (e) { return fail(e); }
}

const SERIAL = `Values use JSON. Primitives as-is. Datatypes: {"$type":"Vector3","value":[x,y,z]}, {"$type":"Vector2","value":[x,y]}, {"$type":"CFrame","value":[x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22]} (or {"$type":"CFrame","position":[x,y,z],"lookAt":[x,y,z]}), {"$type":"Color3","value":[r,g,b]} (0-1) or {"$type":"Color3","hex":"#ff0000"}, {"$type":"UDim","value":[scale,offset]}, {"$type":"UDim2","value":[xs,xo,ys,yo]}, {"$type":"Enum","enum":"Material","value":"Neon"}, {"$type":"BrickColor","value":"Bright red"}, {"$type":"NumberRange","value":[min,max]}, {"$type":"Rect","value":[x0,y0,x1,y1]}, {"$type":"Instance","path":"game.Workspace.Part"}. Paths are dot-separated from game (e.g. "Workspace.Model.Part" or "game.Workspace.Part"); use [\"Name.With.Dots\"] brackets for names containing dots.`;

function buildServer() {
  const s = new McpServer({ name: "roblox-studio-mcp", version: "1.0.0" });
  s.registerTool("get_studio_state", { description: "Bridge connection status per context, plus run mode, selection, place info, camera from the plugin.", inputSchema: { context: ctxSchema } },
    async (a) => { const st = bridge.status(); try { return text({ bridge: st, studio: await bridge.send(a.context ?? "edit", "get_studio_state", {}) }); } catch (e) { return text({ bridge: st, error: (e as Error).message }); } });
  s.registerTool("list_tree", { description: "List the instance tree under a path. " + SERIAL, inputSchema: { path: z.string().default("game"), depth: z.number().int().min(0).max(10).default(2), maxNodes: z.number().int().max(5000).default(800), context: ctxSchema } }, (a) => call("list_tree", a));
  s.registerTool("get_properties", { description: "Read properties of an instance. If 'properties' omitted, returns a common set for its class (plus Attributes & Tags). " + SERIAL, inputSchema: { path: z.string(), properties: z.array(z.string()).optional(), context: ctxSchema } }, (a) => call("get_properties", a));
  s.registerTool("set_properties", { description: "Set properties (and optionally attributes) on an instance. Undoable (ChangeHistoryService). " + SERIAL, inputSchema: { path: z.string(), properties: z.record(z.string(), z.any()).default({}), attributes: z.record(z.string(), z.any()).optional(), context: ctxSchema } }, (a) => call("set_properties", a));
  s.registerTool("create_instance", { description: "Create an instance of className under parent path with properties. Undoable. " + SERIAL, inputSchema: { className: z.string(), parent: z.string().default("Workspace"), name: z.string().optional(), properties: z.record(z.string(), z.any()).optional(), context: ctxSchema } }, (a) => call("create_instance", a));
  s.registerTool("delete_instance", { description: "Destroy an instance (actually parents to nil so Ctrl+Z works). Undoable.", inputSchema: { path: z.string(), context: ctxSchema } }, (a) => call("delete_instance", a));
  s.registerTool("clone_instance", { description: "Clone an instance, optionally into another parent and with a new name. Undoable.", inputSchema: { path: z.string(), newParent: z.string().optional(), newName: z.string().optional(), context: ctxSchema } }, (a) => call("clone_instance", a));
  s.registerTool("move_instance", { description: "Reparent (and optionally rename) an instance. Undoable.", inputSchema: { path: z.string(), newParent: z.string(), newName: z.string().optional(), context: ctxSchema } }, (a) => call("move_instance", a));
  s.registerTool("get_script_source", { description: "Get the Source of a Script/LocalScript/ModuleScript (via ScriptEditorService when available).", inputSchema: { path: z.string(), context: ctxSchema } }, (a) => call("get_script_source", a));
  s.registerTool("set_script_source", { description: "Replace the Source of a script (ScriptEditorService:UpdateSourceAsync, so open editors update). Undoable.", inputSchema: { path: z.string(), source: z.string(), context: ctxSchema } }, (a) => call("set_script_source", a));
  s.registerTool("run_luau", { description: "Execute Luau code inside Studio (plugin security) and return printed output, return values and errors. Wrapped in an undo waypoint. During playtests pass context 'server' or 'client'.", inputSchema: { code: z.string(), timeoutSec: z.number().min(1).max(120).default(25), context: ctxSchema } },
    (a) => call("run_luau", a, (a.timeoutSec + 5) * 1000));
  s.registerTool("get_selection", { description: "Get selected instances (paths).", inputSchema: { context: ctxSchema } }, (a) => call("get_selection", a));
  s.registerTool("set_selection", { description: "Set the Studio selection to the given paths.", inputSchema: { paths: z.array(z.string()), context: ctxSchema } }, (a) => call("set_selection", a));
  s.registerTool("set_camera", { description: "Move the Studio camera. Provide cframe (serialized CFrame), or position+lookAt arrays, and/or focus (instance path to frame like pressing F). " + SERIAL, inputSchema: { cframe: z.any().optional(), position: z.array(z.number()).length(3).optional(), lookAt: z.array(z.number()).length(3).optional(), focus: z.string().optional(), fieldOfView: z.number().optional(), context: ctxSchema } }, (a) => call("set_camera", a));
  s.registerTool("start_playtest", { description: "Start a playtest via StudioTestService. mode 'play' = Play (F5, with character), 'run' = Run (F8, server only). Returns immediately; poll get_studio_state for server/client contexts to appear.", inputSchema: { mode: z.enum(["play", "run"]).default("play") } }, (a) => call("start_playtest", { ...a, context: "edit" }));
  s.registerTool("stop_playtest", { description: "Stop the running playtest (StudioTestService:EndTest from the server context).", inputSchema: {} },
    async () => { try { return text(await bridge.send("server", "stop_playtest", {})); } catch (e) { try { return text(await bridge.send("edit", "stop_playtest", {})); } catch { return fail(e); } } });
  s.registerTool("get_output_log", { description: "Recent Output window messages captured by the plugin in that context.", inputSchema: { limit: z.number().int().max(2000).default(200), sinceId: z.number().int().optional().describe("Only messages with id > sinceId"), filter: z.string().optional(), context: ctxSchema } }, (a) => call("get_output_log", a));
  s.registerTool("screenshot", { description: "Capture the Roblox Studio window (Windows) as PNG, downscaled to maxWidth.", inputSchema: { maxWidth: z.number().int().min(320).max(2560).default(1280), mode: z.enum(["window", "screen"]).default("window") } },
    async (a) => { try { return { content: [{ type: "image" as const, data: await captureStudio(a.maxWidth, a.mode), mimeType: "image/png" }] }; } catch (e) { return fail(e); } });
  return s;
}

function authOk(h?: string) {
  if (!h?.startsWith("Bearer ")) return false;
  const a = Buffer.from(h.slice(7)), b = Buffer.from(MCP_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

const app = express();
app.use(express.json({ limit: "20mb" }));
app.get("/healthz", (_q, r) => r.json({ ok: true }));
app.use("/mcp", (req, res, next) => authOk(req.headers.authorization) ? next() : res.status(401).json({ jsonrpc: "2.0", error: { code: -32001, message: "Unauthorized" }, id: null }));
app.post("/mcp", async (req, res) => {
  // Stateless: a fresh server+transport per request.
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  res.on("close", () => { transport.close(); server.close(); });
  try { await server.connect(transport); await transport.handleRequest(req, res, req.body); }
  catch (e) { console.error(e); if (!res.headersSent) res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null }); }
});
app.all("/mcp", (_q, r) => r.status(405).set("Allow", "POST").json({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed" }, id: null }));

await bridge.start();
app.listen(MCP_PORT, MCP_HOST, () => {
  console.log(`[roblox-studio-mcp] MCP endpoint: http://${MCP_HOST}:${MCP_PORT}/mcp (Bearer token required)`);
  console.log(`[roblox-studio-mcp] Plugin bridge: http://127.0.0.1:${BRIDGE_PORT}`);
});
