const DEFAULT_PROTOCOL = "lightspeed";
const DEFAULT_VERSION = 1;
const PATCH_STREAM_TAG = "ps";
const PATCH_STREAM_VERSION = 1;
const HOOK_SELECTOR = "[data-ls-hook]";
const EVENT_SELECTOR = "[data-ls-event]";
const COMMAND_DEFAULT_DISPLAY = "block";
const COMMAND_PATCH_EVENT = "lv:patch";
const COMMAND_NAVIGATE_EVENT = "lv:navigate";

function encodeField(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/\|/g, "\\|");
}

function splitFields(payload) {
  const fields = [];
  let current = "";
  let escaped = false;

  for (let index = 0; index < payload.length; index += 1) {
    const char = payload[index];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\") {
      escaped = true;
      continue;
    }

    if (char === "|") {
      fields.push(current);
      current = "";
      continue;
    }

    current += char;
  }

  if (escaped) {
    throw new Error("invalid_escape_sequence");
  }

  fields.push(current);
  return fields;
}

function joinFields(fields) {
  return fields.map(encodeField).join("|");
}

function encodeFrame(frame) {
  switch (frame.tag) {
    case "hello":
      return joinFields([
        "hello",
        frame.protocol,
        String(frame.version),
      ]);
    case "event":
      return joinFields([
        "event",
        frame.ref,
        frame.name,
        frame.payload,
      ]);
    case "diff": {
      const payload = frame.payload ?? frame.html ?? "";
      return joinFields(["diff", frame.ref, payload]);
    }
    case "ack":
      return joinFields(["ack", frame.ref]);
    case "failure":
      return joinFields([
        "failure",
        frame.ref,
        frame.reason,
      ]);
    default:
      throw new Error(`unsupported_frame_tag:${String(frame.tag)}`);
  }
}

function decodeFrame(payload) {
  if (payload === "") {
    throw new Error("empty_frame");
  }

  const fields = splitFields(payload);
  const [tag] = fields;

  switch (tag) {
    case "hello": {
      if (fields.length !== 3) {
        throw new Error(`bad_field_count:hello:3:${fields.length}`);
      }
      const [, protocol, versionText] = fields;
      const version = Number.parseInt(versionText, 10);
      if (Number.isNaN(version)) {
        throw new Error(`invalid_version:${versionText}`);
      }
      return { tag: "hello", protocol, version };
    }

    case "event": {
      if (fields.length !== 4) {
        throw new Error(`bad_field_count:event:4:${fields.length}`);
      }
      const [, ref, name, payloadValue] = fields;
      return { tag: "event", ref, name, payload: payloadValue };
    }

    case "diff": {
      if (fields.length !== 3) {
        throw new Error(`bad_field_count:diff:3:${fields.length}`);
      }
      const [, ref, payload] = fields;
      return { tag: "diff", ref, payload, html: payload };
    }

    case "ack": {
      if (fields.length !== 2) {
        throw new Error(`bad_field_count:ack:2:${fields.length}`);
      }
      const [, ref] = fields;
      return { tag: "ack", ref };
    }

    case "failure": {
      if (fields.length !== 3) {
        throw new Error(`bad_field_count:failure:3:${fields.length}`);
      }
      const [, ref, reason] = fields;
      return { tag: "failure", ref, reason };
    }

    default:
      throw new Error(`unknown_frame_tag:${tag}`);
  }
}

function parseIntStrict(value) {
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`invalid_integer:${value}`);
  }
  return parsed;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function dynamicSlot(name, value) {
  return { name, value };
}

function patchStringValues(patch) {
  switch (patch.op) {
    case "replace":
    case "append":
    case "prepend":
      return [patch.target, patch.html];
    case "remove":
      return [patch.target];
    case "replace_segments": {
      const strings = [patch.target, patch.fingerprint, patch.staticHtml];
      for (const slot of patch.dynamicSlots) {
        strings.push(slot.name, slot.value);
      }
      return strings;
    }
    case "update_segments": {
      const strings = [patch.target, patch.fingerprint];
      for (const slot of patch.dynamicSlots) {
        strings.push(slot.name, slot.value);
      }
      return strings;
    }
    case "upsert_keyed":
      return [patch.target, patch.key, patch.html];
    case "remove_keyed":
      return [patch.target, patch.key];
    case "reorder_keyed":
      return [patch.target, ...patch.keys];
    default:
      throw new Error(`unsupported_patch_op:${String(patch.op)}`);
  }
}

function buildDictionary(patches) {
  const dictionary = [];
  const seen = new Set();

  for (const patch of patches) {
    for (const value of patchStringValues(patch)) {
      if (seen.has(value)) continue;
      seen.add(value);
      dictionary.push(value);
    }
  }

  return dictionary;
}

function dictionaryIndex(dictionary, value) {
  const index = dictionary.indexOf(value);
  if (index < 0) {
    throw new Error(`missing_dictionary_entry:${value}`);
  }
  return index;
}

function encodeDynamicSlotTokens(dictionary, dynamicSlots) {
  const tokens = [];

  for (const slot of dynamicSlots) {
    tokens.push(String(dictionaryIndex(dictionary, slot.name)));
    tokens.push(String(dictionaryIndex(dictionary, slot.value)));
  }

  return tokens;
}

