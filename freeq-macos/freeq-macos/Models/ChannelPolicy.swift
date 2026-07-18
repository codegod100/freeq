import Foundation

/// Decodable mirror of the server's channel policy (`GET /api/v1/policy/{ch}`).
/// Read-only: the macOS client renders these so operators can *see* a channel's
/// join gate, role gating, and verifiers. Writes still go through the IRC
/// `POLICY` command. Mirrors the Rust `Requirement` DSL in
/// `freeq-server/src/policy/types.rs` and the web `describeRequirements`.
indirect enum PolicyRequirement: Decodable, Equatable {
    case open
    case accept(hash: String)
    case present(credentialType: String, issuer: String?)
    case prove(proofType: String)
    case all([PolicyRequirement])
    case any([PolicyRequirement])
    case not(PolicyRequirement)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case type, hash
        case credentialType = "credential_type"
        case issuer
        case proofType = "proof_type"
        case requirements, requirement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = ((try? c.decode(String.self, forKey: .type)) ?? "").uppercased()
        switch type {
        case "OPEN":
            self = .open
        case "ACCEPT":
            self = .accept(hash: (try? c.decode(String.self, forKey: .hash)) ?? "")
        case "PRESENT":
            self = .present(
                credentialType: (try? c.decode(String.self, forKey: .credentialType)) ?? "",
                issuer: try? c.decode(String.self, forKey: .issuer)
            )
        case "PROVE":
            self = .prove(proofType: (try? c.decode(String.self, forKey: .proofType)) ?? "")
        case "ALL":
            self = .all((try? c.decode([PolicyRequirement].self, forKey: .requirements)) ?? [])
        case "ANY":
            self = .any((try? c.decode([PolicyRequirement].self, forKey: .requirements)) ?? [])
        case "NOT":
            self = .not((try? c.decode(PolicyRequirement.self, forKey: .requirement)) ?? .unknown("?"))
        default:
            self = .unknown(type.isEmpty ? "unknown" : type)
        }
    }

    /// Human-readable summary (mirrors the web client's `describeRequirements`).
    func describe() -> String {
        switch self {
        case .open: return "Open — anyone may join"
        case .accept: return "Accept the channel rules"
        case .present(let t, _): return "Present credential: \(t)"
        case .prove(let p): return "Prove: \(p)"
        case .all(let rs): return rs.map { $0.describe() }.joined(separator: " + ")
        case .any(let rs): return "Any of: " + rs.map { $0.describe() }.joined(separator: " or ")
        case .not(let r): return "Not: \(r.describe())"
        case .unknown(let t): return t
        }
    }

    /// Compact technical form (mirrors the web `describeRequirementsTechnical`).
    func technical() -> String {
        switch self {
        case .open: return "OPEN"
        case .accept(let h): return "ACCEPT(\(h.prefix(12)))"
        case .present(let t, let iss): return iss.map { "PRESENT(\(t), \($0))" } ?? "PRESENT(\(t))"
        case .prove(let p): return "PROVE(\(p))"
        case .all(let rs): return "ALL(\(rs.map { $0.technical() }.joined(separator: ", ")))"
        case .any(let rs): return "ANY(\(rs.map { $0.technical() }.joined(separator: ", ")))"
        case .not(let r): return "NOT(\(r.technical()))"
        case .unknown(let t): return t
        }
    }
}

struct PolicyCredentialEndpoint: Decodable, Equatable {
    let issuer: String
    let url: String
    let label: String
}

/// A channel policy document as returned by the REST API.
struct ChannelPolicyDoc: Decodable, Equatable {
    let policyId: String?
    let version: Int
    let requirements: PolicyRequirement
    let roleRequirements: [String: PolicyRequirement]
    let credentialEndpoints: [String: PolicyCredentialEndpoint]

    private enum CodingKeys: String, CodingKey {
        case policyId = "policy_id"
        case version, requirements
        case roleRequirements = "role_requirements"
        case credentialEndpoints = "credential_endpoints"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policyId = try? c.decode(String.self, forKey: .policyId)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        requirements = (try? c.decode(PolicyRequirement.self, forKey: .requirements)) ?? .unknown("none")
        roleRequirements = (try? c.decode([String: PolicyRequirement].self, forKey: .roleRequirements)) ?? [:]
        credentialEndpoints = (try? c.decode([String: PolicyCredentialEndpoint].self, forKey: .credentialEndpoints)) ?? [:]
    }
}

/// Response shape of `GET /api/v1/policy/{ch}/rules`.
struct ChannelPolicyRules: Decodable, Equatable {
    let channel: String
    let hash: String
    let text: String
}
