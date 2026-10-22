# Document preview tabs

On macOS, files open as read-only tabs in the existing notes/browser asset pane.
This includes composer uploads, sent attachments, file handbacks from agents,
Library files/photos, and Saved Artifacts. Client Library downloads use the same
pane. Web links keep their existing behavior.

The preview uses the macOS Quick Look renderer. Common documents, spreadsheets,
PDFs, images, and other formats supported by the Mac's installed preview providers
can be inspected inline. Quick Look provides a file summary when it cannot render
a format; the toolbar always offers **Open in default app** and **Reveal in Finder**.
Editing remains in the external application. **Reload preview** refreshes the view.
Spreadsheet formulas are not recalculated by Woven Matter; Quick Look may rely on
the workbook's saved calculation results. Preview providers retain their native
document appearance and scrolling controls.

Up to eight document tabs can coexist with the existing note/browser limits.
Opening an existing file selects its tab. Hiding the pane and switching chats keep
those tabs; closing a tab releases its preview, without deleting the retained file.
Tabs are window-session state and are not restored after app restart.

Generated handbacks have **Preview [filename]** buttons beneath the response.
These resolve the original message/file identity through Library. They never read
a path directly from agent text. The file must have been retained by Library; a
pending, unavailable, removed, or inaccessible item reports an error. Existing
Library activation/history and retention limits still apply. Files already indexed
in Library remain available there even when they came from an older conversation.
Opening a preview does not add document contents to a new agent prompt.

## Review and testing

- Upload a PDF, DOCX, XLSX, CSV, and image. Click the composer attachment and the
  sent attachment; verify the preview opens beside the conversation.
- Open a generated file's Preview button, the same file in Library, and a saved
  artifact. Confirm the expected filename and contents, including in client mode.
- Mix document, note, and browser tabs. Reopen a file, switch chats, hide/reveal the
  pane, move it left/right, focus it, resize narrow/wide, and close the active tab.
- Open eight documents, then a ninth. Confirm the capacity message; an existing
  document must remain selectable at capacity.
- Check an unsupported format and a removed opening copy. Verify the fallback,
  reload, external-open action, and error messages.
- Check both themes and keyboard/accessibility labels for the document controls.

Native previews vary by installed macOS preview providers. Manual acceptance of
representative real-world workbooks and documents remains part of PR testing.