function encodePatchOperation(dictionary, patch) {
  switch (patch.op) {
    case "replace":
      return [
        "r",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.html)),
      ].join(",");
    case "append":
      return [
        "a",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.html)),
      ].join(",");
    case "prepend":
      return [
        "p",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.html)),
      ].join(",");
    case "remove":
      return ["x", String(dictionaryIndex(dictionary, patch.target))].join(",");
    case "replace_segments":
      return [
        "s",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.fingerprint)),
        String(dictionaryIndex(dictionary, patch.staticHtml)),
        String(patch.dynamicSlots.length),
        ...encodeDynamicSlotTokens(dictionary, patch.dynamicSlots),
      ].join(",");
    case "update_segments":
      return [
        "u",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.fingerprint)),
        String(patch.dynamicSlots.length),
        ...encodeDynamicSlotTokens(dictionary, patch.dynamicSlots),
      ].join(",");
    case "upsert_keyed":
      return [
        "k",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.key)),
        String(dictionaryIndex(dictionary, patch.html)),
      ].join(",");
    case "remove_keyed":
      return [
        "q",
        String(dictionaryIndex(dictionary, patch.target)),
        String(dictionaryIndex(dictionary, patch.key)),
      ].join(",");
    case "reorder_keyed":
      return [
        "o",
        String(dictionaryIndex(dictionary, patch.target)),
        String(patch.keys.length),
        ...patch.keys.map((key) => String(dictionaryIndex(dictionary, key))),
      ].join(",");
    default:
      throw new Error(`unsupported_patch_op:${String(patch.op)}`);
  }
}

function encodePatchStream(patches, version = PATCH_STREAM_VERSION) {
  const dictionary = buildDictionary(patches);
  const operationFields = patches.map((patch) => encodePatchOperation(dictionary, patch));

  return joinFields([
    PATCH_STREAM_TAG,
    String(version),
    String(dictionary.length),
    ...dictionary,
    String(operationFields.length),
    ...operationFields,
  ]);
}

function dictionaryValue(dictionary, index) {
  if (index < 0 || index >= dictionary.length) {
    throw new Error(`missing_dictionary_entry:${String(index)}`);
  }
  return dictionary[index];
}

function decodeDynamicSlots(tokens, dictionary, slotCount) {
  if (tokens.length !== slotCount * 2) {
    throw new Error(`bad_field_count:dynamic_slots:${slotCount * 2}:${tokens.length}`);
  }

  const slots = [];
  for (let index = 0; index < tokens.length; index += 2) {
    const nameIndex = parseIntStrict(tokens[index]);
    const valueIndex = parseIntStrict(tokens[index + 1]);
    slots.push(dynamicSlot(
      dictionaryValue(dictionary, nameIndex),
      dictionaryValue(dictionary, valueIndex),
    ));
  }
  return slots;
}

function decodePatchOperation(operationField, dictionary) {
  const tokens = operationField.split(",");
  const [tag, ...rest] = tokens;

  switch (tag) {
    case "r": {
      if (rest.length !== 2) {
        throw new Error(`malformed_operation:${operationField}`);
      }
      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const html = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      return { op: "replace", target, html };
    }

    case "a": {
      if (rest.length !== 2) {
        throw new Error(`malformed_operation:${operationField}`);
      }
      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const html = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      return { op: "append", target, html };
    }

    case "p": {
      if (rest.length !== 2) {
        throw new Error(`malformed_operation:${operationField}`);
      }
      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const html = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      return { op: "prepend", target, html };
    }

    case "x": {
      if (rest.length !== 1) {
        throw new Error(`malformed_operation:${operationField}`);
      }
      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      return { op: "remove", target };
    }

    case "s": {
      if (rest.length < 4) {
        throw new Error(`malformed_operation:${operationField}`);
      }

      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const fingerprint = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      const staticHtml = dictionaryValue(dictionary, parseIntStrict(rest[2]));
      const slotCount = parseIntStrict(rest[3]);
      const dynamicSlots = decodeDynamicSlots(rest.slice(4), dictionary, slotCount);

      return {
        op: "replace_segments",
        target,
        fingerprint,
        staticHtml,
        dynamicSlots,
      };
    }

    case "u": {
      if (rest.length < 3) {
        throw new Error(`malformed_operation:${operationField}`);
      }

      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const fingerprint = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      const slotCount = parseIntStrict(rest[2]);
      const dynamicSlots = decodeDynamicSlots(rest.slice(3), dictionary, slotCount);

      return {
        op: "update_segments",
        target,
        fingerprint,
        dynamicSlots,
      };
    }

    case "k": {
      if (rest.length !== 3) {
        throw new Error(`malformed_operation:${operationField}`);
      }

      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const key = dictionaryValue(dictionary, parseIntStrict(rest[1]));
      const html = dictionaryValue(dictionary, parseIntStrict(rest[2]));

      return { op: "upsert_keyed", target, key, html };
    }

    case "q": {
      if (rest.length !== 2) {
        throw new Error(`malformed_operation:${operationField}`);
      }

      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const key = dictionaryValue(dictionary, parseIntStrict(rest[1]));

      return { op: "remove_keyed", target, key };
    }

    case "o": {
      if (rest.length < 2) {
        throw new Error(`malformed_operation:${operationField}`);
      }

      const target = dictionaryValue(dictionary, parseIntStrict(rest[0]));
      const keyCount = parseIntStrict(rest[1]);
      const keyIndexes = rest.slice(2);
      if (keyIndexes.length !== keyCount) {
        throw new Error(`bad_field_count:reorder_keyed_keys:${keyCount}:${keyIndexes.length}`);
      }
      const keys = keyIndexes.map((token) => dictionaryValue(dictionary, parseIntStrict(token)));

      return { op: "reorder_keyed", target, keys };
    }

    default:
      throw new Error(`malformed_operation:${operationField}`);
  }
}

