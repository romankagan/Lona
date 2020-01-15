//
//  MarkdownDocument.swift
//  LonaStudio
//
//  Created by Devin Abbott on 6/29/19.
//  Copyright © 2019 Devin Abbott. All rights reserved.
//

import AppKit
import Logic

class MarkdownDocument: NSDocument {

    public static let INDEX_PAGE_NAME = "README.md"

    override init() {
        super.init()

        self.hasUndoManager = false
    }

    override var autosavingFileType: String? {
        return nil
    }

    var viewController: WorkspaceViewController? {
        return windowControllers[0].contentViewController as? WorkspaceViewController
    }

    var _content: [BlockEditor.Block] = [] {
        didSet {
            if let url = fileURL {
                LogicModule.invalidateCaches(url: url, newValue: program)
            }
        }
    }

    var content: [BlockEditor.Block] { return _content }

    var program: LGCProgram {
        return MarkdownFile.makeMarkdownRoot(content).program()
    }

    private var changeEmitter: Emitter<[BlockEditor.Block]> = .init()

    public var isIndexPage: Bool {
        return fileURL?.lastPathComponent == MarkdownDocument.INDEX_PAGE_NAME
    }

    public func addChangeListener(_ listener: @escaping ([BlockEditor.Block]) -> Void) -> Int {
        return changeEmitter.addListener(listener)
    }

    public func removeChangeListener(forKey key: Int) {
        changeEmitter.removeListener(forKey: key)
    }

    override func makeWindowControllers() {
        // We manage window controllers in `showWindows`
    }

    override func showWindows() {
        DocumentController.shared.createOrFindWorkspaceWindowController(for: self)

        super.showWindows()
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = MarkdownFile.makeMarkdownData(content) else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile, userInfo: nil)
        }
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let content = MarkdownFile.makeBlocks(data) else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile, userInfo: nil)
        }

        // Ensure that a document has at least one editable block when we load it
        self._content = (content.last == nil || content.last?.isEmpty == false)
            ? content + [BlockEditor.Block.makeDefaultEmptyBlock()]
            : content

        if let url = fileURL {
            LogicModule.invalidateCaches(url: url, newValue: program)
        }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)

        LogicModule.invalidateCaches(url: url, newValue: program)
    }

    func save(to url: URL, for saveOperation: NSDocument.SaveOperationType) -> Promise<Void, NSError> {
        return Promise<Void, NSError>.result { completed in
            save(to: url, ofType: "Markdown", for: saveOperation, completionHandler: { error in
                if let error = error {
                    return completed(.failure(error as NSError))
                } else {
                    return completed(.success(()))
                }
            })
        }
    }
}

extension MarkdownDocument {

    enum MarkdownError: Error {
        case failedToDeleteFile
        case directoryNotEmpty
    }

    func pages(blocks: [BlockEditor.Block]) -> [String] {
        blocks.compactMap {
            switch $0.content {
            case .page(title: _, target: let target):
                return target
            default:
                return nil
            }
        }
    }

    func replacePageLink(blocks: [BlockEditor.Block], oldTarget: String, newTarget: String) -> [BlockEditor.Block] {
        return blocks.map { block in
            switch block.content {
            case .page(title: let title, target: oldTarget):
                return .init(.page(title: title, target: newTarget), block.listDepth)
            default:
                return block
            }
        }
    }

