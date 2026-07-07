import XCTest
@testable import FreeqMacosCore

/// Decoding + human-readable rendering of the channel policy the macOS client
/// reads from `GET /api/v1/policy/{ch}`. Mirrors the #freeq v5 shape (ACCEPT
/// join gate + op → github_repo role) and the open-by-default case.
final class ChannelPolicyTests: XCTestCase {

    func testDecodesFreeqStylePolicy() throws {
        let json = """
        {
          "channel_id": "#freeq",
          "policy_id": "6c0a64c9f91698b3bee3443d5c942fa448af7c1bfb067aa3c96b19d4c0090317",
          "version": 5,
          "requirements": { "type": "ACCEPT", "hash": "0b5752faf791ed46e0" },
          "role_requirements": {
            "op": { "type": "PRESENT", "credential_type": "github_repo", "issuer": "did:web:irc.freeq.at:verify" }
          },
          "credential_endpoints": {
            "github_repo": { "issuer": "did:web:irc.freeq.at:verify", "url": "/verify/github/start?repo=chad/freeq", "label": "GitHub Repo Collaborator" }
          }
        }
        """
        let doc = try JSONDecoder().decode(ChannelPolicyDoc.self, from: Data(json.utf8))

        XCTAssertEqual(doc.version, 5)
        XCTAssertEqual(doc.requirements, .accept(hash: "0b5752faf791ed46e0"))
        XCTAssertEqual(doc.requirements.describe(), "Accept the channel rules")
        XCTAssertEqual(doc.requirements.technical(), "ACCEPT(0b5752faf791)")

        XCTAssertEqual(doc.roleRequirements["op"],
                       .present(credentialType: "github_repo", issuer: "did:web:irc.freeq.at:verify"))
        XCTAssertEqual(doc.roleRequirements["op"]?.describe(), "Present credential: github_repo")

        XCTAssertEqual(doc.credentialEndpoints["github_repo"]?.label, "GitHub Repo Collaborator")
    }

    func testDecodesOpenJoinGate() throws {
        let json = """
        { "channel_id": "#lobby", "version": 2, "requirements": { "type": "OPEN" },
          "role_requirements": {}, "credential_endpoints": {} }
        """
        let doc = try JSONDecoder().decode(ChannelPolicyDoc.self, from: Data(json.utf8))
        XCTAssertEqual(doc.requirements, .open)
        XCTAssertEqual(doc.requirements.describe(), "Open — anyone may join")
        XCTAssertTrue(doc.roleRequirements.isEmpty)
    }

    func testDecodesCompositeRequirement() throws {
        let json = """
        { "channel_id": "#c", "version": 1, "requirements": {
            "type": "ALL", "requirements": [
              { "type": "ACCEPT", "hash": "abcdef012345" },
              { "type": "PRESENT", "credential_type": "github_membership", "issuer": "github" }
            ] },
          "role_requirements": {}, "credential_endpoints": {} }
        """
        let doc = try JSONDecoder().decode(ChannelPolicyDoc.self, from: Data(json.utf8))
        XCTAssertEqual(doc.requirements.describe(),
                       "Accept the channel rules + Present credential: github_membership")
        XCTAssertEqual(doc.requirements.technical(),
                       "ALL(ACCEPT(abcdef012345), PRESENT(github_membership, github))")
    }

    func testDecodesRulesResponse() throws {
        let json = ##"{ "channel": "#freeq", "hash": "0b5752", "text": "Be respectful." }"##
        let rules = try JSONDecoder().decode(ChannelPolicyRules.self, from: Data(json.utf8))
        XCTAssertEqual(rules.text, "Be respectful.")
    }

    func testDefaultsWhenFieldsMissing() throws {
        // role_requirements / credential_endpoints absent → empty, not a decode error.
        let json = ##"{ "channel_id": "#c", "version": 3, "requirements": { "type": "OPEN" } }"##
        let doc = try JSONDecoder().decode(ChannelPolicyDoc.self, from: Data(json.utf8))
        XCTAssertTrue(doc.roleRequirements.isEmpty)
        XCTAssertTrue(doc.credentialEndpoints.isEmpty)
    }
}