function decodePatchStream(payload) {
  const fields = splitFields(payload);
  if (fields.length < 5) {
    throw new Error(`bad_field_count:patch_stream:5:${fields.length}`);
  }

  const [tag, versionText, dictionaryCountText, ...rest] = fields;
  if (tag !== PATCH_STREAM_TAG) {
    throw new Error(`unknown_payload_tag:${tag}`);
  }

  const version = parseIntStrict(versionText);
  if (version !== PATCH_STREAM_VERSION) {
    throw new Error(`unsupported_version:${String(version)}`);
  }

  const dictionaryCount = parseIntStrict(dictionaryCountText);
  if (dictionaryCount < 0 || rest.length < dictionaryCount + 1) {
    throw new Error("malformed_operation:insufficient_fields");
  }

  const dictionary = rest.slice(0, dictionaryCount);
  const operationCount = parseIntStrict(rest[dictionaryCount]);
  const operationFields = rest.slice(dictionaryCount + 1);

  if (operationFields.length !== operationCount) {
    throw new Error(
      `bad_field_count:operation_fields:${operationCount}:${operationFields.length}`,
    );
  }

  return {
    version,
    patches: operationFields.map((field) => decodePatchOperation(field, dictionary)),
  };
}

function defaultSocketFactory(url) {
  return new WebSocket(url);
}

function defaultTimer() {
  return {
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (handle) => clearTimeout(handle),
  };
}

function getDefaultLocation() {
  if (typeof window !== "undefined" && window.location) {
    return window.location;
  }

  if (typeof location !== "undefined") {
    return location;
  }

  return null;
}

function resolveRoot(documentRef, explicitRoot) {
  if (explicitRoot) return explicitRoot;
  if (!documentRef || typeof documentRef.querySelector !== "function") return null;
  return documentRef.querySelector("[data-ls-root]") ?? documentRef.querySelector("#app");
}

function resolveUrl(explicitUrl, root, locationRef) {
  if (explicitUrl) return explicitUrl;
  if (!root || !root.dataset) return null;

  const wsValue = root.dataset.lsWs;
  if (!wsValue) return null;

  if (wsValue.startsWith("ws://") || wsValue.startsWith("wss://")) {
    return wsValue;
  }

  if (!locationRef) return wsValue;

  const protocol = locationRef.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${locationRef.host}${wsValue}`;
}

function dispatchCustomEvent(root, type, detail) {
  if (!root || typeof root.dispatchEvent !== "function") return;

  if (typeof CustomEvent === "function") {
    root.dispatchEvent(new CustomEvent(type, { detail }));
    return;
  }

  root.dispatchEvent({ type, detail });
}

function splitClassNames(names) {
  if (Array.isArray(names)) {
    return names
      .flatMap((value) => splitClassNames(value))
      .filter((value) => value !== "");
  }

  return String(names ?? "")
    .split(/\s+/)
    .map((value) => value.trim())
    .filter((value) => value !== "");
}

function normalizePayload(payload) {
  if (payload === null || payload === undefined) return "{}";
  if (typeof payload === "string") return payload;

  try {
    return JSON.stringify(payload);
  } catch (_error) {
    return "{}";
  }
}

function stableStringify(value) {
  if (value === null || value === undefined) return String(value);
  if (typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringify(entry)).join(",")}]`;
  }

  const keys = Object.keys(value).sort();
  const fields = keys.map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
  return `{${fields.join(",")}}`;
}

function normalizeCommand(commandLike) {
  if (commandLike instanceof LightspeedJS) {
    return commandLike;
  }

  if (commandLike && Array.isArray(commandLike.ops)) {
    return new LightspeedJS(commandLike.ops);
  }

  throw new Error("invalid_command");
}

function asOperationOptions(options = {}) {
  return {
    to: options.to ?? null,
    persist: options.persist === true,
  };
}

class LightspeedJS {
  constructor(ops = []) {
    this.ops = [...ops];
  }

  static command() {
    return new LightspeedJS();
  }

  static concat(first, second) {
    return normalizeCommand(first).concat(second);
  }

  static compose(commands) {
    return commands.reduce((acc, command) => acc.concat(command), LightspeedJS.command());
  }

  concat(commandLike) {
    const command = normalizeCommand(commandLike);
    return new LightspeedJS([...this.ops, ...command.ops]);
  }

  addClass(names, options = {}) {
    const classes = splitClassNames(names);
    return this.append({
      kind: "add_class",
      classes,
      ...asOperationOptions(options),
      transition: options.transition ?? null,
      time: options.time ?? 200,
    });
  }

  removeClass(names, options = {}) {
    const classes = splitClassNames(names);
    return this.append({
      kind: "remove_class",
      classes,
      ...asOperationOptions(options),
      transition: options.transition ?? null,
      time: options.time ?? 200,
    });
  }

  toggleClass(names, options = {}) {
    const classes = splitClassNames(names);
    return this.append({
      kind: "toggle_class",
      classes,
      ...asOperationOptions(options),
    });
  }

  setAttribute(name, value, options = {}) {
    return this.append({
      kind: "set_attr",
      name: String(name),
      value: String(value),
      ...asOperationOptions(options),
    });
  }

  removeAttribute(name, options = {}) {
    return this.append({
      kind: "remove_attr",
      name: String(name),
      ...asOperationOptions(options),
    });
  }

  show(options = {}) {
    return this.append({
      kind: "show",
      ...asOperationOptions(options),
      display: options.display ?? COMMAND_DEFAULT_DISPLAY,
      transition: options.transition ?? null,
      time: options.time ?? 200,
    });
  }

