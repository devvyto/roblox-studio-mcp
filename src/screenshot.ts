// Captures the Roblox Studio window on Windows using PowerShell + Win32 PrintWindow, downscaled PNG.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile, readFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
const run = promisify(execFile);

export const PS_SCRIPT = String.raw`
param([int]$MaxWidth = 1280, [string]$Out, [string]$Mode = "window")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[W32]::SetProcessDPIAware() | Out-Null
if ($Mode -eq "screen") {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $g.Dispose()
} else {
  $p = Get-Process -Name RobloxStudioBeta -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "Roblox Studio window not found (process RobloxStudioBeta)" }
  $h = $p.MainWindowHandle
  if ([W32]::IsIconic($h)) { [W32]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 400 }
  $r = New-Object W32+RECT; [W32]::GetWindowRect($h, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $hh
  $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
  $ok = [W32]::PrintWindow($h, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
  if (-not $ok) { $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size); $g.Dispose() }
}
if ($bmp.Width -gt $MaxWidth) {
  $nh = [int]($bmp.Height * $MaxWidth / $bmp.Width)
  $s = New-Object System.Drawing.Bitmap $MaxWidth, $nh
  $g = [System.Drawing.Graphics]::FromImage($s); $g.InterpolationMode = "HighQualityBicubic"; $g.DrawImage($bmp, 0, 0, $MaxWidth, $nh); $g.Dispose(); $bmp.Dispose(); $bmp = $s
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Write-Output "OK"
`;

export async function captureStudio(maxWidth = 1280, mode: "window" | "screen" = "window"): Promise<string> {
  if (process.platform !== "win32") throw new Error("screenshot is only supported when the server runs on Windows");
  const stamp = `${process.pid}-${Date.now()}`;
  const ps1 = path.join(tmpdir(), `rsmcp-shot-${stamp}.ps1`);
  const png = path.join(tmpdir(), `rsmcp-shot-${stamp}.png`);
  await writeFile(ps1, PS_SCRIPT, "utf8");
  try {
    await run("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1, "-MaxWidth", String(maxWidth), "-Out", png, "-Mode", mode], { timeout: 20000, windowsHide: true });
    return (await readFile(png)).toString("base64");
  } finally { await unlink(ps1).catch(() => {}); await unlink(png).catch(() => {}); }
}
