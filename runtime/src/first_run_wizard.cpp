#include "first_run_wizard.h"
#include "runtime_config.h"
#include "runtime_log.h"
#include <cstdlib>
#include <cstdio>
#include <iostream>
#include <fstream>
#include <array>
#include <algorithm>
#include <cctype>
#include <thread>
#include <chrono>
#ifndef _WIN32
#include <sys/wait.h>
#include <unistd.h>
#else
#include <io.h>
#define access _access
#define X_OK 0
#define popen _popen
#define pclose _pclose
#endif

namespace fs = std::filesystem;

bool IsDvdDataRootPath(const fs::path& p) {
    std::error_code ec;
    return fs::is_directory(p, ec) && fs::is_directory(p / "files", ec) && fs::is_regular_file(p / "sys" / "fst.bin", ec);
}

fs::path DefaultGameDataPath() {
    // Prefer portable location: <PortableRoot>/GameData if portable, else <AppData>/GameData
    if (auto root = RuntimeConfigFile::PortableRootDirectory()) {
        return *root / "GameData";
    }
    // If exe dir is writable and no portable marker yet, we will create portable structure there
    // Check if we can create portable marker
    if (auto exeDir = RuntimeConfigFile::ExecutableDirectory()) {
        std::error_code ec;
        // heuristic: if exeDir is not /usr/bin and writable, use portable GameData beside exe
        auto testFile = *exeDir / ".wii_write_test";
        std::ofstream t(testFile); bool writable = t.good(); t.close(); if (writable) fs::remove(testFile, ec);
        if (writable && exeDir->string().find("/usr") != 0) {
            // create portable structure
            fs::create_directories(*exeDir / RuntimeConfigFile::kPortableUserDataDirectoryName, ec);
            auto marker = *exeDir / RuntimeConfigFile::kPortableMarkerFileName;
            if (!fs::exists(marker, ec)) {
                std::ofstream m(marker); if (m) m << "Portable WiiCompiled installation\n";
            }
            // Re-evaluate via ApplicationDataDirectory after marker creation
            // Note PortableRootDirectory is cached; we just return exeDir/GameData
            return *exeDir / "GameData";
        }
    }
    return RuntimeConfigFile::ApplicationDataDirectory() / "GameData";
}

static std::string TrimLower(std::string s){
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [](unsigned char ch){return !std::isspace(ch);} ));
    s.erase(std::find_if(s.rbegin(), s.rend(), [](unsigned char ch){return !std::isspace(ch);} ).base(), s.end());
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return std::tolower(c); });
    return s;
}

static std::optional<fs::path> TryZenityDialog() {
#ifndef _WIN32
    if (std::system("which zenity > /dev/null 2>&1") != 0) return std::nullopt;
    std::array<char, 4096> buf{};
    std::string cmd = "zenity --file-selection --title=\"Select Mario Kart Wii ISO (RMCP01/RMCE01)\" --file-filter=\"Wii disc | *.iso *.wbfs *.gcm *.rvz *.wia *.ciso *.gcz\" 2>/dev/null";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return std::nullopt;
    std::string out;
    while (fgets(buf.data(), buf.size(), pipe)) out += buf.data();
    int rc = pclose(pipe);
    // trim preserving case
    size_t b=0; while(b<out.size() && std::isspace((unsigned char)out[b])) ++b;
    size_t e=out.size(); while(e>b && std::isspace((unsigned char)out[e-1])) --e;
    out = out.substr(b,e-b);
    if (out.empty() || rc != 0) return std::nullopt;
    return fs::path(out);
#else
    return std::nullopt;
#endif
}

static std::optional<fs::path> TryKDialog() {
#ifndef _WIN32
    if (std::system("which kdialog > /dev/null 2>&1") != 0) return std::nullopt;
    std::array<char, 4096> buf{};
    std::string cmd = "kdialog --getopenfilename \"$HOME\" \"*.iso *.wbfs *.gcm *.rvz *.wia *.ciso *.gcz | Wii disc\" 2>/dev/null";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return std::nullopt;
    std::string out; while(fgets(buf.data(), buf.size(), pipe)) out+=buf.data();
    pclose(pipe);
    size_t b=0; while(b<out.size() && std::isspace((unsigned char)out[b])) ++b;
    size_t e=out.size(); while(e>b && std::isspace((unsigned char)out[e-1])) --e;
    out = out.substr(b,e-b);
    if (out.empty()) return std::nullopt;
    return fs::path(out);
#else
    return std::nullopt;
#endif
}

static std::optional<fs::path> TryXdgOpenDialog() {
    // fallback console
    return std::nullopt;
}

