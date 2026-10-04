# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Gezi46
#
## 桌宠改窗口样式 / 托盘图标用的 **PowerShell 脚本源码**（运行时写到 user://pet_shell_window.ps1）。
##
## 从 pet_shell.gd 搬出来（作业单 B5.1 复核的结论）：那边 1123 行里 **577 行是这个脚本**，
## 而它是**数据，不是逻辑** —— 不搬走的话：一是怎么切逻辑都进不了 500 行，
## 二是读 pet_shell 得先跳过五百多行 PowerShell 才看得到真正在做事的代码。
##
## ⚠️ 这个脚本里**不能出现中文** —— PowerShell 5.1 在没有 BOM 的 .ps1 上按 ANSI 解码，
## 中文会变乱码（脚本的输出也因此只用 ASCII）。改它的时候别顺手加中文注释。
##
## 用它的只有 pet_shell.gd：`_ensure_ps1()` 把 SOURCE 写进 PS1_FILE（内容没变就不重写），
## 那个 .ps1 是给外面那个 watcher 后台进程读的 —— 见 pet_shell.gd 的「命令通道 + 看门狗」
extends RefCounted

const SOURCE := """# 参数个数要够！watch 模式用到 $Arg5（意愿文件路径）。
# 之前只声明到 $Arg2，$Arg4/$Arg5 全是 $null —— 而读取那一步包在 try/catch 里，
# 异常被默默吞掉，表现成"托盘图标是系统默认图标"和"菜单开着收不到通知"，
# 一点都不像参数没传进来。加参数时记得同步这里。
param([string]$Mode, [string]$Arg, [string]$Arg2, [string]$Arg3, [string]$Arg4, [string]$Arg5, [string]$Arg6)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class PetWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after,
    int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern int GetClassName(IntPtr h, StringBuilder s, int max);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  delegate bool EnumProc(IntPtr h, IntPtr p);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
  }

  const int GWL_EXSTYLE   = -20;
  const int WS_EX_TOOLWIN = 0x80;      // not in taskbar, not in Alt+Tab
  const int WS_EX_APPWIN  = 0x40000;   // force a taskbar button
  const int WS_EX_TOPMOST = 0x8;
  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  static readonly IntPtr HWND_TOP = IntPtr.Zero;
  const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004,
             SWP_NOACTIVATE = 0x0010, SWP_FRAMECHANGED = 0x0020;
  const uint MONITOR_NEAREST = 2;      // MONITOR_DEFAULTTONEAREST

  // The window we care about: visible + has a title (the pet's own window).
  static IntPtr Find(uint want) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want && IsWindowVisible(h) && GetWindowTextLength(h) > 0) {
        found = h;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Dump(uint want) {
    StringBuilder sb = new StringBuilder();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        sb.Append(String.Format(
          "hwnd=0x{0:X} visible={1} titled={2} exstyle=0x{3:X} TOOLWINDOW={4} APPWINDOW={5} TOPMOST={6}\\n",
          (long)h, IsWindowVisible(h), GetWindowTextLength(h) > 0, ex,
          (ex & WS_EX_TOOLWIN) != 0, (ex & WS_EX_APPWIN) != 0,
          (ex & WS_EX_TOPMOST) != 0));
      }
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }

  // One iteration of the "is anything fullscreen right now" check.
  // Returns "1" = yes, "0" = no, "DEAD" = the pet's own window is gone
  // (the caller should stop looping).
  //
  // Looks at *every* top-level window, not just the foreground one. The first
  // version only checked GetForegroundWindow and turned out flaky: whether a
  // window really gets the foreground is up to the shell (Windows happily
  // refuses a background app's SetForegroundWindow), so a genuinely fullscreen
  // video could be missed. Scanning all of them also catches the
  // "fullscreen on the other monitor" case.
  //
  // The shell's own windows (desktop Progman/WorkerW, the taskbar) always fill
  // the screen and must be excluded, or the answer would always be "yes".
  // What the last Tick() actually changed, for the watcher's log file.
  // "" = nothing changed. Everything that touches the window goes through here so
  // a "flickering" report can be traced to a device instead of a guess.
  public static string LastFix = "";

  public static string Tick(uint want, bool wantTool, bool wantTop, bool popupOpen) {
    LastFix = "";
    IntPtr me = Find(want);
    if (me == IntPtr.Zero) return "DEAD";
    // Keep the right window on top - natively, on purpose.
    //
    // Doing this from Godot (window_set_flag ALWAYS_ON_TOP off/on) works but costs
    // us the taskbar bit every time: Godot recomputes the window styles whenever
    // it touches the window, and that is what kept putting the pet back into the
    // taskbar. SWP_NOACTIVATE also means this can never steal keyboard focus.
    //
    // While the pet's own menu is open, drop the pet out of the topmost group
    // instead of racing it against the menu.
    //
    // Both windows are topmost, so which one wins depends on who was raised last -
    // and the pet gets raised again by her own movement (every window_set_position
    // on a topmost window puts it back in front). Measured: the menu lost that race
    // in all 16 samples. Taking the pet out of the topmost group makes it a hard
    // guarantee instead: the menu (topmost) is above the pet (not topmost), no
    // matter what order things happen in. Restored on the next tick once the menu
    // is closed, since the wish file goes back to "keep me on top".
    if (popupOpen) {
      // Only when we are actually still topmost - the pet's window is per-pixel
      // transparent, so every needless re-composite shows up as a blink
      if ((GetWindowLong(me, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) {
        SetWindowPos(me, HWND_NOTOPMOST, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        LastFix += "notopmost ";
      }
    } else if (wantTop) {
      string blocker = Blocker(me);
      if (blocker != "") {
        // HWND_TOPMOST on a window that is *already* topmost does not move it within
        // the topmost group (measured: the pet never got back above the window that
        // covered it). HWND_TOP is what actually brings it to the front; HWND_TOPMOST
        // is only needed when we are not topmost at all yet.
        bool isTop = (GetWindowLong(me, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
        SetWindowPos(me, isTop ? HWND_TOP : HWND_TOPMOST, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        LastFix += "raise(above=" + blocker + ") ";
      }
    }
    // Keep the "not in the taskbar" bit alive (wantTool comes from the pet's own
    // preference file). Continuous, not a one-shot at startup: measured on this
    // machine it was set at t=2s and gone again by t=4s.
    int ex = GetWindowLong(me, GWL_EXSTYLE);
    bool has = (ex & WS_EX_TOOLWIN) != 0;
    if (wantTool != has) {
      int fixedEx = wantTool ? (ex | WS_EX_TOOLWIN) & ~WS_EX_APPWIN
                             : (ex & ~WS_EX_TOOLWIN) | WS_EX_APPWIN;
      SetWindowLong(me, GWL_EXSTYLE, fixedEx);
      // Hide/show is the folk remedy for making the shell re-evaluate the taskbar
      // button, but it makes the pet blink. SWP_FRAMECHANGED is the documented way
      // to apply a style change without touching visibility.
      SetWindowPos(me, IntPtr.Zero, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
      LastFix += "toolwindow=" + (wantTool ? "1 " : "0 ");
    }
    bool found = false;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (h == me || !IsWindowVisible(h) || IsIconic(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want) return true;              // the pet's own helper windows (menus)
      StringBuilder cn = new StringBuilder(64);
      GetClassName(h, cn, cn.Capacity);
      string cls = cn.ToString();
      if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
          cls == "Shell_SecondaryTrayWnd" || cls == "Windows.UI.Core.CoreWindow") return true;
      // Two filters that matter in practice (both measured on this machine):
      //   - cloaked (DWM): UWP/shell windows report "visible" while being hidden away
      //     (Windows.UI.Core.CoreWindow came back cloaked=2)
      //   - WS_EX_TOOLWINDOW: helper/offscreen widgets are not what a user means by
      //     fullscreen (the IDE's CEF-OSC-WIDGET was one, as is the desktop Progman)
      // Without these the answer was "fullscreen" almost permanently.
      int cloaked = 0;
      try { DwmGetWindowAttribute(h, 14, out cloaked, 4); } catch { cloaked = 0; }
      if (cloaked != 0) return true;
      if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWIN) != 0) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      MONITORINFO mi = new MONITORINFO();
      mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (!GetMonitorInfo(MonitorFromWindow(h, MONITOR_NEAREST), ref mi)) return true;
      RECT m = mi.rcMonitor;
      // Compared against the *monitor* rect, so a merely maximised window does
      // not count (it leaves the taskbar showing). 2px tolerance.
      if (r.Left <= m.Left + 2 && r.Top <= m.Top + 2 &&
          r.Right >= m.Right - 2 && r.Bottom >= m.Bottom - 2) {
        found = true;
        return false;                            // one is enough
      }
      return true;
    }, IntPtr.Zero);
    return found ? "1" : "0";
  }

  // z-order index of two processes' windows: "0 3" = first is on top of second.
  // EnumWindows walks top-to-bottom, so a smaller index is higher up.
  //
  // Not using "is anything above me" as the test: the IME (input method) window
  // sits above everything on this machine, so that question is always "yes" and
  // says nothing about the two windows we actually care about.
  public static string ZOrder(uint a, uint b) {
    IntPtr wa = FindAny(a), wb = FindAny(b);
    int ia = -1, ib = -1, i = 0;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      if (h == wa) ia = i;
      if (h == wb) ib = i;
      i++;
      return true;
    }, IntPtr.Zero);
    return ia + " " + ib;
  }

  // z-order index of one window of the process, picked by its WS_EX_TOOLWINDOW bit.
  // Top-level enumeration goes top-to-bottom, so a smaller index is higher up.
  // Compares the pet's own window (we set TOOLWINDOW on it so it stays out of the
  // taskbar) against its popup menu (a separate OS window without that bit).
  //
  // Not discriminating by "has a title": Godot gives PopupMenu windows a title too,
  // so that test cannot tell them apart (measured).
  public static string ZIndex(uint want, bool wantToolWindow) {
    int idx = -1, i = 0;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool tool = (GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWIN) != 0;
      if (pid == want && tool == wantToolWindow) {
        idx = i;
        return false;
      }
      i++;
      return true;
    }, IntPtr.Zero);
    return idx.ToString();
  }

  // Both z-order indices in one enumeration: "petIndex menuIndex".
  // One call instead of two - each spawn of PowerShell plus Add-Type costs about a
  // second, which made the probe sample far too few times to be useful.
  public static string ZBoth(uint want) {
    int pi = -1, mi = -1, i = 0;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want) {
        bool tool = (GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWIN) != 0;
        if (tool && pi < 0) pi = i;
        else if (!tool && mi < 0) mi = i;
      }
      i++;
      return true;
    }, IntPtr.Zero);
    return pi + " " + mi;
  }

  // Is a "real" window in front of us?
  //
  // This exists because re-raising unconditionally on every tick made the pet
  // visibly blink: her window is per-pixel transparent, so every needless
  // re-composite is visible, and it was by far the most frequent thing the watcher
  // did (51 raises in 45 seconds, measured).
  //
  // Walks the z-order from our window upwards. Anything above a topmost window is
  // itself topmost, so "something real is in front" is exactly the case where
  // raising is worth doing. System windows that permanently sit on top (the IME,
  // tooltips, the shell) are skipped by class name - otherwise the answer would
  // always be "yes" and we would be back to raising every tick.
  static string Blocker(IntPtr me) {
    IntPtr h = GetWindow(me, 3);          // GW_HWNDPREV = the window right above us
    int guard = 0;
    while (h != IntPtr.Zero && guard++ < 64) {
      if (IsWindowVisible(h) && !IsIconic(h)) {
        StringBuilder cn = new StringBuilder(128);
        GetClassName(h, cn, cn.Capacity);
        string cls = cn.ToString();
        if (cls == "IME" || cls == "MSCTFIME UI" || cls == "TooltipWindow" ||
            cls == "Windows.UI.Core.CoreWindow" || cls == "Shell_TrayWnd" ||
            cls == "Shell_SecondaryTrayWnd" || cls == "Progman" || cls == "WorkerW") {
          h = GetWindow(h, 3);
          continue;
        }
        // WS_EX_TOOLWINDOW windows are offscreen helpers, not something a user sees
        // as covering the pet (measured: the IDE's CEF-OSC-WIDGET made her raise
        // herself once for nothing).
        if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWIN) != 0) {
          h = GetWindow(h, 3);
          continue;
        }
        // Windows' own helper windows (measured: ThumbnailDeviceHelperWnd sat above
        // everything and looked like a real app covering the pet, so the pet got
        // re-raised every tick = blinked) and anything without a title is not
        // something a user would think of as "a window covering her".
        if (cls.Contains("Thumbnail") || cls.Contains("Helper") ||
            GetWindowTextLength(h) == 0) {
          h = GetWindow(h, 3);
          continue;
        }
        return cls;                      // report the class so the log says who it is
      }
      h = GetWindow(h, 3);
    }
    return "";
  }

  // The pet's popup menu: a visible top-level window of the same process that does
  // NOT carry the TOOLWINDOW bit (we only set that bit on the pet's own window).
  static IntPtr FindPopup(uint want) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != want) return true;
      if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWIN) != 0) return true;
      found = h;
      return false;
    }, IntPtr.Zero);
    return found;
  }

  // Any visible window of the process (no title required - the test window has none)
  static IntPtr FindAny(uint want) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want && IsWindowVisible(h) && !IsIconic(h)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Hide(uint want, bool on) {
    IntPtr h = Find(want);
    if (h == IntPtr.Zero) return "ERR no visible window for pid " + want;
    int before = GetWindowLong(h, GWL_EXSTYLE);
    int ex = on ? (before | WS_EX_TOOLWIN) & ~WS_EX_APPWIN
                : (before & ~WS_EX_TOOLWIN) | WS_EX_APPWIN;
    if (ex != before) {
      SetWindowLong(h, GWL_EXSTYLE, ex);
      // The shell only re-evaluates a window's taskbar button on show/hide,
      // so toggle visibility once. SW_HIDE=0, SW_SHOW=5.
      ShowWindow(h, 0);
      ShowWindow(h, 5);
    }
    int now = GetWindowLong(h, GWL_EXSTYLE);
    return String.Format("hwnd=0x{0:X} exstyle 0x{1:X} -> 0x{2:X} TOOLWINDOW={3}",
      (long)h, before, now, (now & WS_EX_TOOLWIN) != 0);
  }
}
'@

if ($Mode -eq 'styles') {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  [Console]::Out.Write([PetWin]::Dump([uint32]$Arg))
}
elseif ($Mode -eq 'hide') {
  # Retry until the pet's window shows up. This is now called as early as
  # _enter_tree, to keep the window off the taskbar for as short a time as
  # possible - and at that moment the window may not exist yet. Without the
  # retry the whole thing would silently do nothing (measured: it returns
  # "ERR no visible window for pid ...") and the pet keeps its taskbar button.
  $want = [uint32]$Arg
  $on = ($Arg2 -eq '1')
  $res = ''
  for ($i = 0; $i -lt 25; $i++) {
    $res = [PetWin]::Hide($want, $on)
    if (-not $res.StartsWith('ERR')) { break }
    Start-Sleep -Milliseconds 200
  }
  [Console]::Out.Write($res)
}
elseif ($Mode -eq 'run') {
  # Name and value travel as base64: they contain non-ASCII (the value name is
  # Chinese) and the value itself has embedded quotes + spaces, which the Windows
  # command line cannot carry through unharmed.
  $name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arg))
  $k = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  $v = $null
  try { $v = (Get-ItemProperty -Path $k -Name $name -ErrorAction Stop).$name } catch { $v = $null }
  # Answer in base64 as well. Writing the text as-is comes back mojibake'd:
  # PowerShell encodes stdout with one codepage, Godot decodes it with another
  # (measured: the Chinese value name came back as garbage). ASCII never has that
  # problem, whichever codepage is in play.
  if ($null -eq $v) { [Console]::Out.Write('__MISSING__') }
  else { [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v))) }
}
elseif ($Mode -eq 'setrun') {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arg))
  $val  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arg2))
  $k = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  try {
    Set-ItemProperty -Path $k -Name $name -Value $val -ErrorAction Stop
    [Console]::Out.Write('OK')
  } catch {
    [Console]::Out.Write('ERR ' + $_.Exception.Message)
  }
}
elseif ($Mode -eq 'watch') {
  # $Arg = pet pid, $Arg2 = state file, $Arg3 = command file, $Arg4 = icon png (may be ''),
  # $Arg5 = file holding the pet's current "keep me out of the taskbar" wish ('1'/'0')
  #
  # Runs as a WinForms app rather than a plain while loop: hosting the tray icon
  # needs a message loop (Application::Run), so the periodic work moved into a
  # WinForms timer. Everything shared between the handlers lives in $script: -
  # event handlers run in the same session, so that is what they can see.
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # 参数不全就直接把问题写进状态文件再退出，别硬撑着跑 ——
  # 之前参数没声明够时，异常被下面的 try/catch 吞掉，表现是"功能静默失效"，极难查。
  if ($Arg3 -eq '' -or $Arg5 -eq '') {
    try { [IO.File]::WriteAllText($Arg2, 'ARGS-MISSING') } catch { }
    exit 1
  }
  $script:petPid = [uint32]$Arg
  $script:stateFile = $Arg2
  $script:cmdFile = $Arg3
  $script:wantFile = $Arg5
  $script:last = ''
  $script:n = 0
  $script:miss = 0
  # GPU utilization via the "GPU Engine" performance counters. Only engtype_3D
  # counts (video decode / copy engines are not "the game"). The first
  # NextValue() returns 0 (no prior sample), so prime it once here; from then on
  # each tick reads the last ~800ms interval.
  $script:gpuCounters = @()
  $script:gpuFile = $Arg6
  try {
    $gcat = New-Object Diagnostics.PerformanceCounterCategory('GPU Engine')
    $gnames = @($gcat.GetInstanceNames() | Where-Object { $_ -match 'engtype_3D' })
    foreach ($n in $gnames) {
      $pc = New-Object Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $n)
      [void]$pc.NextValue()
      $script:gpuCounters += $pc
    }
  } catch { $script:gpuCounters = @() }
  $script:lastGpu = -2

  # ---------------------------------------------------------------- tray icon
  # This is the icon that shows up in the "hidden icons" overflow. Windows puts a
  # newly added icon there by default unless the user pins it out.
  $ni = New-Object Windows.Forms.NotifyIcon
  $ni.Icon = [Drawing.SystemIcons]::Application
  if ($Arg4 -ne '' -and (Test-Path $Arg4)) {
    try {
      $bmp = New-Object Drawing.Bitmap($Arg4)
      $ni.Icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch { }
  }
  # Menu labels are Chinese, but this file has to stay ASCII-only: PowerShell 5.1
  # reads a BOM-less .ps1 as ANSI, so non-ASCII here turns into mojibake - and
  # inside a string literal that is a hard parse error (the whole script dies on
  # start, which is exactly what happened the first time round). base64 + decode.
  $lblTip  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('UGV0RGVla++8iOWPs+mUrueci+iPnOWNle+8iQ=='))
  $lblShow = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5pi+56S6IC8g6ZqQ6JeP'))
  $lblQuit = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('6YCA5Ye6IFBldERlZWs='))
  $ni.Text = $lblTip
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $miShow = $menu.Items.Add($lblShow)
  $miShow.Add_Click({ try { [IO.File]::WriteAllText($script:cmdFile, 'toggle') } catch { } })
  $lblGhost = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('6YCP5piO5qih5byP'))
  $miGhost = $menu.Items.Add($lblGhost)
  $miGhost.Add_Click({ try { [IO.File]::WriteAllText($script:cmdFile, 'ghost') } catch { } })
  $miQuit = $menu.Items.Add($lblQuit)
  $miQuit.Add_Click({ try { [IO.File]::WriteAllText($script:cmdFile, 'quit') } catch { } })
  $ni.ContextMenuStrip = $menu
  # Left click on the icon toggles too - that is what tray icons usually do
  $ni.Add_MouseClick({ if ($args[1].Button -eq [Windows.Forms.MouseButtons]::Left) { try { [IO.File]::WriteAllText($script:cmdFile, 'toggle') } catch { } } })
  $ni.Visible = $true

  # ---------------------------------------------------------------- timer
  # 每次真改了窗口属性就记一行，放在状态文件旁边。
  # 只记"改了"的情况（正常情况下应该是空的），用来定位"她一闪一闪"到底是谁在动窗口。
  $script:logFile = $script:stateFile + '.log'
  try { [IO.File]::WriteAllText($script:logFile, '') } catch { }
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 800
  $timer.Add_Tick({
    # 每次读一遍主人的意愿（她改了设置我们就跟着变，不用重启这个进程）。
    # 文件里三个数：1 = 不进任务栏，2 = 保持置顶，3 = 菜单正开着（这时要顶菜单而不是顶她）
    $wantTool = $true
    $wantTop = $true
    $popup = $false
    try {
      # 用空格分割，别用带反斜杠的正则字符类（空白转义那个写法）——
      # 在 GDScript 的字符串里反斜杠会被再转义一层，落盘之后变成两个，
      # PowerShell 就把它当成"字面反斜杠后面跟字母 s"（实测：三段变一段），
      # 于是三个意愿全读成 false，自愈和托盘通知一起静默失效。
      # 写文件那头用的是单个空格，这里按空格切就够了，不需要任何反斜杠。
      $w = @(([IO.File]::ReadAllText($script:wantFile)).Trim() -split ' ' | Where-Object { $_ -ne '' })
      if ($w.Length -ge 1) { $wantTool = ($w[0] -eq '1') }
      if ($w.Length -ge 2) { $wantTop = ($w[1] -eq '1') }
      if ($w.Length -ge 3) { $popup = ($w[2] -eq '1') }
    } catch { }
    $s = [PetWin]::Tick($script:petPid, $wantTool, $wantTop, $popup)
    if ($s -eq 'DEAD') {
      # 容忍偶尔一次找不到窗口（窗口重建、过渡态都可能瞬时如此）。
      # 之前是一发现就退出，于是"进程悄悄死了"——自愈和托盘图标一起失效，
      # 外面还以为是功能坏了。连续 ~8 秒都找不到才真的收摊。
      $script:miss++
      if ($script:miss -lt 10) { return }
      $ni.Visible = $false
      [Windows.Forms.Application]::Exit()
      return
    }
    $script:miss = 0
    if ([PetWin]::LastFix -ne '') {
      try {
        $lf = Get-Item $script:logFile -ErrorAction SilentlyContinue
        if ($null -eq $lf -or $lf.Length -lt 200000) {
          [IO.File]::AppendAllText($script:logFile,
            ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + [PetWin]::LastFix + [Environment]::NewLine))
        }
      } catch { }
    }
    # Write on change, plus a heartbeat every ~10s so the other side can tell
    # "nothing changed" apart from "the watcher died"
    if ($s -ne $script:last -or ($script:n % 12) -eq 0) {
      try { [IO.File]::WriteAllText($script:stateFile, $s) } catch { }
      $script:last = $s
    }
    # GPU usage -> its own file (only when a path was passed in). Write on change,
    # plus every ~5 ticks so a steady value still refreshes the other side's staleness.
    if ($script:gpuFile -ne '') {
      $gpu = -1
      foreach ($pc in $script:gpuCounters) {
        try { $v = $pc.NextValue(); if ($v -gt $gpu) { $gpu = $v } } catch { }
      }
      if ([int]$gpu -ne $script:lastGpu -or ($script:n % 5) -eq 0) {
        try { [IO.File]::WriteAllText($script:gpuFile, [string][int]$gpu) } catch { }
        $script:lastGpu = [int]$gpu
      }
    }
    $script:n++
  })
  $timer.Start()

  [Windows.Forms.Application]::Run()
  $ni.Visible = $false
  $ni.Dispose()
  $timer.Dispose()
}
elseif ($Mode -eq 'zboth') {
  [Console]::Out.Write([PetWin]::ZBoth([uint32]$Arg))
}
elseif ($Mode -eq 'zidx') {
  # $Arg = pid, $Arg2 = 'toolwindow' (the pet's own window) / 'notoolwindow' (its menu)
  [Console]::Out.Write([PetWin]::ZIndex([uint32]$Arg, $Arg2 -eq 'toolwindow'))
}
elseif ($Mode -eq 'zorder') {
  $p = $Arg.Split(' ')
  [Console]::Out.Write([PetWin]::ZOrder([uint32]$p[0], [uint32]$p[1]))
}
elseif ($Mode -eq 'topwin') {
  # A small always-on-top window that closes itself after $Arg seconds.
  # probe_quiet uses it to check we climb back to the top after being covered.
  Add-Type -AssemblyName System.Windows.Forms
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'
  $f.StartPosition = 'Manual'
  $f.Bounds = New-Object Drawing.Rectangle(300, 300, 160, 120)
  $f.TopMost = $true
  $f.BackColor = 'DarkSlateBlue'
  # Give it a title: the pet only treats a window in front of it as "really covering
  # me" when that window has one (helper windows never do, and counting them made
  # the pet re-raise itself every tick = blink).
  $f.Text = 'pet probe topwin'
  $f.Show()
  $f.Activate()
  $end = (Get-Date).AddSeconds([int]$Arg)
  while ((Get-Date) -lt $end) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
  }
  $f.Close()
}
elseif ($Mode -eq 'fakefullscreen') {
  # A REAL fullscreen window that closes itself after $Arg seconds.
  # Only used by tools/probe_quiet.gd, to prove the watch detection is not
  # something that just always answers "0".
  Add-Type -AssemblyName System.Windows.Forms
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'
  $f.StartPosition = 'Manual'
  $f.Bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  $f.TopMost = $true
  $f.BackColor = 'Black'
  $f.Show()
  $f.Activate()
  # Poll with DoEvents instead of Start-Sleep: a sleeping process stops pumping
  # messages and the window stops behaving like a live window
  $end = (Get-Date).AddSeconds([int]$Arg)
  while ((Get-Date) -lt $end) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
  }
  $f.Close()
}
elseif ($Mode -eq 'delrun') {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arg))
  $k = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  # Not finding the value is not a failure: the result is the same ("not there")
  try { Remove-ItemProperty -Path $k -Name $name -ErrorAction Stop } catch { }
  [Console]::Out.Write('OK')
}
"""
