#pragma once
#include <filesystem>
#include <string>
#include <optional>

// Returns true if GameData is available (already present or wizard completed extraction).
// If false, the caller should exit gracefully (user cancelled or fatal error).
bool EnsureGameDataAvailable();
std::optional<std::filesystem::path> PromptForIsoPath();
bool IsValidMkwiiDump(const std::filesystem::path& isoPath, std::string& outGameId, std::string& outDetails);
bool ExtractIsoToGameData(const std::filesystem::path& isoPath, const std::filesystem::path& gameDataRoot, std::string& error);
bool IsDvdDataRootPath(const std::filesystem::path& p);
std::filesystem::path DefaultGameDataPath();
