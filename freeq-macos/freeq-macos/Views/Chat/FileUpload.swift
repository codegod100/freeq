import SwiftUI
import UniformTypeIdentifiers

/// Handles image/file uploads to the freeq server.
enum FileUploader {
    /// Upload a file to the server, returns the blob URL.
    static func upload(
        data: Data,
        filename: String,
        contentType: String,
        did: String,
        channel: String?
    ) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)

        // did field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"did\"\r\n\r\n".data(using: .utf8)!)
        body.append(did.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)

        // channel field
        if let channel {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"channel\"\r\n\r\n".data(using: .utf8)!)
            body.append(channel.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "\(ServerConfig.apiBaseUrl)/api/v1/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch UploadResponse.classify(status: status, body: responseData) {
        case .success(let url):
            return url
        case .failure(let failure):
            throw failure  // UploadResponse.Failure is LocalizedError below
        }
    }

    /// Open the server's step-up OAuth page in the browser so the user can
    /// grant PDS write scope (needed only for Bluesky/PDS sharing). macOS
    /// reuses the browser for OAuth exactly as login does; after granting,
    /// the user retries the upload.
    @MainActor
    static func beginStepUp(purpose: String, path: String, did: String) {
        var components = URLComponents(string: "\(ServerConfig.apiBaseUrl)\(path)")
        // Ensure did + purpose are present even if the server gave a bare path.
        var items = components?.queryItems ?? []
        if !items.contains(where: { $0.name == "purpose" }) {
            items.append(URLQueryItem(name: "purpose", value: purpose))
        }
        items.append(URLQueryItem(name: "did", value: did))
        components?.queryItems = items
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UploadResponse.Failure: LocalizedError {
    public var errorDescription: String? { userMessage }
}

/// Pending upload state for the compose bar.
struct PendingUpload: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let contentType: String
    let preview: NSImage?
    var uploading: Bool = false
    var error: String?
}
