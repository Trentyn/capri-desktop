# Watches the top-level windows so Capri can sit on them.
# Prints one JSON line whenever something changes: the foreground window and the visible
# windows in z-order (front first), as physical-pixel frame bounds. No titles, no contents.
#
#   powershell -File windows.ps1 <capri hwnd> <capri pid>

param([long]$Self = 0, [int]$ParentPid = 0)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CapriWindows {
  delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
  [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
  [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);

  // Sleep(8) really sleeps ~16ms on the default 15.6ms timer: a 1ms timer, only while a window moves
  static bool fine;
  public static void FineTimer(bool on) {
    if (on == fine) return;
    fine = on;
    if (on) timeBeginPeriod(1); else timeEndPeriod(1);
  }

  // Windows tells us the moment a window moves, shows, hides or comes to the front, so the first
  // frame of a drag isn't up to a whole idle poll late (she'd jump to catch up with the window).
  delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

  [StructLayout(LayoutKind.Sequential)]
  struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
  [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
  [DllImport("user32.dll")] static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool all, uint ms, uint wake);

  const uint WINEVENT_SKIPOWNPROCESS = 2;
  const uint QS_ALLINPUT = 0x04FF;

  static WinEventProc onEvent; // kept alive: Windows calls it for as long as the hooks are on
  static bool poked;

  public static void Watch() {
    onEvent = (hook, evt, hwnd, idObject, idChild, thread, time) => {
      if (idObject == 0 && idChild == 0) poked = true; // the window itself, not its caret or cursor
    };
    SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, onEvent, 0, 0, WINEVENT_SKIPOWNPROCESS); // foreground
    SetWinEventHook(0x000A, 0x000B, IntPtr.Zero, onEvent, 0, 0, WINEVENT_SKIPOWNPROCESS); // drag starts, ends
    SetWinEventHook(0x0016, 0x0017, IntPtr.Zero, onEvent, 0, 0, WINEVENT_SKIPOWNPROCESS); // minimized, restored
    SetWinEventHook(0x8001, 0x8003, IntPtr.Zero, onEvent, 0, 0, WINEVENT_SKIPOWNPROCESS); // destroyed, shown, hidden
    SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, onEvent, 0, 0, WINEVENT_SKIPOWNPROCESS); // moved, resized
  }

  // Waits up to `ms`, or less when a window event comes in (but at least `min`). The hooks'
  // events are delivered through this thread's message queue, so it pumps it meanwhile.
  public static void Wait(int ms, int min) {
    var clock = System.Diagnostics.Stopwatch.StartNew();
    while (true) {
      MSG msg;
      while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) {
        TranslateMessage(ref msg);
        DispatchMessage(ref msg);
      }
      int elapsed = (int)clock.ElapsedMilliseconds;
      if (poked && elapsed >= min) { poked = false; return; }
      int left = (poked ? min : ms) - elapsed;
      if (left <= 0) return;
      MsgWaitForMultipleObjects(0, null, false, (uint)left, QS_ALLINPUT);
    }
  }

  const int GWL_EXSTYLE = -20;
  const int WS_EX_TOOLWINDOW = 0x80;
  const int WS_EX_NOACTIVATE = 0x08000000;
  const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
  const int DWMWA_CLOAKED = 14;

  public static void Init() {
    SetProcessDpiAwarenessContext(new IntPtr(-4)); // per-monitor v2: real pixels everywhere
  }

  public static string Snapshot(long self) {
    var sb = new StringBuilder();
    sb.Append("{\"fg\":").Append(GetForegroundWindow().ToInt64()).Append(",\"wins\":[");
    int count = 0;
    EnumWindows((h, l) => {
      if (count >= 40) return false;
      if (h.ToInt64() == self || !IsWindowVisible(h) || IsIconic(h)) return true;
      int ex = GetWindowLong(h, GWL_EXSTYLE);
      if ((ex & WS_EX_TOOLWINDOW) != 0 || (ex & WS_EX_NOACTIVATE) != 0) return true;
      int cloaked;
      if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return true;
      var cls = new StringBuilder(64);
      GetClassName(h, cls, 64);
      string c = cls.ToString();
      if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return true;
      RECT r;
      if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, 16) != 0) return true;
      if (r.Right - r.Left < 200 || r.Bottom - r.Top < 120) return true;
      if (count > 0) sb.Append(',');
      count++;
      sb.Append("{\"id\":").Append(h.ToInt64())
        .Append(",\"x\":").Append(r.Left).Append(",\"y\":").Append(r.Top)
        .Append(",\"w\":").Append(r.Right - r.Left).Append(",\"h\":").Append(r.Bottom - r.Top)
        .Append(",\"max\":").Append(IsZoomed(h) ? "true" : "false").Append('}');
      return true;
    }, IntPtr.Zero);
    sb.Append("]}");
    return sb.ToString();
  }
}
"@

[CapriWindows]::Init()
[CapriWindows]::Watch()
$last = ''
$clock = [Diagnostics.Stopwatch]::StartNew()
$fastUntil = 0
$parentCheck = 0
while ($true) {
  $snap = [CapriWindows]::Snapshot($Self)
  if ($snap -ne $last) {
    [Console]::Out.WriteLine($snap)
    [Console]::Out.Flush()
    $last = $snap
    # something moves (a window dragged, resized...): look every frame for a moment, so she rides it smoothly
    $fastUntil = $clock.ElapsedMilliseconds + 500
  }
  $now = $clock.ElapsedMilliseconds
  # stop with Capri, even if she crashed without telling us
  if ($ParentPid -and $now -ge $parentCheck) {
    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
    $parentCheck = $now + 3000
  }
  $fast = $now -lt $fastUntil
  [CapriWindows]::FineTimer($fast)
  # a window event wakes it right away; the poll is the safety net for what the hooks miss
  if ($fast) { [CapriWindows]::Wait(8, 8) } else { [CapriWindows]::Wait(150, 0) }
}
[CapriWindows]::FineTimer($false)