std::optional<fs::path> PromptForIsoPath() {
    // Try GUI dialogs first, fallback to console stdin
    if (auto p = TryZenityDialog()) return p;
    if (auto p = TryKDialog()) return p;

    // Check if we have a display - if not, fallback to console
    std::cout << "\n[WiiCompiled] No GameData found. Please enter the full path to your clean Mario Kart Wii ISO/WBFS:\n";
    std::cout << "Supported: .iso .wbfs .gcm .rvz .wia .ciso .gcz (RMCP01 PAL, RMCE01 NTSC-U, RMCJ01, RMCK01)\n";
    std::cout << "Path: " << std::flush;
    std::string line;
    if (!std::getline(std::cin, line)) return std::nullopt;
    size_t b=0; while(b<line.size() && std::isspace((unsigned char)line[b])) ++b;
    size_t e=line.size(); while(e>b && std::isspace((unsigned char)line[e-1])) ++e;
    line = line.substr(b,e-b);
    // strip quotes
    if (line.size()>=2 && ((line.front()=='"'&&line.back()=='"')||(line.front()=='\''&&line.back()=='\''))) line=line.substr(1,line.size()-2);
    if (line.empty()) return std::nullopt;
    return fs::path(line);
}

bool IsValidMkwiiDump(const fs::path& isoPath, std::string& outGameId, std::string& outDetails) {
    std::error_code ec;
    if (!fs::exists(isoPath, ec) || !fs::is_regular_file(isoPath, ec)) {
        outDetails = "File does not exist or not a regular file: " + isoPath.string();
        return false;
    }
    auto sz = fs::file_size(isoPath, ec);
    if (ec || sz < 0x100) {
        outDetails = "File too small to be a Wii dump";
        return false;
    }
    std::ifstream f(isoPath, std::ios::binary);
    if (!f) { outDetails = "Unable to open file for reading"; return false; }
    // Wii disc header: offset 0x00 GameID 6 bytes, 0x18 magic 0x5D1C9EA3, 0x1C maybe?
    char header[0x100]={};
    f.read(header, sizeof(header));
    if (f.gcount() < 0x20) { outDetails="Failed to read disc header"; return false; }
    std::string gameId(header, header+6);
    // Trim nul/padding
    gameId.erase(std::find(gameId.begin(), gameId.end(), '\0'), gameId.end());
    // Check GameID against known MKWii IDs
    static const std::array<std::string,4> kValid = {"RMCP01","RMCE01","RMCJ01","RMCK01"};
    bool ok = std::find(kValid.begin(), kValid.end(), gameId) != kValid.end();
    outGameId = gameId;
    if (!ok) {
        outDetails = "This disc is '" + gameId + "', not a Mario Kart Wii dump (expected RMCP01/RMCE01/RMCJ01/RMCK01)";
        return false;
    }
    // Check magic at 0x18
    uint32_t magic = (static_cast<uint8_t>(header[0x18])<<24) | (static_cast<uint8_t>(header[0x19])<<16) | (static_cast<uint8_t>(header[0x1A])<<8) | static_cast<uint8_t>(header[0x1B]);
    if (magic != 0x5D1C9EA3u) {
        outDetails = "Disc header magic mismatch (expected 0x5D1C9EA3, got 0x" + std::to_string(magic) + ") - not a valid Wii dump";
        return false;
    }
    // Additional quick check: file size plausible (4.7GB for ISO, <2GB for WBFS? but allow)
    // Don't enforce strict size because WBFS/RVZ are compressed.
    outDetails = "Valid " + gameId + " dump";
    return true;
}

static std::optional<fs::path> FindTool(const std::string& name) {
    std::vector<fs::path> tryPaths;
    if (auto exe = RuntimeConfigFile::ExecutableDirectory()) {
        tryPaths.push_back(*exe / name);
#ifdef _WIN32
        tryPaths.push_back(*exe / (name + ".exe"));
#endif
        tryPaths.push_back(*exe / "tools" / name);
        tryPaths.push_back((*exe).parent_path() / name);
    }
    tryPaths.push_back(fs::path("/usr/bin") / name);
    tryPaths.push_back(fs::path("/usr/local/bin") / name);
    for (auto &p: tryPaths) {
        std::error_code ec; if (fs::exists(p, ec) && fs::is_regular_file(p, ec)) {
#ifndef _WIN32
            if (access(p.c_str(), X_OK)==0) return p;
#else
            return p;
#endif
        }
    }
#ifndef _WIN32
    std::string cmd = "which " + name + " 2>/dev/null";
    std::array<char,1024> buf{};
    FILE* pipe = popen(cmd.c_str(), "r");
    if (pipe) {
        std::string out; while(fgets(buf.data(), buf.size(), pipe)) out+=buf.data();
        pclose(pipe);
        size_t b=0; while(b<out.size() && std::isspace((unsigned char)out[b])) ++b;
        size_t e=out.size(); while(e>b && std::isspace((unsigned char)out[e-1])) --e;
        out=out.substr(b,e-b);
        if (!out.empty()) return fs::path(out);
    }
#endif
    return std::nullopt;
}