  hide(options = {}) {
    return this.append({
      kind: "hide",
      ...asOperationOptions(options),
      transition: options.transition ?? null,
      time: options.time ?? 200,
    });
  }

  toggle(options = {}) {
    return this.append({
      kind: "toggle",
      ...asOperationOptions(options),
      display: options.display ?? COMMAND_DEFAULT_DISPLAY,
      inTransition: options.in ?? null,
      outTransition: options.out ?? null,
      time: options.time ?? 200,
    });
  }

  transition(transition, options = {}) {
    return this.append({
      kind: "transition",
      transition,
      ...asOperationOptions(options),
      time: options.time ?? 200,
    });
  }

  dispatch(event, options = {}) {
    return this.append({
      kind: "dispatch",
      event: String(event),
      detail: options.detail ?? {},
      bubbles: options.bubbles !== false,
      to: options.to ?? null,
    });
  }

  push(event, options = {}) {
    return this.append({
      kind: "push",
      event: String(event),
      target: options.target ?? null,
      loading: options.loading ?? null,
      pageLoading: options.page_loading === true,
      value: options.value ?? options.payload ?? {},
    });
  }

  patch(href, options = {}) {
    return this.append({
      kind: "patch",
      href: String(href),
      replace: options.replace === true,
    });
  }

  navigate(href, options = {}) {
    return this.append({
      kind: "navigate",
      href: String(href),
      replace: options.replace === true,
    });
  }

  append(operation) {
    return new LightspeedJS([...this.ops, operation]);
  }
}

class LightspeedClient {
  constructor(options = {}) {
    this.document = options.document ?? (typeof document !== "undefined" ? document : null);
    this.root = resolveRoot(this.document, options.root ?? null);
    this.location = options.location ?? getDefaultLocation();
    this.url = resolveUrl(options.url ?? null, this.root, this.location);

    this.protocol = options.protocol ?? DEFAULT_PROTOCOL;
    this.version = options.version ?? DEFAULT_VERSION;

    this.socketFactory = options.socketFactory ?? defaultSocketFactory;
    this.timer = options.timer ?? defaultTimer();
    this.hooks = options.hooks ?? {};

    this.reconnect = {
      enabled: options.reconnect?.enabled ?? true,
      baseDelayMs: options.reconnect?.baseDelayMs ?? 200,
      maxDelayMs: options.reconnect?.maxDelayMs ?? 5000,
    };

    this.state = "idle";
    this.socket = null;
    this.closedManually = false;
    this.reconnectAttempts = 0;
    this.reconnectHandle = null;
    this.nextEventRef = 1;
    this.lastAppliedPatchRef = null;
    this.hookInstances = new Map();
    this.hookEventHandlers = new Map();
    this.segmentState = new Map();
    this.keyedState = new Map();
    this.persistentCommandOps = new Map();
    this.nextPersistentCommandOrder = 0;
    this.commandLog = [];

    this.boundHandleClick = (event) => this.handleClick(event);
    this.boundHandleSubmit = (event) => this.handleSubmit(event);
    this.delegationAttached = false;
  }

  connect() {
    if (!this.url) {
      this.setError("missing_url");
      return;
    }

    this.closedManually = false;
    this.clearReconnectTimer();
    this.setState(this.socket ? "reconnecting" : "connecting");
    this.attachEventDelegation();
    this.openSocket();
  }

  disconnect(reason = "client_disconnect") {
    this.closedManually = true;
    this.clearReconnectTimer();

    if (this.socket && this.socket.readyState === 1) {
      this.sendFrame({ tag: "failure", ref: "", reason });
    }

    if (this.socket && typeof this.socket.close === "function") {
      this.socket.close();
    }

    this.socket = null;
    this.setState("closed");
    this.notifyHooks("disconnected");
  }

  pushEvent(name, payload = "{}") {
    const ref = String(this.nextEventRef);
    this.nextEventRef += 1;
    this.sendFrame({ tag: "event", ref, name, payload });
    this.commandLog.push(`push:${name}:${ref}`);
    return ref;
  }

  js() {
    return LightspeedJS.command();
  }

  concatCommands(first, second) {
    return LightspeedJS.concat(first, second);
  }

  composeCommands(commands) {
    return LightspeedJS.compose(commands);
  }

  executeJS(commandLike, options = {}) {
    const command = normalizeCommand(commandLike);
    const context = {
      element: options.element ?? null,
      dispatcher: options.dispatcher ?? options.element ?? null,
    };
    const labels = [];

    for (const operation of command.ops) {
      this.executeCommandOperation(operation, context);
      labels.push(this.commandOperationLabel(operation));
      this.persistCommandOperation(operation);
    }

    return labels;
  }

  openSocket() {
    const socket = this.socketFactory(this.url);
    this.socket = socket;

    socket.addEventListener("open", () => {
      if (this.socket !== socket) return;
      const wasReconnecting = this.state === "reconnecting";
      this.reconnectAttempts = 0;
      this.setState("live");
      this.sendFrame({
        tag: "hello",
        protocol: this.protocol,
        version: this.version,
      });
      if (wasReconnecting) {
        this.notifyHooks("reconnected");
      } else {
        this.syncHooks();
      }
    });

    socket.addEventListener("message", (event) => {
      if (this.socket !== socket) return;
      this.receiveFrame(event.data);
    });

    socket.addEventListener("error", () => {
      if (this.socket !== socket) return;
      this.setError("socket_error");
    });

    socket.addEventListener("close", () => {
      if (this.socket !== socket) return;
      this.socket = null;
      if (this.closedManually) {
        this.setState("closed");
        return;
      }
      this.notifyHooks("disconnected");
      this.scheduleReconnect();
    });
  }

