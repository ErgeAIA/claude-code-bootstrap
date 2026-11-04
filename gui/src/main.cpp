// Claude Code Bootstrap - native Win32 GUI
// A small wrapper around setup-claude.ps1: install / uninstall / check update / update.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <commctrl.h>
#include <richedit.h>
#include <dwmapi.h>
#include <uxtheme.h>

#include <string>
#include <vector>

#include "resource.h"
#include "util.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

namespace {

const wchar_t* kClass = L"ClaudeBootstrapGui";
const wchar_t* kTitle = L"Claude Code Bootstrap";
const wchar_t* kGuiVersion = L"1.0.0";
const wchar_t* kSetupUrl =
    L"https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/setup-claude.ps1";

enum : int {
    IDC_INSTALL = 1001,
    IDC_FULL,
    IDC_CHECK,
    IDC_UPDATE,
    IDC_UNINSTALL,
    IDC_LOG = 1100
};

enum TaskType {
    TASK_NONE = 0,
    TASK_INSTALL,
    TASK_FULL,
    TASK_UPDATE,
    TASK_UNINSTALL,
    TASK_CHECK,
    TASK_CHECK_SILENT
};

const COLORREF C_BG        = RGB(23, 24, 28);
const COLORREF C_CARD      = RGB(31, 33, 39);
const COLORREF C_HOVER     = RGB(42, 45, 54);
const COLORREF C_PRESSED   = RGB(28, 30, 36);
const COLORREF C_BORDER    = RGB(52, 56, 66);
const COLORREF C_TEXT      = RGB(232, 234, 239);
const COLORREF C_MUTED     = RGB(142, 148, 160);
const COLORREF C_ACCENT    = RGB(59, 156, 246);
const COLORREF C_ACCENT_HI = RGB(84, 172, 252);
const COLORREF C_ACCENT_LO = RGB(44, 127, 205);
const COLORREF C_GREEN     = RGB(74, 222, 128);
const COLORREF C_YELLOW    = RGB(234, 179, 8);
const COLORREF C_RED       = RGB(248, 113, 113);

#define WM_APP_LOG  (WM_APP + 1)
#define WM_APP_DONE (WM_APP + 2)
#define TIMER_BUSY  1

struct CheckResult {
    int generation = 0;
    bool silent = false;
    bool installed = false;
    bool latestOk = false;
    std::wstring installedVersion;
    std::wstring installedPath;
    std::wstring latestVersion;
    std::wstring error;
};

struct TaskDone {
    TaskType type = TASK_NONE;
    DWORD exitCode = 0;
    int generation = 0;
    std::wstring error;
    CheckResult* check = nullptr;
};

struct CheckParams {
    int generation = 0;
    bool silent = false;
};

struct ButtonInfo {
    int id = 0;
    bool primary = false;
    bool danger = false;
    bool hover = false;
    HWND hwnd = nullptr;
    WNDPROC orig = nullptr;
    const wchar_t* label = L"";
};

struct Layout {
    RECT header{};
    RECT status{};
    RECT buttons{};
    RECT log{};
    RECT footer{};
    int btnW = 0;
    int btnH = 0;
};

HINSTANCE g_inst = nullptr;
HWND g_hwnd = nullptr;
HWND g_log = nullptr;
HFONT g_fontTitle = nullptr;
HFONT g_fontSub = nullptr;
HFONT g_fontLabel = nullptr;
HFONT g_fontValue = nullptr;
HFONT g_fontButton = nullptr;
HFONT g_fontLog = nullptr;
UINT g_dpi = 96;
ButtonInfo g_buttons[5];
const int g_buttonCount = 5;
Layout g_layout;
bool g_busy = false;
TaskType g_task = TASK_NONE;
HANDLE g_job = nullptr;
std::wstring g_footer = L"就绪";
bool g_installedKnown = false;
bool g_latestKnown = false;
std::wstring g_installedVersion;
std::wstring g_latestVersion;
std::wstring g_installedPath;
std::wstring g_checkError;
volatile LONG g_checking = 0;
int g_checkGen = 0;

int S(int px) { return MulDiv(px, (int)g_dpi, 96); }

// ---------------------------------------------------------------------------
// Fonts / layout
// ---------------------------------------------------------------------------
HFONT MakeFont(int pt, int weight, const wchar_t* face) {
    LOGFONTW lf{};
    lf.lfHeight = -MulDiv(pt, (int)g_dpi, 72);
    lf.lfWeight = weight;
    lf.lfQuality = CLEARTYPE_QUALITY;
    lf.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(lf.lfFaceName, face, LF_FACESIZE);
    return CreateFontIndirectW(&lf);
}

void CreateFonts(bool rebuild) {
    HFONT old[6] = {g_fontTitle, g_fontSub, g_fontLabel, g_fontValue, g_fontButton, g_fontLog};
    g_fontTitle  = MakeFont(17, FW_SEMIBOLD, L"Microsoft YaHei UI");
    g_fontSub    = MakeFont(9,  FW_NORMAL,   L"Microsoft YaHei UI");
    g_fontLabel  = MakeFont(9,  FW_NORMAL,   L"Microsoft YaHei UI");
    g_fontValue  = MakeFont(13, FW_SEMIBOLD, L"Microsoft YaHei UI");
    g_fontButton = MakeFont(10, FW_MEDIUM,   L"Microsoft YaHei UI");
    g_fontLog    = MakeFont(9,  FW_NORMAL,   L"Consolas");
    if (rebuild) {
        if (g_log) SendMessageW(g_log, WM_SETFONT, (WPARAM)g_fontLog, TRUE);
        for (int i = 0; i < g_buttonCount; i++) {
            if (g_buttons[i].hwnd) SendMessageW(g_buttons[i].hwnd, WM_SETFONT, (WPARAM)g_fontButton, TRUE);
        }
        for (HFONT f : old) if (f) DeleteObject(f);
    }
}

Layout ComputeLayout(int w, int h) {
    Layout L{};
    int m = S(20);
    int headerH = S(58);
    L.header = RECT{m, m, w - m, m + headerH};

    int y = L.header.bottom + S(12);
    int statusH = S(74);
    L.status = RECT{m, y, w - m, y + statusH};

    y = L.status.bottom + S(14);
    int btnH = S(40);
    L.buttons = RECT{m, y, w - m, y + btnH};
    int gap = S(10);
    int total = (w - 2 * m) - gap * (g_buttonCount - 1);
    L.btnW = total / g_buttonCount;
    L.btnH = btnH;

    y = L.buttons.bottom + S(14);
    int footerH = S(26);
    int bottom = h - m;
    L.footer = RECT{m, bottom - footerH, w - m, bottom};
    L.log = RECT{m, y, w - m, L.footer.top - S(10)};
    if (L.log.bottom < L.log.top + S(80)) L.log.bottom = L.log.top + S(80);
    return L;
}

void LayoutChildren() {
    RECT rc{};
    GetClientRect(g_hwnd, &rc);
    g_layout = ComputeLayout(rc.right, rc.bottom);

    int gap = S(10);
    int x = g_layout.buttons.left;
    for (int i = 0; i < g_buttonCount; i++) {
        MoveWindow(g_buttons[i].hwnd, x, g_layout.buttons.top, g_layout.btnW, g_layout.btnH, TRUE);
        x += g_layout.btnW + gap;
    }

    int inset = S(2);
    int lx = g_layout.log.left + inset;
    int ly = g_layout.log.top + inset;
    int lw = (g_layout.log.right - inset) - lx;
    int lh = (g_layout.log.bottom - inset) - ly;
    if (g_log && lw > 0 && lh > 0) MoveWindow(g_log, lx, ly, lw, lh, TRUE);
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------
void FillRound(HDC dc, const RECT& r, int radius, COLORREF fill, COLORREF border) {
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, border);
    HGDIOBJ ob = SelectObject(dc, brush);
    HGDIOBJ op = SelectObject(dc, pen);
    RoundRect(dc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(brush);
    DeleteObject(pen);
}

void TextAt(HDC dc, const std::wstring& s, const RECT& r0, HFONT font, COLORREF color, UINT flags) {
    RECT r = r0;
    SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, color);
    DrawTextW(dc, s.c_str(), (int)s.size(), &r, flags | DT_NOPREFIX);
}

void HLine(HDC dc, int x1, int x2, int y, COLORREF color) {
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ old = SelectObject(dc, pen);
    MoveToEx(dc, x1, y, nullptr);
    LineTo(dc, x2, y);
    SelectObject(dc, old);
    DeleteObject(pen);
}

bool UpdateAvailable() {
    return g_installedKnown && !g_installedVersion.empty() &&
           g_latestKnown && !g_latestVersion.empty() &&
           IsVersionNewer(g_latestVersion, g_installedVersion);
}

std::wstring StatusText(COLORREF& color) {
    if (!g_installedKnown) {
        color = C_MUTED;
        return L"检测中…";
    }
    if (g_installedVersion.empty()) {
        color = C_YELLOW;
        return L"未安装 Claude Code";
    }
    if (!g_latestKnown) {
        color = C_YELLOW;
        return L"无法检查更新";
    }
    if (UpdateAvailable()) {
        color = C_YELLOW;
        return L"发现新版本";
    }
    color = C_GREEN;
    return L"已是最新版本";
}

const wchar_t* TaskLabel(TaskType t) {
    switch (t) {
        case TASK_INSTALL:   return L"安装 Claude Code";
        case TASK_FULL:      return L"完整安装（Claude Code + hooks）";
        case TASK_UPDATE:    return L"更新 Claude Code";
        case TASK_UNINSTALL: return L"卸载 Claude Code";
        case TASK_CHECK:     return L"检查更新";
        default:             return L"操作";
    }
}

const wchar_t* TaskBusyText(TaskType t) {
    switch (t) {
        case TASK_INSTALL:   return L"正在安装 Claude Code";
        case TASK_FULL:      return L"正在完整安装（含 hooks）";
        case TASK_UPDATE:    return L"正在更新 Claude Code";
        case TASK_UNINSTALL: return L"正在卸载 Claude Code";
        case TASK_CHECK:     return L"正在检查更新";
        default:             return L"正在处理";
    }
}

// ---------------------------------------------------------------------------
// Log control
// ---------------------------------------------------------------------------
std::wstring StripAnsi(const std::wstring& s) {
    std::wstring out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        if (s[i] == 0x1B) {
            if (i + 1 < s.size() && s[i + 1] == L'[') {
                i += 2;
                while (i < s.size() && !(s[i] >= 0x40 && s[i] <= 0x7E)) i++;
                if (i < s.size()) i++;
                continue;
            }
            if (i + 1 < s.size() && s[i + 1] == L']') {
                i += 2;
                while (i < s.size()) {
                    if (s[i] == 7) { i++; break; }
                    if (s[i] == 0x1B && i + 1 < s.size() && s[i + 1] == L'\\') { i += 2; break; }
                    i++;
                }
                continue;
            }
            i += 2;
            continue;
        }
        if (s[i] == 7) { i++; continue; }
        out.push_back(s[i++]);
    }
    while (!out.empty() && (out.back() == L'\r' || out.back() == L'\n')) out.pop_back();
    return out;
}

