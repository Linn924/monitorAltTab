#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
#MaxThreadsPerHotkey 1

; Free, local-only monitor Alt+Tab. AutoHotkey v2, Windows 10/11.
; No administrator rights required for ordinary applications.
InstallKeybdHook()
SetWinDelay(-1)
try DllCall("User32\SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

global S := {active: false, items: [], index: 0, gui: 0, thumbs: [], page: 0,
    monitor: 0, capacity: 8, cols: 4, scale: 1, work: []}
A_TrayMenu.Add()
A_TrayMenu.Add("Exit Monitor Alt+Tab", (*) => ExitApp())
OnExit((*) => ClosePicker())
OnMessage(0x202, PickerClick) ; WM_LBUTTONUP, including child controls
OnMessage(0x21, PickerMouseActivate)

!Tab::Step(1)
!+Tab::Step(-1)

#HotIf S.active
*Esc::ClosePicker()
#HotIf

Step(direction) {
    global S
    Critical("On")
    try {
        if !S.active {
            S.monitor := MouseMonitor()
            S.items := CollectWindows(S.monitor)
            if !S.items.Length
                return
            S.index := 0
            foreground := WinExist("A")
            for i, item in S.items {
                if item.hwnd = foreground {
                    S.index := i
                    break
                }
            }
            S.active := true
            S.work := MonitorWork(S.monitor)
            dpi := A_ScreenDPI
            dx := 0, dy := 0
            try {
                if DllCall("Shcore\GetDpiForMonitor", "ptr", S.monitor,
                    "int", 0, "uint*", &dx, "uint*", &dy, "int") = 0
                    dpi := dx
            }
            S.scale := Max(0.65, Min(dpi / 96,
                (S.work[3] - S.work[1]) / 340,
                (S.work[4] - S.work[2]) / 300))
            S.cols := Max(1, Min(4, Floor((S.work[3] - S.work[1] - ScalePx(48)) / ScalePx(258))))
            rows := Max(1, Min(2, Floor((S.work[4] - S.work[2] - ScalePx(120)) / ScalePx(192))))
            S.capacity := S.cols * rows
        }
        S.index += direction
        if S.index > S.items.Length
            S.index := 1
        if S.index < 1
            S.index := S.items.Length
        DrawPicker()
        SetTimer(CheckAlt, 20)
    } catch as err {
        ClosePicker()
        MsgBox("Monitor Alt+Tab: " err.Message "`n`nLine: " err.Line "`nWhat: " err.What "`nExtra: " err.Extra "`n`n" err.Stack, "Monitor Alt+Tab")
    } finally {
        Critical("Off")
    }
}

CheckAlt() {
    global S
    if S.active && !GetKeyState("LAlt", "P") && !GetKeyState("RAlt", "P")
        Commit()
}

Commit() {
    global S
    if !S.active || S.index < 1 || S.index > S.items.Length
        return
    Critical("On")
    hwnd := S.items[S.index].hwnd
    monitor := S.monitor
    ClosePicker()
    try {
        if WinExist("ahk_id " hwnd) && Eligible(hwnd)
            && DllCall("User32\MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr") = monitor {
            if WinGetMinMax("ahk_id " hwnd) = -1
                WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
        }
    }
    Critical("Off")
}

ClosePicker() {
    global S
    SetTimer(CheckAlt, 0)
    SetTimer(Commit, 0)
    S.active := false
    DestroyView()
    S.items := []
    S.index := 0
}

DestroyView() {
    global S
    for thumb in S.thumbs
        try DllCall("Dwmapi\DwmUnregisterThumbnail", "ptr", thumb)
    S.thumbs := []
    if IsObject(S.gui)
        S.gui.Destroy()
    S.gui := 0
}

ScalePx(n) {
    global S
    return Round(n * S.scale)
}

MouseMonitor() {
    pt := Buffer(8, 0)
    DllCall("User32\GetCursorPos", "ptr", pt)
    return DllCall("User32\MonitorFromPoint", "int64", NumGet(pt, 0, "int64"),
        "uint", 2, "ptr")
}

MonitorWork(hmon) {
    mi := Buffer(40, 0)
    NumPut("uint", 40, mi)
    if !DllCall("User32\GetMonitorInfoW", "ptr", hmon, "ptr", mi)
        throw Error("Unable to read monitor bounds.")
    return [NumGet(mi, 20, "int"), NumGet(mi, 24, "int"),
        NumGet(mi, 28, "int"), NumGet(mi, 32, "int")]
}

CollectWindows(hmon) {
    result := [], seen := Map()
    ; WinGetList enumerates top-level windows in Z order.
    for hwnd in WinGetList() {
        try {
            if !Eligible(hwnd)
                continue
            ex := WinGetExStyle("ahk_id " hwnd)
            ; Keep the last visible owned popup (e.g. a modal dialog),
            ; unless WS_EX_APPWINDOW explicitly requests its own entry.
            if !(ex & 0x40000) && Representative(hwnd) != hwnd
                continue
            if seen.Has(hwnd)
                continue
            if DllCall("User32\MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr") != hmon
                continue
            title := WinGetTitle("ahk_id " hwnd)
            if title = ""
                title := WinGetProcessName("ahk_id " hwnd)
            result.Push({hwnd: hwnd, title: title})
            seen[hwnd] := true
        }
    }
    return result
}

Eligible(hwnd) {
    if !DllCall("User32\IsWindowVisible", "ptr", hwnd)
        return false
    cls := WinGetClass("ahk_id " hwnd)
    if cls ~= "i)^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd|tooltips_class32)$"
        return false
    ex := WinGetExStyle("ahk_id " hwnd)
    if (ex & 0x80) || (ex & 0x08000000) ; TOOLWINDOW / NOACTIVATE
        return false
    if WinGetStyle("ahk_id " hwnd) & 0x40000000 ; CHILD
        return false
    cloaked := 0
    if DllCall("Dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14,
        "uint*", &cloaked, "uint", 4, "int") = 0 && cloaked
        return false
    return true
}

Representative(hwnd) {
    root := DllCall("User32\GetAncestor", "ptr", hwnd, "uint", 3, "ptr")
    ; Hidden/tool owners should not hide an otherwise ordinary app window.
    if !root || !Eligible(root)
        return hwnd
    walk := root
    Loop 32 {
        popup := DllCall("User32\GetLastActivePopup", "ptr", walk, "ptr")
        if !popup || popup = walk
            break
        if Eligible(popup)
            return popup
        walk := popup
    }
    return root
}

DrawPicker() {
    global S
    newPage := Floor((S.index - 1) / S.capacity)
    if IsObject(S.gui) {
        if S.page != newPage {
            S.page := newPage
            FillPage()
        }
        UpdateSelection()
        return
    }
    S.page := newPage
    first := S.page * S.capacity + 1
    count := Min(S.capacity, S.items.Length)
    cols := Min(S.cols, count)
    rows := Ceil(count / cols)
    w := ScalePx(32 + cols * 258 - 12)
    h := ScalePx(86 + rows * 192)
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "Monitor Alt+Tab")
    S.gui := g
    g.BackColor := "202024"
    g.MarginX := 0, g.MarginY := 0
    g.SetFont("s" Max(8, Round(10 * S.scale * 96 / A_ScreenDPI)) " cF4F4F5", "Segoe UI")
    S.heading := g.AddText("x" ScalePx(18) " y" ScalePx(12) " w" (w - ScalePx(36)) " h" ScalePx(24),
        "CURRENT DISPLAY    " S.index " / " S.items.Length)
    S.cards := []
    Loop count {
        i := first + A_Index - 1
        x := ScalePx(16 + Mod(A_Index - 1, cols) * 258)
        y := ScalePx(44 + Floor((A_Index - 1) / cols) * 192)
        cw := ScalePx(246), ch := ScalePx(180)
        color := "44444B"
        borders := []
        ; Four thin controls leave the preview area free for DWM composition.
        for r in [[x,y,cw,ScalePx(3)], [x,y+ch-ScalePx(3),cw,ScalePx(3)],
            [x,y,ScalePx(3),ch], [x+cw-ScalePx(3),y,ScalePx(3),ch]]
            borders.Push(g.AddText("x" r[1] " y" r[2] " w" r[3] " h" r[4] " Background" color))
        pic := g.AddPicture("x" (x+ScalePx(10)) " y" (y+ScalePx(9)) " w" ScalePx(24) " h" ScalePx(24))
        title := g.AddText("x" (x+ScalePx(42)) " y" (y+ScalePx(12)) " w" (cw-ScalePx(52)) " h" ScalePx(22)
            " +0x4000 +0x80")
        fallback := g.AddText("x" (x+ScalePx(10)) " y" (y+ScalePx(90)) " w" (cw-ScalePx(20))
            " h" ScalePx(26) " Center cA0A0AA")
        S.cards.Push({x:x, y:y, w:cw, h:ch, borders:borders, pic:pic, title:title,
            fallback:fallback, itemIndex:0, selected:false})
    }
    S.footer := g.AddText("x" ScalePx(18) " y" (h-ScalePx(38)) " w" (w-ScalePx(36)) " h" ScalePx(36) " cB8B8C2",
        "Tab / Shift+Tab   |   "
        (S.page+1) "/" Ceil(S.items.Length/S.capacity)
        "`nAlt: confirm   |   Esc: cancel")
    x := S.work[1] + Floor((S.work[3]-S.work[1]-w)/2)
    y := S.work[2] + Floor((S.work[4]-S.work[2]-h)/2)
    g.Show("NA x" x " y" y " w" w " h" h)
    ; Windows 11 rounded corner preference; harmless on Windows 10.
    corner := Buffer(4, 0)
    NumPut("uint", 2, corner)
    try DllCall("Dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "uint", 33, "ptr", corner, "uint", 4)
    FillPage()
    UpdateSelection()
}

FillPage() {
    global S
    for thumb in S.thumbs
        try DllCall("Dwmapi\DwmUnregisterThumbnail", "ptr", thumb)
    S.thumbs := []
    for slot, card in S.cards {
        i := S.page*S.capacity + slot
        card.itemIndex := i <= S.items.Length ? i : 0
        card.selected := false
        for border in card.borders {
            border.Visible := !!card.itemIndex
            border.Opt("Background44444B")
            border.Redraw()
        }
        card.pic.Visible := !!card.itemIndex
        card.title.Visible := !!card.itemIndex
        card.fallback.Visible := false
        if !card.itemIndex
            continue
        item := S.items[i]
        card.title.Text := item.title
        card.title.SetFont("norm cF4F4F5")
        card.pic.Value := ""
        icon := WindowIcon(item.hwnd)
        if icon
            try card.pic.Value := "HICON:" icon
        preview := {hwnd:item.hwnd, x:card.x+ScalePx(10), y:card.y+ScalePx(44),
            w:card.w-ScalePx(20), h:card.h-ScalePx(54)}
        if !AddThumbnail(S.gui.Hwnd, preview) {
            card.fallback.Text := "Preview unavailable"
            card.fallback.Visible := true
        }
    }
    S.footer.Text := "Tab / Shift+Tab   |   " (S.page+1) "/" Ceil(S.items.Length/S.capacity)
        . "`nAlt / Click: OK   Esc: cancel"
}

UpdateSelection() {
    global S
    S.heading.Text := "CURRENT DISPLAY    " S.index " / " S.items.Length
    for card in S.cards {
        selected := card.itemIndex = S.index
        if selected = card.selected
            continue
        card.selected := selected
        for border in card.borders {
            border.Opt("Background" (selected ? "40C4FF" : "44444B"))
            border.Redraw()
        }
        if card.itemIndex {
            card.title.Text := (selected ? "> " : "") S.items[card.itemIndex].title
            card.title.SetFont(selected ? "bold c40C4FF" : "norm cF4F4F5")
            card.title.Redraw()
        }
    }
}

PickerMouseActivate(wParam, lParam, msg, hwnd) {
    global S
    if S.active && IsObject(S.gui)
        && DllCall("User32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") = S.gui.Hwnd
        return 3 ; MA_NOACTIVATE: deliver the click without stealing focus.
}

PickerClick(wParam, lParam, msg, hwnd) {
    global S
    if !S.active || !IsObject(S.gui)
        return
    if DllCall("User32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != S.gui.Hwnd
        return
    ; Map coordinates from either the GUI or its title/icon/border child.
    point := Buffer(8, 0)
    NumPut("short", lParam & 0xFFFF, point, 0)
    NumPut("int", NumGet(point, 0, "short"), point, 0)
    NumPut("short", (lParam >> 16) & 0xFFFF, point, 4)
    NumPut("int", NumGet(point, 4, "short"), point, 4)
    DllCall("User32\MapWindowPoints", "ptr", hwnd, "ptr", S.gui.Hwnd, "ptr", point, "uint", 1)
    px := NumGet(point, 0, "int"), py := NumGet(point, 4, "int")
    for card in S.cards {
        if card.itemIndex && px >= card.x && px < card.x+card.w
            && py >= card.y && py < card.y+card.h {
            S.index := card.itemIndex
            ; Do not destroy controls inside their mouse message handler.
            SetTimer(Commit, -1)
            return 0
        }
    }
}

AddThumbnail(dest, p) {
    global S
    thumb := 0
    if DllCall("Dwmapi\DwmRegisterThumbnail", "ptr", dest, "ptr", p.hwnd,
        "ptr*", &thumb, "int") != 0
        return false
    size := Buffer(8, 0)
    if DllCall("Dwmapi\DwmQueryThumbnailSourceSize", "ptr", thumb, "ptr", size, "int") != 0 {
        DllCall("Dwmapi\DwmUnregisterThumbnail", "ptr", thumb)
        return false
    }
    sw := NumGet(size, 0, "int"), sh := NumGet(size, 4, "int")
    if sw <= 0 || sh <= 0 {
        DllCall("Dwmapi\DwmUnregisterThumbnail", "ptr", thumb)
        return false
    }
    ratio := Min(p.w/sw, p.h/sh)
    tw := Max(1, Floor(sw*ratio)), th := Max(1, Floor(sh*ratio))
    tx := p.x + Floor((p.w-tw)/2), ty := p.y + Floor((p.h-th)/2)
    props := Buffer(48, 0)
    NumPut("uint", 0x1|0x4|0x8|0x10, props, 0)
    NumPut("int", tx, "int", ty, "int", tx+tw, "int", ty+th, props, 4)
    NumPut("uchar", 255, props, 36)
    NumPut("int", 1, props, 40)
    NumPut("int", 0, props, 44)
    if DllCall("Dwmapi\DwmUpdateThumbnailProperties", "ptr", thumb, "ptr", props, "int") != 0 {
        DllCall("Dwmapi\DwmUnregisterThumbnail", "ptr", thumb)
        return false
    }
    S.thumbs.Push(thumb)
    return true
}

WindowIcon(hwnd) {
    icon := 0
    ; Bound every cross-process icon query; a hung app must not hang the picker.
    for kind in [2, 0, 1] {
        DllCall("User32\SendMessageTimeoutW", "ptr", hwnd, "uint", 0x7F,
            "uptr", kind, "ptr", 0, "uint", 2, "uint", 25, "ptr*", &icon, "ptr")
        if icon
            break
    }
    if !icon {
        fn := A_PtrSize = 8 ? "User32\GetClassLongPtrW" : "User32\GetClassLongW"
        icon := DllCall(fn, "ptr", hwnd, "int", -34, "ptr")
        if !icon
            icon := DllCall(fn, "ptr", hwnd, "int", -14, "ptr")
    }
    if !icon
        icon := DllCall("User32\LoadIconW", "ptr", 0, "ptr", 32512, "ptr")
    ; GUI owns this copy, never the application's shared original icon.
    return icon ? DllCall("User32\CopyIcon", "ptr", icon, "ptr") : 0
}