    func setContent(_ value: [BlockEditor.Block], userInitiated: Bool) {
        let oldPages = pages(blocks: content)
        let newPages = pages(blocks: value)

        let diff = oldPages.extendedDiff(newPages)
        let deleted: [String] = diff.compactMap {
            switch $0 {
            case .delete(at: let index):
                return oldPages[index]
            case .insert, .move:
                return nil
            }
        }

        _ = deleteChildPageFiles(deleted, userInitiated: userInitiated)

        let value = value.isEmpty ? [BlockEditor.Block.makeDefaultEmptyBlock()] : value

        self._content = value

        self.updateChangeCount(.changeDone)

        if deleted.isEmpty {
            self.changeEmitter.emit(self.content)
        } else {
            guard let fileURL = fileURL else { return }

            Swift.print("Will delete", deleted)

            // If we deleted child pages, we automatically save
            save(to: fileURL, for: .saveOperation).finalSuccess {
                Swift.print("Saved after delete", fileURL)

                if self.shouldConvertToFile() {
                    self.convertToFile().finalResult { _ in
                        Swift.print("Finished converting")

                        self.changeEmitter.emit(self.content)
                    }
                } else {
                    self.changeEmitter.emit(self.content)
                }
            }
        }
    }

    func makeAndOpenChildPage(pageName: String, blockIndex index: Int, shouldReplaceBlock shouldReplace: Bool) {
        guard let fileURL = fileURL else { return }

        // Ensure that this is a directory before creating a child page
        if !isIndexPage {
            convertToDirectory().finalResult { result in
                switch result {
                case .success:
                    self.makeAndOpenChildPage(pageName: pageName, blockIndex: index, shouldReplaceBlock: shouldReplace)
                case .failure(let error):
                    Swift.print("Failed to convert readme to directory", error)
                }
            }
            return
        }

        var pageURL = fileURL.deletingLastPathComponent().appendingPathComponent(pageName)

        if pageURL.pathExtension != "md" {
            pageURL = pageURL.appendingPathExtension("md")
        }

        let title = pageURL.deletingPathExtension().lastPathComponent
        let newBlock = BlockEditor.Block(.page(title: title, target: pageURL.lastPathComponent), .none)

        var blocks = content
        if shouldReplace {
            blocks[index] = newBlock
        } else {
            blocks.insert(newBlock, at: index)
        }

        setContent(blocks, userInitiated: true)

        save(to: fileURL, for: .saveOperation).onSuccess { _ in
            return DocumentController.shared.makeAndOpenMarkdownDocument(withTitle: title, savedTo: pageURL)
        }
        .finalFailure { error in
            Swift.print("Failed to save", error)
            Alert.runInformationalAlert(messageText: "Failed to save \(fileURL.path).")
        }
    }

    func deleteChildPageFiles(_ deleted: [String], userInitiated: Bool) -> Result<Void, MarkdownError> {
        guard let fileURL = fileURL else { return .success(()) }

        if deleted.isEmpty { return .success(()) }

        let pageNoun = "page\(deleted.count > 1 ? "s" : "")"

        if !userInitiated || Alert.runConfirmationAlert(
            confirmationText: "Delete \(pageNoun)",
            messageText: "This will delete the \(pageNoun) \(deleted.map { "'\($0)'" }.joined(separator: ", ")) and can't be undone. Continue?"
        ) {
            for pageName in deleted {
                let pageURL = fileURL.deletingLastPathComponent().appendingPathComponent(pageName)

                do {
                    try FileManager.default.removeItem(at: pageURL)
                } catch CocoaError.fileNoSuchFile {
                    // Continue if the file didn't exist
                } catch {
                    Swift.print("Failed to delete markdown page \(pageName)")
                    return .failure(.failedToDeleteFile)
                }
            }
        }

        return .success(())
    }

