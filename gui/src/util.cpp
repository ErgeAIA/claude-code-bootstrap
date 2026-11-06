#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <shlobj.h>

#include <string>
#include <vector>

#include "util.h"

#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif

static std::wstring WinErrorText(DWORD code) {
    wchar_t* buf = nullptr;
    DWORD n = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPWSTR>(&buf), 0, nullptr);
    std::wstring s = (n && buf) ? std::wstring(buf, n) : L"unknown error";
    if (buf) LocalFree(buf);
    while (!s.empty() && (s.back() == L'\r' || s.back() == L'\n' || s.back() == L' ')) s.pop_back();
    return s + L" (" + std::to_wstring(code) + L")";
}

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    UINT cp = CP_UTF8;
    if (n <= 0) {
        cp = CP_ACP;
        n = MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), nullptr, 0);
    }
    if (n <= 0) return L"";
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

std::wstring GetEnvVar(const wchar_t* name) {
    DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
    if (n == 0) return L"";
    std::wstring val((size_t)n, L'\0');
    DWORD got = GetEnvironmentVariableW(name, &val[0], n);
    if (got == 0 || got >= n) return L"";
    val.resize(got);
    return val;
}

std::wstring JoinPath(const std::wstring& a, const std::wstring& b) {
    if (a.empty()) return b;
    if (b.empty()) return a;
    std::wstring out = a;
    if (out.back() != L'\\' && out.back() != L'/') out.push_back(L'\\');
    out += b;
    return out;
}

std::wstring ParentDir(const std::wstring& path) {
    std::wstring s = path;
    while (s.size() > 1 && (s.back() == L'\\' || s.back() == L'/')) s.pop_back();
    size_t i = s.find_last_of(L"\\/");
    if (i == std::wstring::npos) return s;
    if (i == 2 && s[1] == L':') return s.substr(0, 3);
    if (i == 0) return L"\\";
    return s.substr(0, i);
}

std::wstring ModuleDir() {
    std::vector<wchar_t> buf(MAX_PATH);
    for (;;) {
        DWORD n = GetModuleFileNameW(nullptr, buf.data(), (DWORD)buf.size());
        if (n == 0) return L".";
        if (n < buf.size() - 1) return ParentDir(std::wstring(buf.data(), n));
        buf.resize(buf.size() * 2);
    }
}

bool FileExists(const std::wstring& path) {
    if (path.empty()) return false;
    DWORD a = GetFileAttributesW(path.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

ULONGLONG FileSize(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return 0;
    return (static_cast<ULONGLONG>(data.nFileSizeHigh) << 32) | data.nFileSizeLow;
}

bool EnsureDir(const std::wstring& path) {
    if (path.empty()) return false;
    DWORD a = GetFileAttributesW(path.c_str());
    if (a != INVALID_FILE_ATTRIBUTES) return (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
    int r = SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
    return r == ERROR_SUCCESS || r == ERROR_ALREADY_EXISTS || r == ERROR_FILE_EXISTS;
}

// ---------------------------------------------------------------------------
// WinHTTP
// ---------------------------------------------------------------------------
static bool HttpGetRaw(const std::wstring& url, std::string& body, std::wstring& err) {
    body.clear();
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    uc.dwHostNameLength = (DWORD)-1;
    uc.dwUrlPathLength = (DWORD)-1;
    uc.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &uc)) {
        err = L"URL 解析失败：" + WinErrorText(GetLastError());
        return false;
    }
    std::wstring host(uc.lpszHostName, uc.dwHostNameLength);
    std::wstring path(uc.lpszUrlPath, uc.dwUrlPathLength);
    if (uc.dwExtraInfoLength && uc.lpszExtraInfo) {
        path.append(uc.lpszExtraInfo, uc.dwExtraInfoLength);
    }

    HINTERNET session = WinHttpOpen(L"ClaudeBootstrapGUI/1.0",
                                    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        session = WinHttpOpen(L"ClaudeBootstrapGUI/1.0",
                              WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    }
    if (!session) {
        err = L"无法初始化 WinHTTP：" + WinErrorText(GetLastError());
        return false;
    }
    WinHttpSetTimeouts(session, 8000, 8000, 20000, 20000);

    HINTERNET connect = WinHttpConnect(session, host.c_str(), (INTERNET_PORT)uc.nPort, 0);
    if (!connect) {
        err = L"无法连接 " + host + L"：" + WinErrorText(GetLastError());
        WinHttpCloseHandle(session);
        return false;
    }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET request = WinHttpOpenRequest(connect, L"GET", path.c_str(), nullptr,
                                           WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request) {
        err = L"无法创建请求：" + WinErrorText(GetLastError());
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return false;
    }

    DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));

    bool ok = WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                 nullptr, 0, 0, 0) &&
              WinHttpReceiveResponse(request, nullptr);
    if (!ok) {
        err = L"请求失败：" + WinErrorText(GetLastError());
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return false;
    }

    DWORD status = 0, statusLen = sizeof(status);
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen, WINHTTP_NO_HEADER_INDEX);

    char buf[8192];
    DWORD read = 0;
    while (WinHttpReadData(request, buf, sizeof(buf), &read) && read > 0) {
        body.append(buf, read);
    }

    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);

    if (status != 200) {
        err = L"HTTP " + std::to_wstring(status);
        return false;
    }
    return true;
}

