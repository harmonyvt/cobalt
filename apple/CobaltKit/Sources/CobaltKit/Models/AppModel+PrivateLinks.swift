import Foundation

// A file's link, three ways (APP-API-CONTRACT 36.2, 36.6): off, public, private. Public and off go through the section 16
// switch (`setVisibility`); private is `PUT /share/private/items/<id>`, which turns the public link off first. The
// library's file carries the answer (`privateURL`, no public `url`) and the links store keeps the link's numbers.
extension AppModel {
    /// The rendition offers the three-way choice: the server has private links and the switch, and takes this file.
    public func canChoosePrivateLink(_ rendition: Rendition) -> Bool {
        capabilities.privateLinks && capabilities.visibility && rendition.file?.canToggleVisibility == true
    }

    /// The rendition's link as the library has it now.
    public func fileLink(of rendition: Rendition) -> FileLink {
        guard let id = rendition.file?.id, let file = library.file(id: id) else { return rendition.fileLink }
        return file.linkState
    }

    /// The live private link URL of a rendition's file as the library has it now.
    public func privateURL(of rendition: Rendition) -> URL? {
        guard let id = rendition.file?.id, let file = library.file(id: id) else { return rendition.privateURL }
        return file.privateURL
    }

    /// The live private link of a rendition's file with its numbers (opened, when its key was made), once the links
    /// store has listed it; nil otherwise.
    public func privateLink(of rendition: Rendition) -> PrivateLink? {
        guard let id = rendition.file?.id else { return nil }
        return shareSets.privateLink(forItem: id)
    }

    /// The public gallery links this rendition's file is in (the ones it drops out of when it goes private).
    public func publicSets(containing rendition: Rendition) -> [ShareSet] {
        guard let id = rendition.file?.id else { return [] }
        return shareSets.publicSets(containing: id)
    }

    /// Moves a rendition's link to `target`. Private answers the live link (the caller copies it); public and off
    /// answer nil. `alsoMakePrivate` (only with `.private`): gallery link ids made private too once the file is (36.6
    /// "make those links private too"); a failure among them is not the file's failure, so it is ignored here and the
    /// links tab shows them as they are. One request per file at a time, like `setVisibility`. Throws `.unsupported`
    /// without the capability or for a file the server does not take, `PrivateLinkError` for the private routes'
    /// refusals, and the mapped failure otherwise; the file is put back then.
    @discardableResult
    public func setFileLink(_ rendition: Rendition, to target: FileLink, alsoMakePrivate setIDs: [String] = []) async throws -> PrivateLink? {
        guard canChoosePrivateLink(rendition), let listed = rendition.file else { throw PipelineFailure.unsupported }
        let current = library.file(id: listed.id) ?? listed
        if current.linkState == target { return target == .private ? shareSets.privateLink(forItem: listed.id) : nil }
        switch target {
        case .private:
            let link = try await turnOnPrivateLink(rendition, current)
            for id in setIDs { _ = try? await shareSets.makePrivate(id) }
            return link
        case .public:
            // the section 16 route makes it public and revokes the private link (36.2)
            try await setVisibility(rendition, public: true)
            clearPrivateURL(listed.id)
            return nil
        case .off:
            if current.privateURL != nil {
                try await revokePrivateLink(rendition, current)
            } else {
                try await setVisibility(rendition, public: false)
            }
            return nil
        }
    }

    /// A new key for a rendition's private link (`POST /share/private/items/<id>/rotate`); the old one stops at once.
    /// The file carries the new link. `.notFound` (none live any more) clears it and rethrows.
    @discardableResult
    public func rotateFileLink(_ rendition: Rendition) async throws -> PrivateLink {
        guard canChoosePrivateLink(rendition), let listed = rendition.file else { throw PipelineFailure.unsupported }
        guard !library.visibilityInFlight.contains(listed.id) else { throw PipelineFailure.unsupported }
        library.visibilityInFlight.insert(listed.id)
        defer { library.visibilityInFlight.remove(listed.id) }
        do {
            let link = try await shareSets.rotateItem(listed.id)
            if var file = library.file(id: listed.id) {
                file.privateURL = link.url
                library.replace(file: file)
            }
            return link
        } catch PrivateLinkError.notFound {
            clearPrivateURL(listed.id)
            throw PrivateLinkError.notFound
        } catch {
            throw privateLinkFailure(error)
        }
    }

    /// Every live key rotated in one batch (settings › sharing): the links store and the library's files carry the new
    /// keys, so every place that hands out a link gives the new one.
    @discardableResult
    public func rotateAllPrivateLinks() async throws -> PrivateLinkRotation {
        let answer = try await shareSets.rotateAll()
        for link in answer.links where link.kind == .item {
            guard var file = library.file(id: link.targetID) else { continue }
            file.privateURL = link.url
            library.replace(file: file)
        }
        return answer
    }

    // MARK: -

    /// `PUT /share/private/items/<id>`: optimistic like `setVisibility` (the file goes not public at once), put back
    /// on a failure.
    private func turnOnPrivateLink(_ rendition: Rendition, _ previous: LibraryFile) async throws -> PrivateLink {
        let id = previous.id
        guard !library.visibilityInFlight.contains(id) else { throw PipelineFailure.unsupported }
        library.visibilityInFlight.insert(id)
        defer { library.visibilityInFlight.remove(id) }
        var optimistic = previous
        optimistic.wireVisibility = .private
        optimistic.url = nil
        library.replace(file: optimistic)
        do {
            let link = try await ctx.client.enablePrivateLink(.item, id: id)
            var file = library.file(id: id) ?? optimistic
            file.privateURL = link.url
            file.wireVisibility = .private
            file.url = nil
            library.replace(file: file)
            shareSets.noteItemLink(link)
            // the public link this device recorded for the original is gone
            if !rendition.isWebp, let local = rendition.local {
                _ = ctx.store.setPublicURL(nil, forSession: local.sessionID, orEntry: local.id)
            }
            return link
        } catch {
            library.replace(file: previous)
            throw privateLinkFailure(error)
        }
    }

    /// `DELETE /share/private/items/<id>`: the file stays not public (off). Optimistic, put back on a failure.
    private func revokePrivateLink(_ rendition: Rendition, _ previous: LibraryFile) async throws {
        let id = previous.id
        guard !library.visibilityInFlight.contains(id) else { return }
        library.visibilityInFlight.insert(id)
        defer { library.visibilityInFlight.remove(id) }
        var optimistic = previous
        optimistic.privateURL = nil
        library.replace(file: optimistic)
        do {
            try await ctx.client.revokePrivateLink(.item, id: id)
            shareSets.dropItemLink(id)
        } catch {
            library.replace(file: previous)
            throw privateLinkFailure(error)
        }
    }

    /// The file has no private link any more (made public, or the server says none is live).
    private func clearPrivateURL(_ id: String) {
        shareSets.dropItemLink(id)
        guard var file = library.file(id: id), file.privateURL != nil else { return }
        file.privateURL = nil
        library.replace(file: file)
    }

    /// The private routes' own refusals stay as they are (the screen words them); anything else is the failure a screen
    /// can word, and a revoked key is told to the app.
    private func privateLinkFailure(_ error: Error) -> Error {
        if error is PrivateLinkError { return error }
        let mapped = pipelineFailure(from: error, during: .saving, limits: ctx.capabilities.limits) ?? error
        if let f = mapped as? PipelineFailure, f == .keyInvalid { markKeyInvalid() }
        return mapped
    }
}
