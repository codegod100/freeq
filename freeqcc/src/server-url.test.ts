import { describe, it, expect } from "vitest";
import { actorStatusUrl, healthUrl } from "./server-url.js";
import { configToSave } from "./config.js";

const DID = "did:key:z6MkBot";

describe("the server freeqcc asks about its bot", () => {
  it("is the server the bot connects to", () => {
    expect(actorStatusUrl("ws://localhost:8080/irc", DID)).toBe(
      `http://localhost:8080/api/v1/actors/${encodeURIComponent(DID)}`,
    );
    expect(healthUrl("wss://irc.example.test/irc")).toBe(
      "https://irc.example.test/api/v1/health",
    );
  });

  it("is irc.freeq.at when no server is configured, as for the connection", () => {
    expect(actorStatusUrl(undefined, DID)).toBe(
      `https://irc.freeq.at/api/v1/actors/${encodeURIComponent(DID)}`,
    );
    expect(healthUrl(undefined)).toBe("https://irc.freeq.at/api/v1/health");
  });
});

describe("configToSave", () => {
  it("saves a --server given at launch, so status asks that server", () => {
    expect(configToSave({ nick: "helper" }, "helper", "ws://localhost:8080/irc")).toEqual({
      nick: "helper",
      serverUrl: "ws://localhost:8080/irc",
    });
  });

  it("saves a new nick and keeps the stored server", () => {
    expect(
      configToSave({ nick: "old", serverUrl: "wss://a.test/irc" }, "new", undefined),
    ).toEqual({ nick: "new", serverUrl: "wss://a.test/irc" });
    expect(configToSave(null, "first", undefined)).toEqual({ nick: "first" });
  });

  it("saves nothing when nothing changed", () => {
    const stored = { nick: "helper", serverUrl: "wss://a.test/irc" };
    expect(configToSave(stored, "helper", undefined)).toBeNull();
    expect(configToSave(stored, "helper", "wss://a.test/irc")).toBeNull();
  });
});
