// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
//
// Standalone HSR XXMI hook-runner. It installs 3dmloader's global CBT hook,
// starts MacGacha's already-resolved StarRail command, verifies the exact game
// image and payload module, and keeps the hook armed until the game window is
// visible. See compat/xxmi/README.md for provenance and build inputs.

#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <wchar.h>

typedef int (__cdecl *hook_fn)(LPCWSTR, HHOOK *, HANDLE *);
typedef int (__cdecl *wait_fn)(LPCWSTR, LPCWSTR, int);
typedef int (__cdecl *unhook_fn)(HHOOK *, HANDLE *);
static wchar_t command[32768];

#undef memset
void *memset(void *destination, int value, size_t count)
{
    unsigned char *bytes = destination;
    for (size_t i = 0; i < count; ++i) bytes[i] = (unsigned char)value;
    return destination;
}

static void say(const wchar_t *message)
{
    char line[512];
    int length = WideCharToMultiByte(CP_UTF8, 0, message, -1, line, sizeof(line) - 2, NULL, NULL);
    DWORD written = 0;
    HANDLE output = GetStdHandle(STD_ERROR_HANDLE);
    if (length <= 1 || output == INVALID_HANDLE_VALUE || output == NULL) return;
    line[length - 1] = '\n';
    line[length] = '\0';
    WriteFile(output, line, (DWORD)length, &written, NULL);
}

static BOOL append_argument(wchar_t *buffer, size_t capacity, size_t *used, const wchar_t *argument)
{
    size_t slashes = 0;
    if (*used) {
        if (*used + 1 >= capacity) return FALSE;
        buffer[(*used)++] = L' ';
    }
    if (*used + 1 >= capacity) return FALSE;
    buffer[(*used)++] = L'"';
    for (const wchar_t *p = argument; ; ++p) {
        if (*p == L'\\') { ++slashes; continue; }
        if (*p == L'"') {
            while (slashes > 0) {
                if (*used + 1 >= capacity) return FALSE;
                buffer[(*used)++] = L'\\';
                --slashes;
            }
            slashes = 0;
            if (*used + 2 >= capacity) return FALSE;
            buffer[(*used)++] = L'\\';
            buffer[(*used)++] = L'"';
            continue;
        }
        if (*p == L'\0') {
            while (slashes > 0) {
                if (*used + 2 >= capacity) return FALSE;
                buffer[(*used)++] = L'\\';
                buffer[(*used)++] = L'\\';
                --slashes;
            }
            if (*used + 1 >= capacity) return FALSE;
            buffer[(*used)++] = L'"';
            buffer[*used] = L'\0';
            return TRUE;
        }
        while (slashes > 0) {
            if (*used + 1 >= capacity) return FALSE;
            buffer[(*used)++] = L'\\';
            --slashes;
        }
        slashes = 0;
        if (*used + 1 >= capacity) return FALSE;
        buffer[(*used)++] = *p;
    }
}

static BOOL is_target_path(const wchar_t *candidate)
{
    const wchar_t suffix[] = L"\\StarRail.exe";
    size_t n = 0;
    while (candidate[n]) ++n;
    return n >= ARRAYSIZE(suffix) - 1 && CompareStringOrdinal(candidate + n - (ARRAYSIZE(suffix) - 1),
        (int)(ARRAYSIZE(suffix) - 1), suffix, -1, TRUE) == CSTR_EQUAL;
}

static BOOL find_target_argument(LPWSTR *argv, int first, int argc, const wchar_t **target)
{
    for (int i = first; i < argc; ++i) {
        if (is_target_path(argv[i])) { *target = argv[i]; return TRUE; }
    }
    return FALSE;
}

static BOOL target_already_running(void)
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W entry;
    BOOL found = FALSE;
    if (snapshot == INVALID_HANDLE_VALUE) return TRUE;
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (lstrcmpiW(entry.szExeFile, L"StarRail.exe") == 0) { found = TRUE; break; }
        } while (Process32NextW(snapshot, &entry));
    } else found = TRUE;
    CloseHandle(snapshot);
    return found;
}

