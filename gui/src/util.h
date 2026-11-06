// Claude Code Bootstrap GUI - small Win32 helpers (no external dependencies)
#pragma once

#include <windows.h>
#include <string>

std::wstring Utf8ToWide(const std::string& s);
std::wstring GetEnvVar(const wchar_t* name);
std::wstring JoinPath(const std::wstring& a, const std::wstring& b);
std::wstring ParentDir(const std::wstring& path);
std::wstring ModuleDir();
bool FileExists(const std::wstring& path);
ULONGLONG FileSize(const std::wstring& path);
bool EnsureDir(const std::wstring& path);

// Minimal HTTPS GET (WinHTTP). Returns the raw body, fills `err` on failure.
std::wstring HttpGet(const std::wstring& url, std::wstring& err);
bool DownloadToFile(const std::wstring& url, const std::wstring& path, std::wstring& err);

// Locate pwsh.exe (preferred) or the system Windows PowerShell.
std::wstring FindPowerShell();

// Run a command, capture stdout+stderr as raw bytes (UTF-8 from PowerShell).
bool RunCapture(const std::wstring& cmdline, DWORD timeoutMs, std::string& out, DWORD& exitCode);

// Version helpers
std::wstring ExtractVersion(const std::wstring& text);
bool IsVersionNewer(const std::wstring& latest, const std::wstring& current);
bool FetchLatestVersion(std::wstring& version, std::wstring& err);
bool DetectInstalledClaude(std::wstring& version, std::wstring& exePath);