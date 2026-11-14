import { setGlobalOptions } from "firebase-functions/v2";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { ENABLE_TEST_ERROR, ENFORCE_APP_CHECK, MAX_INSTANCES, MIN_INSTANCES, REGION } from "./config";
import { reportError } from "./sentry";

setGlobalOptions({
  region: REGION,
  minInstances: MIN_INSTANCES,
  maxInstances: MAX_INSTANCES,
});

/**
 * Prompt 1: proves Sentry works from Cloud Functions. Throws on purpose,
 * reports the error (scrubbed) and returns an "internal" error to the app.
 * Disabled in prod via ENABLE_TEST_ERROR.
 */
export const debugTestError = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, async () => {
  if (!ENABLE_TEST_ERROR.value()) {
    throw new HttpsError("permission-denied", "Test errors are disabled in this environment.");
  }
  const error = new Error("Sentry test error from Cloud Functions (Prompt 1)");
  logger.warn("debugTestError called; reporting a test error to Sentry");
  await reportError(error);
  throw new HttpsError("internal", "Test error raised and reported.");
});

// Sign-up and sign-in with a WhatsApp code (Prompt 2: F1, F44).
export { acceptConsents, confirmEmail, requestCode, verifyCode } from "./auth/callables";

// Identity verification, children and the automated ID check (Prompt 3: F2, F3, F18).
export {
  decideVerification,
  listVerificationQueue,
  openVerificationCase,
  purgeVerificationImagesDaily,
  removeChild,
  submitVerification,
  withdrawVerification,
} from "./verification/callables";

// Admin web panel (Prompt 4: F14). Verification review uses the functions above.
export {
  adminApproveSchool,
  adminCreateAdmin,
  adminGetReport,
  adminGetSchool,
  adminGetUser,
  adminLiftDrivingPause,
  adminListAdmins,
  adminListAuditLog,
  adminListReports,
  adminListSchools,
  adminMergeSchool,
  adminModerateUser,
  adminPing,
  adminRemoveChatMember,
  adminRemoveChatMessage,
  adminResolveReport,
  adminSaveArea,
  adminSaveSchool,
  adminSearchUsers,
  adminSetAdminDisabled,
} from "./admin_panel/callables";

// Parents: WhatsApp-code sign-in (custom token) only. Admins: email and
// password for allow-listed admin accounts, then a TOTP second factor.
export { blockClientSignUps, blockNonCodeSignIn, blockSignInEmails } from "./auth/blocking";

// Schools list (Prompt 4B: F4): "Other" schools, the search key and the index sync.
export { addOtherSchool, getSchoolSearchKey, syncSchoolToSearch } from "./schools/callables";

// Home, schools and maps (Prompt 5: F21 to F24, F40): home pin, address
// search, map settings, driving schools, nearby parents and the public
// (rounded) record kept in step with accounts and children.
export {
  placeDetails,
  placesAutocomplete,
  searchNearbyParents,
  setDrivingSchools,
  setHomeLocation,
  syncMapOnChildWrite,
  syncMapOnUserWrite,
  updateMapSettings,
} from "./maps/callables";

// Carpools (Prompt 6: F5, F6, F25, F26, F31, F32, F36, F39): create, search,
// join requests, driver consent, pickup point sharing, invite links and
// "looking for a carpool" posts. Every membership and status write is here.
export {
  cancelJoinRequest,
  createCarpool,
  createCarpoolInvite,
  decideJoinRequest,
  deleteCarpoolWanted,
  leaveCarpool,
  listCarpoolWanted,
  openCarpoolInvite,
  requestToJoinCarpool,
  saveCarpoolWanted,
  searchCarpools,
  setDriverConsent,
  setPickupSharing,
} from "./carpools/callables";

// Schedule (Prompt 7: F7, F11, F27, F28, F30, F37): rotation, driver
// confirmation, swaps, absences, exceptions and the drive balance. Every
// schedule write is here; scheduleTick handles cut-offs (Africa/Cairo).
export {
  cancelSwap,
  confirmRun,
  deleteScheduleException,
  planScheduleWeek,
  requestSwap,
  saveScheduleException,
  scheduleTick,
  setChildAbsent,
  setDrivingDays,
  takeRun,
} from "./schedule/callables";

// Notifications (Prompt 8: F12, F23): ONE sender (sendNotification) for
// every event in notificationEvents, the reminder and alarm tick, phones
// and settings.
export {
  notificationTick,
  registerPushDevice,
  sendNotification,
  setWhatsAppNotifications,
  unregisterPushDevice,
  updateNotificationSettings,
} from "./notifications/callables";

// Chat (Prompt 9: F8, F9, F10, F13) on Stream Chat: tokens for verified,
// non-suspended parents only; every channel and member decided here;
// requests, blocks, mutes and reports; the Stream webhook feeds chat push
// into the one notification sender; daily retention.
export {
  answerChatRequest,
  blockChatUser,
  cancelChatRequest,
  chatRetentionDaily,
  chatWebhook,
  getChatToken,
  reportChat,
  sendChatRequest,
  setChatMute,
  syncChatOnCarpoolMemberWrite,
  syncChatOnLocationWrite,
  syncChatOnUserWrite,
  syncMyChats,
  unblockChatUser,
  updateChatSettings,
} from "./chat/callables";
// Trips and live location (Prompt 10: F15, F16, F20, F29, F33, F34, F35,
// F38, F41): start a run (selfie check first on some runs), live points from
// the phone's location plugin, stops, quick buttons, emergency, handover
// list, emergency contact, today's driver card, and the minute tick
// (location stopped, child not confirmed, deleting live points).
export {
  confirmHandover,
  endTrip,
  endTripsOnUserWrite,
  getHandoverAdults,
  getTodayDriverCards,
  prepareTrip,
  quickMessage,
  saveHandoverAdults,
  setEmergencyContact,
  startTrip,
  stopMyTrips,
  submitSelfieCheck,
  tripAction,
  tripEmergency,
  tripLocation,
  tripTick,
} from "./trips/callables";

// Wallet (Prompt 11B: F43, F44, F25) through ONE WalletProvider (the
// CBE-licensed partner; a fake with test money until the contract). Every
// transfer runs here: verified parents, open wallets, limits from server
// settings, one transfer per request ID, append-only records, a
// reconciliation job for unknown outcomes. Admins: read-only log, freeze,
// alerts; never money movement.
export {
  addMoney,
  adminGetWallet,
  adminListTransfers,
  adminListWalletAlerts,
  adminResolveWalletAlert,
  adminSetWalletFrozen,
  getTransfer,
  getWallet,
  listWalletHistory,
  lookupParentId,
  openWallet,
  reportTransfer,
  sendMoney,
  walletContacts,
  walletReconcile,
  withdrawMoney,
} from "./wallet/callables";
