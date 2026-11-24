#!/usr/bin/env node
import { spawn } from "node:child_process";
import { accessSync, constants, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const EXE = "StudioMCP.exe";

// Vinegar ships its own Wine under `kombucha/` and builds the Studio prefix with it. The host
// may carry a different Wine entirely — a Fedora box has 11.0 Staging against Vinegar's 11.11 —
// and an older Wine opening a prefix a newer one wrote does not just run: it decides the prefix
// needs reconfiguring and forks `wineboot --init`, which is the "The Wine configuration in
// .../prefixes/studio is being updated, please wait..." toast that never clears. Two wineservers
// then hold one prefix, the update wedges, StudioMCP.exe never starts, and the MCP handshake
// times out with nothing on stdio to explain why. So the bundled Wine wins whenever it is there.
const VINEGAR_DATA = join(homedir(), ".var/app/org.vinegarhq.Vinegar/data/vinegar");
const BUNDLED_WINE = join(VINEGAR_DATA, "kombucha/bin/wine");

function wineCommand() {
  try {
    accessSync(BUNDLED_WINE, constants.X_OK);
    return BUNDLED_WINE;
  } catch {
    // No bundled Wine — a non-Vinegar install, or a layout that moved. PATH is the only guess
    // left, and it is the right one when the host Wine is also the one that built the prefix.
    return "wine";
  }
}

const roots = process.platform === "win32"
  ? [
      join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "Roblox", "Versions"),
      "C:\\Program Files (x86)\\Roblox\\Versions",
    ]
  : [join(VINEGAR_DATA, "versions")];

const found = roots.flatMap((root) => {
  let names;
  try {
    names = readdirSync(root);
  } catch {
    return [];
  }
  return names.flatMap((name) => {
    const exe = join(root, name, EXE);
    try {
      return [{ exe, mtime: statSync(exe).mtimeMs }];
    } catch {
      return [];
    }
  });
}).sort((a, b) => b.mtime - a.mtime);

if (!found.length) {
  console.error(`${EXE} not found under:\n  ${roots.join("\n  ")}`);
  process.exit(1);
}

const exe = found[0].exe;
const [cmd, args, env] = process.platform === "win32"
  ? [exe, [], process.env]
  : [wineCommand(), [exe], {
      ...process.env,
      WINEPREFIX: join(VINEGAR_DATA, "prefixes/studio"),
      WINEDEBUG: process.env.WINEDEBUG ?? "-all",
      // This is a stdio MCP server: anything Wine prints on stdout is read as a protocol frame
      // and corrupts the session. Keep its chatter on stderr, where the client logs it.
      WINEDLLOVERRIDES: process.env.WINEDLLOVERRIDES ?? "mscoree,mshtml=",
    }];

const child = spawn(cmd, args, { stdio: "inherit", env });
child.on("error", (e) => {
  console.error(`failed to launch ${cmd}: ${e.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => process.exit(signal ? 1 : (code ?? 0)));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => child.kill(sig));