  receiveFrame(payload) {
    let frame;

    try {
      frame = decodeFrame(payload);
    } catch (error) {
      const reason = `decode_failed:${error.message}`;
      this.setError(reason);
      this.sendFrame({ tag: "failure", ref: "", reason });
      return;
    }

    switch (frame.tag) {
      case "hello":
        this.handleHello(frame);
        break;
      case "diff":
        this.handleDiff(frame);
        break;
      case "event":
        this.handleServerEvent(frame);
        break;
      case "failure":
        this.setError(`server_failure:${frame.reason}`);
        break;
      case "ack":
        break;
      default:
        this.setError(`unsupported_frame:${frame.tag}`);
    }
  }

  handleHello(frame) {
    if (frame.protocol !== this.protocol) {
      this.setError(`unsupported_protocol:${frame.protocol}`);
      return;
    }

    if (frame.version !== this.version) {
      this.setError(`unsupported_version:${String(frame.version)}`);
    }
  }

  handleDiff(frame) {
    if (frame.ref === this.lastAppliedPatchRef) {
      this.sendFrame({ tag: "ack", ref: frame.ref });
      return;
    }

    try {
      this.applyPatchPayload(frame.payload ?? frame.html ?? "");
      this.lastAppliedPatchRef = frame.ref;
      this.sendFrame({ tag: "ack", ref: frame.ref });
      this.setState("live");
    } catch (error) {
      const reason = `patch_failed:${error.message}`;
      this.setError(reason);
      this.sendFrame({ tag: "failure", ref: frame.ref, reason });
    }
  }

  applyPatchPayload(payload) {
    if (payload.startsWith(`${PATCH_STREAM_TAG}|`)) {
      const stream = decodePatchStream(payload);
      this.applyPatchOperations(stream.patches);
      this.replayPersistentCommands();
      return;
    }

    this.applyPatch(payload);
    this.replayPersistentCommands();
  }

  applyPatch(html) {
    if (!this.root) {
      throw new Error("missing_root");
    }

    this.segmentState.set("#app", null);
    this.keyedState.set("#app", []);
    this.teardownHooks();
    this.root.innerHTML = html;
    this.syncHooks();
  }

  applyPatchOperations(operations) {
    for (const operation of operations) {
      this.applyPatchOperation(operation);
    }
  }

  applyPatchOperation(operation) {
    switch (operation.op) {
      case "replace":
        this.segmentState.delete(operation.target);
        this.keyedState.delete(operation.target);
        this.setTargetHtml(operation.target, operation.html);
        break;

      case "append": {
        this.segmentState.delete(operation.target);
        this.keyedState.delete(operation.target);
        const target = this.resolveTarget(operation.target);
        if (!target) throw new Error(`missing_target:${operation.target}`);
        this.setTargetHtml(operation.target, (target.innerHTML ?? "") + operation.html);
        break;
      }

      case "prepend": {
        this.segmentState.delete(operation.target);
        this.keyedState.delete(operation.target);
        const target = this.resolveTarget(operation.target);
        if (!target) throw new Error(`missing_target:${operation.target}`);
        this.setTargetHtml(operation.target, operation.html + (target.innerHTML ?? ""));
        break;
      }

      case "remove":
        this.segmentState.delete(operation.target);
        this.keyedState.delete(operation.target);
        this.setTargetHtml(operation.target, "");
        break;

      case "replace_segments": {
        const slots = new Map(
          operation.dynamicSlots.map((slot) => [slot.name, slot.value]),
        );
        this.segmentState.set(operation.target, {
          fingerprint: operation.fingerprint,
          staticHtml: operation.staticHtml,
          slots,
        });
        this.keyedState.delete(operation.target);
        this.setTargetHtml(
          operation.target,
          this.renderSegmentHtml(operation.staticHtml, slots),
        );
        break;
      }

      case "update_segments": {
        const state = this.segmentState.get(operation.target);
        if (!state) {
          throw new Error(`fingerprint_missing:${operation.target}`);
        }
        if (state.fingerprint !== operation.fingerprint) {
          throw new Error(
            `fingerprint_mismatch:${operation.target}:${state.fingerprint}:${operation.fingerprint}`,
          );
        }

        for (const slot of operation.dynamicSlots) {
          state.slots.set(slot.name, slot.value);
        }

        this.segmentState.set(operation.target, state);
        this.setTargetHtml(
          operation.target,
          this.renderSegmentHtml(state.staticHtml, state.slots),
        );
        break;
      }

      case "upsert_keyed": {
        this.segmentState.delete(operation.target);
        const current = this.keyedState.get(operation.target) ?? [];
        const next = [...current];
        const index = next.findIndex((entry) => entry.key === operation.key);
        const entry = { key: operation.key, html: operation.html };
        if (index >= 0) {
          next[index] = entry;
        } else {
          next.push(entry);
        }
        this.keyedState.set(operation.target, next);
        this.setTargetHtml(
          operation.target,
          next.map((node) => node.html).join(""),
        );
        break;
      }

      case "remove_keyed": {
        this.segmentState.delete(operation.target);
        const current = this.keyedState.get(operation.target) ?? [];
        const next = current.filter((entry) => entry.key !== operation.key);
        this.keyedState.set(operation.target, next);
        this.setTargetHtml(
          operation.target,
          next.map((node) => node.html).join(""),
        );
        break;
      }

      case "reorder_keyed": {
        this.segmentState.delete(operation.target);
        const current = this.keyedState.get(operation.target) ?? [];
        const byKey = new Map(current.map((entry) => [entry.key, entry]));
        const used = new Set();
        const next = [];

        for (const key of operation.keys) {
          const entry = byKey.get(key);
          if (!entry) continue;
          next.push(entry);
          used.add(key);
        }

        for (const entry of current) {
          if (used.has(entry.key)) continue;
          next.push(entry);
        }

        this.keyedState.set(operation.target, next);
        this.setTargetHtml(
          operation.target,
          next.map((node) => node.html).join(""),
        );
        break;
      }

      default:
        throw new Error(`unsupported_patch_op:${String(operation.op)}`);
    }
  }