static bool RunCommand(const std::string& cmd, std::string* out=nullptr) {
    std::array<char,4096> buf{};
    FILE* pipe = popen((cmd + " 2>&1").c_str(), "r");
    if (!pipe) return false;
    std::string collected;
    while (fgets(buf.data(), buf.size(), pipe)) collected+=buf.data();
    int rc = pclose(pipe);
    if (out) *out = collected;
#ifndef _WIN32
    if (WIFEXITED(rc)) return WEXITSTATUS(rc)==0;
#endif
    return rc==0;
}

bool ExtractIsoToGameData(const fs::path& isoPath, const fs::path& gameDataRoot, std::string& error) {
    std::error_code ec;
    fs::create_directories(gameDataRoot, ec);
    // Try nodtool first (encounter/nod v2)
    if (auto nod = FindTool("nodtool")) {
        std::cout << "[wizard] Using nodtool: " << nod->string() << std::endl;
        std::string cmd = "\"" + nod->string() + "\" extract \"" + isoPath.string() + "\" \"" + gameDataRoot.string() + "\" -q";
        std::cout << "[wizard] Running: " << cmd << std::endl;
        std::string out;
        bool ok = RunCommand(cmd, &out);
        std::cout << out << std::endl;
        if (ok && IsDvdDataRootPath(gameDataRoot)) return true;
        // nodtool may have created subdirectory DATA inside gameDataRoot? Check
        if (fs::exists(gameDataRoot / "DATA" / "sys" / "fst.bin", ec)) {
            // Move DATA/* to gameDataRoot
            for (auto &e : fs::directory_iterator(gameDataRoot / "DATA", ec)) {
                fs::rename(e.path(), gameDataRoot / e.path().filename(), ec);
            }
            fs::remove(gameDataRoot / "DATA", ec);
            if (IsDvdDataRootPath(gameDataRoot)) return true;
        }
        error = "nodtool failed: " + out;
        // fall through to wit
    }
    if (auto wit = FindTool("wit")) {
        std::cout << "[wizard] Using wit: " << wit->string() << std::endl;
        // wit EXTRACT <iso> <out> --psel DATA -q?
        // wit needs output dir empty? It creates <out>/DATA
        std::string cmd = "\"" + wit->string() + "\" EXTRACT \"" + isoPath.string() + "\" \"" + (gameDataRoot / "wit_tmp").string() + "\" --psel DATA --flat -q 2>&1";
        // Alternative simple: wit EXTRACT <iso> <tmp> -D
        cmd = "\"" + wit->string() + "\" EXTRACT \"" + isoPath.string() + "\" \"" + (gameDataRoot.string() + "_wit") + "\" -q";
        std::cout << "[wizard] Running: " << cmd << std::endl;
        std::string out; bool ok = RunCommand(cmd, &out);
        std::cout << out << std::endl;
        // Find extracted DATA
        fs::path witOut = gameDataRoot.string() + "_wit";
        if (fs::exists(witOut / "DATA" / "sys" / "fst.bin", ec)) {
            for (auto &e : fs::directory_iterator(witOut / "DATA", ec)) {
                fs::rename(e.path(), gameDataRoot / e.path().filename(), ec);
            }
            fs::remove_all(witOut, ec);
            if (IsDvdDataRootPath(gameDataRoot)) return true;
        } else if (fs::exists(witOut / "sys" / "fst.bin", ec)) {
            for (auto &e : fs::directory_iterator(witOut, ec)) {
                fs::rename(e.path(), gameDataRoot / e.path().filename(), ec);
            }
            fs::remove_all(witOut, ec);
            if (IsDvdDataRootPath(gameDataRoot)) return true;
        }
        error = "wit failed: " + out;
    }
    // If no tool, provide instructions
    error = "No extractor found (nodtool/wit). Please install 'wit' or place 'nodtool' beside the executable, or manually extract with: wit EXTRACT <iso> ./GameData --psel DATA";
    // List found?
    std::cout << "[wizard] " << error << std::endl;
    return false;
}

