// Starts the built server, simulates the Studio plugin (edit + server contexts), and drives it via a real MCP client.
import { spawn } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
const TOKEN = "test-token-0123456789abcdef", MCP = 3999, BR = 44999;
const srv = spawn(process.execPath, ["dist/index.js"], { env: { ...process.env, MCP_TOKEN: TOKEN, MCP_PORT: MCP, BRIDGE_PORT: BR }, stdio: "inherit" });
await new Promise((r) => setTimeout(r, 800));
let ok = 0, failN = 0;
const check = (name, cond, extra = "") => { cond ? ok++ : failN++; console.log(`${cond ? "PASS" : "FAIL"} ${name} ${extra}`); };

// --- mock plugin
const world = { "game.Workspace.Part": { Name: "Part", Position: { $type: "Vector3", value: [0, 5, 0] } } };
let running = true;
async function mockPlugin(context) {
  while (running) {
    const r = await fetch(`http://127.0.0.1:${BR}/poll?context=${context}`).catch(() => null);
    if (!r || r.status !== 200) continue;
    const m = await r.json();
    let res = { id: m.id, ok: true };
    switch (m.cmd) {
      case "get_studio_state": res.result = { context, isEdit: context === "edit", placeName: "MockPlace", selection: [] }; break;
      case "get_properties": if (!world[m.args.path]) res = { id: m.id, ok: false, error: "Instance not found: " + m.args.path }; else res.result = { properties: world[m.args.path] }; break;
      case "set_properties": Object.assign(world[m.args.path], m.args.properties); res.result = { path: m.args.path, errors: {} }; break;
      case "run_luau": res.result = { ok: true, output: ["hello from " + context], returns: [42] }; break;
      case "stop_playtest": res.result = { stopping: true, by: context }; break;
      default: res.result = { echo: m.cmd, args: m.args };
    }
    await fetch(`http://127.0.0.1:${BR}/result?context=${context}`, { method: "POST", body: JSON.stringify(res) });
  }
}

try {
  // unauthorized
  const un = await fetch(`http://127.0.0.1:${MCP}/mcp`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  check("rejects missing token", un.status === 401);
  const bad = await fetch(`http://127.0.0.1:${MCP}/mcp`, { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer nope" }, body: "{}" });
  check("rejects wrong token", bad.status === 401);

  const client = new Client({ name: "test", version: "1" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${MCP}/mcp`), { requestInit: { headers: { Authorization: `Bearer ${TOKEN}` } } }));
  const tools = (await client.listTools()).tools.map((t) => t.name).sort();
  check("lists 18 tools", tools.length === 18, tools.join(","));

  const notConn = await client.callTool({ name: "get_properties", arguments: { path: "game.Workspace.Part" } });
  check("error when plugin not connected", notConn.isError === true, notConn.content[0].text);

  mockPlugin("edit"); await new Promise((r) => setTimeout(r, 200));
  const st = await client.callTool({ name: "get_studio_state", arguments: {} });
  const stJ = JSON.parse(st.content[0].text);
  check("get_studio_state", stJ.studio.placeName === "MockPlace" && stJ.bridge.edit.connected && !stJ.bridge.server.connected);

  const sp = await client.callTool({ name: "set_properties", arguments: { path: "game.Workspace.Part", properties: { Color: { $type: "Color3", value: [1, 0, 0] } } } });
  check("set_properties", !sp.isError);
  const gp = await client.callTool({ name: "get_properties", arguments: { path: "game.Workspace.Part" } });
  check("datatype roundtrip", JSON.parse(gp.content[0].text).properties.Color.$type === "Color3");
  const nf = await client.callTool({ name: "get_properties", arguments: { path: "game.Nope" } });
  check("plugin error propagates", nf.isError && nf.content[0].text.includes("not found"));

  // concurrency
  const many = await Promise.all([1, 2, 3, 4, 5].map((i) => client.callTool({ name: "list_tree", arguments: { path: "Workspace", depth: i } })));
  check("5 concurrent calls", many.every((m) => !m.isError && JSON.parse(m.content[0].text).args.depth >= 1));

  const ps = await client.callTool({ name: "start_playtest", arguments: { mode: "play" } });
  check("start_playtest routed to edit", JSON.parse(ps.content[0].text).echo === "start_playtest");
  mockPlugin("server"); await new Promise((r) => setTimeout(r, 200));
  const rl = await client.callTool({ name: "run_luau", arguments: { code: "print('hi') return 42", context: "server" } });
  check("run_luau in server context", JSON.parse(rl.content[0].text).output[0] === "hello from server");
  const sp2 = await client.callTool({ name: "stop_playtest", arguments: {} });
  check("stop_playtest routed to server", JSON.parse(sp2.content[0].text).by === "server");

  const shot = await client.callTool({ name: "screenshot", arguments: {} });
  check("screenshot errors cleanly on non-Windows", shot.isError && shot.content[0].text.includes("Windows"));
  await client.close();
} catch (e) { failN++; console.error(e); }
running = false; srv.kill();
console.log(`\n${ok} passed, ${failN} failed`);
process.exit(failN ? 1 : 0);