std::wstring HttpGet(const std::wstring& url, std::wstring& err) {
    std::string body;
    if (!HttpGetRaw(url, body, err)) return L"";
    return Utf8ToWide(body);
}

bool DownloadToFile(const std::wstring& url, const std::wstring& path, std::wstring& err) {
    std::string body;
    if (!HttpGetRaw(url, body, err)) return false;
    if (body.empty()) {
        err = L"下载内容为空";
        return false;
    }
    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        err = L"无法写入文件：" + WinErrorText(GetLastError());
        return false;
    }
    DWORD written = 0;
    BOOL ok = WriteFile(f, body.data(), (DWORD)body.size(), &written, nullptr);
    CloseHandle(f);
    if (!ok || written != body.size()) {
        err = L"文件写入不完整";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tool / process helpers
// ---------------------------------------------------------------------------
std::wstring FindPowerShell() {
    wchar_t found[MAX_PATH];
    if (SearchPathW(nullptr, L"pwsh.exe", nullptr, MAX_PATH, found, nullptr)) {
        return found;
    }
    std::wstring pf = GetEnvVar(L"ProgramFiles");
    std::wstring cand = JoinPath(pf, L"PowerShell\\7\\pwsh.exe");
    if (FileExists(cand)) return cand;
    pf = GetEnvVar(L"ProgramW6432");
    cand = JoinPath(pf, L"PowerShell\\7\\pwsh.exe");
    if (FileExists(cand)) return cand;
    wchar_t sys[MAX_PATH];
    if (GetSystemDirectoryW(sys, MAX_PATH)) {
        cand = JoinPath(sys, L"WindowsPowerShell\\v1.0\\powershell.exe");
        if (FileExists(cand)) return cand;
    }
    return L"powershell.exe";
}

bool RunCapture(const std::wstring& cmdline, DWORD timeoutMs, std::string& out, DWORD& exitCode) {
    out.clear();
    exitCode = 1;

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE readPipe = nullptr, writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) return false;
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

    if (writePipe) CloseHandle(writePipe);
    if (nul && nul != INVALID_HANDLE_VALUE) CloseHandle(nul);

    if (!ok) {
        CloseHandle(readPipe);
        return false;
    }

    DWORD wait = WaitForSingleObject(pi.hProcess, timeoutMs);
    if (wait == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 1000);
    }

    char chunk[2048];
    DWORD got = 0;
    while (ReadFile(readPipe, chunk, sizeof(chunk), &got, nullptr) && got > 0) {
        out.append(chunk, got);
    }
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(readPipe);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}

// ---------------------------------------------------------------------------
// Version helpers
// ---------------------------------------------------------------------------
std::wstring ExtractVersion(const std::wstring& text) {
    for (size_t i = 0; i < text.size();) {
        if (text[i] >= L'0' && text[i] <= L'9') {
            size_t j = i;
            int dots = 0;
            while (j < text.size() && ((text[j] >= L'0' && text[j] <= L'9') || text[j] == L'.')) {
                if (text[j] == L'.') dots++;
                j++;
            }
            if (dots == 2 && j > i && text[j - 1] != L'.') {
                return text.substr(i, j - i);
            }
            i = j;
        } else {
            i++;
        }
    }
    return L"";
}