    // Convert Page.md to Page/README.md
    // - Make the Page directory
    // - Delete the old Page.md
    // - Fix parent URL to point to Page/README.md
    func convertToDirectory() -> Promise<URL, NSError> {
        guard let originalFileURL = fileURL else { return .failure(.init()) }

        if FileManager.default.isDirectory(path: originalFileURL.path) { return .failure(.init()) }

        let pageName = originalFileURL.deletingPathExtension().lastPathComponent
        let directoryURL = originalFileURL.deletingLastPathComponent().appendingPathComponent(pageName).deletingPathExtension()

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [:])
        } catch let error {
            Swift.print("Error creating directory \(directoryURL)", error)
            return .failure(error as NSError)
        }

        let readmeURL = directoryURL.appendingPathComponent(MarkdownDocument.INDEX_PAGE_NAME)

        let saved: Promise<URL, NSError> = save(to: readmeURL, for: .saveAsOperation).onSuccess {
            do {
                try FileManager.default.removeItem(at: originalFileURL)
            } catch let error {
                return .failure(error as NSError)
            }

            return .success(readmeURL)
        }

        // Fix the parent URL. If it fails, still consider the whole operation a success
        saved.finalSuccess { _ in
            let parentReadmeURL = directoryURL.deletingLastPathComponent().appendingPathComponent(MarkdownDocument.INDEX_PAGE_NAME)

            DocumentController.shared.openDocument(withContentsOf: parentReadmeURL, display: false).finalSuccess { parentDocument in
                if let parentDocument = parentDocument as? MarkdownDocument {
                    let updated = self.replacePageLink(
                        blocks: parentDocument.content,
                        oldTarget: originalFileURL.lastPathComponent,
                        newTarget: directoryURL.lastPathComponent
                    )
                    parentDocument.setContent(updated, userInitiated: false)
                    _ = parentDocument.save(to: parentDocument.fileURL!, for: .saveOperation)
                }
            }
        }

        return saved
    }

    // If a markdown document is a README.md alone in its directory, then we should represent it
    // as a named .md file in the parent directory instead.
    func shouldConvertToFile() -> Bool {
        guard let originalFileURL = fileURL else { return false }

        if originalFileURL.lastPathComponent != MarkdownDocument.INDEX_PAGE_NAME { return false }

        let files: [String]

        do {
            files = try FileManager.default.contentsOfDirectory(atPath: originalFileURL.deletingLastPathComponent().path)
        } catch {
            Swift.print("Failed to read directory \(originalFileURL.path)", error)
            return false
        }

        let remainingFiles = files.filter { $0 != "README.md" && $0 != ".DS_Store" }

        Swift.print(originalFileURL.deletingLastPathComponent().path, "remaining files", remainingFiles)

        return remainingFiles.isEmpty
    }

    // Convert Page/README.md to Page.md
    // - Double check that it's safe to delete the directory
    // - Make the Page.md file
    // - Delete the old Page directory
    // - Fix parent URL to point to Page.md
    func convertToFile() -> Promise<URL, NSError> {
        guard let originalFileURL = fileURL else { return .failure(.init()) }

        if !shouldConvertToFile() { return .failure(MarkdownError.directoryNotEmpty as NSError) }

        Swift.print("Convert to file")

        let pageName = originalFileURL.deletingLastPathComponent().lastPathComponent
        let directoryURL = originalFileURL.deletingLastPathComponent()
        let pageURL = directoryURL.deletingLastPathComponent().appendingPathComponent(pageName + ".md")

        Swift.print("Saving", originalFileURL.path, "as", pageURL.path)

        let saved: Promise<URL, NSError> = save(to: pageURL, for: .saveAsOperation).onSuccess {
            do {
                try FileManager.default.removeItem(at: originalFileURL)
            } catch let error {
                return .failure(error as NSError)
            }

            return .success(pageURL)
        }

        // Fix the parent URL. If it fails, still consider the whole operation a success
        saved.finalSuccess { _ in
            let parentReadmeURL = directoryURL.deletingLastPathComponent().appendingPathComponent(MarkdownDocument.INDEX_PAGE_NAME)

            DocumentController.shared.openDocument(withContentsOf: parentReadmeURL, display: false).finalSuccess { parentDocument in
                if let parentDocument = parentDocument as? MarkdownDocument {
                    let updated = self.replacePageLink(
                        blocks: parentDocument.content,
                        oldTarget: directoryURL.lastPathComponent,
                        newTarget: pageURL.lastPathComponent
                    )
                    parentDocument.setContent(updated, userInitiated: false)
                    _ = parentDocument.save(to: parentDocument.fileURL!, for: .saveOperation)
                }
            }
        }

        return .success(originalFileURL)
    }
}