void AppendLog(const std::wstring& raw, COLORREF force = CLR_INVALID) {
    if (!g_log) return;
    std::wstring line = StripAnsi(raw);
    if (line.empty()) return;

    COLORREF color = force;
    if (color == CLR_INVALID) {
        if (line.find(L"[ERROR]") != std::wstring::npos || line.find(L"[FATAL]") != std::wstring::npos)
            color = C_RED;
        else if (line.find(L"[WARN]") != std::wstring::npos)
            color = C_YELLOW;
        else if (line.find(L"[OK]") != std::wstring::npos)
            color = C_GREEN;
        else if (line.find(L"==>") != std::wstring::npos)
            color = C_ACCENT;
        else if (line.find(L"[SKIP]") != std::wstring::npos || line.find(L"[GET ]") != std::wstring::npos)
            color = C_MUTED;
        else
            color = C_TEXT;
    }

    SCROLLINFO si{};
    si.cbSize = sizeof(si);
    si.fMask = SIF_RANGE | SIF_POS | SIF_PAGE;
    GetScrollInfo(g_log, SB_VERT, &si);
    bool stick = (si.nMax <= 0) || ((int)si.nPos + (int)si.nPage >= si.nMax - 4);

    SendMessageW(g_log, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
    CHARFORMAT2W cf{};
    cf.cbSize = sizeof(cf);
    cf.dwMask = CFM_COLOR;
    cf.crTextColor = color;
    SendMessageW(g_log, EM_SETCHARFORMAT, SCF_SELECTION, (LPARAM)&cf);

    std::wstring text = line + L"\r\n";
    SendMessageW(g_log, EM_REPLACESEL, FALSE, (LPARAM)text.c_str());
    if (stick) SendMessageW(g_log, WM_VSCROLL, SB_BOTTOM, 0);
}

void PostLog(const std::wstring& s) {
    auto* p = new std::wstring(s);
    if (!PostMessageW(g_hwnd, WM_APP_LOG, 0, (LPARAM)p)) delete p;
}

void ClearLog() {
    if (g_log) SetWindowTextW(g_log, L"");
}

void CreateLogControl() {
    LoadLibraryW(L"Msftedit.dll");
    g_log = CreateWindowExW(0, MSFTEDIT_CLASS, L"",
                            WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE |
                                ES_READONLY | ES_NOHIDESEL,
                            0, 0, 0, 0, g_hwnd, (HMENU)(INT_PTR)IDC_LOG, g_inst, nullptr);
    SendMessageW(g_log, EM_SETBKGNDCOLOR, 0, (LPARAM)C_CARD);
    SendMessageW(g_log, EM_EXLIMITTEXT, 0, (LPARAM)0x7FFFFFFE);
    SendMessageW(g_log, WM_SETFONT, (WPARAM)g_fontLog, TRUE);
    SendMessageW(g_log, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELONG(S(12), S(12)));
    SetWindowTheme(g_log, L"DarkMode_Explorer", nullptr);
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------
void PaintHeader(HDC dc, const Layout& L) {
    RECT title = L.header;
    title.bottom = title.top + S(30);
    TextAt(dc, L"Claude Code Bootstrap", title, g_fontTitle, C_TEXT,
           DT_LEFT | DT_TOP | DT_SINGLELINE);

    RECT sub = L.header;
    sub.top = title.bottom - S(1);
    TextAt(dc, L"Windows 一键环境部署 · 安装 / 卸载 / 更新", sub, g_fontSub, C_MUTED,
           DT_LEFT | DT_TOP | DT_SINGLELINE);

    std::wstring ver = L"GUI v";
    ver += kGuiVersion;
    TextAt(dc, ver, L.header, g_fontSub, C_MUTED, DT_RIGHT | DT_TOP | DT_SINGLELINE);

    HLine(dc, L.header.left, L.header.right, L.header.bottom + S(6), C_BORDER);
}

void PaintStatus(HDC dc, const Layout& L) {
    FillRound(dc, L.status, S(8), C_CARD, C_BORDER);

    int x1 = L.status.left + S(18);
    int top = L.status.top + S(12);

    RECT lab1{x1, top, x1 + S(190), top + S(16)};
    TextAt(dc, L"已安装", lab1, g_fontLabel, C_MUTED, DT_LEFT | DT_TOP | DT_SINGLELINE);

    std::wstring installed;
    COLORREF installedColor = C_TEXT;
    if (!g_installedKnown) {
        installed = L"…";
        installedColor = C_MUTED;
    } else if (g_installedVersion.empty()) {
        installed = L"未安装";
        installedColor = C_MUTED;
    } else {
        installed = L"v" + g_installedVersion;
    }
    RECT val1{x1, top + S(18), x1 + S(190), top + S(44)};
    TextAt(dc, installed, val1, g_fontValue, installedColor, DT_LEFT | DT_TOP | DT_SINGLELINE);

    int divX = L.status.left + S(215);
    HPEN pen = CreatePen(PS_SOLID, 1, C_BORDER);
    HGDIOBJ old = SelectObject(dc, pen);
    MoveToEx(dc, divX, top, nullptr);
    LineTo(dc, divX, L.status.bottom - S(12));
    SelectObject(dc, old);
    DeleteObject(pen);

    int x2 = L.status.left + S(230);
    RECT lab2{x2, top, x2 + S(190), top + S(16)};
    TextAt(dc, L"最新版本", lab2, g_fontLabel, C_MUTED, DT_LEFT | DT_TOP | DT_SINGLELINE);

    std::wstring latest;
    COLORREF latestColor = C_TEXT;
    if (!g_latestKnown) {
        latest = g_installedKnown ? L"—" : L"…";
        latestColor = C_MUTED;
    } else {
        latest = g_latestVersion.empty() ? L"—" : (L"v" + g_latestVersion);
    }
    RECT val2{x2, top + S(18), x2 + S(190), top + S(44)};
    TextAt(dc, latest, val2, g_fontValue, latestColor, DT_LEFT | DT_TOP | DT_SINGLELINE);

    COLORREF statusColor = C_MUTED;
    std::wstring status = StatusText(statusColor);

    // 状态文字与版本号数字同一行渲染（同 rect / 同 DT_TOP），圆点垂直居中于该行
    SelectObject(dc, g_fontValue);
    TEXTMETRICW tm{};
    GetTextMetricsW(dc, &tm);
    int lineTop = top + S(18);
    int lineBottom = top + S(44);
    int dot = S(5);
    int sx = L.status.right - S(214);
    int sy = lineTop + tm.tmHeight / 2 - dot;
    HBRUSH brush = CreateSolidBrush(statusColor);
    HPEN dotPen = CreatePen(PS_SOLID, 1, statusColor);
    HGDIOBJ ob = SelectObject(dc, brush);
    HGDIOBJ op = SelectObject(dc, dotPen);
    Ellipse(dc, sx, sy, sx + dot * 2, sy + dot * 2);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(brush);
    DeleteObject(dotPen);

    RECT sr{sx + dot * 2 + S(8), lineTop, L.status.right - S(16), lineBottom};
    TextAt(dc, status, sr, g_fontValue, statusColor,
           DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS);
}

void PaintFooter(HDC dc, const Layout& L) {
    HLine(dc, L.footer.left, L.footer.right, L.footer.top - S(6), C_BORDER);

    std::wstring text;
    COLORREF color = C_MUTED;
    if (g_busy) {
        text = TaskBusyText(g_task);
        int dots = (int)((GetTickCount64() / 420) % 4);
        text += std::wstring((size_t)dots, L'.');
        color = C_ACCENT;
    } else {
        text = g_footer;
        if (g_installedKnown && g_installedVersion.empty()) color = C_YELLOW;
        else if (UpdateAvailable()) color = C_YELLOW;
        else if (g_installedKnown && g_latestKnown) color = C_GREEN;
    }

    int dot = S(3);
    int cy = (L.footer.top + L.footer.bottom) / 2;
    HBRUSH brush = CreateSolidBrush(color);
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ ob = SelectObject(dc, brush);
    HGDIOBJ op = SelectObject(dc, pen);
    Ellipse(dc, L.footer.left, cy - dot, L.footer.left + dot * 2, cy + dot);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(brush);
    DeleteObject(pen);

    RECT tr{L.footer.left + dot * 2 + S(8), L.footer.top, L.footer.right - S(120), L.footer.bottom};
    TextAt(dc, text, tr, g_fontSub, color, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

    TextAt(dc, L"日志可选中复制", L.footer, g_fontSub, C_MUTED,
           DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
}

void PaintProgress(HDC dc, int w, int h) {
    int barH = S(3);
    RECT track{0, h - barH, w, h};
    HBRUSH tb = CreateSolidBrush(RGB(36, 38, 45));
    FillRect(dc, &track, tb);
    DeleteObject(tb);

    int block = S(190);
    int span = w + block;
    int x = (int)((GetTickCount64() / 4) % (ULONGLONG)span) - block;
    RECT fill{x, track.top, x + block, track.bottom};
    HBRUSH fb = CreateSolidBrush(C_ACCENT);
    FillRect(dc, &fill, fb);
    DeleteObject(fb);
}

void PaintMain(HDC dc, int w, int h) {
    Layout L = ComputeLayout(w, h);
    HBRUSH bg = CreateSolidBrush(C_BG);
    RECT full{0, 0, w, h};
    FillRect(dc, &full, bg);
    DeleteObject(bg);

    PaintHeader(dc, L);
    PaintStatus(dc, L);
    FillRound(dc, L.log, S(8), C_CARD, C_BORDER);
    PaintFooter(dc, L);
    if (g_busy) PaintProgress(dc, w, h);
}

// ---------------------------------------------------------------------------
// Owner-drawn buttons
// ---------------------------------------------------------------------------
int ButtonIndexFromHwnd(HWND h) {
    for (int i = 0; i < g_buttonCount; i++) {
        if (g_buttons[i].hwnd == h) return i;
    }
    return -1;
}

LRESULT CALLBACK ButtonProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    int i = ButtonIndexFromHwnd(h);
    if (i < 0) return DefWindowProcW(h, msg, wp, lp);
    if (msg == WM_MOUSEMOVE) {
        if (!g_buttons[i].hover) {
            g_buttons[i].hover = true;
            TRACKMOUSEEVENT t{};
            t.cbSize = sizeof(t);
            t.dwFlags = TME_LEAVE;
            t.hwndTrack = h;
            TrackMouseEvent(&t);
            InvalidateRect(h, nullptr, TRUE);
        }
    } else if (msg == WM_MOUSELEAVE) {
        g_buttons[i].hover = false;
        InvalidateRect(h, nullptr, TRUE);
    } else if (msg == WM_SETCURSOR) {
        SetCursor(LoadCursorW(nullptr, IsWindowEnabled(h) ? IDC_HAND : IDC_ARROW));
        return TRUE;
    } else if (msg == WM_ENABLE) {
        g_buttons[i].hover = false;
        InvalidateRect(h, nullptr, TRUE);
    }
    return CallWindowProcW(g_buttons[i].orig, h, msg, wp, lp);
}

void SetButtonsEnabled(bool enabled);

void CreateButtons() {
    struct Def { int id; const wchar_t* label; bool primary; bool danger; };
    Def defs[5] = {
        {IDC_INSTALL,   L"安装",     true,  false},
        {IDC_FULL,      L"完整安装", false, false},
        {IDC_CHECK,     L"检查更新", false, false},
        {IDC_UPDATE,    L"更新",     false, false},
        {IDC_UNINSTALL, L"卸载",     false, true},
    };
    for (int i = 0; i < g_buttonCount; i++) {
        g_buttons[i].id = defs[i].id;
        g_buttons[i].label = defs[i].label;
        g_buttons[i].primary = defs[i].primary;
        g_buttons[i].danger = defs[i].danger;
        g_buttons[i].hover = false;
        HWND h = CreateWindowExW(0, L"BUTTON", defs[i].label,
                                 WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                 0, 0, 0, 0, g_hwnd, (HMENU)(INT_PTR)defs[i].id, g_inst, nullptr);
        SendMessageW(h, WM_SETFONT, (WPARAM)g_fontButton, TRUE);
        g_buttons[i].hwnd = h;
        g_buttons[i].orig = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)ButtonProc);
    }
    // 初始禁用「更新」，等待首次版本检测结果
    SetButtonsEnabled(true);
}

void SetButtonsEnabled(bool enabled) {
    for (int i = 0; i < g_buttonCount; i++) {
        if (!g_buttons[i].hwnd) continue;
        // 「更新」仅在检测到新版本时可用
        bool on = enabled && (g_buttons[i].id != IDC_UPDATE || UpdateAvailable());
        EnableWindow(g_buttons[i].hwnd, on);
        InvalidateRect(g_buttons[i].hwnd, nullptr, TRUE);
    }
}

void DrawButton(const DRAWITEMSTRUCT* d) {
    int i = -1;
    for (int k = 0; k < g_buttonCount; k++) {
        if (g_buttons[k].id == (int)d->CtlID) { i = k; break; }
    }
    if (i < 0) return;

    bool disabled = (d->itemState & ODS_DISABLED) != 0;
    bool pressed = (d->itemState & ODS_SELECTED) != 0;
    bool focused = (d->itemState & ODS_FOCUS) != 0;
    bool hover = g_buttons[i].hover && !disabled;
    bool primary = g_buttons[i].primary;
    bool danger = g_buttons[i].danger;
    bool highlight = (g_buttons[i].id == IDC_UPDATE) && UpdateAvailable() && !disabled;

    RECT r = d->rcItem;
    InflateRect(&r, -S(1), -S(1));

    COLORREF fill, border, text;
    if (disabled) {
        fill = C_CARD;
        border = C_BORDER;
        text = C_MUTED;
    } else if (primary) {
        fill = pressed ? C_ACCENT_LO : (hover ? C_ACCENT_HI : C_ACCENT);
        border = fill;
        text = RGB(255, 255, 255);
    } else if (danger) {
        fill = pressed ? RGB(60, 34, 39) : (hover ? RGB(50, 31, 36) : C_CARD);
        border = hover ? RGB(150, 62, 72) : C_BORDER;
        text = C_RED;
    } else {
        fill = pressed ? C_PRESSED : (hover ? C_HOVER : C_CARD);
        border = highlight ? C_ACCENT : (hover ? RGB(70, 75, 88) : C_BORDER);
        text = highlight ? C_ACCENT : C_TEXT;
    }

    FillRound(d->hDC, r, S(6), fill, border);

    SelectObject(d->hDC, g_fontButton);
    SetBkMode(d->hDC, TRANSPARENT);
    SetTextColor(d->hDC, text);
    wchar_t label[64] = {};
    GetWindowTextW(d->hwndItem, label, 63);
    RECT tr = r;
    DrawTextW(d->hDC, label, -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);

    if (focused && !disabled) {
        RECT fr = r;
        InflateRect(&fr, -S(4), -S(4));
        HPEN pen = CreatePen(PS_DOT, 1, text);
        HGDIOBJ op = SelectObject(d->hDC, pen);
        HGDIOBJ ob = SelectObject(d->hDC, GetStockObject(NULL_BRUSH));
        RoundRect(d->hDC, fr.left, fr.top, fr.right, fr.bottom, S(4) * 2, S(4) * 2);
        SelectObject(d->hDC, op);
        SelectObject(d->hDC, ob);
        DeleteObject(pen);
    }
}

// ---------------------------------------------------------------------------
// Task runner
// ---------------------------------------------------------------------------
std::wstring EnsureSetupScript(std::wstring& err) {
    std::vector<std::wstring> dirs;
    std::wstring base = ModuleDir();
    dirs.push_back(base);
    std::wstring p = base;
    for (int i = 0; i < 4; i++) {
        p = ParentDir(p);
        dirs.push_back(p);
    }
    std::wstring cache = JoinPath(GetEnvVar(L"LOCALAPPDATA"), L"claude-bootstrap");
    dirs.push_back(cache);

    for (const auto& dir : dirs) {
        std::wstring candidate = JoinPath(dir, L"setup-claude.ps1");
        if (FileExists(candidate)) {
            PostLog(L"使用脚本: " + candidate);
            return candidate;
        }
    }

    PostLog(L"[WARN] 未找到本地 setup-claude.ps1，正在从 GitHub 下载...");
    if (!EnsureDir(cache)) {
        err = L"无法创建目录：" + cache;
        return L"";
    }
    std::wstring dest = JoinPath(cache, L"setup-claude.ps1");
    std::wstring derr;
    if (!DownloadToFile(kSetupUrl, dest, derr)) {
        err = L"下载 setup-claude.ps1 失败：" + derr;
        return L"";
    }
    if (FileSize(dest) < 1000) {
        err = L"下载的 setup-claude.ps1 不完整，请检查网络后重试";
        return L"";
    }
    PostLog(L"[OK] 已下载到 " + dest);
    return dest;
}

DWORD RunStreaming(const std::wstring& cmdline, std::wstring& err) {
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) {
        err = L"CreatePipe 失败";
        return 1;
    }
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &sa, OPEN_EXISTING, 0, nullptr);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput = nul;
    si.hStdOutput = writePipe;
    si.hStdError = writePipe;

    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmdline.begin(), cmdline.end());
    buf.push_back(L'\0');
    BOOL ok = CreateProcessW(nullptr, buf.data(), nullptr, nullptr, TRUE,
                             CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    DWORD spawnError = ok ? 0 : GetLastError();

    if (writePipe) CloseHandle(writePipe);
    if (nul && nul != INVALID_HANDLE_VALUE) CloseHandle(nul);

    if (!ok) {
        CloseHandle(readPipe);
        err = L"无法启动 PowerShell（错误 " + std::to_wstring(spawnError) + L"）";
        return 1;
    }

    if (g_job) AssignProcessToJobObject(g_job, pi.hProcess);

    std::string pending;
    char chunk[4096];
    DWORD got = 0;
    while (ReadFile(readPipe, chunk, sizeof(chunk), &got, nullptr) && got > 0) {
        pending.append(chunk, got);
        size_t pos;
        while ((pos = pending.find('\n')) != std::string::npos) {
            std::string line = pending.substr(0, pos);
            pending.erase(0, pos + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            std::wstring w = Utf8ToWide(line);
            if (!w.empty()) PostLog(w);
        }
    }
    if (!pending.empty()) {
        if (!pending.empty() && pending.back() == '\r') pending.pop_back();
        std::wstring w = Utf8ToWide(pending);
        if (!w.empty()) PostLog(w);
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(readPipe);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return exitCode;
}

DWORD RunTask(TaskType type, std::wstring& err) {
    std::wstring script = EnsureSetupScript(err);
    if (script.empty()) return 1;

    std::wstring ps = FindPowerShell();
    PostLog(L"PowerShell: " + ps);

    std::wstring args;
    switch (type) {
        case TASK_INSTALL:
            args = L"-InstallMode Minimal -NoUpdateCheck -SettingsStrategy merge -InstallTimeout 600";
            break;
        case TASK_FULL:
            args = L"-InstallMode Full -NoUpdateCheck -SettingsStrategy merge -InstallTimeout 600";
            break;
        case TASK_UPDATE:
            args = L"-Upgrade -ClaudeVersion latest -InstallTimeout 600";
            break;
        case TASK_UNINSTALL:
            args = L"-Uninstall";
            break;
        default:
            err = L"未知操作";
            return 1;
    }

    std::wstring cmd = L"\"" + ps + L"\" -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" +
                       script + L"\" " + args;
    PostLog(L"$ " + cmd);
    return RunStreaming(cmd, err);
}

void RunCheck(CheckResult& r, bool verbose) {
    if (verbose) PostLog(L"==> 正在检测本机 Claude Code...");
    r.installed = DetectInstalledClaude(r.installedVersion, r.installedPath);
    if (verbose) {
        if (r.installed) PostLog(L"[OK] 已安装 v" + r.installedVersion + L"  (" + r.installedPath + L")");
        else PostLog(L"[WARN] 本机未检测到 Claude Code");
    }

    std::wstring e;
    r.latestOk = FetchLatestVersion(r.latestVersion, e);
    if (!r.latestOk) r.error = e;
    if (verbose) {
        if (r.latestOk) PostLog(L"[OK] 最新版本 v" + r.latestVersion);
        else PostLog(L"[WARN] 获取最新版本失败：" + e);
    }

    if (verbose && r.installed && r.latestOk) {
        if (IsVersionNewer(r.latestVersion, r.installedVersion)) {
            PostLog(L"[WARN] 发现新版本，可点击「更新」升级");
        } else {
            PostLog(L"[OK] 已是最新版本");
        }
    }
}

DWORD WINAPI CheckThreadProc(LPVOID lp) {
    auto* p = (CheckParams*)lp;
    auto* r = new CheckResult();
    r->generation = p->generation;
    r->silent = p->silent;
    RunCheck(*r, !p->silent);

    auto* d = new TaskDone();
    d->type = p->silent ? TASK_CHECK_SILENT : TASK_CHECK;
    d->generation = p->generation;
    d->check = r;
    if (!PostMessageW(g_hwnd, WM_APP_DONE, 0, (LPARAM)d)) {
        delete d->check;
        delete d;
    }
    delete p;
    return 0;
}

DWORD WINAPI TaskThreadProc(LPVOID lp) {
    TaskType type = (TaskType)(INT_PTR)lp;
    std::wstring err;
    DWORD code = RunTask(type, err);

    // Refresh the status card from the post-operation state.
    auto* r = new CheckResult();
    RunCheck(*r, false);

    auto* d = new TaskDone();
    d->type = type;
    d->exitCode = code;
    d->error = err;
    d->check = r;
    if (!PostMessageW(g_hwnd, WM_APP_DONE, 0, (LPARAM)d)) {
        delete d->check;
        delete d;
    }
    return 0;
}

void StartSilentCheck() {
    if (InterlockedCompareExchange(&g_checking, 1, 0) != 0) return;
    int gen = ++g_checkGen;
    auto* p = new CheckParams();
    p->generation = gen;
    p->silent = true;
    HANDLE h = CreateThread(nullptr, 0, CheckThreadProc, p, 0, nullptr);
    if (!h) {
        delete p;
        InterlockedExchange(&g_checking, 0);
        return;
    }
    CloseHandle(h);
}

void ApplyCheck(const CheckResult& r) {
    g_installedKnown = true;
    g_installedVersion = r.installed ? r.installedVersion : L"";
    g_installedPath = r.installedPath;
    g_latestKnown = r.latestOk;
    if (r.latestOk) g_latestVersion = r.latestVersion;
    else g_latestVersion.clear();
    g_checkError = r.error;
    // 刷新「更新」按钮的可用状态（依赖 UpdateAvailable）
    SetButtonsEnabled(!g_busy);
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

void StartTask(TaskType type) {
    if (g_busy) return;
    int gen = ++g_checkGen;   // invalidate any in-flight silent check
    g_busy = true;
    g_task = type;
    g_footer = TaskBusyText(type);
    SetButtonsEnabled(false);
    ClearLog();
    AppendLog(std::wstring(L"==> ") + TaskLabel(type), C_ACCENT);
    SetTimer(g_hwnd, TIMER_BUSY, 50, nullptr);
    InvalidateRect(g_hwnd, nullptr, FALSE);

    if (type == TASK_CHECK) {
        InterlockedExchange(&g_checking, 1);
        auto* p = new CheckParams();
        p->generation = gen;
        p->silent = false;
        HANDLE h = CreateThread(nullptr, 0, CheckThreadProc, p, 0, nullptr);
        if (!h) {
            delete p;
            InterlockedExchange(&g_checking, 0);
            g_busy = false;
            KillTimer(g_hwnd, TIMER_BUSY);
            SetButtonsEnabled(true);
        }
        return;
    }

    HANDLE h = CreateThread(nullptr, 0, TaskThreadProc, (LPVOID)(INT_PTR)type, 0, nullptr);
    if (!h) {
        g_busy = false;
        g_footer = L"无法启动任务";
        KillTimer(g_hwnd, TIMER_BUSY);
        SetButtonsEnabled(true);
        AppendLog(L"[ERROR] 无法创建后台线程", C_RED);
    } else {
        CloseHandle(h);
    }
}

void HandleDone(TaskDone* d) {
    if (!d) return;

    if (d->type == TASK_CHECK_SILENT) {
        if (d->check && d->generation == g_checkGen && !g_busy) ApplyCheck(*d->check);
        if (d->check) delete d->check;
        delete d;
        InterlockedExchange(&g_checking, 0);
        return;
    }

    InterlockedExchange(&g_checking, 0);

    if (d->check) {
        ApplyCheck(*d->check);
        delete d->check;
    }

    g_busy = false;
    g_task = TASK_NONE;
    KillTimer(g_hwnd, TIMER_BUSY);
    SetButtonsEnabled(true);

    if (d->exitCode == 0) {
        AppendLog(L"[OK] 操作完成", C_GREEN);
        g_footer = L"完成";
    } else {
        std::wstring msg = L"[ERROR] 操作失败";
        if (d->exitCode) msg += L"（退出码 " + std::to_wstring(d->exitCode) + L"）";
        if (!d->error.empty()) msg += L"：" + d->error;
        AppendLog(msg, C_RED);
        g_footer = L"操作失败";
    }
    delete d;
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

bool ConfirmUninstall() {
    const wchar_t* text =
        L"将卸载 Claude Code，并清理本工具部署的 hooks / status_lines 以及 "
        L"settings.json 中对应的条目。\n\n"
        L"删除的文件会先备份到 ~/.claude/backups/uninstall-<时间戳>/。\n\n"
        L"注意：请先退出所有 Claude Code 会话，否则卸载会被中止。\n\n是否继续？";
    return MessageBoxW(g_hwnd, text, L"确认卸载",
                       MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES;
}

// ---------------------------------------------------------------------------
// Window plumbing
// ---------------------------------------------------------------------------
void ApplyDarkFrame(HWND h) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(h, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    int corner = 2; // DWMWCP_ROUND
    DwmSetWindowAttribute(h, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
    COLORREF caption = C_BG;
    DwmSetWindowAttribute(h, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
    COLORREF text = C_TEXT;
    DwmSetWindowAttribute(h, DWMWA_TEXT_COLOR, &text, sizeof(text));
}

void CreateJob() {
    g_job = CreateJobObjectW(nullptr, nullptr);
    if (!g_job) return;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &info, sizeof(info));
}

UINT DpiForWindowSafe(HWND h) {
    typedef UINT(WINAPI* PFN)(HWND);
    static PFN fn = nullptr;
    static bool resolved = false;
    if (!resolved) {
        HMODULE user32 = GetModuleHandleW(L"user32.dll");
        if (user32) fn = reinterpret_cast<PFN>(reinterpret_cast<void*>(GetProcAddress(user32, "GetDpiForWindow")));
        resolved = true;
    }
    if (fn) {
        UINT d = fn(h);
        if (d) return d;
    }
    HDC dc = GetDC(h);
    UINT d = dc ? (UINT)GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(h, dc);
    return d ? d : 96;
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_CREATE:
            g_hwnd = hwnd;
            g_dpi = DpiForWindowSafe(hwnd);
            CreateFonts(false);
            CreateJob();
            CreateButtons();
            CreateLogControl();
            LayoutChildren();
            AppendLog(L"就绪：选择上方按钮开始。安装 / 卸载日志会实时显示在这里。", C_MUTED);
            ApplyDarkFrame(hwnd);
            return 0;

        case WM_SIZE:
            if (wp != SIZE_MINIMIZED) {
                LayoutChildren();
                InvalidateRect(hwnd, nullptr, FALSE);
            }
            return 0;

        case WM_GETMINMAXINFO: {
            auto* mm = (MINMAXINFO*)lp;
            RECT r{0, 0, S(720), S(480)};
            AdjustWindowRectEx(&r, WS_OVERLAPPEDWINDOW, FALSE, 0);
            mm->ptMinTrackSize.x = r.right - r.left;
            mm->ptMinTrackSize.y = r.bottom - r.top;
            return 0;
        }

        case WM_DPICHANGED: {
            g_dpi = HIWORD(wp);
            CreateFonts(true);
            RECT* pr = (RECT*)lp;
            SetWindowPos(hwnd, nullptr, pr->left, pr->top,
                         pr->right - pr->left, pr->bottom - pr->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            LayoutChildren();
            InvalidateRect(hwnd, nullptr, TRUE);
            return 0;
        }

        case WM_ERASEBKGND:
            return 1;

        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            RECT rc{};
            GetClientRect(hwnd, &rc);
            if (rc.right > 0 && rc.bottom > 0) {
                HDC mem = CreateCompatibleDC(dc);
                HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
                HGDIOBJ old = SelectObject(mem, bmp);
                PaintMain(mem, rc.right, rc.bottom);
                BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
                SelectObject(mem, old);
                DeleteObject(bmp);
                DeleteDC(mem);
            }
            EndPaint(hwnd, &ps);
            return 0;
        }

        case WM_DRAWITEM:
            DrawButton((const DRAWITEMSTRUCT*)lp);
            return TRUE;

        case WM_COMMAND:
            if (HIWORD(wp) == BN_CLICKED || HIWORD(wp) == 0) {
                switch (LOWORD(wp)) {
                    case IDC_INSTALL:
                        StartTask(TASK_INSTALL);
                        return 0;
                    case IDC_FULL:
                        StartTask(TASK_FULL);
                        return 0;
                    case IDC_CHECK:
                        StartTask(TASK_CHECK);
                        return 0;
                    case IDC_UPDATE:
                        // 仅检测到新版本时允许更新
                        if (UpdateAvailable()) StartTask(TASK_UPDATE);
                        return 0;
                    case IDC_UNINSTALL:
                        if (!g_busy && ConfirmUninstall()) StartTask(TASK_UNINSTALL);
                        return 0;
                }
            }
            break;

        case WM_TIMER:
            if (wp == TIMER_BUSY) {
                RECT rc{};
                GetClientRect(hwnd, &rc);
                RECT strip{0, rc.bottom - S(40), rc.right, rc.bottom};
                RedrawWindow(hwnd, &strip, nullptr, RDW_INVALIDATE);
            }
            return 0;

        case WM_APP_LOG: {
            auto* s = (std::wstring*)lp;
            if (s) {
                AppendLog(*s);
                delete s;
            }
            return 0;
        }

        case WM_APP_DONE:
            HandleDone((TaskDone*)lp);
            return 0;

        case WM_CLOSE:
            if (g_busy) {
                if (MessageBoxW(hwnd,
                                L"任务正在运行，退出将中止当前操作。确定退出吗？",
                                kTitle, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES) {
                    return 0;
                }
            }
            DestroyWindow(hwnd);
            return 0;

        case WM_DESTROY:
            KillTimer(hwnd, TIMER_BUSY);
            if (g_job) {
                CloseHandle(g_job);
                g_job = nullptr;
            }
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    g_inst = inst;

    INITCOMMONCONTROLSEX icc{};
    icc.dwSize = sizeof(icc);
    icc.dwICC = ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES;
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APP));
    wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(IDI_APP), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON),
                                   GetSystemMetrics(SM_CYSMICON), 0);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kClass;
    if (!RegisterClassExW(&wc)) return 1;

    HDC screen = GetDC(nullptr);
    int sysDpi = screen ? GetDeviceCaps(screen, LOGPIXELSY) : 96;
    if (screen) ReleaseDC(nullptr, screen);
    if (!sysDpi) sysDpi = 96;
    int initW = MulDiv(760, sysDpi, 96);
    int initH = MulDiv(600, sysDpi, 96);
    RECT wr{0, 0, initW, initH};
    AdjustWindowRectEx(&wr, WS_OVERLAPPEDWINDOW, FALSE, 0);

    HWND hwnd = CreateWindowExW(0, kClass, kTitle, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                                CW_USEDEFAULT, CW_USEDEFAULT,
                                wr.right - wr.left, wr.bottom - wr.top,
                                nullptr, nullptr, inst, nullptr);
    if (!hwnd) return 1;

    ApplyDarkFrame(hwnd);
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);
    StartSilentCheck();

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return (int)msg.wParam;
}