static bool ParseVersion(const std::wstring& s, int parts[3]) {
    parts[0] = parts[1] = parts[2] = 0;
    std::wstring v = ExtractVersion(s);
    if (v.empty()) return false;
    int idx = 0;
    for (wchar_t ch : v) {
        if (ch == L'.') {
            if (++idx > 2) return false;
        } else if (ch >= L'0' && ch <= L'9') {
            parts[idx] = parts[idx] * 10 + (ch - L'0');
        } else {
            return false;
        }
    }
    return idx == 2;
}

bool IsVersionNewer(const std::wstring& latest, const std::wstring& current) {
    int a[3], b[3];
    if (!ParseVersion(latest, a) || !ParseVersion(current, b)) return false;
    for (int i = 0; i < 3; i++) {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

bool FetchLatestVersion(std::wstring& version, std::wstring& err) {
    const wchar_t* url =
        L"https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819"
        L"/claude-code-releases/latest";
    std::wstring body = HttpGet(url, err);
    if (body.empty()) return false;
    std::wstring v = ExtractVersion(body);
    if (v.empty()) {
        err = L"无法解析最新版本号";
        return false;
    }
    version = v;
    return true;
}

static void AddCandidate(std::vector<std::wstring>& list, const std::wstring& path) {
    if (!path.empty() && FileExists(path)) list.push_back(path);
}

bool DetectInstalledClaude(std::wstring& version, std::wstring& exePath) {
    std::vector<std::wstring> candidates;
    std::wstring home = GetEnvVar(L"USERPROFILE");
    std::wstring local = GetEnvVar(L"LOCALAPPDATA");
    std::wstring roaming = GetEnvVar(L"APPDATA");
    std::wstring pf = GetEnvVar(L"ProgramFiles");
    std::wstring pf86 = GetEnvVar(L"ProgramFiles(x86)");

    AddCandidate(candidates, JoinPath(JoinPath(home, L".local\\bin"), L"claude.exe"));
    AddCandidate(candidates, JoinPath(JoinPath(local, L"Programs\\claude-code"), L"claude.exe"));
    AddCandidate(candidates, JoinPath(JoinPath(local, L"Programs\\Claude Code"), L"claude.exe"));
    AddCandidate(candidates, JoinPath(JoinPath(pf, L"Claude Code"), L"claude.exe"));
    AddCandidate(candidates, JoinPath(JoinPath(pf86, L"Claude Code"), L"claude.exe"));
    AddCandidate(candidates, JoinPath(JoinPath(roaming, L"npm"), L"claude.cmd"));

    // Fall back to a manual PATH scan (GUI may have been started before PATH was updated).
    std::wstring pathEnv = GetEnvVar(L"PATH");
    size_t start = 0;
    while (start < pathEnv.size()) {
        size_t end = pathEnv.find(L';', start);
        if (end == std::wstring::npos) end = pathEnv.size();
        std::wstring dir = pathEnv.substr(start, end - start);
        if (dir.size() >= 2 && dir.front() == L'"' && dir.back() == L'"') {
            dir = dir.substr(1, dir.size() - 2);
        }
        if (!dir.empty()) {
            AddCandidate(candidates, JoinPath(dir, L"claude.exe"));
            AddCandidate(candidates, JoinPath(dir, L"claude.cmd"));
            AddCandidate(candidates, JoinPath(dir, L"claude.bat"));
        }
        start = end + 1;
    }

    for (const auto& exe : candidates) {
        std::wstring cmd = L"cmd.exe /d /s /c \"\"" + exe + L"\" --version\"";
        std::string raw;
        DWORD code = 1;
        if (!RunCapture(cmd, 10000, raw, code)) continue;
        std::wstring text = Utf8ToWide(raw);
        std::wstring v = ExtractVersion(text);
        if (!v.empty()) {
            version = v;
            exePath = exe;
            return true;
        }
    }
    return false;
}