  resolveTarget(target) {
    if (!this.root) return null;
    if (target === "#app") return this.root;
    if (target === "[data-ls-root]") return this.root;

    if (typeof this.root.matches === "function" && this.root.matches(target)) {
      return this.root;
    }

    if (typeof this.root.querySelector === "function") {
      const nested = this.root.querySelector(target);
      if (nested) return nested;
    }

    if (this.document && typeof this.document.querySelector === "function") {
      return this.document.querySelector(target);
    }

    return null;
  }

  setTargetHtml(targetSelector, html) {
    const target = this.resolveTarget(targetSelector);
    if (!target) {
      throw new Error(`missing_target:${targetSelector}`);
    }

    if (target === this.root) {
      this.teardownHooks();
      target.innerHTML = html;
      this.syncHooks();
      return;
    }

    target.innerHTML = html;
  }

  renderSegmentHtml(staticHtml, slots) {
    let rendered = staticHtml;

    for (const [name, value] of slots.entries()) {
      const slotPattern = new RegExp(
        `(<[^>]*data-ls-slot="${escapeRegExp(name)}"[^>]*>)([\\s\\S]*?)(<\\/[^>]+>)`,
        "g",
      );

      rendered = rendered.replace(slotPattern, `$1${escapeHtml(value)}$3`);
    }

    return rendered;
  }

  attachEventDelegation() {
    if (!this.root || this.delegationAttached) return;
    this.root.addEventListener("click", this.boundHandleClick);
    this.root.addEventListener("submit", this.boundHandleSubmit);
    this.delegationAttached = true;
  }

  handleClick(event) {
    const element = event?.target?.closest?.(EVENT_SELECTOR);
    if (!element || !element.dataset?.lsEvent) return;
    if (typeof event.preventDefault === "function") {
      event.preventDefault();
    }
    const payload = element.dataset.lsPayload ?? "{}";
    this.pushEvent(element.dataset.lsEvent, payload);
  }

  handleSubmit(event) {
    const element = event?.target?.closest?.(EVENT_SELECTOR);
    if (!element || !element.dataset?.lsEvent) return;
    if (typeof event.preventDefault === "function") {
      event.preventDefault();
    }
    const payload = this.serializeFormPayload(element);
    this.pushEvent(element.dataset.lsEvent, payload);
  }

  serializeFormPayload(form) {
    if (typeof form.dataset?.lsPayload === "string") {
      return form.dataset.lsPayload;
    }

    if (Array.isArray(form.__lsFormEntries)) {
      const object = {};
      for (const [key, value] of form.__lsFormEntries) {
        object[key] = value;
      }
      return JSON.stringify(object);
    }

    if (typeof FormData === "function") {
      try {
        const object = {};
        const data = new FormData(form);
        for (const [key, value] of data.entries()) {
          object[key] = value;
        }
        return JSON.stringify(object);
      } catch (_error) {
        return "{}";
      }
    }

    return "{}";
  }

  sendFrame(frame) {
    if (!this.socket || this.socket.readyState !== 1) return;
    this.socket.send(encodeFrame(frame));
  }

  scheduleReconnect() {
    if (!this.reconnect.enabled) {
      this.setState("closed");
      return;
    }

    this.setState("reconnecting");

    const exponent = Math.max(this.reconnectAttempts, 0);
    const delay = Math.min(
      this.reconnect.maxDelayMs,
      this.reconnect.baseDelayMs * 2 ** exponent,
    );

    this.reconnectAttempts += 1;
    this.reconnectHandle = this.timer.setTimeout(() => {
      this.reconnectHandle = null;
      this.openSocket();
    }, delay);
  }

  clearReconnectTimer() {
    if (!this.reconnectHandle) return;
    this.timer.clearTimeout(this.reconnectHandle);
    this.reconnectHandle = null;
  }

  setState(state) {
    this.state = state;
    if (this.root?.dataset) {
      this.root.dataset.lsClientState = state;
      this.root.dataset.lsLoading = state === "connecting" || state === "reconnecting"
        ? "true"
        : "false";
      if (state !== "error") {
        delete this.root.dataset.lsError;
      }
    }
    dispatchCustomEvent(this.root, "lightspeed:state", { state });
  }

  setError(reason) {
    if (this.root?.dataset) {
      this.root.dataset.lsError = reason;
    }
    this.setState("error");
    dispatchCustomEvent(this.root, "lightspeed:error", { reason });
  }

  syncHooks() {
    if (!this.root) return;

    const next = new Map();
    const elements = this.collectHookElements();

    for (const element of elements) {
      const hookName = element?.dataset?.lsHook;
      if (!hookName) continue;
      const hook = this.hooks[hookName];
      if (!hook) continue;

      const existing = this.hookInstances.get(element);
      const context = this.buildHookContext(element, hookName);

      if (existing && typeof hook.updated === "function") {
        hook.updated(context);
      } else if (typeof hook.mounted === "function") {
        hook.mounted(context);
      }

      next.set(element, { hookName, hook });
    }

    for (const [element, entry] of this.hookInstances.entries()) {
      if (next.has(element)) continue;
      if (typeof entry.hook.destroyed === "function") {
        entry.hook.destroyed(this.buildHookContext(element, entry.hookName));
      }
    }

    this.hookInstances = next;
  }

