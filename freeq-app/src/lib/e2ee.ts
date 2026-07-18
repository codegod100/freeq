/** Re-export E2EE from @freeq/sdk. */
export {
  isEncrypted,
  isENC1,
  isE2eeReady,
  hasSession,
  hasChannelKey,
  getIdentityPublicKey,
  getSafetyNumber,
  initialize,
  shutdown,
  setChannelKey,
  removeChannelKey,
  encryptMessage,
  decryptMessage,
  encryptChannel,
  decryptChannel,
  fetchPreKeyBundle,
} from '@freeq/sdk/e2ee';
