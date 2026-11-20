import Foundation
import WovenProtocol

/// Settings → Bots: profiles, models, bots and teams, containers and memory.
/// Each read and change is one `BotsCall` to the home machine's server.
extension BotsStore {
    // MARK: Profiles and models

    func profiles() async throws -> [PiBotProfile] {
        PiBotProfile.list(try await call("profiles.list", as: BotsWire.ProfilesList.self))
    }

    func modelCatalog() async throws -> PiBotModelCatalog {
        PiBotModelCatalog(try await call("models.catalog", as: BotsWire.ModelCatalog.self))
    }

    /// Returns the profiles after the save.
    func saveProfile(_ draft: PiBotProfileDraft, create: Bool) async throws -> [PiBotProfile] {
        try await changeProfiles("profiles.save", ["profile": draft.wire, "create": .bool(create)])
    }

    func setDefaultProfile(id: String) async throws -> [PiBotProfile] {
        try await changeProfiles("profiles.setDefault", ["profileId": .string(id)])
    }

    func deleteProfile(id: String) async throws -> [PiBotProfile] {
        try await changeProfiles("profiles.delete", ["profileId": .string(id)])
    }

    private func changeProfiles(_ type: String, _ fields: [String: JSONValue]) async throws -> [PiBotProfile] {
        let list = PiBotProfile.list(try await call(type, fields, as: BotsWire.ProfilesList.self))
        await refresh()
        return list
    }

    /// Returns the roles as saved.
    func setRoles(_ roles: PiBotRoles) async throws -> PiBotRoles {
        var fields: [String: JSONValue] = ["titlesReasoning": .string(roles.titlesReasoning)]
        if !roles.titles.isEmpty { fields["titles"] = .string(roles.titles) }
        return PiBotRoles(try await call("models.setRoles", fields, as: BotsWire.RolesResult.self).roles)
    }

    // MARK: Bots and teams

    func deletedBots() async throws -> [PiBotDeletedBot] {
        try await call("bots.listDeleted", as: BotsWire.DeletedBotsList.self).bots.map {
            PiBotDeletedBot(id: $0.id, name: $0.name, deletedAt: BotsDate.parse($0.deletedAt))
        }
    }

    func setOrchestrator(botID: String?) async throws {
        _ = try await call("bots.setOrchestrator", ["botId": botID.map(JSONValue.string) ?? .null])
    }

    func renameBot(id: String, name: String) async throws {
        _ = try await call("bots.rename", ["botId": .string(id), "name": .string(name)])
    }

    func setProfile(botID: String, profileID: String?) async throws {
        _ = try await call("bots.setProfile", ["botId": .string(botID), "profileId": profileID.map(JSONValue.string) ?? .null])
    }

    func setManager(botID: String, manager: Bool) async throws {
        _ = try await call("bots.setManager", ["botId": .string(botID), "manager": .bool(manager)])
    }

    func setTeam(botID: String, managerID: String?) async throws {
        _ = try await call("bots.setTeam", ["botId": .string(botID), "managerId": managerID.map(JSONValue.string) ?? .null])
    }

    func replaceManager(managerID: String, newManagerID: String) async throws {
        _ = try await call("bots.replaceManager", ["managerId": .string(managerID), "newManagerId": .string(newManagerID)])
    }

    func restoreBot(id: String) async throws {
        _ = try await call("bots.restore", ["botId": .string(id)])
    }

    func purgeBot(id: String) async throws -> PiBotPurgeResult {
        let result = try await call("bots.purge", ["botId": .string(id)], as: BotsWire.PurgeResult.self)
        return PiBotPurgeResult(environmentError: result.environment?.error)
    }

    // MARK: Containers

    func environment(botID: String) async throws -> PiBotEnvironment {
        PiBotEnvironment(try await call("bots.environment", ["botId": .string(botID)], as: BotsWire.EnvironmentResult.self).environment)
    }

    func stopBot(id: String) async throws {
        _ = try await call("bots.stop", ["botId": .string(id)])
    }

    func rebuildBot(id: String) async throws {
        _ = try await call("bots.rebuild", ["botId": .string(id)])
    }

    // MARK: Memory

    /// Each call returns the bot's facts after it.
    func memory(botID: String) async throws -> [String] {
        try await facts("memory.list", ["botId": .string(botID)])
    }

    func addMemory(botID: String, text: String) async throws -> [String] {
        try await facts("memory.add", ["botId": .string(botID), "text": .string(text)])
    }

    func updateMemory(botID: String, fact: String, text: String) async throws -> [String] {
        try await facts("memory.update", ["botId": .string(botID), "fact": .string(fact), "text": .string(text)])
    }

    func deleteMemory(botID: String, fact: String) async throws -> [String] {
        try await facts("memory.delete", ["botId": .string(botID), "fact": .string(fact)])
    }

    private func facts(_ type: String, _ fields: [String: JSONValue]) async throws -> [String] {
        try await call(type, fields, as: BotsWire.MemoryList.self).facts
    }
}