  teardownHooks() {
    for (const [element, entry] of this.hookInstances.entries()) {
      if (typeof entry.hook.destroyed === "function") {
        entry.hook.destroyed(this.buildHookContext(element, entry.hookName));
      }
      this.hookEventHandlers.delete(element);
    }
    this.hookInstances = new Map();
  }

  notifyHooks(kind) {
    for (const [element, entry] of this.hookInstances.entries()) {
      const callback = entry.hook[kind];
      if (typeof callback !== "function") continue;
      callback(this.buildHookContext(element, entry.hookName));
    }
  }

  handleServerEvent(frame) {
    let payload = {};

    try {
      payload = frame.payload === "" ? {} : JSON.parse(frame.payload);
    } catch (_error) {
      payload = { raw: frame.payload };
    }

    dispatchCustomEvent(this.root, `phx:${frame.name}`, payload);

    for (const [element, handlersByEvent] of this.hookEventHandlers.entries()) {
      const handlers = handlersByEvent.get(frame.name) ?? [];
      for (const handler of handlers) {
        handler(payload);
      }

      if (handlers.length > 0) {
        dispatchCustomEvent(element, `phx:${frame.name}`, payload);
      }
    }
  }

  collectHookElements() {
    const elements = [];
    if (this.root?.dataset?.lsHook) {
      elements.push(this.root);
    }

    if (typeof this.root?.querySelectorAll === "function") {
      const list = this.root.querySelectorAll(HOOK_SELECTOR);
      for (const element of list) {
        elements.push(element);
      }
    }

    return elements;
  }

  buildHookContext(element, hookName) {
    const hookHandlers = this.ensureHookHandlers(element);

    return {
      client: this,
      element,
      hookName,
      pushEvent: (name, payload) => this.pushEvent(name, payload),
      pushEventTo: (to, name, payload) => this.pushEventTo(to, name, payload),
      handleEvent: (name, callback) => {
        if (!hookHandlers.has(name)) {
          hookHandlers.set(name, []);
        }
        hookHandlers.get(name).push(callback);
      },
      dispatch: (event, detail = {}, options = {}) => this.executeJS(
        this.js().dispatch(event, { detail, ...options }),
        { element, dispatcher: element },
      ),
      js: () => ({
        exec: (commandLike, options = {}) =>
          this.executeJS(commandLike, { element, dispatcher: element, ...options }),
      }),
      state: this.state,
    };
  }

  pushEventTo(target, name, payload = {}) {
    const value = payload === null || payload === undefined ? {} : payload;
    const body = {
      target,
      value,
    };
    return this.pushEvent(name, normalizePayload(body));
  }

  ensureHookHandlers(element) {
    if (!this.hookEventHandlers.has(element)) {
      this.hookEventHandlers.set(element, new Map());
    }
    return this.hookEventHandlers.get(element);
  }

  commandOperationLabel(operation) {
    switch (operation.kind) {
      case "push":
        return `push:${operation.event}`;
      case "patch":
        return `patch:${operation.href}`;
      case "navigate":
        return `navigate:${operation.href}`;
      default:
        return operation.kind;
    }
  }

  persistCommandOperation(operation) {
    if (operation.persist !== true) return;
    if (!this.isPersistableOperation(operation)) return;

    const key = `${operation.kind}:${operation.to ?? "__self__"}:${stableStringify(operation)}`;
    this.persistentCommandOps.set(key, {
      order: this.nextPersistentCommandOrder,
      operation,
    });
    this.nextPersistentCommandOrder += 1;
  }

  replayPersistentCommands() {
    if (this.persistentCommandOps.size === 0) return;
    const entries = [...this.persistentCommandOps.values()]
      .sort((left, right) => left.order - right.order);

    for (const entry of entries) {
      this.executeCommandOperation(entry.operation, { replay: true, element: null, dispatcher: null });
    }
  }

  isPersistableOperation(operation) {
    switch (operation.kind) {
      case "add_class":
      case "remove_class":
      case "toggle_class":
      case "set_attr":
      case "remove_attr":
      case "show":
      case "hide":
      case "transition":
        return true;
      default:
        return false;
    }
  }

  executeCommandOperation(operation, context) {
    switch (operation.kind) {
      case "add_class":
        this.applyClasses(operation, context, "add");
        break;

      case "remove_class":
        this.applyClasses(operation, context, "remove");
        break;

      case "toggle_class":
        this.applyClasses(operation, context, "toggle");
        break;

      case "set_attr":
        this.applyAttributes(operation, context, "set");
        break;

      case "remove_attr":
        this.applyAttributes(operation, context, "remove");
        break;

      case "show":
        this.applyVisibility(operation, context, "show");
        break;

      case "hide":
        this.applyVisibility(operation, context, "hide");
        break;

      case "toggle":
        this.applyVisibility(operation, context, "toggle");
        break;

      case "transition":
        this.applyTransition(operation, context);
        break;

      case "dispatch":
        this.dispatchCommandEvent(operation, context);
        break;

      case "push":
        this.pushEvent(operation.event, normalizePayload(
          this.pushCommandPayload(operation),
        ));
        break;

      case "patch":
        this.pushEvent(COMMAND_PATCH_EVENT, normalizePayload({
          to: operation.href,
          replace: operation.replace === true,
        }));
        break;

      case "navigate":
        this.pushEvent(COMMAND_NAVIGATE_EVENT, normalizePayload({
          to: operation.href,
          replace: operation.replace === true,
        }));
        break;

      default:
        throw new Error(`unsupported_command:${String(operation.kind)}`);
    }
  }

