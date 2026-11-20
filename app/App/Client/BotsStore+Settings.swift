import Foundation

/// Settings → Bots: profiles, models, bots and teams, containers and memory.
/// Each read and change is one request to the home machine's server.
extension BotsStore {
    // MARK: Profiles and models

    func profiles() async throws -> [PiBotProfile] { throw ClientError.notConnected }
    func modelCatalog() async throws -> PiBotModelCatalog { throw ClientError.notConnected }
    /// Returns the profiles after the save.
    func saveProfile(_ draft: PiBotProfileDraft, create: Bool) async throws -> [PiBotProfile] { throw ClientError.notConnected }
    func setDefaultProfile(id: String) async throws -> [PiBotProfile] { throw ClientError.notConnected }
    func deleteProfile(id: String) async throws -> [PiBotProfile] { throw ClientError.notConnected }
    /// Returns the roles as saved.
    func setRoles(_ roles: PiBotRoles) async throws -> PiBotRoles { throw ClientError.notConnected }

    // MARK: Bots and teams

    func deletedBots() async throws -> [PiBotDeletedBot] { throw ClientError.notConnected }
    func setOrchestrator(botID: String?) async throws { throw ClientError.notConnected }
    func renameBot(id: String, name: String) async throws { throw ClientError.notConnected }
    func setProfile(botID: String, profileID: String?) async throws { throw ClientError.notConnected }
    func setManager(botID: String, manager: Bool) async throws { throw ClientError.notConnected }
    func setTeam(botID: String, managerID: String?) async throws { throw ClientError.notConnected }
    func replaceManager(managerID: String, newManagerID: String) async throws { throw ClientError.notConnected }
    func restoreBot(id: String) async throws { throw ClientError.notConnected }
    func purgeBot(id: String) async throws -> PiBotPurgeResult { throw ClientError.notConnected }

    // MARK: Containers

    func environment(botID: String) async throws -> PiBotEnvironment { throw ClientError.notConnected }
    func stopBot(id: String) async throws { throw ClientError.notConnected }
    func rebuildBot(id: String) async throws { throw ClientError.notConnected }
    func stopPreview(botID: String, port: Int) async throws { throw ClientError.notConnected }

    // MARK: Memory

    /// Each call returns the bot's facts after it.
    func memory(botID: String) async throws -> [String] { throw ClientError.notConnected }
    func addMemory(botID: String, text: String) async throws -> [String] { throw ClientError.notConnected }
    func updateMemory(botID: String, fact: String, text: String) async throws -> [String] { throw ClientError.notConnected }
    func deleteMemory(botID: String, fact: String) async throws -> [String] { throw ClientError.notConnected }
}