static BOOL verify_target_modules(const wchar_t *target_path, const wchar_t *payload_path)
{
    HANDLE processes = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W process;
    BOOL verified = FALSE;
    if (processes == INVALID_HANDLE_VALUE) return FALSE;
    process.dwSize = sizeof(process);
    if (Process32FirstW(processes, &process)) {
        do {
            HANDLE modules;
            MODULEENTRY32W module;
            BOOL image_match = FALSE, payload_match = FALSE;
            if (lstrcmpiW(process.szExeFile, L"StarRail.exe") != 0) continue;
            modules = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, process.th32ProcessID);
            if (modules == INVALID_HANDLE_VALUE) continue;
            module.dwSize = sizeof(module);
            if (Module32FirstW(modules, &module)) {
                do {
                    if (lstrcmpiW(module.szExePath, target_path) == 0) image_match = TRUE;
                    if (lstrcmpiW(module.szExePath, payload_path) == 0) payload_match = TRUE;
                } while (Module32NextW(modules, &module));
            }
            CloseHandle(modules);
            if (image_match && payload_match) { verified = TRUE; break; }
        } while (Process32NextW(processes, &process));
    }
    CloseHandle(processes);
    return verified;
}

static void report_loaded_payload_module(const wchar_t *expected_path)
{
    HANDLE modules = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    MODULEENTRY32W module;
    if (modules == INVALID_HANDLE_VALUE) {
        say(L"could not enumerate loaded modules after HookLibrary failure");
        return;
    }
    module.dwSize = sizeof(module);
    if (Module32FirstW(modules, &module)) {
        do {
            if (lstrcmpiW(module.szModule, L"d3d11.dll") == 0 ||
                lstrcmpiW(module.szExePath, expected_path) == 0) {
                wchar_t message[600];
                FARPROC callback = GetProcAddress(module.hModule, "CBTProc");
                wsprintfW(message, L"loaded hook candidate path=%s expected_path_match=%s CBTProc=%s",
                    module.szExePath, lstrcmpiW(module.szExePath, expected_path) == 0 ? L"yes" : L"no",
                    callback ? L"present" : L"missing");
                say(message);
            }
        } while (Module32NextW(modules, &module));
    }
    CloseHandle(modules);
}

typedef struct {
    DWORD process_id;
    BOOL visible_window;
} window_probe;

static BOOL CALLBACK find_visible_process_window(HWND window, LPARAM parameter)
{
    window_probe *probe = (window_probe *)parameter;
    DWORD process_id = 0;
    GetWindowThreadProcessId(window, &process_id);
    if (process_id == probe->process_id && IsWindowVisible(window) && GetWindow(window, GW_OWNER) == NULL) {
        probe->visible_window = TRUE;
        return FALSE;
    }
    return TRUE;
}

static BOOL process_has_visible_window(DWORD process_id)
{
    window_probe probe = { process_id, FALSE };
    EnumWindows(find_visible_process_window, (LPARAM)&probe);
    return probe.visible_window;
}

// Match XXMI's launch lifecycle: keep its global CBT hook installed until the
// injected game process has a visible window, allowing a bootstrap process to
// respawn the real game before the hook is removed. The bounded timeout mirrors
// XXMI's default process/window startup timeout.
static BOOL wait_for_target_window(const wchar_t *target_path, const wchar_t *payload_path, DWORD timeout_ms)
{
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    do {
        HANDLE processes = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (processes != INVALID_HANDLE_VALUE) {
            PROCESSENTRY32W process;
            process.dwSize = sizeof(process);
            if (Process32FirstW(processes, &process)) {
                do {
                    HANDLE modules;
                    MODULEENTRY32W module;
                    BOOL image_match = FALSE, payload_match = FALSE;
                    if (lstrcmpiW(process.szExeFile, L"StarRail.exe") != 0) continue;
                    modules = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32,
                        process.th32ProcessID);
                    if (modules == INVALID_HANDLE_VALUE) continue;
                    module.dwSize = sizeof(module);
                    if (Module32FirstW(modules, &module)) {
                        do {
                            if (lstrcmpiW(module.szExePath, target_path) == 0) image_match = TRUE;
                            if (lstrcmpiW(module.szExePath, payload_path) == 0) payload_match = TRUE;
                        } while (Module32NextW(modules, &module));
                    }
                    CloseHandle(modules);
                    if (image_match && payload_match && process_has_visible_window(process.th32ProcessID)) {
                        CloseHandle(processes);
                        return TRUE;
                    }
                } while (Process32NextW(processes, &process));
            }
            CloseHandle(processes);
        }
        Sleep(250);
    } while (GetTickCount64() < deadline);
    return FALSE;
}

