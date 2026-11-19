// The format tags this server writes on native history records (Swift
// `NativeRecordFormat` in shared/ holds the same names). A tag says what a
// record's bytes are; it is stored with the record and synced as it is, and
// every reader knows these names only. Nothing on this server compares a tag:
// it writes records and passes stored ones on.
export const nativeRecordFormats = Object.freeze({
  // A chained activity: `{activity}`, complete, or a suffix that names the
  // record before it in `previousDetailsRecordID`.
  chainedActivity: 'wovenmatter.activity.chained',
  // One native harness update, as the JSON the harness sent.
  nativeUpdate: 'woven-native-update',
})