  resolveCommandTargets(operation, context = {}) {
    if (!operation.to) {
      if (context.element) return [context.element];
      if (this.root) return [this.root];
      return [];
    }

    const found = [];

    const pushUnique = (element) => {
      if (!element) return;
      if (found.includes(element)) return;
      found.push(element);
    };

    if (this.root) {
      if (typeof this.root.matches === "function" && this.root.matches(operation.to)) {
        pushUnique(this.root);
      }

      if (typeof this.root.querySelectorAll === "function") {
        const nested = this.root.querySelectorAll(operation.to);
        for (const element of nested) {
          pushUnique(element);
        }
      }
    }

    if (this.document && typeof this.document.querySelectorAll === "function") {
      const global = this.document.querySelectorAll(operation.to);
      for (const element of global) {
        pushUnique(element);
      }
    } else if (this.document && typeof this.document.querySelector === "function") {
      pushUnique(this.document.querySelector(operation.to));
    }

    return found;
  }

  applyClasses(operation, context, mode) {
    const targets = this.resolveCommandTargets(operation, context);

    for (const element of targets) {
      for (const name of operation.classes) {
        this.mutateClass(element, name, mode);
      }
    }

    if (operation.transition) {
      this.applyTransition({
        kind: "transition",
        to: operation.to,
        transition: operation.transition,
        time: operation.time,
      }, context);
    }
  }

  mutateClass(element, className, mode) {
    if (!element) return;

    if (element.classList) {
      switch (mode) {
        case "add":
          element.classList.add(className);
          return;
        case "remove":
          element.classList.remove(className);
          return;
        case "toggle":
          element.classList.toggle(className);
          return;
        default:
          return;
      }
    }

    const classes = new Set(splitClassNames(element.className ?? ""));
    switch (mode) {
      case "add":
        classes.add(className);
        break;
      case "remove":
        classes.delete(className);
        break;
      case "toggle":
        if (classes.has(className)) {
          classes.delete(className);
        } else {
          classes.add(className);
        }
        break;
      default:
        break;
    }
    element.className = [...classes].join(" ");
  }

  applyAttributes(operation, context, mode) {
    const targets = this.resolveCommandTargets(operation, context);

    for (const element of targets) {
      if (mode === "set") {
        if (typeof element.setAttribute === "function") {
          element.setAttribute(operation.name, operation.value);
        } else {
          element[operation.name] = operation.value;
        }
      } else if (typeof element.removeAttribute === "function") {
        element.removeAttribute(operation.name);
      } else {
        delete element[operation.name];
      }
    }
  }

  applyVisibility(operation, context, mode) {
    const targets = this.resolveCommandTargets(operation, context);

    for (const element of targets) {
      if (!element.style) {
        element.style = {};
      }

      if (mode === "show") {
        element.style.display = operation.display ?? COMMAND_DEFAULT_DISPLAY;
      } else if (mode === "hide") {
        element.style.display = "none";
      } else {
        const hidden = element.style.display === "none";
        element.style.display = hidden
          ? operation.display ?? COMMAND_DEFAULT_DISPLAY
          : "none";
      }
    }

    const transition = mode === "toggle"
      ? (targets.some((element) => element.style?.display === "none")
        ? operation.outTransition
        : operation.inTransition)
      : operation.transition;

    if (transition) {
      this.applyTransition({
        kind: "transition",
        to: operation.to,
        transition,
        time: operation.time,
      }, context);
    }
  }

  applyTransition(operation, context) {
    const targets = this.resolveCommandTargets(operation, context);
    const classes = splitClassNames(operation.transition);

    for (const element of targets) {
      for (const name of classes) {
        this.mutateClass(element, name, "add");
      }

      if (element.dataset) {
        element.dataset.lsLastTransition = classes.join(" ");
      }
    }
  }

  dispatchCommandEvent(operation, context) {
    const targets = this.resolveCommandTargets(operation, context);
    const dispatcher = context.dispatcher ?? context.element ?? this.root;

    for (const element of targets) {
      const detail = {
        ...(operation.detail ?? {}),
        dispatcher,
      };

      if (typeof CustomEvent === "function" && typeof element.dispatchEvent === "function") {
        element.dispatchEvent(new CustomEvent(operation.event, {
          detail,
          bubbles: operation.bubbles !== false,
        }));
      } else if (typeof element.dispatchEvent === "function") {
        element.dispatchEvent({
          type: operation.event,
          detail,
          bubbles: operation.bubbles !== false,
        });
      }
    }
  }

  pushCommandPayload(operation) {
    const hasPushOptions =
      operation.target !== null
      || operation.loading !== null
      || operation.pageLoading === true;

    if (!hasPushOptions) {
      return operation.value;
    }

    return {
      value: operation.value,
      target: operation.target,
      loading: operation.loading,
      page_loading: operation.pageLoading === true,
    };
  }
}

function mountLightspeed(options = {}) {
  const client = new LightspeedClient(options);
  client.connect();
  return client;
}

const LightspeedRuntime = {
  encodeFrame,
  decodeFrame,
  encodePatchStream,
  decodePatchStream,
  LightspeedJS,
  LightspeedClient,
  mountLightspeed,
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = LightspeedRuntime;
}

if (typeof globalThis !== "undefined") {
  globalThis.LightspeedRuntime = LightspeedRuntime;
}