bool EnsureGameDataAvailable() {
    RuntimeConfigFile::EnsureConfigFile();
    auto configured = RuntimeConfigFile::ResolvedDvdRoot();
    if (!configured.empty() && IsDvdDataRootPath(configured)) {
        std::cout << "[wizard] GameData found: " << configured << std::endl;
        return true;
    }
    // Try default GameData path (portable GameData)
    auto defaultPath = DefaultGameDataPath();
    if (IsDvdDataRootPath(defaultPath)) {
        std::cout << "[wizard] Found default GameData at " << defaultPath << " - configuring" << std::endl;
        // Set dvd_root relative if possible
        std::string rel;
        auto configDir = RuntimeConfigFile::ResolveConfigPath().parent_path();
        std::error_code ec;
        auto relPath = fs::relative(defaultPath, configDir, ec);
        std::string value;
        if (!ec && !relPath.empty() && relPath.string().find("..") != 0) {
            value = relPath.string();
        } else {
            value = defaultPath.string();
        }
        // Write to config
        RuntimeConfigFile::WriteSetting("paths","dvd_root", RuntimeConfigFile::FormatString(value));
        // Update in-memory
        RuntimeConfigFile::Mutable().dvdRoot = value;
        return true;
    }
    // Also try common locations: ./GameData, ../GameData, ./Assets/DATA, etc.
    std::vector<fs::path> search;
    if (auto exe = RuntimeConfigFile::ExecutableDirectory()) {
        search.push_back(*exe / "GameData");
        search.push_back(*exe / "DATA");
        search.push_back(exe->parent_path() / "GameData");
        search.push_back(fs::current_path() / "GameData");
    }
    search.push_back(RuntimeConfigFile::ApplicationDataDirectory() / "GameData");
    for (auto &p: search) {
        if (IsDvdDataRootPath(p)) {
            std::cout << "[wizard] Found GameData at " << p << std::endl;
            auto configDir = RuntimeConfigFile::ResolveConfigPath().parent_path();
            std::error_code ec;
            auto relPath = fs::relative(p, configDir, ec);
            std::string value = (!ec && !relPath.empty()) ? relPath.string() : p.string();
            RuntimeConfigFile::WriteSetting("paths","dvd_root", RuntimeConfigFile::FormatString(value));
            RuntimeConfigFile::Mutable().dvdRoot = value;
            return true;
        }
    }

    std::cout << "\n========================================\n";
    std::cout << " WiiCompiled - First Run Setup\n";
    std::cout << "========================================\n";
    std::cout << "No GameData found. A clean Mario Kart Wii dump is required.\n";
    std::cout << "Place your ISO/WBFS next to the executable or select it now.\n";

    // Ensure portable UserData exists
    auto userPath = RuntimeConfigFile::ApplicationDataDirectory();
    std::error_code ec; fs::create_directories(userPath, ec);
    // Ensure config exists (already)
    for (int attempt=0; attempt<3; ++attempt) {
        auto isoOpt = PromptForIsoPath();
        if (!isoOpt) {
            std::cout << "[wizard] No file selected. Cancelled.\n";
            return false;
        }
        std::string gameId, details;
        if (!IsValidMkwiiDump(*isoOpt, gameId, details)) {
            std::cout << "[wizard] Invalid dump: " << details << "\n";
            std::cout << "Please select a valid Mario Kart Wii dump (RMCP01 Pal, RMCE01 NTSC-U, etc.)\n";
            continue;
        }
        std::cout << "[wizard] Valid dump detected: " << details << " (" << isoOpt->string() << ")\n";
        std::cout << "[wizard] Extracting to " << defaultPath << " ...\n";
        std::string err;
        if (ExtractIsoToGameData(*isoOpt, defaultPath, err)) {
            std::cout << "[wizard] Extraction successful!\n";
            // Verify
            if (!IsDvdDataRootPath(defaultPath)) {
                std::cout << "[wizard] Extraction completed but GameData invalid at " << defaultPath << "\n";
                return false;
            }
            // Write config
            auto configDir = RuntimeConfigFile::ResolveConfigPath().parent_path();
            auto relPath = fs::relative(defaultPath, configDir, ec);
            std::string value = (!ec && !relPath.empty()) ? relPath.string() : defaultPath.string();
            // Prefer relative if inside portable root
            if (value.find("..")==0) value = defaultPath.string();
            // Normalize to forward slashes
            std::replace(value.begin(), value.end(), '\\', '/');
            RuntimeConfigFile::WriteSetting("paths","dvd_root", RuntimeConfigFile::FormatString(value));
            RuntimeConfigFile::Mutable().dvdRoot = value;
            std::cout << "[wizard] Configured dvd_root = " << value << std::endl;
            std::cout << "[wizard] Setup complete, starting game...\n";
            return true;
        } else {
            std::cout << "[wizard] Extraction failed: " << err << "\n";
            std::cout << "Please manually extract and set [paths] dvd_root in " << RuntimeConfigFile::ResolveConfigPath() << "\n";
            return false;
        }
    }
    return false;
}