void srmi_hook_launcher_entry(void)
{
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    HMODULE loader;
    HHOOK hook = NULL;
    HANDLE mutex = NULL;
    PROCESS_INFORMATION child = {0};
    STARTUPINFOW startup = {0};
    hook_fn install_hook;
    wait_fn wait_for_injection;
    unhook_fn remove_hook;
    const wchar_t *target = NULL;
    size_t used = 0;
    BOOL created = FALSE, captured = FALSE;
    DWORD child_exit = 1;
    int hook_result;
    DWORD hook_error;

    if (!argv || argc < 8 || lstrcmpiW(argv[1], L"--loader") != 0 ||
        lstrcmpiW(argv[3], L"--payload") != 0 || lstrcmpiW(argv[5], L"--") != 0 ||
        !find_target_argument(argv, 6, argc, &target) || target_already_running()) {
        say(L"invalid command or StarRail.exe is already running; refusing to continue");
        goto done;
    }
    loader = LoadLibraryW(argv[2]);
    if (!loader) { say(L"could not load 3dmloader.dll"); goto done; }
    install_hook = (hook_fn)GetProcAddress(loader, "HookLibrary");
    wait_for_injection = (wait_fn)GetProcAddress(loader, "WaitForInjection");
    remove_hook = (unhook_fn)GetProcAddress(loader, "UnhookLibrary");
    if (!install_hook || !wait_for_injection || !remove_hook) {
        say(L"required injector exports are missing"); FreeLibrary(loader); goto done;
    }
    SetLastError(ERROR_SUCCESS);
    hook_result = install_hook(argv[4], &hook, &mutex);
    hook_error = GetLastError();
    if (hook_result != 0 || hook == NULL) {
        wchar_t message[192];
        wsprintfW(message, L"HookLibrary failed: result=%d last_error=%lu hook=%s mutex=%s; game was not started",
            hook_result, hook_error, hook ? L"set" : L"null", mutex ? L"set" : L"null");
        say(message);
        report_loaded_payload_module(argv[4]);
        FreeLibrary(loader);
        goto done;
    }
    if (!append_argument(command, ARRAYSIZE(command), &used, argv[6])) {
        say(L"game command line is too long"); remove_hook(&hook, &mutex); FreeLibrary(loader); goto done;
    }
    for (int i = 7; i < argc; ++i) {
        if (!append_argument(command, ARRAYSIZE(command), &used, argv[i])) {
            say(L"game command line is too long"); remove_hook(&hook, &mutex); FreeLibrary(loader); goto done;
        }
    }
    startup.cb = sizeof(startup);
    if (!CreateProcessW(argv[6], command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) {
        say(L"CreateProcessW failed after HookLibrary armed"); remove_hook(&hook, &mutex); FreeLibrary(loader); goto done;
    }
    created = TRUE;
    say(L"HookLibrary armed; MacGacha's resolved game command was started");
    captured = wait_for_injection(argv[4], L"StarRail.exe", 600) == 0 && verify_target_modules(target, argv[4]);
    if (captured) {
        say(L"exact StarRail.exe path and SRMI payload module verified");
        say(L"keeping HookLibrary armed until the injected game window is ready or 30 seconds elapse");
        if (wait_for_target_window(target, argv[4], 30000))
            say(L"injected StarRail.exe has a visible game window");
        else
            say(L"game window did not become ready before timeout; removing HookLibrary");
    }
    else say(L"capture was not verified; leaving the launched game under MacGacha supervision");
    if (remove_hook(&hook, &mutex) != 0) say(L"UnhookLibrary reported a cleanup failure");
    FreeLibrary(loader);
    WaitForSingleObject(child.hProcess, INFINITE);
    if (!GetExitCodeProcess(child.hProcess, &child_exit)) child_exit = 1;
    CloseHandle(child.hThread); CloseHandle(child.hProcess);

done:
    if (argv) LocalFree(argv);
    if (!created) ExitProcess(1);
    ExitProcess(captured ? child_exit : 21);
}
